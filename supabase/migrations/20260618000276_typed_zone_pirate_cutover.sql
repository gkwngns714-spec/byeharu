-- Byeharu — TYPED-ZONE PIRATE CUTOVER (migration 0276). Slice 4 of the typed-zone platform.
-- LANDS DARK. typed_zone_pirate_intercept_runtime_enabled is still seeded FALSE, and while it is
-- false this function behaves byte-for-byte as 0233 shipped it.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE ONLY FUNCTION THIS SLICE TOUCHES
-- pirate_intercept_evaluate_leg is re-created with EXACTLY TWO changes, spliced into a verbatim copy
-- of the deployed 0233 body so the untouched ~90% cannot drift through hand-transcription:
--
--   1. ZONE SELECTION — one branch on the flag. Dark: the legacy
--      `order by exposure_fraction desc, zone_id asc limit 1`. Lit: the pure V1 planner decides,
--      so selection follows declared EFFECTS instead of the bare existence of a polygon.
--   2. RISK — dark: pirate_intercept_compute_risk (globals only). Lit: the risk the planner already
--      resolved from that zone's own effect config, so a per-zone override is honoured rather than
--      silently re-globalised.
--
-- EVERYTHING ELSE IS UNCHANGED AND SHARED: the dark gate, the movement/fleet reads, the group-fleet
-- guard, the stats adapter with its fail-open, the roll, the pirate_intercepts log, the re-lock and
-- race check, the cancel, the standalone forced-stop stub, the location-missing fallback, the
-- presence/encounter path and the exception handler.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- ONE PATH DECIDES. NEVER BOTH.
-- The flag is read ONCE into v_typed and every later branch reads that local, so a mid-execution
-- flip cannot produce a half-legacy, half-typed decision. The branches are mutually exclusive and
-- neither is run "for comparison" — comparison is slice 3's read-only shadow, which writes nothing.
-- Running both here would double-log and could double-trigger an ambush.
--
-- FAIL CLOSED, NEVER FAIL OPEN. If the planner rejects the request or plans nothing usable, the leg
-- is left UNINTERRUPTED and a typed reason is returned. It deliberately does NOT fall back to the
-- legacy path: a silent fallback would make the cutover unobservable and hide the very fault the
-- flag exists to expose. Not intercepting is always the safe direction — it is what 'no_crossing'
-- already does on a leg that touches nothing.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THE PLANNER IS CALLED TWICE ON THE LIT BRANCH
-- The candidate request must exist BEFORE the group-stats adapter runs (selection needs it), but the
-- risk depends on combined stats the adapter produces AFTER. Rather than reorder the deployed
-- function — which would move the fail-open stats guard relative to the reads around it — the
-- request is built once with combined_stats 0 to select the zone, then re-planned with the real
-- stats to resolve the risk. The dispatcher is IMMUTABLE and free of IO, so the second call is pure
-- arithmetic over jsonb, and selection cannot change between them: only combined_stats differs, and
-- it is not a selection input.
--
-- NO ROLLBACK RISK IN THE DATA. This slice writes no row and adds no column. Reverting is a flag
-- flip; the pre-0276 function body is recoverable verbatim from 0233.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regprocedure('public.typed_zone_effect_dispatch_v1(jsonb)') is null then
    raise exception 'TYPED-ZONE 0276: typed_zone_effect_dispatch_v1 (0274) is missing — slice 2 must land first';
  end if;
  if to_regprocedure('public.typed_zone_pirate_candidates_v1(uuid, double precision, double precision, double precision, double precision, double precision)') is null then
    raise exception 'TYPED-ZONE 0276: typed_zone_pirate_candidates_v1 (0275) is missing — slice 3 must land first';
  end if;
  if to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)') is null then
    raise exception 'TYPED-ZONE 0276: pirate_intercept_evaluate_leg (0233) is missing — there is nothing to cut over';
  end if;
  if not exists (select 1 from public.game_config where key = 'typed_zone_pirate_intercept_runtime_enabled') then
    raise exception 'TYPED-ZONE 0276: the cutover flag is missing — 0273 must land first';
  end if;
end $pre$;

-- ── 1. the evaluator, re-created with the cutover spliced in ────────────────────────────────────
create or replace function public.pirate_intercept_evaluate_leg(p_movement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mv       record;
  v_fleet    record;
  v_hit      record;
  v_group    uuid;
  v_stats    jsonb;
  v_combined double precision;
  v_risk     double precision;
  v_roll     double precision;
  v_hitbool  boolean;
  v_now      timestamptz := now();
  v_loc      record;
  v_presence uuid;
  v_enc      uuid;
  v_log_id   uuid;
  -- 0276 cutover locals. Only ever populated on the typed-zone branch.
  v_typed    boolean;
  v_req      jsonb;
  v_res      jsonb;
  v_pe       jsonb;
begin
  -- DARK GATE FIRST — before any read at all.
  if not public.cfg_bool('pirate_intercept_enabled') then
    return jsonb_build_object('hit', false, 'reason', 'dark');
  end if;

  select id, fleet_id, player_id, origin_x, origin_y, target_x, target_y, status
    into v_mv
    from public.fleet_movements
   where id = p_movement_id;
  if not found or v_mv.status <> 'moving' then
    return jsonb_build_object('hit', false, 'reason', 'not_moving');
  end if;

  select id, player_id, group_id, main_ship_id
    into v_fleet
    from public.fleets
   where id = v_mv.fleet_id;
  -- This hook only ever fires from the unified GROUP mover / route advance — the ONLY shapes that
  -- mint main_ship_id NULL + group_id SET fleets. Anything else (a legacy per-ship or unit fleet) is
  -- simply not this feature's concern for the prototype — skip cleanly, never guess.
  if not found or v_fleet.group_id is null or v_fleet.main_ship_id is not null then
    return jsonb_build_object('hit', false, 'reason', 'not_group_fleet');
  end if;
  v_group := v_fleet.group_id;

  -- ── 0276 CUTOVER POINT ──────────────────────────────────────────────
  -- Exactly ONE path decides, chosen once, here. The branches are never both run for side effects:
  -- whichever is authoritative produces v_hit, and everything downstream — the roll, the
  -- pirate_intercepts log, the cancel, the ambush — is shared and unchanged. With the flag dark
  -- (its seeded state) this is byte-for-byte the legacy 0233 decision.
  v_typed := coalesce(public.cfg_bool('typed_zone_pirate_intercept_runtime_enabled'), false);

  if not v_typed then
    -- LEGACY, authoritative while the flag is dark: deepest crossing wins (highest
    -- exposure_fraction); `limit 1` needs SOME order to be deterministic.
    select * into v_hit
      from public.pirate_intercept_leg_zone_hits(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y)
     order by exposure_fraction desc, zone_id asc
     limit 1;
    if not found then
      return jsonb_build_object('hit', false, 'reason', 'no_crossing');
    end if;
  else
    -- TYPED-ZONE: the same geometry, but the decision comes from the pure V1 planner, so selection
    -- follows declared EFFECTS rather than the bare existence of a polygon. A zone carrying no
    -- pirate_intercept effect row is simply not planned — that is the point of the platform.
    v_req := public.typed_zone_pirate_candidates_v1(
               p_movement_id, v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, 0);
    v_res := public.typed_zone_effect_dispatch_v1(v_req);
    -- FAIL CLOSED, NEVER FAIL OPEN. A planner that cannot answer must not silently fall back to the
    -- legacy path — that would make the cutover unobservable and hide the fault — and must not
    -- invent an interception. It leaves the leg alone, exactly as 'no_crossing' does.
    if (v_res->>'ok') <> 'true' then
      raise warning 'pirate_intercept_evaluate_leg: typed-zone dispatch rejected movement % (leg left UNINTERRUPTED): %',
        p_movement_id, v_res->'error';
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
    if jsonb_array_length(v_res->'plan'->'planned_effects') = 0 then
      return jsonb_build_object('hit', false, 'reason', 'no_crossing');
    end if;
    v_pe := v_res->'plan'->'planned_effects'->0;
    -- Re-read the geometry row for the PLANNED zone: location_id and the ambush point drive the
    -- shared downstream, and they must come from the same authority the legacy branch uses.
    select h.* into v_hit
      from public.pirate_intercept_leg_zone_hits(v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y) h
     where h.zone_id = (v_pe->>'zone_id')::uuid;
    if not found then
      raise warning 'pirate_intercept_evaluate_leg: planned zone % is not among the leg hits for movement % (leg left UNINTERRUPTED)',
        v_pe->>'zone_id', p_movement_id;
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
  end if;

  -- combined stats: reuse the SAME group-stats adapter the mover already calls for speed (D0, 0166).
  -- Fail OPEN on any adapter raise (an illegal member state etc.) — treat as unknown/weak (combined=0,
  -- the conservative choice) rather than let a stats bug break a player's movement command.
  begin
    v_stats := public.calculate_group_expedition_stats(v_fleet.player_id, v_group, 'none');
    v_combined := coalesce((v_stats->'totals'->>'combat_power')::double precision, 0)
                + coalesce((v_stats->'totals'->>'survival')::double precision, 0);
  exception when others then
    v_combined := 0;
  end;

  -- The typed branch resolves risk from THIS zone's own effect config (per-zone overrides coalesced
  -- against the globals). Recomputing with pirate_intercept_compute_risk here would read the globals
  -- only and silently re-globalise a zone the owner had deliberately tuned. The candidate request is
  -- rebuilt with the real combined stats — it was first built with 0, before the stats adapter ran.
  if v_typed then
    v_res := public.typed_zone_effect_dispatch_v1(
               jsonb_set(v_req, '{event,combined_stats}', to_jsonb(v_combined)));
    if (v_res->>'ok') <> 'true' or jsonb_array_length(v_res->'plan'->'planned_effects') = 0 then
      raise warning 'pirate_intercept_evaluate_leg: typed-zone re-plan failed for movement % (leg left UNINTERRUPTED)',
        p_movement_id;
      return jsonb_build_object('hit', false, 'reason', 'typed_zone_dispatch_error');
    end if;
    v_risk := (v_res->'plan'->'planned_effects'->0->>'risk')::double precision;
  else
    v_risk := public.pirate_intercept_compute_risk(v_combined, v_hit.exposure_fraction);
  end if;
  v_roll    := random();
  v_hitbool := v_roll < v_risk;

  insert into public.pirate_intercepts (
    movement_id, fleet_id, player_id, zone_id, location_id,
    origin_x, origin_y, target_x, target_y, exposure_fraction,
    combined_stats, risk, roll, hit)
  values (
    p_movement_id, v_fleet.id, v_fleet.player_id, v_hit.zone_id, v_hit.location_id,
    v_mv.origin_x, v_mv.origin_y, v_mv.target_x, v_mv.target_y, v_hit.exposure_fraction,
    v_combined, v_risk, v_roll, v_hitbool)
  returning id into v_log_id;

  if not v_hitbool then
    return jsonb_build_object('hit', false, 'risk', v_risk, 'roll', v_roll, 'zone_id', v_hit.zone_id);
  end if;

  -- ── THE AMBUSH ───────────────────────────────────────────────────────────────────────────────
  -- Re-lock + re-check: a concurrent brake/redirect may have resolved this movement between the
  -- first (unlocked) read above and here. Never double-trigger a settled/cancelled leg.
  perform 1 from public.fleet_movements where id = p_movement_id and status = 'moving' for update;
  if not found then
    update public.pirate_intercepts set hit = false, note = 'race_lost' where id = v_log_id;
    return jsonb_build_object('hit', false, 'reason', 'race_lost');
  end if;

  update public.fleet_movements set status = 'cancelled', resolved_at = v_now where id = p_movement_id;

  if v_hit.location_id is null then
    -- STANDALONE drawn zone (no linked pirate_hunt location): the documented combat stub. No
    -- location means no presence/encounter is possible without inventing one — instead the ambush
    -- is made TANGIBLE by forcing the fleet to a stop at the ambush point, the SAME leaf the brake
    -- (command_ship_group_stop, 0215/0218) uses to park a fleet mid-flight. Not a no-op.
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'standalone_zone_stub_forced_stop' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'standalone_zone_stub', 'risk', v_risk, 'roll', v_roll);
  end if;

  select l.id, l.zone_id, z.sector_id
    into v_loc
    from public.locations l
    join public.zones z on z.id = l.zone_id
   where l.id = v_hit.location_id and l.status = 'active';
  if v_loc.id is null then
    -- the linked location vanished/deactivated since the zone was drawn/seeded — fail open: park,
    -- no combat, rather than reference a location that can no longer host a presence.
    perform public.fleet_set_in_space(v_fleet.id, v_hit.ambush_x, v_hit.ambush_y);
    update public.pirate_intercepts set note = 'location_missing' where id = v_log_id;
    return jsonb_build_object('hit', true, 'reason', 'location_missing', 'risk', v_risk, 'roll', v_roll);
  end if;

  -- fleet_set_present demands status='moving' (0006) — true here: the mover just called
  -- fleet_set_moving and nothing since has changed the fleet's status.
  perform public.fleet_set_present(v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id);

  -- Freeze the sortie MANIFEST — byte-identical INSERT shape to send_ship_group_hunt's sole-writer
  -- freeze (0168:304-306), so combat_create_encounter's manifest-gated branch (0168) routes this
  -- fleet into combat_create_group_encounter exactly as a deliberate hunt does. ON CONFLICT DO
  -- NOTHING: idempotent against a (should-be-impossible) re-entry.
  insert into public.group_sortie_members (fleet_id, main_ship_id, player_id)
  select v_fleet.id, msi.main_ship_id, v_fleet.player_id
    from public.main_ship_instances msi
   where msi.group_id = v_group and msi.player_id = v_fleet.player_id
  on conflict (fleet_id, main_ship_id) do nothing;

  -- presence_create -> activity_start('hunt_pirates') -> combat_create_encounter -> (manifest exists)
  -- -> combat_create_group_encounter. FOUR frozen functions composed, ZERO re-created.
  v_presence := public.presence_create(v_fleet.player_id, v_fleet.id, v_loc.sector_id, v_loc.zone_id, v_loc.id, 'hunt_pirates');

  select id into v_enc from public.combat_encounters where presence_id = v_presence order by created_at desc limit 1;
  update public.pirate_intercepts set encounter_id = v_enc, presence_id = v_presence where id = v_log_id;

  return jsonb_build_object(
    'hit', true, 'risk', v_risk, 'roll', v_roll,
    'location_id', v_loc.id, 'presence_id', v_presence, 'encounter_id', v_enc);
exception
  when others then
    raise warning 'pirate_intercept_evaluate_leg: unexpected error for movement % (leg left UNINTERRUPTED): %',
      p_movement_id, sqlerrm;
    return jsonb_build_object('hit', false, 'reason', 'internal_error');
end;
$$;

revoke execute on function public.pirate_intercept_evaluate_leg(uuid) from public, anon, authenticated;
grant execute on function public.pirate_intercept_evaluate_leg(uuid) to service_role;

comment on function public.pirate_intercept_evaluate_leg(uuid) is
  'PIRATE INTERCEPT (0233) + TYPED-ZONE CUTOVER (0276). While '
  'typed_zone_pirate_intercept_runtime_enabled is false this behaves byte-for-byte as 0233 shipped '
  'it. While true, zone SELECTION and RISK come from the pure V1 typed-zone planner, so declared '
  'effects decide rather than the bare existence of a polygon, and per-zone overrides are honoured. '
  'Exactly one path decides; a planner failure leaves the leg UNINTERRUPTED rather than falling back.';

-- ── 2. SELF-ASSERT — lands dark, one decider, fail-closed ───────────────────────────────────────
do $tzc$
declare
  v_def text;
begin
  select pg_get_functiondef(to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)')) into v_def;
  if v_def is null then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the evaluator vanished'; end if;

  -- (1) LANDS DARK
  if coalesce(public.cfg_bool('typed_zone_pirate_intercept_runtime_enabled'), true) then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the cutover flag is not false'; end if;

  -- (2) the flag is read exactly ONCE, into a local — no mid-execution re-read can split a decision
  if (length(v_def) - length(replace(v_def, 'cfg_bool(''typed_zone_pirate_intercept_runtime_enabled'')', '')))
     / length('cfg_bool(''typed_zone_pirate_intercept_runtime_enabled'')') <> 1 then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the cutover flag is read more than once';
  end if;

  -- (3) BOTH deciders are present, and the legacy one is intact
  if strpos(v_def, 'order by exposure_fraction desc, zone_id asc') = 0 then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the legacy selection was lost'; end if;
  if strpos(v_def, 'typed_zone_effect_dispatch_v1') = 0 then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the typed-zone branch is missing'; end if;
  if strpos(v_def, 'pirate_intercept_compute_risk') = 0 then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the legacy risk path was lost'; end if;

  -- (4) FAIL CLOSED: the typed branch returns a typed reason and never silently uses the legacy path
  if strpos(v_def, 'typed_zone_dispatch_error') = 0 then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the typed branch has no fail-closed exit'; end if;

  -- (5) THE SHARED DOWNSTREAM IS UNTOUCHED — every 0233 anchor still present, exactly once each
  if strpos(v_def, 'insert into public.pirate_intercepts') = 0
     or strpos(v_def, 'group_sortie_members') = 0
     or strpos(v_def, 'public.presence_create') = 0
     or strpos(v_def, 'public.fleet_set_present') = 0
     or strpos(v_def, 'public.fleet_set_in_space') = 0
     or strpos(v_def, 'standalone_zone_stub_forced_stop') = 0
     or strpos(v_def, 'location_missing') = 0
     or strpos(v_def, 'race_lost') = 0
     or strpos(v_def, 'calculate_group_expedition_stats') = 0 then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: a shared downstream anchor was lost';
  end if;
  -- exactly ONE roll and ONE log insert: a second of either would double-trigger
  if (length(v_def) - length(replace(v_def, 'random()', ''))) / length('random()') <> 1 then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the evaluator does not roll exactly once'; end if;
  if (length(v_def) - length(replace(v_def, 'insert into public.pirate_intercepts', '')))
     / length('insert into public.pirate_intercepts') <> 1 then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the evaluator does not log exactly once'; end if;

  -- (6) the dark gate still runs FIRST
  if strpos(v_def, 'cfg_bool(''pirate_intercept_enabled'')') = 0 then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the pirate_intercept_enabled dark gate was lost'; end if;
  if strpos(v_def, 'cfg_bool(''pirate_intercept_enabled'')')
     > strpos(v_def, 'cfg_bool(''typed_zone_pirate_intercept_runtime_enabled'')') then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: the cutover flag is read before the dark gate';
  end if;

  -- (7) ACL unchanged: engine-only
  if has_function_privilege('anon', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute') then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: a client role can execute the evaluator'; end if;
  if not has_function_privilege('service_role', 'public.pirate_intercept_evaluate_leg(uuid)', 'execute') then
    raise exception 'TYPED-ZONE 0276 self-assert FAIL: service_role lost execute on the evaluator'; end if;

  raise notice 'TYPED-ZONE 0276 self-assert ok: lands DARK (typed_zone_pirate_intercept_runtime_enabled still false, so the legacy decision is authoritative and byte-identical to 0233); the cutover flag is read EXACTLY ONCE into a local, after the pirate_intercept_enabled dark gate, so no mid-execution flip can split a decision; both deciders are present and mutually exclusive; the typed branch fails CLOSED with a typed reason and never silently falls back; every shared downstream anchor survives (log/cancel/race/stub/location-missing/presence/encounter/stats-adapter) with exactly ONE roll and exactly ONE pirate_intercepts insert; ACL unchanged (engine-only, service_role execute)';
end $tzc$;
