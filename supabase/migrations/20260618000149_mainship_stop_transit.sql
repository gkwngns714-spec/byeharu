-- Byeharu — MOVEMENT UX (item 3): halt an in-transit LEGACY main-ship move → symmetric return home.
--
-- Gap being closed: the visible send surfaces (send_main_ship_expedition 0050 / move_main_ship_to_location
-- 0053) create legacy fleet_movements, and NOTHING can halt one mid-flight today — request_main_ship_return
-- (0050) requires status='present', and the OSN Stop (0064/0067) only sees main_ship_space_movements. The
-- legacy domain deliberately has NO "hold in open space" state (that is an OSN concept — recreating it here
-- would be a forbidden parallel movement system), so the principled stop is a Fleet/Movement-domain
-- HALT → RETURN-HOME on the fleet system's own table.
--
-- SEMANTICS (design decision): stopping an outbound legacy transit turns the ship around at its current
-- interpolated point and returns it to its ORIGIN BASE with a SYMMETRIC turnaround — it arrives home after
-- exactly the time already spent outbound (arrive_at = now() + elapsed, elapsed floored at 1s). The SAME
-- movement row is transformed in place into the return_home shape request_main_ship_return produces
-- (mission_type='return_home', target=origin base), so:
--   • the one-active-movement-per-fleet invariant (0007) holds by construction (no second row);
--   • ONE settlement path remains — process_fleet_movements' existing base-arrival branch (0030) finishes
--     it (fleet_complete + no unit merge for a unit-less main-ship fleet);
--   • the row's new origin_x/y is the interpolated halt point, so map interpolation shows the ship turning
--     around in place (origin entity ids keep the halted trip's destination as provenance).
--   • travel_seconds is the DESIGN-fixed symmetric time (not distance/speed_used-derived — documented here;
--     speed_used keeps the outbound hull speed, satisfying its >0 constraint).
--
-- GATED ON THE EXISTING HUMAN GATE: cfg 'mainship_send_enabled' — the SAME flag that gates the visible send
-- surface (0050:73 / 0053:34). No new flag, no flip: dark environments reject with feature_disabled; the
-- already-enabled live environment gets the capability. NOT applied to any database by this commit.
--
-- IDEMPOTENT / RACE-SAFE BY STATE (no receipts needed — a stop grants nothing):
--   • The command claims the movement row FOR UPDATE in the cron's OWN lock order (process_fleet_movements
--     locks due movement rows first, then updates fleets — 0030:48-57), so the two can never deadlock, and
--     the cron's SKIP LOCKED scan simply skips a row this command holds.
--   • Every mutation is guarded by status='moving' under that lock: if the cron settled the arrival first
--     the command finds nothing and no-ops ({ok:true, stopped:false, reason:'already_settled'}); a
--     duplicate call finds mission_type='return_home' and no-ops ('already_returning'); a due-but-unsettled
--     row is LEFT for the cron (reason:'arrived') so settlement stays single-path.
--   • No double-reward is possible: main-ship legacy targets are activity_type='none' (0050:104 / 0053:71),
--     so no combat ever attaches cargo, reward_payload_json stays '{}', and the base-arrival deposit branch
--     (0030:70-72) requires a non-empty payload + source. The transform touches no reward field.
--
-- BOUNDARIES: Movement stays the sole writer of fleet_movements. The fleets moving→returning transition is
-- a dedicated, main-ship-scoped inline update (the generic state machine has no moving→returning edge) —
-- the EXACT 0053 idiom used there for its missing present→moving edge. The main_ship_instances.status write
-- mirrors request_main_ship_return (0050:223). Call graph stays acyclic; no new table; no OSN state touched.

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

  -- The ship is now heading home (mirrors request_main_ship_return, 0050:223).
  update main_ship_instances set status = 'returning', updated_at = now()
    where main_ship_id = v_fleet.main_ship_id;

  return jsonb_build_object(
    'ok', true, 'stopped', true,
    'movement_id', m.id, 'main_ship_id', v_fleet.main_ship_id, 'arrive_at', v_arrive);
end;
$$;

revoke execute on function public.command_main_ship_stop_transit(uuid) from public, anon;
grant  execute on function public.command_main_ship_stop_transit(uuid) to authenticated;
