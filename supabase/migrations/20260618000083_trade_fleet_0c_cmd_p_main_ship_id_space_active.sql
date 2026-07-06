-- Byeharu — TRADE-FLEET-0C §2.5: per-ship command conversion — the two ACTIVE space commands (#2, #3).
--
-- Third §2.5 commit: convert the two ACTIVE space commands command_main_ship_space_stop (#2) and
-- command_main_ship_space_move_to_location (#3) — both governed by `mainship_space_movement_enabled`
-- (true; the ENABLED port-to-port path). Each gains a TRAILING `p_main_ship_id uuid default null`, so
-- existing callers keep working (default null → sole-ship shim) — no commit is broken, no src/ change
-- until TRADE-UI-1. Both reuse the shared mainship_resolve_owned_ship helper (created in 0081).
--
-- ── DESIGN DECISION (planner authority — resolves the §2.5 [M] vs [C] tension) ────────────────────
-- #1 command_main_ship_space_move (the RAW arbitrary-coordinate command, 0070) is DEFERRED — honoring
-- §2.5's [C] row ("coordinate-gate command … stays dark; ship-scoped only when later touched — deferred,
-- not in 0C's active path"). It rejects deterministically at 0070:57 (mainship_coordinate_travel_enabled
-- = false) BEFORE its ship read at 0070:62, so its single-ship derivation is UNREACHABLE while dark;
-- converting it now is dead work on a dark path and would widen scope. Its signature stays unchanged
-- (so no verifier pin for it breaks); the future coordinate-enable slice owns ship-scoping it.
--
-- Each converted command resolves via mainship_resolve_owned_ship(auth.uid(), p_main_ship_id): explicit
-- selection → ownership asserted server-side (UI never trusted); null → sole ship only when the player
-- has exactly one; zero/>1 → null → the EXISTING {ok:false, code:'no_ship'} shape, verbatim. The distinct
-- not_authenticated early-return and (for #3) the flag gate are preserved byte-for-byte, in place. The
-- per-ship lock substrate is unchanged — the delegated writer now locks the SELECTED ship, never a
-- derived one. Idempotency keying (p_request_id) is untouched.
--
-- FROZEN VERIFIERS (deploy-time human repoint; out of this loop's scope): the PORT-ENTRY-1 production gate
-- and the dispatch-only OSN3/PORT-LAUNCH realchain-perm/postenable verifiers that pin pre-0C signatures via
-- ::regprocedure / to_regprocedure / has_function_privilege('…()') truthfully describe DEPLOYED production
-- (0072) and are NOT edited here. Every pin these conversions invalidate is recorded in
-- docs/TRADE_FLEET_0C_VERIFIER_REPOINT.md. This migration touches NO verifier file. Abstract columns,
-- flags, and src/ are untouched. DARK: explicit selection is inert while every player has ≤ 1 ship.

-- ── A. command_main_ship_space_stop (#2) — resolver swap; not_authenticated + no_ship shapes preserved.
drop function if exists public.command_main_ship_space_stop(uuid);
create function public.command_main_ship_space_stop(
  p_request_id uuid,
  p_main_ship_id uuid default null
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

  -- §2.5: resolve the SELECTED owned ship (explicit p_main_ship_id, ownership asserted) or the sole ship
  -- (shim); UI selection is never trusted. Null (unowned / zero / ambiguous >1) → existing no_ship shape.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
  if v_ship is null then
    return jsonb_build_object('ok', false, 'code', 'no_ship', 'message', 'You do not have a main ship.');
  end if;

  -- Delegate. The writer is the final authority on flag/ownership/state/boundary/precedence/idempotency.
  v_res := public.mainship_space_stop(v_player, v_ship, p_request_id);

  if (v_res->>'ok')::boolean is true then
    return jsonb_build_object(
      'ok', true,
      'outcome', v_res->'outcome',          -- 'stopped' | 'arrived'
      'movement_id', v_res->'movement_id',
      'stop_x', v_res->'stop_x',            -- present when outcome='stopped'
      'stop_y', v_res->'stop_y',
      'target_x', v_res->'target_x',        -- present when outcome='arrived'
      'target_y', v_res->'target_y');
  end if;

  v_reason := coalesce(v_res->>'reason', 'unavailable');
  return jsonb_build_object(
    'ok', false,
    'code', case v_reason
      when 'feature_disabled'              then 'feature_disabled'
      when 'not_in_transit'                then 'not_in_transit'
      when 'legacy_transit_not_stoppable'  then 'not_in_transit'
      when 'movement_not_moving'           then 'not_in_transit'
      when 'not_space_movement'            then 'not_stoppable'
      when 'invalid_movement_window'       then 'not_stoppable'
      when 'request_id_payload_conflict'   then 'request_conflict'
      when 'invalid_request_id'            then 'invalid_request'
      when 'destroyed'                     then 'ship_destroyed'
      when 'missing_ship'                  then 'no_ship'
      when 'not_owned'                     then 'no_ship'
      else 'unavailable'
    end,
    'message', case v_reason
      when 'feature_disabled'              then 'Coordinate movement is not available yet.'
      when 'not_in_transit'                then 'The ship is not currently travelling.'
      when 'legacy_transit_not_stoppable'  then 'The ship is not currently travelling.'
      when 'movement_not_moving'           then 'The ship is not currently travelling.'
      when 'request_id_payload_conflict'   then 'This command was already used.'
      when 'destroyed'                     then 'The ship must be repaired first.'
      else 'The ship cannot be stopped right now.'
    end);
end;
$$;

revoke execute on function public.command_main_ship_space_stop(uuid, uuid) from public, anon;
grant  execute on function public.command_main_ship_space_stop(uuid, uuid) to authenticated;

-- ── B. command_main_ship_space_move_to_location (#3) — resolver swap; flag gate + shapes preserved in place.
drop function if exists public.command_main_ship_space_move_to_location(uuid, uuid);
create function public.command_main_ship_space_move_to_location(
  p_location   uuid,
  p_request_id uuid,
  p_main_ship_id uuid default null
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

  -- §2.5: resolve the SELECTED owned ship (explicit p_main_ship_id, ownership asserted) or the sole ship
  -- (shim); UI selection is never trusted. Null (unowned / zero / ambiguous >1) → existing no_ship shape.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
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

revoke execute on function public.command_main_ship_space_move_to_location(uuid, uuid, uuid) from public, anon;
grant  execute on function public.command_main_ship_space_move_to_location(uuid, uuid, uuid) to authenticated;
