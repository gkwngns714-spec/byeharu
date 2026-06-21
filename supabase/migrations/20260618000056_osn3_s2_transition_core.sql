-- Byeharu — OSN-3 S2: internal transition boundary (lock / validate / resolve-origin) — NO writers.
--
-- Adds the trusted, SERVER-ONLY locking + validation + origin-resolution helpers that FUTURE OSN-3
-- writers (S3+) will compose. S2 mutates NOTHING: it never creates/settles/cancels a coordinate
-- movement, never changes ship/fleet/presence/spatial state, never touches a flag, and exposes NO
-- player RPC. All four helpers are SECURITY DEFINER, search_path=public, execute revoked from
-- public/anon/authenticated and granted to service_role ONLY (the established server-only pattern;
-- future writer functions run as their definer-owner and compose these without a client grant).
--
-- Canonical lock order (the ONLY order any helper acquires): main_ship_instances → fleets →
-- main_ship_space_movements → location_presence. Legacy fleet_movements is NEVER locked here (only a
-- non-locking EXISTS read), so this can never invert against the frozen process_fleet_movements
-- (which locks legacy movement first, then the fleet). No advisory locks.

-- ── A. mainship_space_lock_context — acquire the per-ship lock context in canonical order ──────────
-- p_skip_locked=false → blocking FOR UPDATE (player/writer callers). true → FOR UPDATE SKIP LOCKED on
-- the ship row first (background-processor callers): if the ship is locked, returns {status:'skipped'}
-- without blocking. The lock-mode is a typed boolean and the function is server-only, so it can never
-- be client-controlled. Returns a jsonb SNAPSHOT of the locked rows (locks persist in the caller's txn).
create or replace function public.mainship_space_lock_context(p_main_ship_id uuid, p_skip_locked boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship      main_ship_instances%rowtype;
  v_fleet     fleets%rowtype;
  v_fleets    jsonb := '[]'::jsonb;
  v_count     integer := 0;
  v_one_fleet uuid := null;
  v_mv        main_ship_space_movements%rowtype;
  v_pres      location_presence%rowtype;
  v_has_legacy boolean := false;
begin
  -- 1) ship row FIRST
  if p_skip_locked then
    select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id for update skip locked;
    if not found then
      if exists (select 1 from main_ship_instances where main_ship_id = p_main_ship_id)
        then return jsonb_build_object('status','skipped');     -- locked by another txn
        else return jsonb_build_object('status','not_found');
      end if;
    end if;
  else
    select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id for update;
    if not found then return jsonb_build_object('status','not_found'); end if;
  end if;

  -- 2) the ship's non-terminal fleets (locked, deterministic order). >1 is a contradiction validate flags.
  for v_fleet in
    select * from fleets
    where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning')
    order by id
    for update
  loop
    v_count := v_count + 1;
    v_fleets := v_fleets || to_jsonb(v_fleet);
    v_one_fleet := v_fleet.id;
  end loop;
  if v_count <> 1 then v_one_fleet := null; end if;   -- only a single relevant fleet is "the" fleet

  -- 3) the active coordinate movement (<=1 by partial unique index)
  select * into v_mv from main_ship_space_movements
    where main_ship_id = p_main_ship_id and status = 'moving' for update;

  -- 4) the active location presence for the single relevant fleet (if any)
  if v_one_fleet is not null then
    select * into v_pres from location_presence where fleet_id = v_one_fleet and status = 'active' for update;
    -- 5) NON-LOCKING legacy-movement existence check (never lock fleet_movements after the fleet)
    v_has_legacy := exists (select 1 from fleet_movements where fleet_id = v_one_fleet and status = 'moving');
  end if;

  return jsonb_build_object(
    'status', 'locked',
    'main_ship_id', p_main_ship_id,
    'ship', to_jsonb(v_ship),
    'fleets', v_fleets,
    'fleet_count', v_count,
    'relevant_fleet_id', v_one_fleet,
    'space_movement', case when v_mv.id is null then null else to_jsonb(v_mv) end,
    'presence', case when v_pres.id is null then null else to_jsonb(v_pres) end,
    'has_active_legacy_movement', v_has_legacy
  );
end;
$$;

-- ── B. mainship_space_validate_context — read-only linkage + state validation (no mutation) ────────
-- Re-reads under the locks lock_context holds. Returns {ok, state, reason}. state ∈ legacy_home |
-- home | legacy_present | present | in_space | in_transit | destroyed. Any incoherence → ok=false.
create or replace function public.mainship_space_validate_context(p_main_ship_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship   main_ship_instances%rowtype;
  v_fleet  fleets%rowtype;
  v_count  integer := 0;
  v_mv     main_ship_space_movements%rowtype;
  v_pres   location_presence%rowtype;
  v_ss     text;
  v_st     text;
  v_has_legacy boolean := false;
  v_coord  boolean;
  v_presact boolean;
  fail     constant text := 'contradictory_state';
begin
  select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;
  v_ss := v_ship.spatial_state; v_st := v_ship.status;

  select count(*) into v_count from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
  if v_count > 1 then return jsonb_build_object('ok', false, 'reason', 'multiple_active_fleets'); end if;
  if v_count = 1 then select * into v_fleet from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning'); end if;

  select * into v_mv from main_ship_space_movements where main_ship_id = p_main_ship_id and status = 'moving';
  v_coord := v_mv.id is not null;
  if v_count = 1 then
    select * into v_pres from location_presence where fleet_id = v_fleet.id and status = 'active';
    v_has_legacy := exists (select 1 from fleet_movements where fleet_id = v_fleet.id and status = 'moving');
  end if;
  v_presact := v_pres.id is not null;

  -- DESTROYED (legacy: status destroyed, ss null | new-domain: ss destroyed)
  if v_st = 'destroyed' or v_ss = 'destroyed' then
    if v_coord or v_presact or v_count > 0 then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'destroyed');
  end if;

  -- NEW-DOMAIN states (non-null spatial_state)
  if v_ss = 'in_space' then
    if v_st <> 'stationary' or v_count > 0 or v_coord or v_presact then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_ship.space_x is null or v_ship.space_y is null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'in_space');
  elsif v_ss = 'at_location' then
    if v_st <> 'stationary' or v_count <> 1 then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_fleet.status <> 'present' or v_fleet.location_mode <> 'location' or v_fleet.current_location_id is null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_fleet.active_movement_id is not null or v_fleet.active_space_movement_id is not null or v_coord then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if not v_presact or v_pres.location_id is distinct from v_fleet.current_location_id then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'at_location');
  elsif v_ss = 'in_transit' then
    if v_st <> 'traveling' or v_count <> 1 then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_fleet.status <> 'moving' or v_fleet.location_mode <> 'movement' or v_fleet.active_movement_id is not null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if not v_coord or v_fleet.active_space_movement_id is distinct from v_mv.id then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_mv.fleet_id is distinct from v_fleet.id or v_mv.main_ship_id is distinct from v_ship.main_ship_id or v_mv.player_id is distinct from v_ship.player_id then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_presact or v_has_legacy then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'in_transit');
  elsif v_ss = 'home' then
    if v_st <> 'home' or v_count > 0 or v_coord or v_presact then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'home');
  elsif v_ss is not null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_spatial_state');
  end if;

  -- LEGACY (spatial_state IS NULL)
  if v_count = 0 and v_st = 'home' then
    return jsonb_build_object('ok', true, 'state', 'legacy_home');
  end if;
  if v_count = 1 and v_fleet.status = 'present' and v_fleet.current_location_id is not null
     and v_presact and v_pres.location_id is not distinct from v_fleet.current_location_id then
    return jsonb_build_object('ok', true, 'state', 'legacy_present');
  end if;
  if v_count = 1 and v_fleet.status in ('moving','returning') and v_has_legacy then
    return jsonb_build_object('ok', true, 'state', 'legacy_transit');
  end if;
  -- legacy NULL but nothing coherent → not an actionable origin context
  return jsonb_build_object('ok', false, 'reason', fail);
end;
$$;

-- ── C. mainship_space_resolve_origin — read-only authoritative route origin for future writers ─────
-- Composes validate_context, then maps the validated state to an authoritative origin. NEVER uses the
-- client map resolver; NEVER accepts client coordinates. {ok:false,reason} for in_transit/destroyed/
-- malformed.
create or replace function public.mainship_space_resolve_origin(p_main_ship_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_val   jsonb;
  v_state text;
  v_ship  main_ship_instances%rowtype;
  v_fleet fleets%rowtype;
  v_base  record;
  v_loc   record;
begin
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;
  v_state := v_val->>'state';
  select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;

  if v_state in ('home','legacy_home') then
    select id, x, y into v_base from bases where player_id = v_ship.player_id and status = 'active' order by created_at limit 1;
    if v_base.id is null or v_base.x is null or v_base.y is null then return jsonb_build_object('ok', false, 'reason', 'base_unresolved'); end if;
    return jsonb_build_object('ok', true, 'origin_kind', 'base', 'origin_x', v_base.x, 'origin_y', v_base.y, 'origin_base_id', v_base.id);

  elsif v_state in ('at_location','legacy_present') then
    select * into v_fleet from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning') limit 1;
    select id, x, y into v_loc from locations where id = v_fleet.current_location_id;
    if v_loc.id is null or v_loc.x is null or v_loc.y is null then return jsonb_build_object('ok', false, 'reason', 'location_unresolved'); end if;
    return jsonb_build_object('ok', true, 'origin_kind', 'location', 'origin_x', v_loc.x, 'origin_y', v_loc.y, 'origin_location_id', v_loc.id);

  elsif v_state = 'in_space' then
    if v_ship.space_x is null or v_ship.space_y is null then return jsonb_build_object('ok', false, 'reason', 'contradictory_state'); end if;
    return jsonb_build_object('ok', true, 'origin_kind', 'space', 'origin_x', v_ship.space_x, 'origin_y', v_ship.space_y);

  elsif v_state in ('in_transit','legacy_transit') then
    return jsonb_build_object('ok', false, 'reason', 'in_transit_must_stop');
  elsif v_state = 'destroyed' then
    return jsonb_build_object('ok', false, 'reason', 'destroyed');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'contradictory_state');
end;
$$;

-- ── D. mainship_space_assert_cross_domain_exclusion — read-only exclusion guard for future writers ──
-- Proves a future coordinate-domain action's preconditions WITHOUT mutating either movement domain.
create or replace function public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ship  main_ship_instances%rowtype;
  v_fleet fleets%rowtype;
  v_count integer := 0;
  v_mv    main_ship_space_movements%rowtype;
begin
  select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;

  select count(*) into v_count from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
  if v_count > 1 then return jsonb_build_object('ok', false, 'reason', 'multiple_active_fleets'); end if;
  if v_count = 1 then
    select * into v_fleet from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
    -- a selected fleet with an active LEGACY movement blocks the coordinate domain
    if exists (select 1 from fleet_movements where fleet_id = v_fleet.id and status = 'moving') then
      return jsonb_build_object('ok', false, 'reason', 'active_legacy_movement');
    end if;
  end if;

  select * into v_mv from main_ship_space_movements where main_ship_id = p_main_ship_id and status = 'moving';
  if v_mv.id is not null then
    -- a coordinate movement must agree with the fleet pointer + ownership
    if v_count <> 1 or v_mv.fleet_id is distinct from v_fleet.id
       or v_fleet.active_space_movement_id is distinct from v_mv.id
       or v_mv.player_id is distinct from v_ship.player_id then
      return jsonb_build_object('ok', false, 'reason', 'coordinate_pointer_mismatch');
    end if;
  end if;

  -- an active presence that contradicts a non-located spatial state
  if v_ship.spatial_state in ('in_space','in_transit')
     and v_count = 1
     and exists (select 1 from location_presence where fleet_id = v_fleet.id and status = 'active') then
    return jsonb_build_object('ok', false, 'reason', 'presence_conflict');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ── Re-lock execute surface (anti-cheat). New helpers default-grant to PUBLIC on create → revoke and
--    re-grant ONLY the canonical client RPC list (carried verbatim from 0055). The four S2 helpers are
--    granted to service_role ONLY — no client/public grant. Prior service_role grants survive the revoke.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on function public.get_world_map()                                  to anon, authenticated;
grant execute on function public.bootstrap_me()                                   to authenticated;
grant execute on function public.send_fleet_to_location(uuid, uuid, jsonb)        to authenticated;
grant execute on function public.request_leave_location(uuid)                     to authenticated;
grant execute on function public.request_retreat(uuid)                            to authenticated;
grant execute on function public.get_combat_reports()                             to authenticated;
grant execute on function public.train_units(uuid, text, integer)                 to authenticated;
grant execute on function public.cancel_build_order(uuid)                         to authenticated;
grant execute on function public.get_my_expedition_preview(jsonb, text)           to authenticated;
grant execute on function public.send_main_ship_expedition(jsonb, uuid)           to authenticated;
grant execute on function public.request_main_ship_return(uuid)                   to authenticated;
grant execute on function public.repair_main_ship()                               to authenticated;
grant execute on function public.move_main_ship_to_location(uuid, uuid)           to authenticated;
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.dev_set_main_ship_destroyed(uuid)                to service_role;
grant execute on function public.resolve_fleet_movement_speed(uuid)               to service_role;
grant execute on function public.process_mainship_expeditions()                   to service_role;
grant execute on function public.mainship_space_lock_context(uuid, boolean)       to service_role;
grant execute on function public.mainship_space_validate_context(uuid)            to service_role;
grant execute on function public.mainship_space_resolve_origin(uuid)              to service_role;
grant execute on function public.mainship_space_assert_cross_domain_exclusion(uuid) to service_role;
