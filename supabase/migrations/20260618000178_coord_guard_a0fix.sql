-- Byeharu — COORD-GUARD (the A0-fix): resolver-guard the raw coordinate command BEFORE the flip.
--
-- Closes the last unguarded single-ship read on the OSN MOVEMENT surface (one separate, read-only
-- pre-multi-ship read remains outside movement: commission_first_main_ship, 0072:117,129 —
-- arbitrary-row CLASSIFICATION at N>1, no write path, not exploitable; tracked as its own tiny
-- follow-up in docs/TEAM_COMMAND.md): command_main_ship_space_move
-- (the S6A raw arbitrary-coordinate command) still derived the caller's ship with the pre-multi-ship
-- `where player_id = v_player` (arbitrary row at N>1 ships). That was deliberately deferred in
-- TRADE-FLEET-0C (0083 header, §2.5 [C] row) because the command rejects on
-- mainship_coordinate_travel_enabled (0070:57, seeded false) BEFORE the ship read — unreachable while
-- dark. Multi-ship is now LIVE (team launch 2026-07-12: max_main_ships_per_player=24, commissioning lit),
-- so the moment the coordinate flag flips, the unguarded read becomes a REAL arbitrary-ship correctness
-- bug. This migration is the flip's hard prerequisite (docs/TEAM_COMMAND.md: "retire it when
-- coordinate-travel AND multi-ship commissioning are both lit" — commissioning is; the flip script
-- scripts/activate-coordinate-travel.sql preconditions on THIS migration).
--
-- ── PARITY LAW (grep-verified TRUE head) ─────────────────────────────────────────────────────────
-- create-sites for command_main_ship_space_move across ALL migrations: 0060 (born) → 0070 (coordinate
-- gate added; current head). No later re-create exists (0071/0083/0084 mention it in comments only).
-- The body below is the 0070 head VERBATIM with exactly ONE delta — the §2.5/0083 resolver swap:
--   • signature gains a TRAILING `p_main_ship_id uuid default null` (the 0081/0159 idiom; drop +
--     recreate because the added arg changes the function identity);
--   • step 3's unguarded `select … where player_id = v_player` becomes
--     `public.mainship_resolve_owned_ship(v_player, p_main_ship_id)` (0081): explicit id → ownership
--     asserted server-side (UI never trusted); null → sole ship ONLY when the player has exactly one;
--     zero/>1 → null → the EXISTING {ok:false, code:'no_ship'} shape, verbatim — FAIL-CLOSED.
-- Every other step (auth, both flag gates, finite/grid validation, the mainship_space_begin_move
-- delegation, the narrow payload mapping) is byte-identical to 0070. For every SINGLE-ship player the
-- behavior is byte-identical end to end (the resolver's sole-ship shim returns their one ship).
--
-- CLIENT COMPATIBILITY: pre-slice clients send {p_target_x, p_target_y, p_request_id} — those calls
-- resolve via the trailing default (the sole-ship shim), so nothing breaks at deploy. The SAME slice
-- ships the client passthrough: the S6C wrapper (spaceMoveCommand.ts buildSpaceMoveRpcArgs +
-- mainshipApi.ts commandMainShipSpaceMove) now also sends the explicit selected/sole main-ship id as
-- p_main_ship_id — threaded from GalaxyMap exactly like its stop/settle/readiness siblings — so a
-- multi-ship player's coordinate tap targets the ship the readiness projection was scoped to (the
-- fail-closed null path remains for id-less callers). Asserted by tests/spaceMoveCommand.spec.ts.
--
-- VERIFIER PINS: the frozen dispatch-only verifiers that pin the 3-arg signature are invalidated by
-- the signature change and are repointed at the deploy-time human gate — the COMPLETE list is recorded
-- in docs/TRADE_FLEET_0C_VERIFIER_REPOINT.md (§ "#1 … converted"), per the standing 0C policy:
--   • regprocedure/privilege pins: port-entry-1-production-verify.sql:104,141;
--     osn-postenable-verify.{sql:140-162,sh:173}; osn-enablement-preflight.sql:42;
--     osn-coord-gate-proof.sh:52-53;
--   • the arg-type-OID census osn-postenable-verify.sql:176-181 (COORD_SURFACE_COUNT: pronargs=3 +
--     (float8,float8,uuid) → pronargs=4 + proargtypes[3]=uuid; .sh:89/:135 consumers keep =1);
--   • the exact identity-args + SECURITY-INTENT asserts osn3-s6a-realchain-perm.sql:28,:34 and
--     osn3-s6a-live-check.sh:62,:65 — :34/:65's "no ship id param" intent is now deliberately false
--     and gets a SEMANTIC rewrite ('player' still absent; the sole ship arg is the trailing
--     ownership-resolved p_main_ship_id), not a literal swap.
-- This migration touches NO verifier file.
--
-- NOT TOUCHED: mainship_resolve_owned_ship (0081 head, reused as-is), mainship_space_begin_move (the
-- writer stays the final authority on flag/ownership/bounds/state/exclusion/travel-cap/locking/
-- idempotency), command_main_ship_space_move_to_location / _stop (already guarded, 0083),
-- get_osn_movement_readiness (0082 head), every flag value (this migration flips NOTHING — the flip is
-- the human-run activate script), and all frontend code.

-- ── the resolver-guarded re-create (drop + recreate: the added trailing arg changes the identity) ──
drop function if exists public.command_main_ship_space_move(double precision, double precision, uuid);
create function public.command_main_ship_space_move(
  p_target_x   double precision,
  p_target_y   double precision,
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

  -- 3) COORD-GUARD (§2.5 / A0-fix — the ONE delta vs the 0070 head): resolve the SELECTED owned ship
  --    (explicit p_main_ship_id, ownership asserted server-side) or the sole ship (shim); UI selection is
  --    never trusted. Null (unowned / zero / ambiguous >1) → the existing no_ship shape — FAIL-CLOSED.
  v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id);
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

-- ── ACL re-assert on the NEW signature (the drop removed the old ACL): authenticated-only, as 0070. ──
revoke execute on function public.command_main_ship_space_move(double precision, double precision, uuid, uuid) from public, anon;
grant  execute on function public.command_main_ship_space_move(double precision, double precision, uuid, uuid) to authenticated;

-- ── self-asserts (the 0175/0177 idiom): the guard is REALLY in, the old identity is REALLY gone ──
do $$
declare
  v_src text;
begin
  -- exactly the new 4-arg identity exists; the old 3-arg identity is gone (no overload ambiguity).
  if to_regprocedure('public.command_main_ship_space_move(double precision, double precision, uuid, uuid)') is null then
    raise exception 'COORD-GUARD ASSERT FAIL: 4-arg command_main_ship_space_move missing';
  end if;
  if to_regprocedure('public.command_main_ship_space_move(double precision, double precision, uuid)') is not null then
    raise exception 'COORD-GUARD ASSERT FAIL: old 3-arg command_main_ship_space_move still exists (overload!)';
  end if;

  select p.prosrc into v_src from pg_proc p
    where p.oid = to_regprocedure('public.command_main_ship_space_move(double precision, double precision, uuid, uuid)');
  -- the resolver CALL is live (assignment form), PAIRED with the negative check below — the pair is
  -- the real teeth (presence of the call + absence of the old derivation)…
  if position('v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id)' in v_src) = 0 then
    raise exception 'COORD-GUARD ASSERT FAIL: resolver call not found in prosrc';
  end if;
  -- …and the unguarded pre-multi-ship derivation is gone.
  if v_src like '%where player_id = v_player%' then
    raise exception 'COORD-GUARD ASSERT FAIL: unguarded single-ship read still present in prosrc';
  end if;
  -- both flag gates still precede the ship resolution (reject-before-read preserved, in 0070 order).
  if position('mainship_space_movement_enabled' in v_src) = 0
     or position('mainship_coordinate_travel_enabled' in v_src) = 0
     or position('mainship_coordinate_travel_enabled' in v_src) > position('mainship_resolve_owned_ship' in v_src) then
    raise exception 'COORD-GUARD ASSERT FAIL: flag gates missing or no longer precede the ship resolution';
  end if;
  -- ACL: authenticated yes; anon no.
  if not has_function_privilege('authenticated', 'public.command_main_ship_space_move(double precision, double precision, uuid, uuid)', 'EXECUTE') then
    raise exception 'COORD-GUARD ASSERT FAIL: authenticated lost EXECUTE';
  end if;
  if has_function_privilege('anon', 'public.command_main_ship_space_move(double precision, double precision, uuid, uuid)', 'EXECUTE') then
    raise exception 'COORD-GUARD ASSERT FAIL: anon has EXECUTE';
  end if;
  -- the reused resolver exists at its 0081 head identity.
  if to_regprocedure('public.mainship_resolve_owned_ship(uuid, uuid)') is null then
    raise exception 'COORD-GUARD ASSERT FAIL: mainship_resolve_owned_ship(uuid, uuid) missing';
  end if;

  raise notice 'COORD-GUARD self-asserts ok: 4-arg identity, resolver guard live, unguarded read gone, gates precede resolution, ACL correct';
end $$;
