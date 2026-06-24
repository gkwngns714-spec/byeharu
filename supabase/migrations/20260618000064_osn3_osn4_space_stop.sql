-- Byeharu — OSN-4: player Stop-mid-travel for an active open-space coordinate movement. flag-dark, additive.
--
-- Adds the first capability to terminate an in-flight target_kind='space' coordinate movement at the ship's
-- CURRENT interpolated point, plus an authenticated public wrapper. It composes the deployed S2 boundary
-- (lock → validate) and reuses the existing receipts/idempotency and the proven in_space settlement shape.
--
-- This pass adds, in order:
--   A. mainship_space_settle_space_arrival(ship, movement_id, now) — the shared, PRIVATE, lock-NEUTRAL
--      in_space arrival-settlement primitive. It takes NO new lock, runs NO due-scan, and samples NO time:
--      the caller must already hold the canonical S2 locks (ship → fleets → movement → presence) and pass
--      the locked movement id + ONE captured timestamp. It asserts a valid moving target_kind='space'
--      movement before settling. (Constraint 2.)
--   B. process_mainship_space_arrivals — re-created verbatim from 0061 EXCEPT the in_space ('else') branch,
--      which now captures clock_timestamp() once and DELEGATES to the shared primitive. The DOCK-0
--      location branch, the non-locking due scan, the canonical ship-claim, the in_transit validate, the
--      cross-domain exclusion, and the re-read-under-lock linkage checks are ALL unchanged → identical
--      arrival semantics + exactly-once preserved (proven by non-regression).
--   C. mainship_space_stop(player, ship, request_id) — the PRIVATE service_role-only Stop writer.
--   D. command_main_ship_space_stop(request_id) — the authenticated public Stop wrapper.
--
-- ARRIVAL PRECEDENCE AT THE BOUNDARY (Constraint B): the writer captures ONE clock_timestamp() AFTER the
--   locks are held. Stop settles 'stopped' ONLY when clock_timestamp() < arrive_at (interpolation t and
--   resolved_at use that SAME timestamp). At/after arrive_at it must NEVER record 'stopped' at the
--   destination — it settles the canonical ARRIVAL ('arrived') through the SAME shared primitive A.
--
-- IN-FLIGHT SAFETY vs INITIATION FLAG (Constraint 1): mainship_space_movement_enabled gates CREATION of
--   coordinate moves. Stop must never strand a ship already in a valid active coordinate transit after a
--   later emergency disable. So the writer returns 'feature_disabled' ONLY when there is NO active
--   coordinate transit (keeping the whole surface dark today, since no coordinate moves can exist while the
--   flag is false). When a real active in_transit coordinate move exists, Stop PROCEEDS regardless of the flag.
--
-- HARD BOUNDARIES: never touches DOCK-0 (the location branch + mainship_space_dock_at_location are
--   unchanged; the shared primitive covers ONLY the pre-existing in_space settlement), space_anchors,
--   ports/recovery fields, zones, the world coordinate bound (±10000), or any flag value (the existing flag
--   is READ, never written; no new flag). Lock order is the S2 canonical order ONLY; legacy fleet_movements
--   is never locked. No advisory locks, no dynamic SQL. mainship_send_enabled untouched.

-- ── A. Shared, private, lock-NEUTRAL in_space arrival-settlement primitive ─────────────────────────────────
-- Contract: the CALLER already holds the canonical S2 locks and proved coherence; this re-reads those
-- already-locked rows (same txn — no new lock, no scan), asserts a valid moving target_kind='space'
-- movement, and settles it to the canonical in_space arrival using the caller's captured p_now (it takes NO
-- separate time sample). Returns {ok, outcome:'arrived', ...} or {ok:false, reason}.
create or replace function public.mainship_space_settle_space_arrival(
  p_main_ship_id uuid,
  p_movement_id  uuid,
  p_now          timestamptz
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv    main_ship_space_movements%rowtype;
  v_fleet fleets%rowtype;
begin
  -- Re-read the already-locked movement (defensive; caller proved it active/coherent). No new lock.
  select * into v_mv from main_ship_space_movements
    where id = p_movement_id and main_ship_id = p_main_ship_id and status = 'moving';
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'movement_not_moving');
  end if;
  -- Explicit movement boundary: this primitive settles ONLY open-space movements with a valid window.
  if v_mv.target_kind <> 'space' then
    return jsonb_build_object('ok', false, 'reason', 'not_space_movement');
  end if;
  if not (v_mv.arrive_at > v_mv.depart_at) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_movement_window');
  end if;

  select * into v_fleet from fleets where id = v_mv.fleet_id;

  -- Canonical in_space arrival settlement (byte-for-byte the prior S4 'else' branch; timestamps = p_now).
  update main_ship_space_movements
    set status = 'arrived', resolved_at = p_now, terminal_reason = 'auto_arrival'
    where id = v_mv.id and status = 'moving';

  update fleets
    set status = 'completed', location_mode = 'movement',
        active_space_movement_id = null, active_movement_id = null,
        current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = p_now
    where id = v_fleet.id;

  update main_ship_instances
    set status = 'stationary', spatial_state = 'in_space',
        space_x = v_mv.target_x, space_y = v_mv.target_y, updated_at = p_now
    where main_ship_id = p_main_ship_id;

  return jsonb_build_object('ok', true, 'outcome', 'arrived',
    'movement_id', v_mv.id, 'target_x', v_mv.target_x, 'target_y', v_mv.target_y, 'resolved_at', p_now);
end;
$$;

-- ── B. process_mainship_space_arrivals — DOCK-0 (0061) verbatim EXCEPT the in_space branch delegates ──────
create or replace function public.process_mainship_space_arrivals()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  cand     record;
  v_lock   jsonb;
  v_val    jsonb;
  v_excl   jsonb;
  v_mv     main_ship_space_movements%rowtype;
  v_fleet  fleets%rowtype;
  v_now    timestamptz;
  v_settled integer := 0;
begin
  -- 1) NON-LOCKING candidate scan: due, still-moving rows only.
  for cand in
    select main_ship_id, id as movement_id
    from main_ship_space_movements
    where status = 'moving' and arrive_at <= now()
    order by arrive_at, id
    limit 100
  loop
    -- 2) claim the SHIP first, skip-locked (canonical order ship → fleet → movement → presence).
    v_lock := public.mainship_space_lock_context(cand.main_ship_id, true);
    if (v_lock->>'status') is distinct from 'locked' then
      continue;  -- 3) held by another worker / not_found → retry next tick
    end if;

    -- 4) the locked context must be a coherent in_transit ship.
    v_val := public.mainship_space_validate_context(cand.main_ship_id);
    if (v_val->>'ok')::boolean is not true or (v_val->>'state') is distinct from 'in_transit' then
      raise notice 'process_mainship_space_arrivals: skip (not coherent in_transit) ship=% movement=% reason=%',
        cand.main_ship_id, cand.movement_id, coalesce(v_val->>'reason', v_val->>'state');
      continue;  -- frozen failure policy: leave every affected row UNTOUCHED
    end if;

    -- 5) cross-domain exclusion: no active legacy movement / pointer conflict / presence conflict.
    v_excl := public.mainship_space_assert_cross_domain_exclusion(cand.main_ship_id);
    if (v_excl->>'ok')::boolean is not true then
      raise notice 'process_mainship_space_arrivals: skip (cross-domain exclusion) ship=% movement=% reason=%',
        cand.main_ship_id, cand.movement_id, v_excl->>'reason';
      continue;
    end if;

    -- 6) re-read UNDER LOCK and confirm the candidate is still the active, due, coherently-linked move.
    select * into v_mv from main_ship_space_movements
      where main_ship_id = cand.main_ship_id and status = 'moving';
    if not found or v_mv.id is distinct from cand.movement_id or v_mv.arrive_at > now() then
      raise notice 'process_mainship_space_arrivals: skip (no longer the active/due movement) ship=% movement=%',
        cand.main_ship_id, cand.movement_id;
      continue;
    end if;
    select * into v_fleet from fleets where id = v_mv.fleet_id;
    if not found
       or v_fleet.main_ship_id is distinct from cand.main_ship_id
       or v_fleet.status <> 'moving'
       or v_fleet.location_mode <> 'movement'
       or v_fleet.active_space_movement_id is distinct from v_mv.id
       or v_fleet.active_movement_id is not null
       or v_mv.player_id is distinct from v_fleet.player_id then
      raise notice 'process_mainship_space_arrivals: skip (fleet/movement linkage mismatch) ship=% movement=%',
        cand.main_ship_id, cand.movement_id;
      continue;
    end if;

    -- 7) settle atomically (all rows already locked). DOCK-0: an explicit named-location target is settled
    --    by the private docking primitive (UNCHANGED). Every other target_kind settles in_space — now via
    --    the SHARED primitive A, using ONE captured timestamp (Constraint 2). Behavior-identical to 0061.
    if v_mv.target_kind = 'location' then
      perform public.mainship_space_dock_at_location(cand.main_ship_id, v_mv.id);
    else
      v_now := clock_timestamp();
      perform public.mainship_space_settle_space_arrival(cand.main_ship_id, v_mv.id, v_now);
    end if;

    v_settled := v_settled + 1;
  end loop;

  -- 8) count of movements actually settled this run.
  return v_settled;
end;
$$;

-- ── C. mainship_space_stop — PRIVATE service_role-only Stop writer ────────────────────────────────────────
-- Composes the S2 boundary (blocking lock → validate). Idempotent on (main_ship_id, request_id). Stops an
-- active in_transit coordinate move at the interpolated current point when clock_timestamp() < arrive_at;
-- at/after arrive_at it settles the canonical arrival via primitive A (never 'stopped' at the destination).
create or replace function public.mainship_space_stop(
  p_player       uuid,
  p_main_ship_id uuid,
  p_request_id   uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_cmd    constant text := 'space_stop';
  v_lock   jsonb;
  v_status text;
  v_owner  uuid;
  v_hash   text;
  v_rcpt   main_ship_space_command_receipts%rowtype;
  v_val    jsonb;
  v_state  text;
  v_mv     main_ship_space_movements%rowtype;
  v_fleet  fleets%rowtype;
  v_now    timestamptz;
  v_dur    double precision;
  v_t      double precision;
  v_stop_x double precision;
  v_stop_y double precision;
  v_settle jsonb;
  v_result jsonb;
begin
  -- 1) basic input validation (pure)
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;

  -- 2) S2 canonical lock context (blocking; ship → fleet → coordinate movement → presence)
  v_lock := public.mainship_space_lock_context(p_main_ship_id, false);
  v_status := v_lock->>'status';
  if v_status = 'not_found' then
    return jsonb_build_object('ok', false, 'reason', 'missing_ship');
  elsif v_status <> 'locked' then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_status, 'lock_failed'));
  end if;

  -- 3) ownership from the LOCKED snapshot (never from the client)
  v_owner := (v_lock->'ship'->>'player_id')::uuid;
  if v_owner is distinct from p_player then
    return jsonb_build_object('ok', false, 'reason', 'not_owned');
  end if;

  -- 4) canonical immutable command payload + hash. Stop carries NO coordinate body.
  v_hash := md5(jsonb_build_object('command_type', c_cmd)::text);

  -- 5) idempotency receipt lookup AFTER the ship lock + ownership check
  select * into v_rcpt from main_ship_space_command_receipts
    where main_ship_id = p_main_ship_id and request_id = p_request_id;
  if found then
    if v_rcpt.command_type = c_cmd and v_rcpt.canonical_payload_hash = v_hash then
      return v_rcpt.result_json;                       -- idempotent replay of the first commit
    else
      return jsonb_build_object('ok', false, 'reason', 'request_id_payload_conflict');
    end if;
  end if;

  -- 6) coherent-state validation under the locks
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;
  v_state := v_val->>'state';

  -- 7) IN-FLIGHT SAFETY (Constraint 1): Stop is NOT initiation. Only when there is NO active coordinate
  --    transit do we branch on the flag: flag false → feature_disabled (fully dark today); flag true →
  --    not_in_transit. A real in_transit coordinate move proceeds regardless of the flag (below).
  if v_state <> 'in_transit' then
    if v_state in ('in_space', 'at_location', 'home', 'legacy_home', 'legacy_present') then
      if not public.cfg_bool('mainship_space_movement_enabled') then
        return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
      end if;
      return jsonb_build_object('ok', false, 'reason', 'not_in_transit');
    elsif v_state = 'legacy_transit' then
      return jsonb_build_object('ok', false, 'reason', 'legacy_transit_not_stoppable');
    elsif v_state = 'destroyed' then
      return jsonb_build_object('ok', false, 'reason', 'destroyed');
    else
      return jsonb_build_object('ok', false, 'reason', 'contradictory_state');
    end if;
  end if;

  -- 8) re-read the active coordinate movement + fleet UNDER LOCK (validate proved coherence already).
  select * into v_mv from main_ship_space_movements
    where main_ship_id = p_main_ship_id and status = 'moving';
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'movement_not_moving');
  end if;
  select * into v_fleet from fleets where id = v_mv.fleet_id;

  -- 9) EXPLICIT MOVEMENT BOUNDARY (Constraint C): space target + moving + valid nonzero window only.
  if v_mv.target_kind <> 'space' then
    return jsonb_build_object('ok', false, 'reason', 'not_space_movement');
  end if;
  if v_mv.status <> 'moving' then
    return jsonb_build_object('ok', false, 'reason', 'movement_not_moving');
  end if;
  if not (v_mv.arrive_at > v_mv.depart_at) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_movement_window');
  end if;

  -- 10) ARRIVAL PRECEDENCE (Constraint B): capture ONE clock_timestamp() AFTER locks are held.
  v_now := clock_timestamp();
  if v_now >= v_mv.arrive_at then
    -- due/overdue at stop time → settle the canonical ARRIVAL via the SHARED primitive (never 'stopped').
    v_settle := public.mainship_space_settle_space_arrival(p_main_ship_id, v_mv.id, v_now);
    if (v_settle->>'ok')::boolean is not true then
      return jsonb_build_object('ok', false, 'reason', coalesce(v_settle->>'reason', 'contradictory_state'));
    end if;
    v_result := jsonb_build_object('ok', true, 'outcome', 'arrived',
      'movement_id', v_mv.id, 'main_ship_id', p_main_ship_id, 'fleet_id', v_fleet.id,
      'target_x', v_mv.target_x, 'target_y', v_mv.target_y, 'resolved_at', v_now, 'request_id', p_request_id);
  else
    -- strictly before arrive_at → STOP at the interpolated current point. SAME v_now drives t + resolved_at.
    v_dur := extract(epoch from (v_mv.arrive_at - v_mv.depart_at));
    v_t   := greatest(0, least(1, extract(epoch from (v_now - v_mv.depart_at)) / v_dur));
    v_stop_x := v_mv.origin_x + v_t * (v_mv.target_x - v_mv.origin_x);
    v_stop_y := v_mv.origin_y + v_t * (v_mv.target_y - v_mv.origin_y);

    update main_ship_space_movements
      set status = 'stopped', resolved_at = v_now, terminal_reason = 'player_stop'
      where id = v_mv.id and status = 'moving';

    update fleets
      set status = 'completed', location_mode = 'movement',
          active_space_movement_id = null, active_movement_id = null,
          current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
          updated_at = v_now
      where id = v_fleet.id;

    update main_ship_instances
      set status = 'stationary', spatial_state = 'in_space',
          space_x = v_stop_x, space_y = v_stop_y, updated_at = v_now
      where main_ship_id = p_main_ship_id;

    v_result := jsonb_build_object('ok', true, 'outcome', 'stopped',
      'movement_id', v_mv.id, 'main_ship_id', p_main_ship_id, 'fleet_id', v_fleet.id,
      'stop_x', v_stop_x, 'stop_y', v_stop_y, 'resolved_at', v_now, 'request_id', p_request_id);
  end if;

  -- 11) finalise the idempotency receipt atomically with the settlement
  insert into main_ship_space_command_receipts (
    main_ship_id, player_id, request_id, command_type, canonical_payload_hash,
    outcome_status, result_json, movement_id, completed_at)
  values (
    p_main_ship_id, p_player, p_request_id, c_cmd, v_hash,
    'success', v_result, v_mv.id, v_now);

  return v_result;
end;
$$;

-- ── D. command_main_ship_space_stop — authenticated public Stop wrapper ───────────────────────────────────
-- Derives the caller + their own ship from auth.uid(); delegates to the private writer. NO defense-in-depth
-- flag gate here: Stop must survive a later emergency flag disable for a ship already in transit (the writer
-- returns feature_disabled ONLY when there is no active coordinate transit). Maps the writer jsonb to a
-- narrow player-safe payload.
create or replace function public.command_main_ship_space_stop(
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

  select main_ship_id into v_ship from public.main_ship_instances where player_id = v_player;
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

-- ── E. Re-lock execute surface (anti-cheat). The NEW functions default-grant EXECUTE to PUBLIC on create →
--    revoke and re-grant ONLY the canonical client RPC list (carried verbatim from 0061) PLUS the one new
--    OSN-4 client wrapper command_main_ship_space_stop. The Stop writer + shared arrival primitive + the S3
--    writer + S4 processor + S5 destruction + DOCK-0 primitive + four S2 helpers stay service_role ONLY.
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
grant execute on function public.command_main_ship_space_stop(uuid)               to authenticated;  -- NEW (OSN-4)
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
grant execute on function public.mainship_space_dock_at_location(uuid, uuid)      to service_role;
grant execute on function public.mainship_space_settle_space_arrival(uuid, uuid, timestamptz) to service_role;  -- NEW (OSN-4)
grant execute on function public.mainship_space_stop(uuid, uuid, uuid)            to service_role;  -- NEW (OSN-4)
