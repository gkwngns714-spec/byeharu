-- Byeharu — MAINSHIP LEGACY SPATIAL-STATE FIX, slice 1 of 2: DEPARTURE/HALT pair-writes.
-- (docs/MAINSHIP_LEGACY_SPATIAL_STATE_FIX.md — recon/decision; this migration implements §5's
--  DEPARTURE + HALT/RETURN half. The ARRIVAL half — movement_settle_arrival's location branch +
--  the shared docking helper extracted from the OSN dock writer — is the NEXT migration, not this one.)
--
-- BUG BEING FIXED (live): every legacy main-ship status writer is spatial_state-blind. A canonically
-- docked ship (status='stationary', spatial_state='at_location' — commissioned via 0072, live/ungated)
-- has its fleet 'present', which is exactly what the legacy send surface accepts, so:
--   • move_main_ship_to_location (0053:105) sets status='traveling' leaving spatial_state='at_location'
--     → violates main_ship_instances_ss_at_location_status (0055) → the whole RPC aborts.  [LIVE BUG 1]
--   • request_main_ship_return (0051:213) sets status='returning' the same way.            [LIVE BUG 2]
--   • send_main_ship_expedition (0051:149) and command_main_ship_stop_transit (0149:152) are the same
--     writer class (status without spatial_state) — unreachable today, fixed for uniformity/defense.
--
-- DESIGN (decision doc §5): the legacy movement family lives entirely in the spatial_state=NULL legacy
-- domain (validate_context state 'legacy_transit'). It must NOT claim the coordinate-domain states
-- in_transit/in_space — those require coordinate-movement linkage (mainship_space_validate_context,
-- 0056:143-149) that a legacy fleet_movements trip cannot satisfy. So the ship write that accompanies
-- every legacy departure/halt/return is: status + spatial_state=NULL + space_x/y=NULL, in ONE statement,
-- expressed in ONE shared helper (four call sites, zero copies — the no-duplication hard rule).
--
-- The 0055 lifecycle CHECKs are CORRECT and untouched — this fixes WRITERS only. No flag is created,
-- read differently, or flipped: the four RPCs keep their existing 'mainship_send_enabled' gate lines
-- verbatim. No client/RPC signature changes (frontend untouched). Forward-only; no shipped migration edited.
--
-- BOUNDARIES: Main Ship remains the sole writer of main_ship_instances state; the four re-created RPCs
-- are the same Main-Ship-owned writers they were (0050 header: "The Main Ship system owns
-- main_ship_instances.status transitions for expeditions") — they now route that write through the one
-- Main-Ship-owned leaf helper below. Call graph stays acyclic (four existing writers → one new leaf).

-- ── 1) THE one legacy in-flight ship write (Main-Ship-owned leaf; service_role/internal only) ─────────────
-- This helper is the ONE place that expresses "legacy movement family → ship in the NULL (legacy) spatial
-- representation". Every legacy writer that puts a main ship in flight (departure, halt, return) MUST call
-- it instead of writing status inline; nothing else may express this transition.
--   • p_status is constrained to the two legal legacy in-flight statuses ('traveling' | 'returning') —
--     the helper can never express a coordinate-domain or terminal state.
--   • spatial_state=NULL is the legacy representation (decision doc §5): dropping a canonically-docked
--     (at_location/stationary) ship into legacy mode is exactly this write; for a ship already in the
--     legacy domain (spatial_state NULL) it is the same write the four RPCs performed before, plus no-op
--     NULL re-assertions. space_x/space_y are cleared in the SAME statement (at_location ships hold NULL
--     coords already; this guards against any future in_space-adjacent caller).
--   • Missing-ship semantics unchanged: like the four inline UPDATEs it replaces, an unknown
--     p_main_ship_id updates zero rows silently (every caller has already validated ownership).
-- RETIREMENT CONDITION: this helper retires when the legacy fleet_movements main-ship family
-- (send_main_ship_expedition / move_main_ship_to_location / request_main_ship_return /
-- command_main_ship_stop_transit) is replaced by the OSN coordinate domain — remove it in the same
-- change that retires its four callers.
create or replace function public.mainship_mark_legacy_in_flight(p_main_ship_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status not in ('traveling', 'returning') then
    raise exception 'mainship_mark_legacy_in_flight: illegal legacy in-flight status % (traveling|returning only)', p_status;
  end if;
  update public.main_ship_instances
    set status = p_status, spatial_state = null, space_x = null, space_y = null, updated_at = now()
    where main_ship_id = p_main_ship_id;
end;
$$;

-- ── 2) send_main_ship_expedition — 0051:65 body VERBATIM; only the ship write changes ──────────────────────
create or replace function public.send_main_ship_expedition(p_ships jsonb, p_location uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_ship_id  uuid;
  v_ship     record;
  v_base     record;
  v_loc      record;
  v_max      integer;
  v_active   integer;
  v_speed    double precision;
  v_fleet    uuid;
  v_movement uuid;
  v_arrive   timestamptz;
begin
  if v_player is null then
    raise exception 'send_main_ship_expedition: not authenticated';
  end if;

  if not cfg_bool('mainship_send_enabled') then
    raise exception 'send_main_ship_expedition: feature disabled';
  end if;

  if p_ships is null or jsonb_typeof(p_ships) <> 'array' or jsonb_array_length(p_ships) <> 1 then
    raise exception 'send_main_ship_expedition: exactly one ship required';
  end if;
  v_ship_id := (p_ships->>0)::uuid;
  if v_ship_id is null then
    raise exception 'send_main_ship_expedition: invalid ship id';
  end if;

  select * into v_ship from main_ship_instances
    where main_ship_id = v_ship_id and player_id = v_player;
  if v_ship.main_ship_id is null then
    raise exception 'send_main_ship_expedition: ship not found or not owned';
  end if;
  if v_ship.status <> 'home' then
    raise exception 'send_main_ship_expedition: ship not available (status %)', v_ship.status;
  end if;

  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' then
    raise exception 'send_main_ship_expedition: location not found or inactive';
  end if;
  if v_loc.activity_type <> 'none' then
    raise exception 'send_main_ship_expedition: only non-combat locations supported in Phase 10C (got %)', v_loc.activity_type;
  end if;

  v_max := coalesce(cfg_num('max_active_fleets'), 3);
  select count(*) into v_active
    from fleets where player_id = v_player and status in ('moving','present','returning');
  if v_active >= v_max then
    raise exception 'send_main_ship_expedition: active fleet limit reached (%/%)', v_active, v_max;
  end if;

  select id, x, y, sector_id into v_base
    from bases where player_id = v_player and status = 'active'
    order by created_at limit 1;
  if v_base.id is null then
    raise exception 'send_main_ship_expedition: no active home base';
  end if;

  -- Insert the fleets row DIRECTLY (no fleet_units), tagged with main_ship_id.
  insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)
    values (v_player, v_base.id, 'idle', 'base', v_base.id, v_ship_id)
    returning id into v_fleet;

  -- Canonical speed resolver (main-ship branch → hull base_speed).
  v_speed := resolve_fleet_movement_speed(v_fleet);

  v_movement := movement_create(
    v_player, v_fleet,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'rally', v_speed);
  perform fleet_set_moving(v_fleet, v_movement);

  -- Ship → legacy in-flight (status + spatial_state=NULL pair-write; the ONE shared 0152 helper).
  perform public.mainship_mark_legacy_in_flight(v_ship_id, 'traveling');

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'fleet_id', v_fleet, 'movement_id', v_movement,
    'main_ship_id', v_ship_id, 'arrive_at', v_arrive);
end;
$$;

-- ── 3) request_main_ship_return — 0051:160 body VERBATIM; only the ship write changes ──────────────────────
create or replace function public.request_main_ship_return(p_fleet uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_fleet    record;
  v_presence record;
  v_base     record;
  v_loc      record;
  v_speed    double precision;
  v_movement uuid;
begin
  if v_player is null then
    raise exception 'request_main_ship_return: not authenticated';
  end if;

  select * into v_fleet from fleets where id = p_fleet and player_id = v_player;
  if v_fleet.id is null then
    raise exception 'request_main_ship_return: fleet not found or not owned';
  end if;
  if v_fleet.main_ship_id is null then
    raise exception 'request_main_ship_return: not a main-ship fleet';
  end if;
  if v_fleet.status <> 'present' then
    raise exception 'request_main_ship_return: fleet not present (status %)', v_fleet.status;
  end if;

  select * into v_presence from location_presence
    where fleet_id = p_fleet and status = 'active';
  if v_presence.id is null then
    raise exception 'request_main_ship_return: no active presence for fleet';
  end if;

  select id, x, y into v_base from bases where id = v_fleet.origin_base_id;
  if v_base.id is null then
    raise exception 'request_main_ship_return: origin base missing';
  end if;
  select x, y into v_loc from locations where id = v_presence.location_id;

  -- Canonical speed resolver (main-ship branch → hull base_speed). Never NULL for a main-ship fleet.
  v_speed := resolve_fleet_movement_speed(p_fleet);

  perform presence_complete(v_presence.id);
  v_movement := movement_create(
    v_player, p_fleet,
    'location', null, v_presence.zone_id, v_presence.location_id, v_loc.x, v_loc.y,
    'base', v_base.id, null, null, v_base.x, v_base.y,
    'return_home', v_speed);
  perform fleet_set_returning(p_fleet, v_movement);

  -- Ship → legacy in-flight (status + spatial_state=NULL pair-write; the ONE shared 0152 helper).
  -- This is the write that let an at_location ship violate ss_at_location_status before 0152. [LIVE BUG 2]
  perform public.mainship_mark_legacy_in_flight(v_fleet.main_ship_id, 'returning');

  return jsonb_build_object('return_movement_id', v_movement, 'main_ship_id', v_fleet.main_ship_id);
end;
$$;

-- ── 4) move_main_ship_to_location — 0053:14 body VERBATIM; only the ship write changes ─────────────────────
create or replace function public.move_main_ship_to_location(p_fleet uuid, p_location uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player   uuid := auth.uid();
  v_fleet    record;
  v_presence record;
  v_loc      record;  -- destination B
  v_cur      record;  -- current location A (movement origin)
  v_speed    double precision;
  v_movement uuid;
  v_arrive   timestamptz;
begin
  if v_player is null then
    raise exception 'move_main_ship_to_location: not authenticated';
  end if;

  if not cfg_bool('mainship_send_enabled') then
    raise exception 'move_main_ship_to_location: feature disabled';
  end if;

  -- Must be the caller's main-ship fleet, currently PRESENT at a location (the new sendable state).
  select * into v_fleet from fleets where id = p_fleet and player_id = v_player;
  if v_fleet.id is null then
    raise exception 'move_main_ship_to_location: fleet not found or not owned';
  end if;
  if v_fleet.main_ship_id is null then
    raise exception 'move_main_ship_to_location: not a main-ship fleet';
  end if;
  if v_fleet.status <> 'present' then
    -- moving / returning / (no active fleet → destroyed/home) are all rejected here.
    raise exception 'move_main_ship_to_location: ship not present (status %)', v_fleet.status;
  end if;

  -- Active presence pins the current location A (movement origin).
  select * into v_presence from location_presence
    where fleet_id = p_fleet and status = 'active';
  if v_presence.id is null then
    raise exception 'move_main_ship_to_location: no active presence for fleet';
  end if;

  -- Defensive same-location reject (UI also excludes the current location).
  if p_location = v_presence.location_id then
    raise exception 'move_main_ship_to_location: main ship is already at that location';
  end if;

  -- Destination B: exists, active, NON-COMBAT only.
  select l.id, l.x, l.y, l.activity_type, l.status, l.zone_id, z.sector_id
    into v_loc
    from locations l join zones z on z.id = l.zone_id
    where l.id = p_location;
  if v_loc.id is null or v_loc.status <> 'active' then
    raise exception 'move_main_ship_to_location: location not found or inactive';
  end if;
  if v_loc.activity_type <> 'none' then
    raise exception 'move_main_ship_to_location: only non-combat locations supported (got %)', v_loc.activity_type;
  end if;

  -- Current location A coords for the movement origin (depart from A, not from base).
  select x, y into v_cur from locations where id = v_presence.location_id;
  if v_cur.x is null then
    raise exception 'move_main_ship_to_location: current location missing';
  end if;

  -- Hull speed via the canonical resolver (the fleet carries no units).
  v_speed := resolve_fleet_movement_speed(p_fleet);

  -- Close presence at A, then depart A → B (mission 'rally' = non-combat).
  perform presence_complete(v_presence.id);
  v_movement := movement_create(
    v_player, p_fleet,
    'location', null, v_presence.zone_id, v_presence.location_id, v_cur.x, v_cur.y,
    'location', null, null, v_loc.id, v_loc.x, v_loc.y,
    'rally', v_speed);

  -- Dedicated present → moving transition (the generic state machine has no such transition).
  -- Scoped to THIS main-ship fleet only; mirrors fleet_set_returning's field changes but to
  -- 'moving' so process_fleet_movements' outbound branch can fleet_set_present on arrival at B.
  update fleets
    set status = 'moving', location_mode = 'movement', active_movement_id = v_movement,
        current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = now()
    where id = p_fleet and status = 'present';
  if not found then
    raise exception 'move_main_ship_to_location: fleet % no longer present', p_fleet;
  end if;

  -- Main ship stays "traveling" (en route again) — status + spatial_state=NULL pair-write via the ONE
  -- shared 0152 helper. This is the write that violated ss_at_location_status on a canonically-docked
  -- (at_location) ship before 0152. [LIVE BUG 1 — the reported failure]
  perform public.mainship_mark_legacy_in_flight(v_fleet.main_ship_id, 'traveling');

  select arrive_at into v_arrive from fleet_movements where id = v_movement;
  return jsonb_build_object(
    'fleet_id', p_fleet, 'movement_id', v_movement, 'main_ship_id', v_fleet.main_ship_id,
    'from_location_id', v_presence.location_id, 'to_location_id', v_loc.id, 'arrive_at', v_arrive);
end;
$$;

-- ── 5) command_main_ship_stop_transit — 0149:44 body VERBATIM; only the ship write changes ─────────────────
create or replace function public.command_main_ship_stop_transit(p_fleet uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player  uuid := auth.uid();
  v_fleet   record;
  m         record;
  v_base    record;
  v_now     timestamptz;
  v_elapsed double precision;
  v_frac    double precision;
  v_turn_x  double precision;
  v_turn_y  double precision;
  v_arrive  timestamptz;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated', 'message', 'You must be signed in.');
  end if;

  -- The EXISTING human gate — the same flag the visible legacy send surface checks (0050/0053).
  if not cfg_bool('mainship_send_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Main-ship movement is not available yet.');
  end if;

  -- Owned main-ship fleet only (the request_main_ship_return ownership predicate, 0050:181-187).
  select * into v_fleet from fleets where id = p_fleet and player_id = v_player;
  if v_fleet.id is null then
    return jsonb_build_object('ok', false, 'code', 'fleet_not_found', 'message', 'Fleet not found or not owned.');
  end if;
  if v_fleet.main_ship_id is null then
    return jsonb_build_object('ok', false, 'code', 'not_main_ship_fleet', 'message', 'Only the main ship can stop mid-transit.');
  end if;

  -- Claim the active movement in the cron's OWN lock order (movement row first; fleets after). At most one
  -- row exists (one_active_movement_per_fleet, 0007).
  select * into m from fleet_movements
    where fleet_id = p_fleet and status = 'moving'
    for update;
  if m.id is null then
    -- The cron settled the arrival first, or there is no transit — idempotent no-op.
    return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'already_settled');
  end if;
  if m.mission_type = 'return_home' then
    -- Duplicate stop, or the ship is already heading home — idempotent no-op.
    return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'already_returning');
  end if;

  v_now := clock_timestamp();
  if m.arrive_at <= v_now then
    -- Due: settlement belongs to process_fleet_movements alone (ONE settlement path). Report arrival.
    return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'arrived');
  end if;

  -- Home = the fleet's origin base (the same return target request_main_ship_return uses).
  select id, x, y into v_base from bases where id = v_fleet.origin_base_id;
  if v_base.id is null then
    return jsonb_build_object('ok', false, 'code', 'no_home_base', 'message', 'Home base unavailable.');
  end if;

  -- Symmetric turnaround: return time = time already spent outbound (floored at 1s so the row's
  -- arrive_at > depart_at constraint always holds); geometry starts at the interpolated halt point.
  v_elapsed := greatest(extract(epoch from (v_now - m.depart_at)), 1.0);
  v_frac    := least(1.0, greatest(0.0, extract(epoch from (v_now - m.depart_at)) / m.travel_seconds));
  v_turn_x  := m.origin_x + (m.target_x - m.origin_x) * v_frac;
  v_turn_y  := m.origin_y + (m.target_y - m.origin_y) * v_frac;
  v_arrive  := v_now + make_interval(secs => v_elapsed);

  -- Transform the SAME row into the return_home shape (status stays 'moving'; guarded by the cron's own
  -- status='moving' condition under the row lock — if anything settled it since, this touches nothing).
  update fleet_movements set
    origin_type        = m.target_type,   -- provenance: returning from the halted trip's destination
    origin_base_id     = m.target_base_id,
    origin_zone_id     = m.target_zone_id,
    origin_location_id = m.target_location_id,
    origin_x           = v_turn_x,        -- geometry: the actual halt point (display interpolation)
    origin_y           = v_turn_y,
    target_type        = 'base',
    target_base_id     = v_base.id,
    target_zone_id     = null,
    target_location_id = null,
    target_x           = v_base.x,
    target_y           = v_base.y,
    mission_type       = 'return_home',
    depart_at          = v_now,
    arrive_at          = v_arrive,
    travel_distance    = sqrt(power(v_base.x - v_turn_x, 2) + power(v_base.y - v_turn_y, 2)),
    travel_seconds     = v_elapsed
    where id = m.id and status = 'moving';
  if not found then
    return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'already_settled');
  end if;

  -- Dedicated moving → returning transition, scoped to THIS main-ship fleet only (the generic state
  -- machine has no moving→returning edge — the exact 0053 idiom for its missing present→moving edge).
  -- fleet_complete (0006:163) then accepts the base arrival exactly like any return.
  update fleets
    set status = 'returning', updated_at = now()
    where id = p_fleet and status = 'moving' and active_movement_id = m.id;
  if not found then
    -- Unreachable in practice (we hold the movement row; main-ship fleets never enter combat) — abort
    -- loudly and roll the whole halt back rather than leave a half-transformed pair.
    raise exception 'command_main_ship_stop_transit: fleet % not moving on movement % (halt rolled back)', p_fleet, m.id;
  end if;

  -- The ship is now heading home (mirrors request_main_ship_return) — status + spatial_state=NULL
  -- pair-write via the ONE shared 0152 helper.
  perform public.mainship_mark_legacy_in_flight(v_fleet.main_ship_id, 'returning');

  return jsonb_build_object(
    'ok', true, 'stopped', true,
    'movement_id', m.id, 'main_ship_id', v_fleet.main_ship_id, 'arrive_at', v_arrive);
end;
$$;

-- ── 6) Execute surface ─────────────────────────────────────────────────────────────────────────────────────
-- CREATE OR REPLACE on an EXISTING function PRESERVES its owner and grants (Postgres semantics), so the
-- four re-created RPCs keep their current client grants (authenticated, from 0053/0149's canonical grant
-- lists) automatically — deliberately NO blanket `revoke execute on all functions ...` re-lock here: that
-- idiom belongs to migrations that add NEW client RPCs and would force re-carrying the entire canonical
-- grant list, which is error-prone. Only the NEWLY-CREATED helper default-grants EXECUTE to PUBLIC on
-- create and must be locked down (0093/0096/0151 internal-function idiom): SECURITY DEFINER orchestrators
-- invoke it as owner; no client path.
revoke execute on function public.mainship_mark_legacy_in_flight(uuid, text) from public, anon, authenticated;
grant  execute on function public.mainship_mark_legacy_in_flight(uuid, text) to service_role;
