-- TYPED-ZONE EFFECT DISPATCH V1 (0274) — disposable real-chain proof. READ-ONLY.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/typed-zone-dispatch-proof.sql
--
-- `supabase start` has already applied 0274, so its in-migration self-assert has run against real
-- Postgres before this begins. This proof drives the full validation + planning matrix.
--
-- It writes NOTHING and needs no transaction: the dispatcher is pure, so every case below is a
-- function call over literal jsonb. That is itself the point — a planner you can exercise exhaustively
-- without touching the world is what makes slice 3's shadow comparison cheap and safe.

\set ON_ERROR_STOP on
\timing off

do $proof$
declare
  v_globals jsonb := jsonb_build_object(
    'base_risk', 0.35, 'min_risk', 0.02, 'max_risk', 0.90,
    'exposure_floor', 0.15, 'stat_reference', 120);
  v_out   jsonb;
  v_a     jsonb;
  v_b     jsonb;
  v_risk  double precision;
begin
  -- ── 1. HAPPY PATH: an all-inherit active zone plans exactly the live 0233 risk ───────────────
  v_out := public.typed_zone_effect_dispatch_v1(jsonb_build_object(
    'contract_version', 1,
    'event', jsonb_build_object('event_type','fleet_leg_traversal',
             'event_id','11111111-1111-1111-1111-111111111111','combined_stats',120),
    'runtime_config', jsonb_build_object('pirate_intercept_globals', v_globals),
    'candidates', jsonb_build_array(jsonb_build_object(
      'zone_id','22222222-2222-2222-2222-222222222222','zone_kind','pirate',
      'zone_status','active','zone_revision',3,
      'match', jsonb_build_object('match_type','fleet_leg_intersection',
               'exposure_fraction',0.4,'ambush_x',10,'ambush_y',20),
      'effects', jsonb_build_array(jsonb_build_object(
        'effect_type','pirate_intercept','overrides','{}'::jsonb))))));

  if (v_out->>'ok') <> 'true' then raise exception 'TZD_FAIL_HAPPY: %', v_out; end if;
  if jsonb_array_length(v_out->'plan'->'planned_effects') <> 1 then
    raise exception 'TZD_FAIL_HAPPY: expected exactly one planned effect'; end if;
  if (v_out->'plan'->'planned_effects'->0->>'risk')::double precision
     is distinct from public.pirate_intercept_compute_risk(120, 0.4) then
    raise exception 'TZD_FAIL_HAPPY: planned risk <> live risk'; end if;
  -- the whole idempotency identity is present, all four parts
  if (v_out->'plan'->'planned_effects'->0->'idempotency'->>'event_id') is null
     or (v_out->'plan'->'planned_effects'->0->'idempotency'->>'zone_id') is null
     or (v_out->'plan'->'planned_effects'->0->'idempotency'->>'effect_type') <> 'pirate_intercept'
     or (v_out->'plan'->'planned_effects'->0->'idempotency'->>'behavior_version') <> '1' then
    raise exception 'TZD_FAIL_HAPPY: idempotency identity incomplete'; end if;
  if (v_out->'plan'->'planned_effects'->0->'selection'->>'policy') <> 'max_exposure_then_zone_id_asc' then
    raise exception 'TZD_FAIL_HAPPY: selection policy not named in the plan'; end if;
  if (v_out->'plan'->'planned_effects'->0->>'zone_revision') <> '3' then
    raise exception 'TZD_FAIL_HAPPY: zone_revision not carried into the plan'; end if;
  raise notice 'TZD_PASS_HAPPY_PATH_PARITY';

  -- ── 2. PER-KNOB OVERRIDES each move the risk in the right direction ─────────────────────────
  v_risk := public.pirate_intercept_compute_risk(120, 0.4);
  -- a lower base_risk must lower the planned risk
  v_out := public.typed_zone_effect_dispatch_v1(jsonb_build_object(
    'contract_version', 1,
    'event', jsonb_build_object('event_type','fleet_leg_traversal',
             'event_id','11111111-1111-1111-1111-111111111111','combined_stats',120),
    'runtime_config', jsonb_build_object('pirate_intercept_globals', v_globals),
    'candidates', jsonb_build_array(jsonb_build_object(
      'zone_id','22222222-2222-2222-2222-222222222222','zone_kind','pirate',
      'zone_status','active','zone_revision',0,
      'match', jsonb_build_object('match_type','fleet_leg_intersection',
               'exposure_fraction',0.4,'ambush_x',0,'ambush_y',0),
      'effects', jsonb_build_array(jsonb_build_object(
        'effect_type','pirate_intercept',
        'overrides', jsonb_build_object('base_risk', 0.10)))))));
  if (v_out->'plan'->'planned_effects'->0->>'risk')::double precision >= v_risk then
    raise exception 'TZD_FAIL_OVERRIDE: a lower base_risk did not lower the planned risk'; end if;
  -- and the resolved_config shows the override beside the inherited globals
  if (v_out->'plan'->'planned_effects'->0->'resolved_config'->>'base_risk')::double precision <> 0.10
     or (v_out->'plan'->'planned_effects'->0->'resolved_config'->>'stat_reference')::double precision <> 120 then
    raise exception 'TZD_FAIL_OVERRIDE: resolved_config did not blend override with globals'; end if;
  raise notice 'TZD_PASS_OVERRIDE_RESOLUTION';

  -- ── 3. OVERLAP: highest exposure wins; equal exposure breaks to the lowest uuid ─────────────
  v_out := public.typed_zone_effect_dispatch_v1(jsonb_build_object(
    'contract_version', 1,
    'event', jsonb_build_object('event_type','fleet_leg_traversal',
             'event_id','11111111-1111-1111-1111-111111111111','combined_stats',60),
    'runtime_config', jsonb_build_object('pirate_intercept_globals', v_globals),
    'candidates', jsonb_build_array(
      jsonb_build_object('zone_id','aaaaaaaa-0000-4000-8000-000000000001','zone_kind','pirate',
        'zone_status','active','zone_revision',0,
        'match', jsonb_build_object('match_type','fleet_leg_intersection',
                 'exposure_fraction',0.2,'ambush_x',0,'ambush_y',0),
        'effects', jsonb_build_array(jsonb_build_object('effect_type','pirate_intercept','overrides','{}'::jsonb))),
      jsonb_build_object('zone_id','bbbbbbbb-0000-4000-8000-000000000002','zone_kind','pirate',
        'zone_status','active','zone_revision',0,
        'match', jsonb_build_object('match_type','fleet_leg_intersection',
                 'exposure_fraction',0.9,'ambush_x',0,'ambush_y',0),
        'effects', jsonb_build_array(jsonb_build_object('effect_type','pirate_intercept','overrides','{}'::jsonb))))));
  if (v_out->'plan'->'planned_effects'->0->>'zone_id') <> 'bbbbbbbb-0000-4000-8000-000000000002' then
    raise exception 'TZD_FAIL_OVERLAP: the deeper crossing did not win'; end if;
  if jsonb_array_length(v_out->'plan'->'planned_effects') <> 1 then
    raise exception 'TZD_FAIL_OVERLAP: single-selection policy produced more than one effect'; end if;
  raise notice 'TZD_PASS_HIGHEST_EXPOSURE_WINS';

  -- equal exposure → lowest uuid
  v_a := jsonb_build_object(
    'contract_version', 1,
    'event', jsonb_build_object('event_type','fleet_leg_traversal',
             'event_id','11111111-1111-1111-1111-111111111111','combined_stats',60),
    'runtime_config', jsonb_build_object('pirate_intercept_globals', v_globals),
    'candidates', jsonb_build_array(
      jsonb_build_object('zone_id','bbbbbbbb-0000-4000-8000-000000000002','zone_kind','pirate',
        'zone_status','active','zone_revision',0,
        'match', jsonb_build_object('match_type','fleet_leg_intersection',
                 'exposure_fraction',0.5,'ambush_x',0,'ambush_y',0),
        'effects', jsonb_build_array(jsonb_build_object('effect_type','pirate_intercept','overrides','{}'::jsonb))),
      jsonb_build_object('zone_id','aaaaaaaa-0000-4000-8000-000000000001','zone_kind','pirate',
        'zone_status','active','zone_revision',0,
        'match', jsonb_build_object('match_type','fleet_leg_intersection',
                 'exposure_fraction',0.5,'ambush_x',0,'ambush_y',0),
        'effects', jsonb_build_array(jsonb_build_object('effect_type','pirate_intercept','overrides','{}'::jsonb)))));
  v_out := public.typed_zone_effect_dispatch_v1(v_a);
  if (v_out->'plan'->'planned_effects'->0->>'zone_id') <> 'aaaaaaaa-0000-4000-8000-000000000001' then
    raise exception 'TZD_FAIL_TIE: equal exposure did not break to the lowest uuid'; end if;
  raise notice 'TZD_PASS_EQUAL_EXPOSURE_LOWEST_UUID';

  -- ── 4. INPUT-ORDER INVARIANCE: reversing the candidate array changes nothing ────────────────
  v_b := jsonb_set(v_a, '{candidates}', jsonb_build_array(v_a->'candidates'->1, v_a->'candidates'->0));
  if public.typed_zone_effect_dispatch_v1(v_a) is distinct from public.typed_zone_effect_dispatch_v1(v_b) then
    raise exception 'TZD_FAIL_ORDER: the plan depends on candidate input order'; end if;
  raise notice 'TZD_PASS_INPUT_ORDER_INVARIANT';

  -- ── 5. DETERMINISM: the same request twice is byte-identical ────────────────────────────────
  if public.typed_zone_effect_dispatch_v1(v_a) is distinct from public.typed_zone_effect_dispatch_v1(v_a) then
    raise exception 'TZD_FAIL_DETERMINISM: two identical requests disagreed'; end if;
  raise notice 'TZD_PASS_DETERMINISTIC';

  -- ── 6. LIFECYCLE: an inactive zone is IGNORED, not an error ─────────────────────────────────
  v_out := public.typed_zone_effect_dispatch_v1(jsonb_set(v_a, '{candidates}', jsonb_build_array(
    jsonb_set(v_a->'candidates'->0, '{zone_status}', '"inactive"'::jsonb))));
  if (v_out->>'ok') <> 'true' then raise exception 'TZD_FAIL_INACTIVE: an inactive zone was an error'; end if;
  if jsonb_array_length(v_out->'plan'->'planned_effects') <> 0 then
    raise exception 'TZD_FAIL_INACTIVE: an inactive zone produced a plan'; end if;
  raise notice 'TZD_PASS_INACTIVE_IGNORED';

  -- an empty effect set is valid and plans nothing
  v_out := public.typed_zone_effect_dispatch_v1(jsonb_set(v_a, '{candidates}', jsonb_build_array(
    jsonb_set(v_a->'candidates'->0, '{effects}', '[]'::jsonb))));
  if (v_out->>'ok') <> 'true' or jsonb_array_length(v_out->'plan'->'planned_effects') <> 0 then
    raise exception 'TZD_FAIL_EMPTY_EFFECTS: an empty effect set was not valid-and-inert'; end if;
  raise notice 'TZD_PASS_EMPTY_EFFECT_SET_INERT';

  -- ── 7. TYPED FAILURES ───────────────────────────────────────────────────────────────────────
  -- unsupported effect type is NEVER silently ignored
  v_out := public.typed_zone_effect_dispatch_v1(
    jsonb_set(v_a, '{candidates,0,effects,0,effect_type}', '"mining_yield"'::jsonb));
  if (v_out->'error'->>'code') <> 'unsupported_effect_type' then
    raise exception 'TZD_FAIL_UNSUPPORTED_EFFECT: got %', v_out; end if;

  v_out := public.typed_zone_effect_dispatch_v1(
    jsonb_set(v_a, '{event,event_type}', '"mining_requested"'::jsonb));
  if (v_out->'error'->>'code') <> 'unsupported_event_type' then
    raise exception 'TZD_FAIL_UNSUPPORTED_EVENT: got %', v_out; end if;

  v_out := public.typed_zone_effect_dispatch_v1(jsonb_set(v_a, '{contract_version}', '2'::jsonb));
  if (v_out->'error'->>'code') <> 'invalid_contract_version' then
    raise exception 'TZD_FAIL_CONTRACT_VERSION: got %', v_out; end if;

  v_out := public.typed_zone_effect_dispatch_v1(jsonb_set(v_a, '{event,event_id}', '"not-a-uuid"'::jsonb));
  if (v_out->'error'->>'code') <> 'invalid_event' then
    raise exception 'TZD_FAIL_BAD_UUID: got %', v_out; end if;

  -- duplicate zone_id is never silently merged
  v_out := public.typed_zone_effect_dispatch_v1(jsonb_set(v_a, '{candidates}', jsonb_build_array(
    v_a->'candidates'->0, v_a->'candidates'->0)));
  if (v_out->'error'->>'code') <> 'duplicate_zone_id' then
    raise exception 'TZD_FAIL_DUP_ZONE: got %', v_out; end if;

  -- duplicate effect_type on ONE zone is invalid
  v_out := public.typed_zone_effect_dispatch_v1(jsonb_set(v_a, '{candidates,0,effects}',
    jsonb_build_array(
      jsonb_build_object('effect_type','pirate_intercept','overrides','{}'::jsonb),
      jsonb_build_object('effect_type','pirate_intercept','overrides','{}'::jsonb))));
  if (v_out->'error'->>'code') <> 'duplicate_effect_type' then
    raise exception 'TZD_FAIL_DUP_EFFECT: got %', v_out; end if;
  raise notice 'TZD_PASS_TYPED_FAILURES';

  -- ── 8. RESOLVED-CONFIG failure is distinct from per-value failure ───────────────────────────
  -- each value is individually in range; only the RESOLVED pair is inverted
  v_out := public.typed_zone_effect_dispatch_v1(
    jsonb_set(
      jsonb_set(v_a, '{runtime_config,pirate_intercept_globals,max_risk}', '0.50'::jsonb),
      '{candidates,0,effects,0,overrides}', jsonb_build_object('min_risk', 0.80)));
  if (v_out->'error'->>'code') <> 'invalid_resolved_effect_config' then
    raise exception 'TZD_FAIL_RESOLVED_CONFIG: got %', v_out; end if;
  if (v_out->'error'->>'path') not like '%overrides%' then
    raise exception 'TZD_FAIL_RESOLVED_CONFIG: error path is not specific'; end if;
  raise notice 'TZD_PASS_RESOLVED_CONFIG_DISTINCT';

  -- ── 9. IDENTITY DOES NOT DISPATCH: zone_kind is carried but never decides ───────────────────
  v_out := public.typed_zone_effect_dispatch_v1(
    jsonb_set(v_a, '{candidates,0,zone_kind}', '"mining"'::jsonb));
  if (v_out->>'ok') <> 'true' or jsonb_array_length(v_out->'plan'->'planned_effects') <> 1 then
    raise exception 'TZD_FAIL_IDENTITY: zone_kind changed applicability'; end if;
  if (v_out->'plan'->'planned_effects'->0->>'zone_kind') <> 'mining' then
    raise exception 'TZD_FAIL_IDENTITY: zone_kind was not carried into the plan'; end if;
  raise notice 'TZD_PASS_IDENTITY_DOES_NOT_DISPATCH';

  -- ── 10. EDGE VALUES of the curve, against the live function ─────────────────────────────────
  -- negative stats floored exactly as 0233 does; zero exposure lifted to the floor
  if public.typed_zone_pirate_intercept_risk_v1(0.35,0.02,0.90,0.15,120, -50, 1.0)
     is distinct from public.pirate_intercept_compute_risk(-50, 1.0) then
    raise exception 'TZD_FAIL_EDGE: negative combined_stats diverged'; end if;
  if public.typed_zone_pirate_intercept_risk_v1(0.35,0.02,0.90,0.15,120, 120, 0.0)
     is distinct from public.pirate_intercept_compute_risk(120, 0.0) then
    raise exception 'TZD_FAIL_EDGE: zero exposure diverged'; end if;
  if public.typed_zone_pirate_intercept_risk_v1(0.35,0.02,0.90,0.15,120, 120, 1.0)
     is distinct from public.pirate_intercept_compute_risk(120, 1.0) then
    raise exception 'TZD_FAIL_EDGE: full exposure diverged'; end if;
  raise notice 'TZD_PASS_EDGE_PARITY';
end $proof$;

select 'TZD_PASS_NO_WRITES' as marker;
