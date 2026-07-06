-- Byeharu — TRADE-FLEET-0C: re-anchor first-ship idempotency on "zero ships" (UNIQUE still retained).
--
-- Step 6a of the multi-ship structural core (§1a). Both commission writers stop relying on the
-- row-level `on conflict (player_id) do nothing` serialization and instead serialize on
-- "player currently has zero ships". `player_id UNIQUE` is DELIBERATELY RETAINED this commit and
-- dropped in the very next tiny commit — so the writers are validated to work correctly WITH or
-- WITHOUT the unique index at every commit (no broken intermediate state).
--
-- ── DESIGN DECISION (planner authority — grounded in §1a) ────────────────────────────────────────
-- Dropping `player_id UNIQUE` (next commit) removes the row-level serialization that
-- `on conflict (player_id) do nothing` relied on. First-ship creation is therefore re-anchored on
-- an equivalent race-safe primitive: a TRANSACTION-SCOPED ADVISORY LOCK keyed on the player
-- (`pg_advisory_xact_lock(hashtext('main_ship_commission'), hashtext(p_player::text))`) serializes
-- concurrent first-ship claims per player, followed by an explicit zero-ship existence check, then
-- the insert. This preserves exactly the graceful "never create a 2nd ship implicitly" guarantee
-- the unique index gave, writes no other system's table, and is scoped to the commission path only.
--   • It is DISTINCT from and does NOT alter the movement lock substrate: `mainship_space_lock_context`
--     stays per-ship with no advisory/player lock (§2.5). The advisory lock here is a commission-only
--     serialization primitive inside the Main-Ship writer.
--   • Multi-ship stays IMPOSSIBLE until the explicit add-ship RPC lands (later step) — dark. Each
--     writer is guarded to zero-ship, so no implicit path can ever create a 2nd ship.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): both writers stay Main-Ship-owned. The advisory lock introduces no
-- table writer and no cycle. ACLs are preserved by `create or replace` (no grant/revoke here):
-- ensure_main_ship_for_player → service_role, port_entry_commission_writer → service_role. The
-- PORT-ENTRY-1 production verifier stays FROZEN at 0072 (its md5 pins derive from the unchanged 0072
-- file); this migration touches NO verifier file. commission_first_main_ship / normalize_main_ship_dock
-- are NOT redefined — commission_first_main_ship's pre-check + created-flag interpretation still work.

-- ── A. ensure_main_ship_for_player — 0077 body; idempotency reframed to advisory-lock + zero-ship guard.
create or replace function public.ensure_main_ship_for_player(p_player uuid)
returns public.main_ship_instances
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship public.main_ship_instances%rowtype;
begin
  -- Race-safe first-ship serialization per player (replaces the `on conflict (player_id)` guard so it is
  -- correct with OR without the player_id UNIQUE index): hold the per-player commission lock, then create
  -- ONLY if the player has zero ships. Never creates a 2nd ship implicitly.
  perform pg_advisory_xact_lock(hashtext('main_ship_commission'), hashtext(p_player::text));
  if not exists (select 1 from main_ship_instances where player_id = p_player) then
    insert into main_ship_instances
      (player_id, hull_type_id, hp, max_hp, cargo_capacity, cargo_capacity_m3, support_capacity, captain_slots, module_slots)
    select p_player, h.hull_type_id, h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_cargo_capacity_m3,
           h.base_support_capacity, h.base_captain_slots, h.base_module_slots
      from main_ship_hull_types h
      where h.hull_type_id = 'starter_frigate';
  end if;

  select * into v_ship from main_ship_instances where player_id = p_player;
  return v_ship;
end;
$$;

-- ── B. port_entry_commission_writer — 0077 body; Phase-A idempotency reframed identically.
create or replace function public.port_entry_commission_writer(p_player uuid)
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
  -- ── Phase A: create-or-detect the ship. Race-safe per-player serialization via the commission advisory
  --    lock (replaces `on conflict (player_id)` so it is correct with OR without the player_id UNIQUE index):
  --    hold the lock, and if the player already has a ship, return created=false writing NOTHING — the caller
  --    re-classifies the existing state. Otherwise INSERT the ship DIRECTLY in canonical at_location shape
  --    (status='stationary', spatial_state='at_location', x/y NULL) so there is never a committed intermediate
  --    bare home/legacy_home row. Never creates a 2nd ship implicitly.
  perform pg_advisory_xact_lock(hashtext('main_ship_commission'), hashtext(p_player::text));
  if exists (select 1 from public.main_ship_instances where player_id = p_player) then
    return jsonb_build_object('created', false);     -- ship already existed; no write performed
  end if;

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
