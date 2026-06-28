-- OSN-COORD-GATE-1 — server-authoritative coordinate-travel gate.
--
-- Closes a pre-existing mismatch: the public raw coordinate command public.command_main_ship_space_move() was
-- guarded only by mainship_space_movement_enabled (which is TRUE for the ENABLED port-to-port path), while the
-- "free coordinate travel OFF" control (OSN_COORDINATE_TRAVEL_ENABLED) lived ONLY in the frontend as a
-- compile-time const. An authenticated direct API caller could therefore request arbitrary coordinates.
--
-- This migration adds a SERVER-OWNED config key (default FALSE) and makes the raw coordinate command reject
-- deterministically unless that key is true — BEFORE any ship read, lock, or writer call (no movement row, no
-- receipt, no ship/fleet/presence mutation). Everything else in the command is preserved verbatim from
-- migration 0060 (auth, ownership, finite/grid validation, delegation to mainship_space_begin_move).
--
-- NOT TOUCHED: public.command_main_ship_space_move_to_location() (the approved port-identity boundary) — it
-- stays governed by mainship_space_movement_enabled and continues to serve legal active port targets. No change
-- to mainship_space_movement_enabled, mainship_send_enabled, bounds, Dock-0, anchors, ports, locations,
-- player_home_port, bases, Trading, or any frontend.

-- 1) server-owned coordinate-travel flag (OFF on live). Separate from mainship_space_movement_enabled so the
--    enabled port-to-port (location-target) path is unaffected. game_config is server-owned (no client write).
insert into public.game_config (key, value, description) values
  ('mainship_coordinate_travel_enabled', 'false',
   'OSN-COORD-GATE-1: server-authoritative gate for FREE arbitrary-coordinate main-ship travel '
   '(command_main_ship_space_move). OFF on live; port-to-port location-target travel is unaffected.')
on conflict (key) do nothing;

-- 2) re-create the raw coordinate command with the added server gate (step 2b); all other steps verbatim (0060).
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
  -- 1) authenticated caller only.
  if v_player is null then
    return jsonb_build_object('ok', false, 'code', 'not_authenticated', 'message', 'You must be signed in.');
  end if;

  -- 2) defense-in-depth movement-domain flag (UNCHANGED). Stays true for the enabled port-to-port path.
  if not public.cfg_bool('mainship_space_movement_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled', 'message', 'Coordinate movement is not available yet.');
  end if;

  -- 2b) OSN-COORD-GATE-1: SERVER-AUTHORITATIVE gate for FREE arbitrary-coordinate travel. When false, reject
  --     deterministically BEFORE any ship read, lock, or writer call — no movement row, no receipt, no
  --     ship/fleet/presence mutation. The location-target command is a separate RPC and is NOT affected.
  if not public.cfg_bool('mainship_coordinate_travel_enabled') then
    return jsonb_build_object('ok', false, 'code', 'coordinate_travel_disabled', 'message', 'Free coordinate travel is disabled.');
  end if;

  -- 3) derive the caller's OWN main ship server-side (one ship per player; client supplies no player/ship id).
  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
  if v_ship is null then
    return jsonb_build_object('ok', false, 'code', 'no_ship', 'message', 'You do not have a main ship.');
  end if;

  -- 4) reject non-finite BEFORE canonicalizing.
  if p_target_x is null or p_target_y is null
     or p_target_x = 'NaN'::double precision or p_target_x = 'Infinity'::double precision or p_target_x = '-Infinity'::double precision
     or p_target_y = 'NaN'::double precision or p_target_y = 'Infinity'::double precision or p_target_y = '-Infinity'::double precision then
    return jsonb_build_object('ok', false, 'code', 'invalid_target', 'message', 'Target coordinates are invalid.');
  end if;

  -- 5) canonicalize to the integer world-unit grid (bounds stay the writer's authority).
  v_cx := round(p_target_x::numeric)::double precision;
  v_cy := round(p_target_y::numeric)::double precision;

  -- 6) DELEGATE to the existing private writer (final authority on flag/ownership/bounds/state/exclusion/
  --    travel-cap/locking/idempotency/movement creation). Service_role-only; this definer may invoke it.
  v_res := public.mainship_space_begin_move(v_player, v_ship, v_cx, v_cy, p_request_id);

  -- 7) map the writer result to a NARROW player-safe payload (never forward internal fields/reasons).
  if (v_res->>'ok')::boolean is true then
    return jsonb_build_object(
      'ok', true,
      'movement_id', v_res->'movement_id',
      'main_ship_id', v_res->'main_ship_id',
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
      else 'unavailable'
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

-- 3) defense-in-depth ACL re-assert (CREATE OR REPLACE preserves the existing ACL; re-assert authenticated-only).
revoke execute on function public.command_main_ship_space_move(double precision, double precision, uuid) from public, anon;
grant  execute on function public.command_main_ship_space_move(double precision, double precision, uuid) to authenticated;
