-- Byeharu — LEGACY STOP = HOLD-IN-OPEN-SPACE (replaces the 0149/0152 return-home settlement).
--
-- BEFORE (0149, re-created body-verbatim in 0152): the visible Stop button
-- (command_main_ship_stop_transit) HALTED an outbound legacy main-ship transit and then flew the ship
-- all the way back to its ORIGIN BASE — it transformed the SAME fleet_movements row in place into the
-- return_home shape (symmetric turnaround; halt-point origin), stepped the fleet moving→returning, set
-- the ship 'returning', and let process_fleet_movements' base-arrival branch finish the trip home.
--
-- AFTER (this migration): Stop HALTS AND HOLDS. The ship stops at its current interpolated point and stays
-- there, parked in open space — it does NOT return home. "Stop" must mean halt-and-hold, not "abort and fly
-- home": returning home was the wrong semantic (the player asked to stop where they are, not to abandon the
-- trip and travel the whole way back), so the return-home transform is removed entirely.
--
-- WHY THIS IS A CLEAN, IN-DOMAIN CHANGE (no parallel movement system, no constraint edit, no new table,
-- no flag change, OSN untouched):
--   • The held terminal state is the ALREADY-LEGAL main_ship_instances shape (status='stationary',
--     spatial_state='in_space', space_x/y set) — legal under the 0055 lifecycle CHECKs
--     (main_ship_instances_ss_in_space_status: in_space ⇒ stationary, 0055:143-144; and
--     main_ship_instances_stationary_spatial_state: stationary ⇒ in_space|at_location, 0055:159-161) and
--     the 0054 coordinate rule (in_space REQUIRES both finite coordinates, 0054:63-74). This is the
--     canonical "held in open space" representation the OSN stop already writes (0064:319-322); the SHARED
--     INVARIANT is the 0055/0054 constraint set — the single source of truth for what "held in open space"
--     legally is. Each movement domain settles its OWN movement INLINE (no cross-domain helper, no OSN call):
--     this legacy path is written inline to match 0149/0152's established inline-write style.
--   • The fleet_movements row is TERMINATED with status='cancelled' (a first-class terminal in the 0007
--     status domain: 'moving','arrived','cancelled','failed' — 0007:32-33). 'cancelled' is the HONEST
--     terminal for a player halt: the ship did NOT arrive at target_x/target_y (that would be 'arrived',
--     a false claim), and it is not an error ('failed'). Once non-'moving', the cron's status='moving'
--     scan (process_fleet_movements, 0030:49-52; and movement_settle_arrival's status='moving' claim)
--     skips it forever — no arrival is ever processed, and no base/location deposit runs (main-ship legacy
--     targets carry no reward: activity_type='none', reward_payload_json='{}' — 0149:35-37).
--   • The fleet lands in the movement-less settled terminal status='completed', location_mode='movement',
--     active_movement_id=NULL, current_*=NULL — a legal 0006 shape (status/location_mode domains, 0006:12-15)
--     and the EXACT representation the OSN stop uses for a fleet held in open space (0064:312-317). It mirrors
--     how a normal legacy settlement leaves the fleet (fleet_complete → 'completed', 0006:155-167) but points
--     at no base/location because the ship stopped out in open space.
--
-- BOUNDARIES (unchanged): Movement stays the SOLE writer of fleet_movements; Main Ship stays the SOLE writer
-- of main_ship_instances. No cross-system call is added; the OSN coordinate domain (functions, tables, its
-- mainship_space_movement_enabled flag) is NOT touched. The mainship_send_enabled gate is preserved verbatim
-- (no flag flip, no gate change). Call graph stays acyclic; no new table; no schema/constraint change.
--
-- IDEMPOTENT / RACE-SAFE BY STATE (a stop grants nothing → no receipt needed):
--   • The command claims the moving fleet_movements row FOR UPDATE in the cron's OWN lock order (movement
--     row first, fleets after — process_fleet_movements, 0030:48-57), so the two never deadlock and the
--     cron's SKIP LOCKED scan simply skips a row this command holds. Every mutation is guarded status='moving'
--     under that lock.
--   • No moving row: if the ship is ALREADY held (stationary/in_space) this is a duplicate Stop →
--     {stopped:false, reason:'already_held'}; otherwise the cron settled the arrival first or there is no
--     transit → {stopped:false, reason:'already_settled'}. A due-but-unsettled row is LEFT for the cron
--     (reason:'arrived') so settlement stays single-path. (The old 'already_returning' no-op is gone: Stop
--     no longer produces a return_home row, so a duplicate Stop now surfaces as 'already_held'.)
--
-- RESPONSE SHAPE CHANGED: a successful hold returns {ok:true, stopped:true, held:true, main_ship_id,
-- space_x, space_y} — NO arrive_at (the ship is not arriving anywhere; it is parked). SLICE C updates the
-- client copy/handling to this shape. SLICE B adds legacy re-departure (Send) from the held position — no
-- existing legacy Send can resume from a spatial_state='in_space' fleet today. This migration is Slice A
-- (the stop settlement) only; it does not touch the Send/resume path or the frontend.

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
  v_ship    record;
  v_now     timestamptz;
  v_frac    double precision;
  v_turn_x  double precision;
  v_turn_y  double precision;
begin
  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated', 'message', 'You must be signed in.');
  end if;

  -- The EXISTING human gate — the same flag the visible legacy send surface checks (0050/0053). UNCHANGED.
  if not cfg_bool('mainship_send_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Main-ship movement is not available yet.');
  end if;

  -- Owned main-ship fleet only (the request_main_ship_return ownership predicate, 0050:181-187). UNCHANGED.
  select * into v_fleet from fleets where id = p_fleet and player_id = v_player;
  if v_fleet.id is null then
    return jsonb_build_object('ok', false, 'code', 'fleet_not_found', 'message', 'Fleet not found or not owned.');
  end if;
  if v_fleet.main_ship_id is null then
    return jsonb_build_object('ok', false, 'code', 'not_main_ship_fleet', 'message', 'Only the main ship can stop mid-transit.');
  end if;

  -- Claim the active movement in the cron's OWN lock order (movement row first; fleets after). At most one
  -- row exists (one_active_movement_per_fleet, 0007). UNCHANGED.
  select * into m from fleet_movements
    where fleet_id = p_fleet and status = 'moving'
    for update;
  if m.id is null then
    -- No moving row. Distinguish a DUPLICATE stop (ship already held in open space) from nothing-to-stop
    -- (cron settled the arrival first, or the ship was never in transit) — both are idempotent no-ops.
    select status, spatial_state into v_ship from main_ship_instances where main_ship_id = v_fleet.main_ship_id;
    if v_ship.status = 'stationary' and v_ship.spatial_state = 'in_space' then
      return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'already_held');
    end if;
    return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'already_settled');
  end if;

  v_now := clock_timestamp();
  if m.arrive_at <= v_now then
    -- Due: settlement belongs to process_fleet_movements alone (ONE settlement path). Report arrival. UNCHANGED.
    return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'arrived');
  end if;

  -- Interpolated halt point along the in-flight leg (UNCHANGED math; the return-home geometry is dropped).
  v_frac    := least(1.0, greatest(0.0, extract(epoch from (v_now - m.depart_at)) / m.travel_seconds));
  v_turn_x  := m.origin_x + (m.target_x - m.origin_x) * v_frac;
  v_turn_y  := m.origin_y + (m.target_y - m.origin_y) * v_frac;

  -- ── SETTLEMENT: HALT AND HOLD (was: transform to return_home) ──────────────────────────────────────────

  -- 1) Terminate the movement row NOW with the constraint-legal terminal 'cancelled' (0007:32-33). Once
  --    non-'moving', the cron's status='moving' scan skips it and NO arrival is ever processed. Guarded by
  --    status='moving' under the row lock — if anything settled it since, this touches nothing (no-op).
  update fleet_movements set
    status      = 'cancelled',
    resolved_at = v_now
    where id = m.id and status = 'moving';
  if not found then
    return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'already_settled');
  end if;

  -- 2) Settle the fleet to the movement-less held terminal — the EXACT shape the OSN stop leaves a fleet
  --    held in open space (0064:312-317): status='completed', location_mode='movement', pointer cleared, no
  --    base/location. Scoped to THIS main-ship fleet under the row lock; if the guarded update finds nothing
  --    (unreachable in practice — we hold the movement row and main-ship fleets never enter combat) abort
  --    loudly and roll the whole halt back rather than leave a half-settled pair (0149's rollback discipline).
  update fleets
    set status = 'completed', location_mode = 'movement', active_movement_id = null,
        current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = now()
    where id = p_fleet and status = 'moving' and active_movement_id = m.id;
  if not found then
    raise exception 'command_main_ship_stop_transit: fleet % not moving on movement % (halt rolled back)', p_fleet, m.id;
  end if;

  -- 3) Hold the ship in open space — the canonical (stationary, in_space) representation with the halt-point
  --    coordinates (0064:319-322; legal per 0055:143-144/159-161 + 0054:63-74). Inline write to match the
  --    0149/0152 established style; the shared invariant is the constraint set, not a helper.
  update main_ship_instances set
    status        = 'stationary',
    spatial_state = 'in_space',
    space_x       = v_turn_x,
    space_y       = v_turn_y,
    updated_at    = now()
    where main_ship_id = v_fleet.main_ship_id;

  return jsonb_build_object(
    'ok', true, 'stopped', true, 'held', true,
    'main_ship_id', v_fleet.main_ship_id, 'space_x', v_turn_x, 'space_y', v_turn_y);
end;
$$;

-- Execute surface preserved verbatim from 0149 (authenticated only; CREATE OR REPLACE already preserves it,
-- re-emitted here for explicitness — no other grant surface changes).
revoke execute on function public.command_main_ship_stop_transit(uuid) from public, anon;
grant  execute on function public.command_main_ship_stop_transit(uuid) to authenticated;
