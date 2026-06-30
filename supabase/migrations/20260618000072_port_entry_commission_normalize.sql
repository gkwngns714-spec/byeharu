-- PORT-ENTRY-1 — First-ship commissioning + same-location dock normalization (additive; Trading prerequisite).
--
-- Implements the PORT-ENTRY-1A corrected contract:
--   • port_entry_commission_writer(player)  — PRIVATE / service_role-only. Atomically creates a player's FIRST
--       main ship DIRECTLY into canonical at_location docked state at Haven Reach (the server-fixed spawn port).
--       NEVER calls ensure_main_ship_for_player; inserts the ship row directly in at_location shape, then creates
--       exactly one present/location fleet + one active presence, under the canonical two-phase lock protocol,
--       and asserts mainship_space_validate_context()='at_location' before returning. No home-port, no movement,
--       no receipt, no wallet/cargo/market/coordinate data.
--   • commission_first_main_ship()           — AUTHENTICATED, zero-arg, auth.uid()-scoped. Outcome matrix A–F.
--   • normalize_main_ship_dock()             — AUTHENTICATED, zero-arg, auth.uid()-scoped. legacy_present → at_location
--       IN PLACE at the ship's identical current eligible dock (no move, no resolve_origin, no new fleet/presence).
--
-- Spawn port is server-fixed to Haven Reach (b1a00001-…-000000000001). Clients supply NO player/ship/port id,
-- coordinates, status, or lifecycle data. NOTHING here touches the coordinate gate / readiness / UI dark state,
-- port-to-port travel, ports/anchors/services, Trading, world_sites, repair, or player_home_port. One additive
-- migration; no new table (the player_id UNIQUE is the business one-ship guard; replay safety is state-branch).

-- Haven Reach canonical starter-port id (fixed 0066 identity; the SOLE server-chosen spawn port).
-- (kept inline as a literal in each function via a constant declaration)

-- ── A. PRIVATE commissioning writer (service_role only) ──────────────────────────────────────────────────────
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
  -- ── Phase A: create-or-detect the ship. The player_id UNIQUE serializes concurrent first-claims; only the
  --    INSERTING caller (RETURNING non-null) proceeds to build the dock. A conflict (ship already exists)
  --    returns created=false and writes NOTHING — the caller re-classifies the existing state. The ship is
  --    inserted DIRECTLY in canonical at_location shape (status='stationary', spatial_state='at_location',
  --    x/y NULL) so there is never a committed intermediate bare home/legacy_home row.
  insert into public.main_ship_instances
    (player_id, hull_type_id, name, status, spatial_state, space_x, space_y,
     hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots)
  select p_player, h.hull_type_id, 'Byeharu', 'stationary', 'at_location', null, null,
         h.base_hp, h.base_hp, h.base_cargo_capacity, h.base_support_capacity, h.base_captain_slots, h.base_module_slots
    from public.main_ship_hull_types h
    where h.hull_type_id = 'starter_frigate'
  on conflict (player_id) do nothing
  returning main_ship_id into v_ship;

  if v_ship is null then
    return jsonb_build_object('created', false);     -- ship already existed; no write performed
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

-- ── B. AUTHENTICATED commission RPC (zero-arg; auth.uid() only) ──────────────────────────────────────────────
create or replace function public.commission_first_main_ship()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_ctx    jsonb;
  v_state  text;
  v_res    jsonb;
  v_dock   uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  -- (A) no ship yet → commission. The writer's insert-on-conflict is the race-safe serialization point.
  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
  if v_ship is null then
    begin
      v_res := public.port_entry_commission_writer(v_player);
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'commission_unavailable');   -- fail-closed, txn rolled back
    end;
    if (v_res->>'created')::boolean is true then
      return jsonb_build_object('ok', true, 'created', true, 'docked', true,
                                'location_id', v_res->'location_id');
    end if;
    -- writer reported created=false → another caller created it first; re-read and classify below.
    select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
    if v_ship is null then
      return jsonb_build_object('ok', false, 'reason', 'commission_unavailable');
    end if;
  end if;

  -- existing ship → classify exactly once via the canonical state machine.
  v_ctx   := public.mainship_space_validate_context(v_ship);
  v_state := case when (v_ctx->>'ok')::boolean is true then v_ctx->>'state' else null end;

  if v_state = 'at_location' then
    -- (B retry / C any-port) already provisioned & coherent → report the ACTUAL current dock; never relocate.
    select current_location_id into v_dock from public.fleets
      where main_ship_id = v_ship and status = 'present' and location_mode = 'location' limit 1;
    return jsonb_build_object('ok', true, 'created', false, 'already_provisioned', true,
                              'docked', true, 'location_id', to_jsonb(v_dock));
  elsif v_state = 'legacy_present' then
    return jsonb_build_object('ok', false, 'created', false, 'reason', 'needs_normalization');
  elsif v_state in ('home', 'legacy_home') then
    return jsonb_build_object('ok', false, 'created', false, 'reason', 'needs_compat_route');
  else
    -- (F) destroyed / in_space / in_transit / legacy_transit / contradictory / not-found → narrow safe reason.
    return jsonb_build_object('ok', false, 'created', false, 'reason', 'not_provisionable',
                              'state', coalesce(v_state, 'noncanonical'));
  end if;
end;
$$;

-- ── C. AUTHENTICATED same-location normalizer (zero-arg; legacy_present only) ────────────────────────────────
create or replace function public.normalize_main_ship_dock()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_lock   jsonb;
  v_ctx    jsonb;
  v_state  text;
  v_fleet  uuid;
  v_loc    uuid;
  v_zone   uuid;
  v_sector uuid;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
  if v_ship is null then
    return jsonb_build_object('ok', false, 'reason', 'no_ship');
  end if;

  -- Phase A: acquire the canonical OSN context locks (ship → relevant fleet → space movement → presence;
  -- legacy movement is an existence check only) BEFORE classifying, so a concurrent legacy-arrival serializes.
  v_lock := public.mainship_space_lock_context(v_ship);
  v_ctx  := public.mainship_space_validate_context(v_ship);
  v_state := case when (v_ctx->>'ok')::boolean is true then v_ctx->>'state' else null end;

  -- idempotent replay: already canonical → no write.
  if v_state = 'at_location' then
    return jsonb_build_object('ok', true, 'normalized', false);
  end if;

  -- ONLY a coherent legacy_present ship may normalize; everything else fails closed with no write.
  if v_state is distinct from 'legacy_present' then
    return jsonb_build_object('ok', false, 'normalized', false, 'reason', 'not_normalizable',
                              'state', coalesce(v_state, 'noncanonical'));
  end if;

  -- The current location comes ONLY from the coherent existing legacy-present fleet (locked above) — never the
  -- client. Read it from the single relevant fleet the lock-context resolved.
  v_fleet := (v_lock->>'relevant_fleet_id')::uuid;
  if v_fleet is null then
    return jsonb_build_object('ok', false, 'normalized', false, 'reason', 'not_normalizable');
  end if;
  select current_location_id, current_zone_id, current_sector_id into v_loc, v_zone, v_sector
    from public.fleets where id = v_fleet;
  if v_loc is null then
    return jsonb_build_object('ok', false, 'normalized', false, 'reason', 'not_normalizable');
  end if;

  -- Phase B: lock the CURRENT location's hierarchy (same canonical order) and REVALIDATE it is still a legal
  -- dockable port AFTER the locks are held, immediately before mutation. Ineligible/inactive/hidden/non-port →
  -- fail closed, no write. (No resolve_origin: a normalizer asserts the at_location invariant, not depart-origin.)
  perform 1 from public.sectors           where id = v_sector for share;
  perform 1 from public.zones             where id = v_zone   for share;
  perform 1 from public.locations         where id = v_loc    for share;
  perform 1 from public.space_anchors     where location_id = v_loc and kind = 'location' and status = 'active' for share;
  perform 1 from public.location_services where location_id = v_loc and service = 'docking' and status = 'active' for share;
  if (public.mainship_space_location_target_legal(v_loc)->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'normalized', false, 'reason', 'ineligible_port');
  end if;

  -- Convert ONLY the required ship state into canonical at_location form; REUSE the existing fleet + presence
  -- (no new fleet, presence, movement, receipt, or coordinate). Defensively clear movement pointers.
  update public.main_ship_instances
    set status = 'stationary', spatial_state = 'at_location', space_x = null, space_y = null, updated_at = now()
    where main_ship_id = v_ship;
  update public.fleets
    set status = 'present', location_mode = 'location', active_movement_id = null, active_space_movement_id = null,
        current_base_id = null, updated_at = now()
    where id = v_fleet;

  if (public.mainship_space_validate_context(v_ship)->>'state') is distinct from 'at_location' then
    raise exception 'normalize_main_ship_dock: post-write state is not canonical at_location';
  end if;

  return jsonb_build_object('ok', true, 'normalized', true, 'location_id', to_jsonb(v_loc));
end;
$$;

-- ── D. ACLs — authenticated RPCs client-callable; the writer is service_role-only. Explicit revoke/grant (no
--    reliance on default privileges); no other function's ACL is touched. ───────────────────────────────────
revoke execute on function public.commission_first_main_ship()  from public, anon;
grant  execute on function public.commission_first_main_ship()  to authenticated;
revoke execute on function public.normalize_main_ship_dock()    from public, anon;
grant  execute on function public.normalize_main_ship_dock()    to authenticated;
revoke execute on function public.port_entry_commission_writer(uuid) from public, anon, authenticated;
grant  execute on function public.port_entry_commission_writer(uuid) to service_role;
