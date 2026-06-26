-- Byeharu — OSN-HUB-1A: Dark Canonical Location-Target Navigation Foundation. flag-dark, additive.
--
-- Makes the OSN coordinate domain resolve a docked ORIGIN and a named-location TARGET through canonical
-- public.space_anchors (kind='location') instead of legacy locations.x/y or bases.x/y, and lets the owner
-- read-model identify a movement's named destination. NO port reveal, NO home-port assignment, NO base
-- anchor, NO seed of any live anchor/port/service/home-port, NO feature-flag change, NO legacy-path change.
-- mainship_send_enabled and mainship_space_movement_enabled are NEITHER read-to-gate-creation differently
-- NOR written here (the existing writer flag-gate is preserved). Production stays dark: with
-- mainship_space_movement_enabled=false the new public wrapper returns feature_disabled and writes nothing,
-- and the only anchored locations today are the three HIDDEN starter ports (status='hidden', absent from
-- get_world_map, ineligible) → zero reachable public location targets exist. That is expected and correct.
--
-- ONE explicit target-discriminated route model (no parallel engine, no second arrival processor, no second
-- Dock-0 resolver, no client-owned coordinates):
--   • NEW private core writer mainship_space_begin_move_core(player, ship, target_kind, x, y, location, req)
--     enforces EXACTLY ONE coherent target shape at a time:
--        space    → target_kind='space',    target_location_id NULL, x/y are the client coordinate path;
--        location → target_kind='location', target_location_id non-null, x/y MUST be NULL (client coords are
--                   never accepted/trusted) and the target coordinate is DERIVED server-side from the one
--                   active canonical location anchor.
--   • The existing 5-arg mainship_space_begin_move(uuid,uuid,double,double,uuid) is preserved verbatim as a
--     thin space-only delegate to the core (so command_main_ship_space_move, OSN-4, and every existing proof
--     keep their exact contract/signature — no overload, no optional-parameter ambiguity).
--   • mainship_space_resolve_origin: a coherent DOCKED origin (at_location / legacy_present) now resolves from
--     that location's one active canonical anchor; legacy/new-domain HOME stays fail-closed origin_not_anchored
--     (port-centric: true home identity is a future docked home-port, NOT a base coordinate). in_space unchanged.
--   • mainship_space_dock_at_location (still the ONLY caller is the existing arrival processor): FULLY
--     revalidates dockability at ARRIVAL under deterministic target-hierarchy FOR SHARE locks (a route legal at
--     departure can become non-dockable in transit), re-running the SINGLE canonical legality rule AND requiring
--     the current canonical anchor to still match the movement's stored target snapshot. Any failed condition is
--     a deterministic terminal failure (ship parked in_space at the snapshot; no presence; never redirects/
--     teleports). locations.x/y is consulted NOWHERE; the canonical anchor is the sole coordinate authority.
--   • mainship_space_location_target_legal(location): the SINGLE canonical target-legality rule (own purpose,
--     own reasons; not the home-port predicate) — exists + active location/zone/sector + role ∈ {city,port} +
--     activity_type='none' (Dock-0-supported) + exactly one active docking service + exactly one active location
--     anchor (finite, in-bounds) → anchor x/y. Used at BOTH departure (writer) and arrival (Dock-0).
--   • NEW public authenticated wrapper command_main_ship_space_move_to_location(location, request_id): derives
--     the caller + their own ship server-side, flag-gates BEFORE target resolution (so a disabled feature
--     cannot probe whether a hidden UUID exists), delegates to the core, and maps every "not a legal target"
--     reason to ONE generic code so a hidden-port UUID guess is indistinguishable from a nonexistent location.
--
-- Lock order: the S2 canonical ship context FIRST (ship → fleets → main_ship_space_movements →
-- location_presence), THEN the target hierarchy FOR SHARE (sector → zone → location → active location anchor →
-- active docking service) — the same hierarchy order as assign_home_port. Legacy fleet_movements is never
-- locked. No advisory locks, no dynamic SQL.

-- ── A. The SINGLE canonical location-target-legality rule (service_role only) ──────────────────────────────
-- Own purpose (navigation target legality) and own reason domain — deliberately NOT is_home_port_eligible
-- (home-port affiliation), though it enforces the same world-shape facts. Returns the resolved anchor coords
-- so the writer never re-derives or trusts a coordinate. STABLE: pure read (the caller owns any locking).
create or replace function public.mainship_space_location_target_legal(p_location_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_loc   record;
  v_svc   integer;
  v_anch  integer;
  v_ax    double precision;
  v_ay    double precision;
begin
  if p_location_id is null then
    return jsonb_build_object('ok', false, 'reason', 'target_not_found');
  end if;

  select l.id as id, l.status as lstatus, l.physical_role as role, l.activity_type as activity,
         z.status as zstatus, se.status as sstatus
    into v_loc
    from public.locations l
    join public.zones   z  on z.id  = l.zone_id
    join public.sectors se on se.id = z.sector_id
    where l.id = p_location_id;
  if not found            then return jsonb_build_object('ok', false, 'reason', 'target_not_found'); end if;
  if v_loc.lstatus <> 'active' then return jsonb_build_object('ok', false, 'reason', 'target_inactive_location'); end if;
  if v_loc.zstatus <> 'active' then return jsonb_build_object('ok', false, 'reason', 'target_inactive_zone'); end if;
  if v_loc.sstatus <> 'active' then return jsonb_build_object('ok', false, 'reason', 'target_inactive_sector'); end if;
  if v_loc.role not in ('city', 'port') then return jsonb_build_object('ok', false, 'reason', 'target_unsupported_role'); end if;
  -- Dock-0 settles ONLY activity_type='none' targets; reject here so we never launch a route Dock-0 must fail.
  if v_loc.activity <> 'none' then return jsonb_build_object('ok', false, 'reason', 'target_unsupported_activity'); end if;

  select count(*) into v_svc from public.location_services svc
    where svc.location_id = p_location_id and svc.service = 'docking' and svc.status = 'active';
  if v_svc <> 1 then return jsonb_build_object('ok', false, 'reason', 'target_no_docking_service'); end if;

  select count(*) into v_anch from public.space_anchors a
    where a.location_id = p_location_id and a.kind = 'location' and a.status = 'active';
  if v_anch <> 1 then return jsonb_build_object('ok', false, 'reason', 'target_anchor_not_unique'); end if;

  select a.space_x, a.space_y into v_ax, v_ay from public.space_anchors a
    where a.location_id = p_location_id and a.kind = 'location' and a.status = 'active';
  if v_ax is null or v_ay is null
     or v_ax = 'NaN'::double precision or v_ax = 'Infinity'::double precision or v_ax = '-Infinity'::double precision
     or v_ay = 'NaN'::double precision or v_ay = 'Infinity'::double precision or v_ay = '-Infinity'::double precision
     or v_ax < -10000 or v_ax > 10000 or v_ay < -10000 or v_ay > 10000 then
    return jsonb_build_object('ok', false, 'reason', 'target_anchor_out_of_bounds');
  end if;

  return jsonb_build_object('ok', true, 'location_id', p_location_id, 'anchor_x', v_ax, 'anchor_y', v_ay);
end;
$$;

-- ── B. The single discriminated core writer (service_role only) ────────────────────────────────────────────
-- Generalised from the deployed mainship_space_begin_move: identical admission/lock/validate/exclusion/origin/
-- speed/idempotency/fleet-materialise frame; the ONLY additions are an explicit target discriminator and the
-- server-side resolution of a named-location target's coordinate from its canonical anchor (under FOR SHARE
-- target-hierarchy locks). VALIDATE-BEFORE-MUTATE preserved: every rejection returns {ok,reason} before any write.
create or replace function public.mainship_space_begin_move_core(
  p_player            uuid,
  p_main_ship_id      uuid,
  p_target_kind       text,
  p_target_x          double precision,
  p_target_y          double precision,
  p_target_location_id uuid,
  p_request_id        uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_lo      constant double precision := -10000;
  c_hi      constant double precision :=  10000;
  v_cmd     text;
  v_lock    jsonb;
  v_status  text;
  v_owner   uuid;
  v_hash    text;
  v_rcpt    main_ship_space_command_receipts%rowtype;
  v_val     jsonb;
  v_excl    jsonb;
  v_origin  jsonb;
  v_okind   text;
  v_ox      double precision;
  v_oy      double precision;
  -- resolved target (server-authoritative; for a location target these come from the canonical anchor)
  v_tkind   text;
  v_tx      double precision;
  v_ty      double precision;
  v_tloc    uuid;
  v_tzone   uuid;
  v_tsector uuid;
  v_legal   jsonb;
  v_dist    double precision;
  v_scale   double precision;
  v_min     double precision;
  v_max     double precision;
  v_seconds double precision;
  v_speed   double precision;
  v_speed2  double precision;
  v_base_id uuid;
  v_fleet   fleets%rowtype;
  v_fleet_id uuid;
  v_mv_id   uuid;
  v_depart  timestamptz;
  v_arrive  timestamptz;
  v_result  jsonb;
begin
  -- 1) basic input validation + EXPLICIT target-shape enforcement (pure: no locks, no writes)
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;
  if p_target_kind = 'space' then
    v_cmd := 'space_begin_move';                       -- preserve the deployed space command identity
    if p_target_location_id is not null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
    end if;
    if p_target_x is null or p_target_y is null
       or p_target_x = 'NaN'::double precision or p_target_x = 'Infinity'::double precision or p_target_x = '-Infinity'::double precision
       or p_target_y = 'NaN'::double precision or p_target_y = 'Infinity'::double precision or p_target_y = '-Infinity'::double precision then
      return jsonb_build_object('ok', false, 'reason', 'invalid_coordinate');
    end if;
    if p_target_x < c_lo or p_target_x > c_hi or p_target_y < c_lo or p_target_y > c_hi then
      return jsonb_build_object('ok', false, 'reason', 'target_out_of_bounds');
    end if;
  elsif p_target_kind = 'location' then
    v_cmd := 'space_begin_move_to_location';
    if p_target_location_id is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_target_location');
    end if;
    -- client coordinates are NEVER accepted for a location target (server derives them from the anchor)
    if p_target_x is not null or p_target_y is not null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_target_shape');
    end if;
  else
    return jsonb_build_object('ok', false, 'reason', 'invalid_target_kind');
  end if;

  -- 2) S2 canonical SHIP lock context (ship → fleet → coordinate movement → presence). Blocking mode.
  v_lock := public.mainship_space_lock_context(p_main_ship_id, false);
  v_status := v_lock->>'status';
  if v_status = 'not_found' then
    return jsonb_build_object('ok', false, 'reason', 'missing_ship');
  elsif v_status <> 'locked' then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_status, 'lock_failed'));
  end if;

  -- 3) ownership, derived from the LOCKED ship snapshot (never from the client)
  v_owner := (v_lock->'ship'->>'player_id')::uuid;
  if v_owner is distinct from p_player then
    return jsonb_build_object('ok', false, 'reason', 'not_owned');
  end if;

  -- 4) canonical immutable command payload + deterministic hash (target identity only). The space hash is
  --    byte-identical to the deployed writer's; a location hash keys on the destination location identity.
  if p_target_kind = 'space' then
    v_hash := md5(jsonb_build_object(
                'command_type', v_cmd, 'target_kind', 'space',
                'target_x', p_target_x, 'target_y', p_target_y)::text);
  else
    v_hash := md5(jsonb_build_object(
                'command_type', v_cmd, 'target_kind', 'location',
                'target_location_id', p_target_location_id)::text);
  end if;

  -- 5) idempotency receipt lookup AFTER the ship lock + ownership check
  select * into v_rcpt from main_ship_space_command_receipts
    where main_ship_id = p_main_ship_id and request_id = p_request_id;
  if found then
    if v_rcpt.command_type = v_cmd and v_rcpt.canonical_payload_hash = v_hash then
      return v_rcpt.result_json;                       -- idempotent replay of the first commit
    else
      return jsonb_build_object('ok', false, 'reason', 'request_id_payload_conflict');
    end if;
  end if;

  -- 6) feature flag (no receipt is written for a rejected disabled command)
  if not cfg_bool('mainship_space_movement_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 7) coherent-state validation under the ship locks
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;

  -- 8) cross-domain exclusion (active legacy movement / coordinate-pointer mismatch / presence conflict)
  v_excl := public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id);
  if (v_excl->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_excl->>'reason', 'contradictory_state'));
  end if;

  -- 9) authoritative ORIGIN (server-resolved; rejects in_transit/legacy_transit/destroyed/unanchored-home)
  v_origin := public.mainship_space_resolve_origin(p_main_ship_id);
  if (v_origin->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_origin->>'reason', 'contradictory_state'));
  end if;
  v_okind := v_origin->>'origin_kind';
  v_ox := (v_origin->>'origin_x')::double precision;
  v_oy := (v_origin->>'origin_y')::double precision;

  -- 10) origin coordinate validation (defensive; resolve_origin only returns canonical anchored/space coords)
  if v_ox is null or v_oy is null
     or v_ox = 'NaN'::double precision or v_ox = 'Infinity'::double precision or v_ox = '-Infinity'::double precision
     or v_oy = 'NaN'::double precision or v_oy = 'Infinity'::double precision or v_oy = '-Infinity'::double precision then
    return jsonb_build_object('ok', false, 'reason', 'invalid_coordinate');
  end if;
  if v_ox < c_lo or v_ox > c_hi or v_oy < c_lo or v_oy > c_hi then
    return jsonb_build_object('ok', false, 'reason', 'origin_out_of_bounds');
  end if;

  -- 11) resolve the authoritative TARGET coordinate. space → the (already-validated) client coordinate.
  --     location → lock the target hierarchy FOR SHARE (sector → zone → location → anchor → docking service,
  --     same order as assign_home_port; FOR SHARE conflicts with a status disable/retire FOR NO KEY UPDATE),
  --     then RE-VALIDATE the single canonical target-legality rule UNDER those locks and take the anchor x/y.
  if p_target_kind = 'space' then
    v_tkind := 'space'; v_tx := p_target_x; v_ty := p_target_y; v_tloc := null;
  else
    select l.zone_id, z.sector_id into v_tzone, v_tsector
      from public.locations l join public.zones z on z.id = l.zone_id
      where l.id = p_target_location_id;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'target_not_found');
    end if;
    perform 1 from public.sectors          where id = v_tsector          for share;
    perform 1 from public.zones            where id = v_tzone            for share;
    perform 1 from public.locations        where id = p_target_location_id for share;
    perform 1 from public.space_anchors    where location_id = p_target_location_id and kind = 'location' and status = 'active' for share;
    perform 1 from public.location_services where location_id = p_target_location_id and service = 'docking' and status = 'active' for share;

    v_legal := public.mainship_space_location_target_legal(p_target_location_id);
    if (v_legal->>'ok')::boolean is not true then
      return jsonb_build_object('ok', false, 'reason', coalesce(v_legal->>'reason', 'target_not_found'));
    end if;
    v_tkind := 'location';
    v_tx    := (v_legal->>'anchor_x')::double precision;
    v_ty    := (v_legal->>'anchor_y')::double precision;
    v_tloc  := p_target_location_id;
  end if;

  -- 12) EXACT zero-distance reject (no epsilon), against the resolved target
  if v_ox = v_tx and v_oy = v_ty then
    return jsonb_build_object('ok', false, 'reason', 'zero_distance');
  end if;

  -- 13) speed + travel time + LIMIT — BEFORE any mutation (validate-before-mutate). Hull speed equals what
  --     resolve_fleet_movement_speed returns for a main-ship fleet; the real fleet's speed is asserted equal.
  select h.base_speed into v_speed
    from main_ship_instances s join main_ship_hull_types h on h.hull_type_id = s.hull_type_id
    where s.main_ship_id = p_main_ship_id;
  if v_speed is null or v_speed <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_speed');
  end if;
  v_scale := coalesce(cfg_num('travel_scale'), 1.0);
  v_min   := coalesce(cfg_num('min_travel_seconds'), 1.0);
  v_max   := coalesce(cfg_num('max_coordinate_travel_seconds'), 86400);
  v_dist    := sqrt(power(v_tx - v_ox, 2) + power(v_ty - v_oy, 2));
  v_seconds := greatest(v_min, v_dist / v_speed * v_scale);
  if v_seconds > v_max then
    return jsonb_build_object('ok', false, 'reason', 'travel_time_exceeds_limit');
  end if;

  -- ════════ all admission checks passed; mutate within this one transaction ════════

  -- 14) obtain or materialise the fleet (origin class decides; identical to the deployed writer)
  if v_okind in ('base', 'space') then
    select id into v_base_id from bases
      where player_id = p_player and status = 'active' order by created_at limit 1;
    insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)
      values (p_player, v_base_id, 'moving', 'movement', null, p_main_ship_id)
      returning id into v_fleet_id;
  else
    select * into v_fleet from fleets
      where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
    v_fleet_id := v_fleet.id;
  end if;

  -- 15) authoritative speed via the canonical resolver; must equal the pre-checked hull speed (integrity)
  v_speed2 := resolve_fleet_movement_speed(v_fleet_id);
  if v_speed2 is distinct from v_speed then
    raise exception 'mainship_space_begin_move_core: speed invariant broken (hull % vs resolver %)', v_speed, v_speed2;
  end if;

  -- 16) insert EXACTLY ONE moving coordinate movement with the discriminated target (table CHECK binds the
  --     target_kind ↔ target_location_id/target_base_id shape; the one-active partial-uniques are the backstop)
  v_depart := now();
  v_arrive := v_depart + make_interval(secs => v_seconds);
  insert into main_ship_space_movements (
    main_ship_id, fleet_id, player_id,
    origin_kind, origin_x, origin_y,
    target_kind, target_x, target_y, target_location_id, target_base_id,
    status, speed_used, depart_at, arrive_at)
  values (
    p_main_ship_id, v_fleet_id, p_player,
    v_okind, v_ox, v_oy,
    v_tkind, v_tx, v_ty, v_tloc, null,
    'moving', v_speed, v_depart, v_arrive)
  returning id into v_mv_id;

  -- 17) point the fleet at the coordinate movement; legacy active_movement_id stays NULL
  update fleets
    set status = 'moving', location_mode = 'movement',
        active_movement_id = null, active_space_movement_id = v_mv_id,
        current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = now()
    where id = v_fleet_id;

  -- 18) location-present origin: close the already-locked active presence (mirrors presence_complete)
  if v_okind = 'location' then
    update location_presence
      set status = 'completed', updated_at = now()
      where fleet_id = v_fleet_id and status = 'active';
  end if;

  -- 19) ship → traveling / in_transit; clear any open-space coordinate
  update main_ship_instances
    set status = 'traveling', spatial_state = 'in_transit', space_x = null, space_y = null, updated_at = now()
    where main_ship_id = p_main_ship_id;

  -- 20) finalise the idempotency receipt atomically with the move
  v_result := jsonb_build_object(
    'ok', true,
    'movement_id', v_mv_id, 'main_ship_id', p_main_ship_id, 'fleet_id', v_fleet_id, 'player_id', p_player,
    'origin_kind', v_okind, 'origin_x', v_ox, 'origin_y', v_oy,
    'target_kind', v_tkind, 'target_x', v_tx, 'target_y', v_ty, 'target_location_id', v_tloc,
    'speed_used', v_speed, 'depart_at', v_depart, 'arrive_at', v_arrive,
    'request_id', p_request_id);
  insert into main_ship_space_command_receipts (
    main_ship_id, player_id, request_id, command_type, canonical_payload_hash,
    outcome_status, result_json, movement_id, completed_at)
  values (
    p_main_ship_id, p_player, p_request_id, v_cmd, v_hash,
    'success', v_result, v_mv_id, now());

  return v_result;
end;
$$;

-- ── C. Preserve the deployed 5-arg space writer EXACTLY, as a thin delegate to the core ────────────────────
-- CREATE OR REPLACE keeps owner/SECURITY DEFINER/search_path AND the existing service_role-only grant, and
-- keeps the signature command_main_ship_space_move + OSN-4 + every existing proof reference depends on.
create or replace function public.mainship_space_begin_move(
  p_player       uuid,
  p_main_ship_id uuid,
  p_target_x     double precision,
  p_target_y     double precision,
  p_request_id   uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.mainship_space_begin_move_core(p_player, p_main_ship_id, 'space', p_target_x, p_target_y, null, p_request_id);
end;
$$;

-- ── D. Truthful, anchored ORIGIN resolution ───────────────────────────────────────────────────────────────
-- DOCKED origin (at_location / legacy_present) → the location's EXACTLY ONE active canonical anchor (never
-- locations.x/y). HOME (home / legacy_home) stays fail-closed origin_not_anchored (port-centric: true home is
-- a future docked home-port, not a base coordinate; no base anchor exists or is created). in_space UNCHANGED.
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
  v_anch  integer;
  v_ax    double precision;
  v_ay    double precision;
begin
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;
  v_state := v_val->>'state';
  select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;

  -- HOME remains fail-closed: legacy bases.x/y is NOT a canonical OSN origin and no base anchor exists.
  if v_state in ('home', 'legacy_home') then
    return jsonb_build_object('ok', false, 'reason', 'origin_not_anchored');

  -- DOCKED origin: resolve from the docked location's one active canonical location anchor. NEVER locations.x/y.
  elsif v_state in ('at_location', 'legacy_present') then
    select * into v_fleet from fleets
      where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning') limit 1;
    if v_fleet.current_location_id is null then
      return jsonb_build_object('ok', false, 'reason', 'origin_not_anchored');
    end if;
    select count(*) into v_anch from public.space_anchors a
      where a.location_id = v_fleet.current_location_id and a.kind = 'location' and a.status = 'active';
    if v_anch <> 1 then
      return jsonb_build_object('ok', false, 'reason', 'origin_not_anchored');
    end if;
    select a.space_x, a.space_y into v_ax, v_ay from public.space_anchors a
      where a.location_id = v_fleet.current_location_id and a.kind = 'location' and a.status = 'active';
    if v_ax is null or v_ay is null then
      return jsonb_build_object('ok', false, 'reason', 'origin_not_anchored');
    end if;
    return jsonb_build_object('ok', true, 'origin_kind', 'location',
      'origin_x', v_ax, 'origin_y', v_ay, 'origin_location_id', v_fleet.current_location_id);

  elsif v_state = 'in_space' then
    if v_ship.space_x is null or v_ship.space_y is null then
      return jsonb_build_object('ok', false, 'reason', 'contradictory_state');
    end if;
    return jsonb_build_object('ok', true, 'origin_kind', 'space', 'origin_x', v_ship.space_x, 'origin_y', v_ship.space_y);

  elsif v_state in ('in_transit', 'legacy_transit') then
    return jsonb_build_object('ok', false, 'reason', 'in_transit_must_stop');
  elsif v_state = 'destroyed' then
    return jsonb_build_object('ok', false, 'reason', 'destroyed');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'contradictory_state');
end;
$$;

-- ── E. Anchor-backed Dock-0 (still ONLY invoked by process_mainship_space_arrivals) ───────────────────────
-- A route legal at DEPARTURE can become non-dockable in transit, so Dock-0 FULLY REVALIDATES at arrival under
-- deterministic target-hierarchy FOR SHARE locks (sector → zone → location → anchor → docking service) before
-- creating presence or marking the ship at_location. It docks ONLY when the SINGLE canonical legality rule
-- (mainship_space_location_target_legal: active sector/zone/location + role city|port + activity 'none' + one
-- active docking service + one active in-bounds anchor) STILL holds AND that anchor exactly matches the
-- movement's stored target x/y snapshot. Any failed condition — inactive sector/zone/location, lost role,
-- activity≠none, lost/duplicate docking service, missing/ambiguous/retired anchor (→ undockable_*), or a moved
-- anchor (→ target_anchor_changed) — is a deterministic terminal failure: the ship floats in_space at the
-- stored target, NO presence, NO redirect/teleport/retarget, no loop. The coordinate authority is the canonical
-- anchor; locations.x/y is consulted NOWHERE. Single arrival processor + single dock resolver (no reconciler).
create or replace function public.mainship_space_dock_at_location(p_main_ship_id uuid, p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv     main_ship_space_movements%rowtype;
  v_fleet  fleets%rowtype;
  v_loc    record;
  v_legal  jsonb;
  v_ax     double precision;
  v_ay     double precision;
  v_reason text;
begin
  select * into v_mv from main_ship_space_movements
    where id = p_movement_id and main_ship_id = p_main_ship_id and status = 'moving';
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'movement_not_moving');
  end if;
  if v_mv.target_kind <> 'location' or v_mv.target_location_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_location_target');
  end if;

  select * into v_fleet from fleets where id = v_mv.fleet_id;

  -- Resolve the target location's identity + zone/sector (for the FOR SHARE locks and, on success, presence).
  -- locations.x/y is intentionally NOT selected: the canonical anchor is the sole coordinate authority.
  select l.id as id, l.zone_id as zone_id, z.sector_id as sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = v_mv.target_location_id;

  -- ── Dock predicate → DOCK (v_reason NULL) vs deterministic TERMINAL FAILURE (v_reason set) ───────────────
  if v_loc.id is null then
    v_reason := 'undockable_invalid_target';                   -- FK-prevented; defensive only
  else
    -- Re-acquire the TARGET hierarchy under deterministic FOR SHARE locks (same order as the writer /
    -- assign_home_port: sector → zone → location → anchor → docking service). FOR SHARE conflicts with the
    -- FOR NO KEY UPDATE of a status disable/retire, so a concurrent de-activation/retirement serializes here.
    perform 1 from public.sectors           where id = v_loc.sector_id for share;
    perform 1 from public.zones             where id = v_loc.zone_id   for share;
    perform 1 from public.locations         where id = v_loc.id        for share;
    perform 1 from public.space_anchors     where location_id = v_loc.id and kind = 'location' and status = 'active' for share;
    perform 1 from public.location_services where location_id = v_loc.id and service = 'docking' and status = 'active' for share;

    -- FULL arrival-time revalidation through the SINGLE canonical legality rule (active sector/zone/location +
    -- role city|port + activity 'none' + one active docking service + one active in-bounds anchor). A route
    -- legal at departure that became non-dockable in transit terminally fails here — never docks on a partial.
    v_legal := public.mainship_space_location_target_legal(v_loc.id);
    if (v_legal->>'ok')::boolean is not true then
      v_reason := case v_legal->>'reason'
        when 'target_not_found'            then 'undockable_invalid_target'
        when 'target_inactive_location'    then 'undockable_inactive_location'
        when 'target_inactive_zone'        then 'undockable_inactive_zone'
        when 'target_inactive_sector'      then 'undockable_inactive_sector'
        when 'target_unsupported_role'     then 'undockable_unsupported_role'
        when 'target_unsupported_activity' then 'undockable_unsupported_activity'
        when 'target_no_docking_service'   then 'undockable_no_docking_service'
        when 'target_anchor_not_unique'    then 'undockable_no_active_anchor'   -- >1 active is schema-impossible → count 0
        when 'target_anchor_out_of_bounds' then 'undockable_anchor_out_of_bounds'
        else 'undockable_target_illegal'
      end;
    else
      -- The canonical anchor must STILL exactly match the movement's stored target snapshot (never redirect to
      -- a moved anchor). The legality rule already proved exactly one active anchor and returned its coords.
      v_ax := (v_legal->>'anchor_x')::double precision;
      v_ay := (v_legal->>'anchor_y')::double precision;
      if v_ax is distinct from v_mv.target_x or v_ay is distinct from v_mv.target_y then
        v_reason := 'target_anchor_changed';
      else
        v_reason := null;                                       -- fully dockable: legal AND anchor matches snapshot
      end if;
    end if;
  end if;

  if v_reason is not null then
    update main_ship_space_movements
      set status = 'failed', resolved_at = now(), terminal_reason = v_reason
      where id = v_mv.id and status = 'moving';

    update fleets
      set status = 'completed', location_mode = 'movement',
          active_space_movement_id = null, active_movement_id = null,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          updated_at = now()
      where id = v_fleet.id;

    update main_ship_instances
      set status = 'stationary', spatial_state = 'in_space',
          space_x = v_mv.target_x, space_y = v_mv.target_y, updated_at = now()
      where main_ship_id = p_main_ship_id;

    return jsonb_build_object('ok', true, 'docked', false, 'reason', v_reason);
  end if;

  -- ── DOCK: settle the movement, dock the fleet at the location, create exactly one active presence ────────
  update main_ship_space_movements
    set status = 'arrived', resolved_at = now(), terminal_reason = 'auto_arrival'
    where id = v_mv.id and status = 'moving';

  update fleets
    set status = 'present', location_mode = 'location',
        active_space_movement_id = null, active_movement_id = null,
        current_base_id = null,
        current_location_id = v_loc.id, current_zone_id = v_loc.zone_id, current_sector_id = v_loc.sector_id,
        updated_at = now()
    where id = v_fleet.id;

  update main_ship_instances
    set status = 'stationary', spatial_state = 'at_location',
        space_x = null, space_y = null, updated_at = now()
    where main_ship_id = p_main_ship_id;

  perform public.presence_create(v_mv.player_id, v_mv.fleet_id, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'none');

  return jsonb_build_object('ok', true, 'docked', true, 'location_id', v_loc.id);
end;
$$;

-- ── F. The public authenticated location-target command wrapper ───────────────────────────────────────────
-- Accepts ONLY a location id + an idempotency key. Derives caller + own ship from auth.uid(). Flag-gates
-- BEFORE any target resolution (a disabled feature cannot be used to probe whether a hidden UUID exists).
-- Delegates to the core; writes no table itself. Maps EVERY "not a legal target" reason to ONE generic code
-- + message so a hidden-port UUID guess is indistinguishable from a nonexistent/ineligible location.
create or replace function public.command_main_ship_space_move_to_location(
  p_location   uuid,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_res    jsonb;
  v_reason text;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated', 'message', 'You must be signed in.');
  end if;

  -- flag gate FIRST (defense-in-depth + anti-probe): dark feature returns the same generic disabled result
  -- regardless of p_location, so no hidden-port existence can be inferred while the feature is off.
  if not public.cfg_bool('mainship_space_movement_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Coordinate movement is not available yet.');
  end if;

  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
  if v_ship is null then
    return jsonb_build_object('ok', false, 'code', 'no_ship', 'message', 'You do not have a main ship.');
  end if;
  if p_location is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_target', 'message', 'That destination is not available.');
  end if;

  v_res := public.mainship_space_begin_move_core(v_player, v_ship, 'location', null, null, p_location, p_request_id);

  if (v_res->>'ok')::boolean is true then
    return jsonb_build_object(
      'ok', true,
      'movement_id', v_res->'movement_id',
      'main_ship_id', v_res->'main_ship_id',
      'target_location_id', v_res->'target_location_id',
      'target_x', v_res->'target_x',
      'target_y', v_res->'target_y',
      'depart_at', v_res->'depart_at',
      'arrive_at', v_res->'arrive_at');
  end if;

  v_reason := coalesce(v_res->>'reason', 'unavailable');
  return jsonb_build_object(
    'ok', false,
    'code', case v_reason
      when 'feature_disabled'            then 'feature_disabled'
      when 'invalid_request_id'          then 'invalid_request'
      when 'request_id_payload_conflict' then 'request_conflict'
      when 'zero_distance'               then 'already_there'
      when 'travel_time_exceeds_limit'   then 'over_travel_cap'
      when 'in_transit_must_stop'        then 'must_stop_first'
      when 'origin_not_anchored'         then 'cannot_depart'
      when 'destroyed'                   then 'ship_destroyed'
      when 'active_legacy_movement'      then 'busy_legacy'
      when 'missing_ship'                then 'no_ship'
      when 'not_owned'                   then 'no_ship'
      -- every target-legality reason → ONE generic code (no hidden-port existence/identity leak):
      when 'target_not_found'            then 'invalid_target'
      when 'target_inactive_location'    then 'invalid_target'
      when 'target_inactive_zone'        then 'invalid_target'
      when 'target_inactive_sector'      then 'invalid_target'
      when 'target_unsupported_role'     then 'invalid_target'
      when 'target_unsupported_activity' then 'invalid_target'
      when 'target_no_docking_service'   then 'invalid_target'
      when 'target_anchor_not_unique'    then 'invalid_target'
      when 'target_anchor_out_of_bounds' then 'invalid_target'
      when 'invalid_target_location'     then 'invalid_target'
      when 'invalid_target_shape'        then 'invalid_target'
      else 'unavailable'
    end,
    'message', case
      when v_reason = 'feature_disabled'          then 'Coordinate movement is not available yet.'
      when v_reason = 'origin_not_anchored'       then 'The ship cannot depart from its current position yet.'
      when v_reason = 'zero_distance'             then 'The ship is already there.'
      when v_reason = 'in_transit_must_stop'      then 'The ship is already travelling.'
      when v_reason = 'travel_time_exceeds_limit' then 'That destination is too far for a single jump.'
      when v_reason = 'destroyed'                 then 'The ship must be repaired first.'
      when v_reason = 'active_legacy_movement'    then 'Finish the current expedition first.'
      when v_reason in ('target_not_found','target_inactive_location','target_inactive_zone','target_inactive_sector',
                        'target_unsupported_role','target_unsupported_activity','target_no_docking_service',
                        'target_anchor_not_unique','target_anchor_out_of_bounds','invalid_target_location','invalid_target_shape')
        then 'That destination is not available.'
      else 'The ship is not available to move right now.'
    end);
end;
$$;

-- ── G. Re-lock execute surface (anti-cheat). New functions default-grant EXECUTE to PUBLIC on create →
--    revoke and re-grant ONLY the canonical client RPC list (carried verbatim from 0064) PLUS the one new
--    OSN-HUB-1A client wrapper command_main_ship_space_move_to_location. The new core writer + target-legality
--    predicate join the service_role-only server set; clients NEVER gain them or the begin-move core.
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
grant execute on function public.command_main_ship_space_move(double precision, double precision, uuid) to authenticated;
grant execute on function public.command_main_ship_space_stop(uuid)               to authenticated;
grant execute on function public.command_main_ship_space_move_to_location(uuid, uuid) to authenticated;  -- NEW (OSN-HUB-1A)
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.dev_set_main_ship_destroyed(uuid)                to service_role;
grant execute on function public.resolve_fleet_movement_speed(uuid)               to service_role;
grant execute on function public.process_mainship_expeditions()                   to service_role;
grant execute on function public.mainship_space_lock_context(uuid, boolean)       to service_role;
grant execute on function public.mainship_space_validate_context(uuid)            to service_role;
grant execute on function public.mainship_space_resolve_origin(uuid)              to service_role;
grant execute on function public.mainship_space_assert_cross_domain_exclusion(uuid) to service_role;
grant execute on function public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid) to service_role;
grant execute on function public.mainship_space_begin_move_core(uuid, uuid, text, double precision, double precision, uuid, uuid) to service_role;  -- NEW (OSN-HUB-1A)
grant execute on function public.mainship_space_location_target_legal(uuid)       to service_role;  -- NEW (OSN-HUB-1A)
grant execute on function public.process_mainship_space_arrivals()               to service_role;
grant execute on function public.mainship_space_dock_at_location(uuid, uuid)      to service_role;
grant execute on function public.mainship_space_settle_space_arrival(uuid, uuid, timestamptz) to service_role;
grant execute on function public.mainship_space_stop(uuid, uuid, uuid)            to service_role;
