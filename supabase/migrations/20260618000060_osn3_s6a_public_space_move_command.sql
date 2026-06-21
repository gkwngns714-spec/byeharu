-- Byeharu — OSN-3 S6A: the FIRST public, player-facing coordinate-movement command boundary. flag-dark.
--
-- Adds ONE narrow, authenticated, SECURITY DEFINER wrapper, public.command_main_ship_space_move(...),
-- that lets a signed-in player command their OWN main ship to an open-space coordinate WITHOUT ever
-- touching the internal writer directly. It composes the deployed engine but adds NO movement math and
-- writes NO table itself: it (1) derives the caller from auth.uid(), (2) derives the caller's own main
-- ship server-side, (3) defense-in-depth flag-gates, (4) canonicalizes the target to the integer
-- world-unit grid, (5) DELEGATES to the existing private writer public.mainship_space_begin_move, and
-- (6) maps the writer's jsonb to a narrow player-safe payload. The private writer remains the FINAL
-- authority on the feature flag, ownership, bounds, availability/state, travel cap, locking, request-id
-- idempotency, and movement creation. Migrations 0050..0059 are untouched (no writer/processor/S2/S5
-- change); no migration adds a table, a cron job, a flag flip, or any UI.
--
-- DARK IN PRODUCTION: command_main_ship_space_move re-checks (and the writer is authoritative for)
-- mainship_space_movement_enabled, which stays FALSE on live. With the flag false the wrapper returns
-- {ok:false, code:'feature_disabled'} and writes nothing → net player-visible effect: none. The legacy
-- named-location path (mainship_send_enabled, TRUE on live) is entirely untouched and stays mutually
-- exclusive with coordinate movement for the same ship (a coordinate-domain ship — stationary/in_space
-- or traveling/in_transit — is neither 'home' nor 'present', so send_main_ship_expedition and
-- move_main_ship_to_location reject it by precondition; and the fleets active_movement_id XOR
-- active_space_movement_id CHECK + the one-active-coordinate-movement-per-ship index are the DB backstops).
--
-- HARDENING (Approved Decision 2): SECURITY DEFINER with a fixed safe search_path=public, all internal
-- calls schema-qualified, NO dynamic SQL, the caller handled only via auth.uid() (no client-supplied
-- player/ship id), EXECUTE granted ONLY to authenticated, and the private writer left service_role-only
-- (a normal client role can never execute mainship_space_begin_move directly).
--
-- CANONICALIZATION (Approved Decision 3): the integer world-unit grid. round(numeric) is half-AWAY-from-
-- zero and deterministic (round(0.5)=1, round(-0.5)=-1, round(2.5)=3), avoiding the half-to-even
-- ambiguity of round(double precision). Non-finite targets are rejected BEFORE the numeric cast (which
-- would otherwise raise on Infinity). Bounds remain the WRITER's authority: a canonical integer outside
-- [-10000,10000] is rejected downstream as target_out_of_bounds, so a raw value with |canonical| <= 10000
-- snaps inward to the boundary and is accepted, while a raw value rounding to |10001|+ rejects. The
-- response returns the canonical accepted target. Canonicalization is a discrete-grid concern ONLY —
-- p_request_id remains the idempotency key (the writer dedupes on (main_ship_id, request_id) + a
-- canonical payload hash; the same request_id with a different canonical target → request_conflict).

create or replace function public.command_main_ship_space_move(
  p_target_x   double precision,
  p_target_y   double precision,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player uuid := auth.uid();
  v_ship   uuid;
  v_cx     double precision;
  v_cy     double precision;
  v_res    jsonb;
  v_reason text;
begin
  -- 1) authenticated caller only (EXECUTE is granted to authenticated; this is a defensive guard).
  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated', 'message', 'You must be signed in.');
  end if;

  -- 2) defense-in-depth flag gate. NOT the security boundary — the private writer re-checks and is the
  --    final authority. Returning early keeps the feature fully dark (no lock taken) in production.
  if not public.cfg_bool('mainship_space_movement_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Coordinate movement is not available yet.');
  end if;

  -- 3) derive the caller's OWN main ship server-side (one ship per player). The client never supplies a
  --    player id or a ship id. SECURITY DEFINER (owner postgres) bypasses RLS for this owner-scoped read.
  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
  if v_ship is null then
    return jsonb_build_object('ok', false, 'code', 'no_ship', 'message', 'You do not have a main ship.');
  end if;

  -- 4) reject non-finite BEFORE canonicalizing (numeric cast of NaN/Infinity would raise, not return).
  if p_target_x is null or p_target_y is null
     or p_target_x = 'NaN'::double precision or p_target_x = 'Infinity'::double precision or p_target_x = '-Infinity'::double precision
     or p_target_y = 'NaN'::double precision or p_target_y = 'Infinity'::double precision or p_target_y = '-Infinity'::double precision then
    return jsonb_build_object('ok', false, 'code', 'invalid_target', 'message', 'Target coordinates are invalid.');
  end if;

  -- 5) canonicalize to the integer world-unit grid (half-away-from-zero; see header). Bounds stay the
  --    writer's authority — a canonical integer outside [-10000,10000] is rejected downstream.
  v_cx := round(p_target_x::numeric)::double precision;
  v_cy := round(p_target_y::numeric)::double precision;

  -- 6) DELEGATE to the existing private writer (final authority on flag/ownership/bounds/state/exclusion/
  --    travel-cap/locking/idempotency/movement creation). p_player from auth.uid(); ship derived above.
  --    The writer is service_role-only; this definer may invoke it, a client may not.
  v_res := public.mainship_space_begin_move(v_player, v_ship, v_cx, v_cy, p_request_id);

  -- 7) map the writer result to a NARROW player-safe payload (never forward internal fields/reasons).
  if (v_res->>'ok')::boolean is true then
    return jsonb_build_object(
      'ok', true,
      'movement_id', v_res->'movement_id',
      'main_ship_id', v_res->'main_ship_id',
      'target_x', v_res->'target_x',     -- canonical accepted target (integer world units)
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
      when 'invalid_coordinate'          then 'invalid_target'
      when 'target_out_of_bounds'        then 'out_of_bounds'
      when 'zero_distance'               then 'zero_distance'
      when 'travel_time_exceeds_limit'   then 'over_travel_cap'
      when 'request_id_payload_conflict' then 'request_conflict'
      when 'in_transit_must_stop'        then 'must_stop_first'
      when 'destroyed'                   then 'ship_destroyed'
      when 'active_legacy_movement'      then 'busy_legacy'
      when 'missing_ship'                then 'no_ship'
      when 'not_owned'                   then 'no_ship'
      else 'unavailable'                 -- origin_out_of_bounds / invalid_speed / coordinate_pointer_mismatch / presence_conflict / contradictory_state / lock states
    end,
    'message', case v_reason
      when 'feature_disabled'            then 'Coordinate movement is not available yet.'
      when 'invalid_request_id'          then 'Invalid command request.'
      when 'invalid_coordinate'          then 'Target coordinates are invalid.'
      when 'target_out_of_bounds'        then 'That destination is outside the navigable region.'
      when 'zero_distance'               then 'The ship is already at that point.'
      when 'travel_time_exceeds_limit'   then 'That destination is too far for a single jump.'
      when 'request_id_payload_conflict' then 'This command was already used for a different destination.'
      when 'in_transit_must_stop'        then 'The ship is already travelling.'
      when 'destroyed'                   then 'The ship must be repaired first.'
      when 'active_legacy_movement'      then 'Finish the current expedition first.'
      else 'The ship is not available to move right now.'
    end);
end;
$$;

-- ── Re-lock execute surface (anti-cheat). The new wrapper default-grants to PUBLIC on create → revoke
--    and re-grant ONLY the canonical client RPC list (carried verbatim from 0059) PLUS the one new S6A
--    client wrapper command_main_ship_space_move. The S3 writer + S4 processor + S5 destruction primitive
--    + four S2 helpers + existing server fns stay service_role ONLY — the client never gains the writer.
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
grant execute on function public.command_main_ship_space_move(double precision, double precision, uuid) to authenticated;  -- NEW (S6A)
-- Server / CI only (service_role); NEVER clients:
grant execute on function public.dev_set_main_ship_destroyed(uuid)                to service_role;
grant execute on function public.resolve_fleet_movement_speed(uuid)               to service_role;
grant execute on function public.process_mainship_expeditions()                   to service_role;
grant execute on function public.mainship_space_lock_context(uuid, boolean)       to service_role;
grant execute on function public.mainship_space_validate_context(uuid)            to service_role;
grant execute on function public.mainship_space_resolve_origin(uuid)              to service_role;
grant execute on function public.mainship_space_assert_cross_domain_exclusion(uuid) to service_role;
grant execute on function public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid) to service_role;
grant execute on function public.process_mainship_space_arrivals()               to service_role;
