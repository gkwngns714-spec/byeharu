-- Byeharu — OSN-3 S3: first internal coordinate-movement WRITER (flag-dark, server-only).
--
-- Adds ONE private writer, public.mainship_space_begin_move(...), that begins a coordinate move by
-- composing the deployed S2 boundary (lock → validate → cross-domain exclusion → resolve-origin) and
-- then atomically creating exactly one main_ship_space_movements 'moving' row with a coherent fleet
-- pointer, ship in-transit state, and a finalized idempotency receipt. It is SECURITY DEFINER, owner
-- postgres, search_path=public, EXECUTE revoked from public/anon/authenticated and granted to
-- service_role ONLY. It is hard-gated on mainship_space_movement_enabled (live value stays false) and
-- exposes NO player RPC. It NEVER touches mainship_send_enabled, the frozen legacy writers
-- (send_main_ship_expedition / move_main_ship_to_location / request_main_ship_return /
-- presence_request_leave / process_fleet_movements / fleet_* state machine), or fleet_movements.
--
-- Lock order is the S2 canonical order ONLY (ship → fleet → main_ship_space_movements →
-- location_presence). Legacy fleet_movements is never locked. No advisory locks. No dynamic SQL.
--
-- ORIGINS SUPPORTED (every stationary class S2 can resolve):
--   home / legacy_home / in_space  → no coherent active fleet exists → MATERIALISE a new main-ship
--                                    fleet in-transaction (origin coords from resolve_origin: base or
--                                    open-space point).
--   at_location / legacy_present   → REUSE the single coherent present fleet (already locked).
-- REJECTS in_transit / legacy_transit / destroyed / missing / not-owned / contradictory / unknown
-- spatial state / multiple active fleets / active legacy movement / inconsistent coordinate movement /
-- pointer mismatch / presence conflict / out-of-bounds origin or target / non-finite / zero-distance /
-- travel-time over the cap.
--
-- VALIDATE-BEFORE-MUTATE (deliberate, documented): every business rejection — INCLUDING
-- travel_time_exceeds_limit — is evaluated BEFORE the first write, returning a structured
-- {ok:false,reason} with NO fleet/movement/ship/presence/receipt change. The literal "materialise
-- fleet (11) → resolve speed (12) → travel-time check (13)" order would otherwise leave an orphan
-- fleet on a travel-time rejection, violating the "no fleet materialisation on rejection" guarantee.
-- Speed for the pre-check is read from the ship's hull (main_ship_hull_types.base_speed), which is
-- exactly what resolve_fleet_movement_speed() returns for a main-ship fleet (its main-ship branch
-- ignores fleet_units); after the real fleet exists the authoritative speed_used is taken from the
-- canonical resolver and asserted equal to the pre-checked hull speed (a true integrity invariant →
-- exception/rollback on mismatch). Only unexpected integrity faults raise; all admission decisions
-- return {ok,reason}.

-- ── 0) one additive, non-flag config guard (does NOT overwrite an existing configured value) ────────
insert into public.game_config (key, value, description) values
  ('max_coordinate_travel_seconds', '86400',
   'OSN-3 S3: hard cap on a single coordinate move''s computed travel seconds (admission guard; not a flag).')
on conflict (key) do nothing;

-- ── 1) the internal writer ──────────────────────────────────────────────────────────────────────
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
declare
  c_cmd     constant text := 'space_begin_move';
  c_lo      constant double precision := -10000;
  c_hi      constant double precision :=  10000;
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
  -- 1) basic input validation (pure: no locks, no writes)
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request_id');
  end if;
  if p_target_x is null or p_target_y is null
     or p_target_x = 'NaN'::double precision or p_target_x = 'Infinity'::double precision or p_target_x = '-Infinity'::double precision
     or p_target_y = 'NaN'::double precision or p_target_y = 'Infinity'::double precision or p_target_y = '-Infinity'::double precision then
    return jsonb_build_object('ok', false, 'reason', 'invalid_coordinate');
  end if;
  if p_target_x < c_lo or p_target_x > c_hi or p_target_y < c_lo or p_target_y > c_hi then
    return jsonb_build_object('ok', false, 'reason', 'target_out_of_bounds');
  end if;

  -- 2) S2 canonical lock context (ship → fleet → coordinate movement → presence). Blocking mode.
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

  -- 4) canonical immutable command payload + deterministic hash (target contract ONLY)
  v_hash := md5(jsonb_build_object(
              'command_type', c_cmd, 'target_kind', 'space',
              'target_x', p_target_x, 'target_y', p_target_y)::text);

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

  -- 6) feature flag (no receipt is written for a rejected disabled command)
  if not cfg_bool('mainship_space_movement_enabled') then
    return jsonb_build_object('ok', false, 'reason', 'feature_disabled');
  end if;

  -- 7) coherent-state validation under the locks
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason', 'contradictory_state'));
  end if;

  -- 8) cross-domain exclusion (active legacy movement / coordinate-pointer mismatch / presence conflict)
  v_excl := public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id);
  if (v_excl->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_excl->>'reason', 'contradictory_state'));
  end if;

  -- 9) authoritative origin (server-resolved; rejects in_transit/legacy_transit/destroyed/malformed)
  v_origin := public.mainship_space_resolve_origin(p_main_ship_id);
  if (v_origin->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_origin->>'reason', 'contradictory_state'));
  end if;
  v_okind := v_origin->>'origin_kind';
  v_ox := (v_origin->>'origin_x')::double precision;
  v_oy := (v_origin->>'origin_y')::double precision;

  -- 10) origin coordinate validation + EXACT zero-distance reject (no epsilon)
  if v_ox is null or v_oy is null
     or v_ox = 'NaN'::double precision or v_ox = 'Infinity'::double precision or v_ox = '-Infinity'::double precision
     or v_oy = 'NaN'::double precision or v_oy = 'Infinity'::double precision or v_oy = '-Infinity'::double precision then
    return jsonb_build_object('ok', false, 'reason', 'invalid_coordinate');
  end if;
  if v_ox < c_lo or v_ox > c_hi or v_oy < c_lo or v_oy > c_hi then
    return jsonb_build_object('ok', false, 'reason', 'origin_out_of_bounds');
  end if;
  if v_ox = p_target_x and v_oy = p_target_y then
    return jsonb_build_object('ok', false, 'reason', 'zero_distance');
  end if;

  -- 11) speed + travel time + LIMIT — BEFORE any mutation (see header: validate-before-mutate).
  select h.base_speed into v_speed
    from main_ship_instances s join main_ship_hull_types h on h.hull_type_id = s.hull_type_id
    where s.main_ship_id = p_main_ship_id;
  if v_speed is null or v_speed <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_speed');
  end if;
  v_scale := coalesce(cfg_num('travel_scale'), 1.0);
  v_min   := coalesce(cfg_num('min_travel_seconds'), 1.0);
  v_max   := coalesce(cfg_num('max_coordinate_travel_seconds'), 86400);
  v_dist    := sqrt(power(p_target_x - v_ox, 2) + power(p_target_y - v_oy, 2));
  v_seconds := greatest(v_min, v_dist / v_speed * v_scale);
  if v_seconds > v_max then
    return jsonb_build_object('ok', false, 'reason', 'travel_time_exceeds_limit');
  end if;

  -- ════════ all admission checks passed; mutate within this one transaction ════════

  -- 12) obtain or materialise the fleet
  if v_okind in ('base', 'space') then
    -- home / legacy_home / in_space → materialise a new main-ship fleet (origin-base = active home base
    -- if any, per the send convention; nullable). active-space pointer set after the movement exists.
    select id into v_base_id from bases
      where player_id = p_player and status = 'active' order by created_at limit 1;
    insert into fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)
      values (p_player, v_base_id, 'moving', 'movement', null, p_main_ship_id)
      returning id into v_fleet_id;
  else
    -- at_location / legacy_present → reuse the single coherent present fleet (already locked).
    select * into v_fleet from fleets
      where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
    v_fleet_id := v_fleet.id;
  end if;

  -- 13) authoritative speed via the canonical resolver (now a real fleet exists); must equal the
  --     pre-checked hull speed — otherwise a genuine integrity fault (roll the whole transaction back).
  v_speed2 := resolve_fleet_movement_speed(v_fleet_id);
  if v_speed2 is distinct from v_speed then
    raise exception 'mainship_space_begin_move: speed invariant broken (hull % vs resolver %)', v_speed, v_speed2;
  end if;

  -- 14) insert EXACTLY ONE moving coordinate movement (one-active partial-uniques are the race backstop)
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
    'space', p_target_x, p_target_y, null, null,
    'moving', v_speed, v_depart, v_arrive)
  returning id into v_mv_id;

  -- 15) point the fleet at the coordinate movement; legacy active_movement_id stays NULL
  update fleets
    set status = 'moving', location_mode = 'movement',
        active_movement_id = null, active_space_movement_id = v_mv_id,
        current_location_id = null, current_zone_id = null, current_sector_id = null,
        updated_at = now()
    where id = v_fleet_id;

  -- 16) location-present origin: close the already-locked active presence. Direct scoped update of the
  --     locked row (mirrors presence_complete; touches no other table → cannot invert the S2 lock order).
  if v_okind = 'location' then
    update location_presence
      set status = 'completed', updated_at = now()
      where fleet_id = v_fleet_id and status = 'active';
  end if;

  -- 17) ship → traveling / in_transit; clear any open-space coordinate
  update main_ship_instances
    set status = 'traveling', spatial_state = 'in_transit', space_x = null, space_y = null, updated_at = now()
    where main_ship_id = p_main_ship_id;

  -- 18) finalise the idempotency receipt atomically with the move
  v_result := jsonb_build_object(
    'ok', true,
    'movement_id', v_mv_id, 'main_ship_id', p_main_ship_id, 'fleet_id', v_fleet_id, 'player_id', p_player,
    'origin_kind', v_okind, 'origin_x', v_ox, 'origin_y', v_oy,
    'target_kind', 'space', 'target_x', p_target_x, 'target_y', p_target_y,
    'speed_used', v_speed, 'depart_at', v_depart, 'arrive_at', v_arrive,
    'request_id', p_request_id);
  insert into main_ship_space_command_receipts (
    main_ship_id, player_id, request_id, command_type, canonical_payload_hash,
    outcome_status, result_json, movement_id, completed_at)
  values (
    p_main_ship_id, p_player, p_request_id, c_cmd, v_hash,
    'success', v_result, v_mv_id, now());

  -- 19) return the authoritative result (byte-identical to the stored receipt result_json)
  return v_result;
end;
$$;

-- ── 2) Re-lock execute surface (anti-cheat). The new writer default-grants to PUBLIC on create →
--       revoke and re-grant ONLY the canonical client RPC list (carried verbatim from 0056). The new
--       writer + the four S2 helpers + the existing server fns are service_role ONLY — no client grant.
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
grant execute on function public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid) to service_role;
