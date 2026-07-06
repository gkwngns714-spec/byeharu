-- Byeharu — TRADE-FLEET-0C: explicit, DARK, cap-guarded ADDITIONAL-ship commissioning (§1a–b, §2.5).
--
-- Adds the sole surface through which a player obtains a 2nd+ main ship — a deliberate, explicit,
-- authenticated action, structurally distinct from the first-ship path. The first-ship dock-build
-- logic is EXTRACTED into a shared private core (port_entry_commission_build) so there is no
-- duplicated dock logic; the new caller justifies the extraction in this same commit.
--
-- ── DESIGN DECISIONS (planner authority) ─────────────────────────────────────────────────────────
-- 1) DOCK PORT FOR ADDITIONAL SHIPS = the canonical commission port (Haven Reach), identical to
--    first ships. This refines §1(a)'s "current port": with cap=3 and no server-side "selected ship"
--    concept yet, "current port" is ambiguous across multiple ships, whereas commissioning every ship
--    at the fixed spawn port is DETERMINISTIC, reuses the existing dock-build logic verbatim, and
--    fully suffices to prove N-ship coexistence (ships then move apart via the converted per-ship
--    commands). Current-port resolution is a future refinement.
-- 2) NEW CAPABILITY SHIPS DARK + SERVER-REJECTED via a new OFF flag. commission_additional_main_ship()
--    checks a NEW game_config boolean `mainship_additional_commission_enabled` (default FALSE) and
--    returns a rejection reason when false — the server refuses to create a 2nd ship until a HUMAN
--    gate flips the flag. It is NOT set true here. The N-ship coexistence proof enables the flag only
--    inside the ephemeral test DB (later verifier step); production stays false.
-- 3) PER-PLAYER SHIP CAP = 3, stored as game_config.max_main_ships_per_player (§1b), enforced
--    server-side UNDER the commission advisory lock.
--
-- The PORT-ENTRY-1 production verifier stays FROZEN at 0072 (its md5 pins derive from the unchanged
-- 0072 file); this migration touches NO verifier file. The post-0C surface (new signatures,
-- commission_additional_main_ship, per-ship idempotency, the §2.7 eight properties) is proven by the
-- forthcoming TRADE-FLEET verifier. commission_first_main_ship / normalize_main_ship_dock are NOT
-- redefined. No movement/dock command signature is converted here (§2.5 conversion is the next slice).
-- No credit debit (the wallet arrives in TRADE-MARKET-1). No flag is set true.

-- ── A. Shared private dock-build core (service_role only). Extracted VERBATIM from the 0078
--    port_entry_commission_writer body, FROM the ship insert onward: it owns NO advisory lock and NO
--    zero-ship guard — every caller acquires the per-player lock and performs its own existence/cap
--    check before calling build. Build inserts UNCONDITIONALLY (no on-conflict) at Haven Reach.
create or replace function public.port_entry_commission_build(p_player uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_haven  constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  v_ship   uuid;
  v_zone   uuid;
  v_sector uuid;
  v_base   uuid;
  v_fleet  uuid;
begin
  -- Insert the ship DIRECTLY in canonical at_location shape (status='stationary',
  -- spatial_state='at_location', x/y NULL) so there is never a committed intermediate bare
  -- home/legacy_home row. No on-conflict: the CALLER already serialized + checked existence/cap.
  insert into public.main_ship_instances
    (player_id, hull_type_id, name, status, spatial_state, space_x, space_y,
     hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots)
  select p_player, h.hull_type_id, 'Byeharu', 'stationary', 'at_location', null, null,
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3, h.base_support_capacity, h.base_captain_slots, h.base_module_slots
    from public.main_ship_hull_types h
    where h.hull_type_id = 'starter_frigate'
  returning main_ship_id into v_ship;

  if v_ship is null then
    return jsonb_build_object('created', false);     -- hull row missing / nothing inserted
  end if;

  -- ── Phase B: lock the Haven Reach target hierarchy in the canonical order (sector → zone → location →
  --    anchor → docking service, FOR SHARE — conflicts with a status disable/retire) and REVALIDATE legality
  --    through the single canonical rule AFTER the locks are held, immediately before the fleet/presence write.
  select l.zone_id, z.sector_id into v_zone, v_sector
    from public.locations l join public.zones z on z.id = l.zone_id
    where l.id = c_haven;
  if v_zone is null then
    raise exception 'port_entry_commission: Haven Reach location not found';
  end if;
  perform 1 from public.sectors           where id = v_sector for share;
  perform 1 from public.zones             where id = v_zone   for share;
  perform 1 from public.locations         where id = c_haven  for share;
  perform 1 from public.space_anchors     where location_id = c_haven and kind = 'location' and status = 'active' for share;
  perform 1 from public.location_services where location_id = c_haven and service = 'docking' and status = 'active' for share;

  if (public.mainship_space_location_target_legal(c_haven)->>'ok')::boolean is not true then
    raise exception 'port_entry_commission: Haven Reach is not dockable';   -- rolls back the ship insert (atomic)
  end if;

  -- exactly ONE present/location fleet at Haven (origin_base_id = the player's base if one exists, else NULL —
  -- NOT a home-port assignment; current_base_id stays NULL, matching a docked OSN fleet).
  select id into v_base from public.bases where player_id = p_player and status = 'active' order by created_at limit 1;
  v_fleet := gen_random_uuid();
  insert into public.fleets
    (id, player_id, origin_base_id, status, location_mode, current_base_id,
     current_location_id, current_zone_id, current_sector_id, main_ship_id)
  values (v_fleet, p_player, v_base, 'present', 'location', null,
          c_haven, v_zone, v_sector, v_ship);

  -- exactly ONE active presence through the established presence path (activity 'none', like the dock writer).
  perform public.presence_create(p_player, v_fleet, v_sector, v_zone, c_haven, 'none');

  -- final coherence gate: the ship MUST now be canonical at_location, else abort the whole transaction.
  if (public.mainship_space_validate_context(v_ship)->>'state') is distinct from 'at_location' then
    raise exception 'port_entry_commission: post-write state is not canonical at_location';
  end if;

  return jsonb_build_object('created', true, 'main_ship_id', v_ship, 'location_id', c_haven);
end;
$$;

-- ── B. port_entry_commission_writer — rewritten to lock + zero-ship guard + delegate to build.
--    Behaviour-preserving vs 0078: lock + `if exists → created=false` + build == the 0078 writer
--    (build is exactly the 0078 body from the insert onward). First-ship semantics are identical.
create or replace function public.port_entry_commission_writer(p_player uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform pg_advisory_xact_lock(hashtext('main_ship_commission'), hashtext(p_player::text));
  if exists (select 1 from public.main_ship_instances where player_id = p_player) then
    return jsonb_build_object('created', false);     -- ship already existed; no write performed
  end if;
  return public.port_entry_commission_build(p_player);
end;
$$;

-- ── C. commission_additional_main_ship — authenticated, DARK, cap-guarded 2nd+ ship RPC.
create or replace function public.commission_additional_main_ship()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_cap    int;
  v_count  int;
  v_res    jsonb;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- DARK server-reject: refuse to create a 2nd ship until a HUMAN gate flips this flag (default false).
  if not public.cfg_bool('mainship_additional_commission_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'additional_commission_disabled');
  end if;

  -- Serialize per-player commission (same primitive as first-ship), then enforce the cap UNDER the lock.
  perform pg_advisory_xact_lock(hashtext('main_ship_commission'), hashtext(v_player::text));
  select coalesce((select (value #>> '{}')::int from public.game_config where key = 'max_main_ships_per_player'), 3)
    into v_cap;
  select count(*) into v_count from public.main_ship_instances where player_id = v_player;

  if v_count = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_first_ship');          -- must use the first-ship path
  elsif v_count >= v_cap then
    return jsonb_build_object('ok', false, 'reason', 'ship_cap_reached', 'cap', v_cap);
  end if;

  v_res := public.port_entry_commission_build(v_player);
  if (v_res->>'created')::boolean is true then
    return jsonb_build_object('ok', true, 'created', true, 'docked', true,
                              'main_ship_id', v_res->'main_ship_id', 'location_id', v_res->'location_id');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'commission_unavailable');
end;
$$;

-- ── D. Seeds (idempotent; bool-flag / numeric seed idiom of 0070 / 0003). New capability ships DARK.
insert into public.game_config (key, value, description) values
  ('mainship_additional_commission_enabled', 'false',
   'TRADE-FLEET-0C: server gate for commissioning ADDITIONAL (2nd+) main ships via '
   'commission_additional_main_ship(). OFF on live — dark until a human gate flips it.'),
  ('max_main_ships_per_player', '3',
   'TRADE-FLEET-0C: per-player cap on total main ships (§1b); enforced under the commission advisory lock.')
on conflict (key) do nothing;

-- ── E. ACLs — new functions default-grant to PUBLIC on create → explicit revoke/grant (0072 pattern).
--    The build core is service_role-only; the additional-ship RPC is authenticated. No other function's
--    ACL is touched (port_entry_commission_writer keeps its prior service_role grant via create-or-replace).
revoke execute on function public.port_entry_commission_build(uuid)   from public, anon, authenticated;
grant  execute on function public.port_entry_commission_build(uuid)   to service_role;
revoke execute on function public.commission_additional_main_ship()   from public, anon;
grant  execute on function public.commission_additional_main_ship()   to authenticated;
