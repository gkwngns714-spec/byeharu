-- Byeharu — TYPED-ZONE EFFECT DISPATCH V1 (migration 0274). Slice 2 of the typed-zone platform.
-- TWO PURE VERSIONED FUNCTIONS. NO new flag, NO table, NO runtime wiring, NOTHING calls these yet.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THIS LIVES IN POSTGRESQL AND NOT IN TYPESCRIPT
-- Byeharu is server-authoritative. The live geometry and interception runtime are already PL/pgSQL,
-- and slice 3 must compare this planner against the deployed 0233 path INSIDE the database, over the
-- same rows, in the same transaction. A TypeScript planner would either become a second authority
-- over player outcomes or be discarded at cutover. So the decision logic is here; the TypeScript
-- side (src/features/worldeditor/zoneEffectDispatchContract.ts) is types only.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- IT PLANS. IT NEVER EXECUTES, AND IT NEVER LOOKS ANYTHING UP.
-- The dispatcher receives ALL data as input and performs:
--   * no table read (not danger_zones, not zone_effect_pirate_intercept, not game_config);
--   * no write of any kind;
--   * no random roll — the entropy stays with the executor, so the same request always plans the same;
--   * no clock read;
--   * no call into any existing runtime function;
--   * no geometry operation — exposure and the ambush point arrive already computed.
-- It returns a PLAN or a TYPED VALIDATION FAILURE. That is precisely what makes slice 3 possible:
-- a plan can be diffed against the live path; a side effect cannot.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- VERSIONING LAW
-- Do NOT later CREATE OR REPLACE these to change V1 semantics. When behaviour changes materially,
-- add typed_zone_effect_dispatch_v2 / typed_zone_pirate_intercept_risk_v2 with behavior_version = 2
-- and contract_version = 2. V1 stays immutable historical behaviour so any effect ever planned can
-- be re-derived exactly. behavior_version therefore comes from the versioned IMPLEMENTATION, never
-- from a mutable schema column — it describes executable semantics, not content configuration, and
-- must never be added to zone_effect_pirate_intercept.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- V1 SCOPE, DELIBERATELY NARROW
--   fleet_leg_traversal  →  pirate_intercept
-- and nothing else. An unknown effect type is a TYPED unsupported_effect_type, never a silent skip:
-- silently ignoring one would turn a newly introduced effect into an invisible gameplay omission the
-- day an older dispatcher version received it. No placeholder mining/exploration variants are added
-- here merely to look generic — genericity that is never exercised is a liability, not a feature.
--
-- IDENTITY DOES NOT DISPATCH. zone_kind rides on every candidate and into every planned effect for
-- rendering, traceability and audit, but it takes NO part in applicability or selection. Effects do
-- that, because effects are what a zone DOES.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regclass('public.zone_effect_pirate_intercept') is null then
    raise exception 'TYPED-ZONE 0274: zone_effect_pirate_intercept (0273) is missing — slice 1 must land first';
  end if;
  if to_regprocedure('public.pirate_intercept_compute_risk(double precision, double precision)') is null then
    raise exception 'TYPED-ZONE 0274: pirate_intercept_compute_risk (0233) is missing — the parity target must exist';
  end if;
  if to_regprocedure('public.typed_zone_pirate_intercept_risk_v1(double precision, double precision, double precision, double precision, double precision, double precision, double precision)') is not null
     or to_regprocedure('public.typed_zone_effect_dispatch_v1(jsonb)') is not null then
    raise exception 'TYPED-ZONE 0274: a V1 function already exists — V1 is immutable; ship a _v2 sibling instead';
  end if;
end $pre$;

-- ── 0c. tiny pure helpers the dispatcher is built from ──────────────────────────────────────────
-- Kept separate so the planner reads as its algorithm rather than as string-wrangling, and so each
-- can be proven on its own. All three are IMMUTABLE and touch nothing.

/* A typed failure envelope. Callers branch on `code`; `message` is diagnostic only. */
create function public.typed_zone_dispatch_error_v1(p_code text, p_path text, p_message text)
returns jsonb
language sql
immutable
strict
parallel safe
security invoker
as $$
  select jsonb_build_object('ok', false, 'error',
           jsonb_build_object('code', p_code, 'path', p_path, 'message', p_message))
$$;

/* Canonical-uuid shape check. Deliberately a regex rather than a ::uuid cast: a cast raises, and a
   malformed id must come back as a TYPED validation failure with a path, not an exception. */
create function public.typed_zone_is_uuid_v1(p_value text)
returns boolean
language sql
immutable
parallel safe
security invoker
as $$
  select p_value is not null
     and p_value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$$;

/* True iff the jsonb value is a REAL finite number. jsonb rejects bare NaN/Infinity literals, but a
   number can still arrive as a string, and a jsonb `number` can be cast to a double that is neither
   finite nor comparable — so this checks the type AND the value. `x = x` is false only for NaN. */
create function public.typed_zone_is_finite_v1(p_value jsonb)
returns boolean
language sql
immutable
parallel safe
security invoker
as $$
  select p_value is not null
     and jsonb_typeof(p_value) = 'number'
     and (p_value #>> '{}')::double precision = (p_value #>> '{}')::double precision
     and (p_value #>> '{}')::double precision <> 'Infinity'::double precision
     and (p_value #>> '{}')::double precision <> '-Infinity'::double precision
$$;

revoke execute on function public.typed_zone_dispatch_error_v1(text, text, text) from public, anon, authenticated;
revoke execute on function public.typed_zone_is_uuid_v1(text) from public, anon, authenticated;
revoke execute on function public.typed_zone_is_finite_v1(jsonb) from public, anon, authenticated;

-- ── 1. typed_zone_pirate_intercept_risk_v1 — the pure risk curve ────────────────────────────────
-- Transcribed from pirate_intercept_compute_risk (0233) with the knobs PASSED IN rather than read
-- from game_config. That is the only difference, and it is the point: the caller resolves each knob
-- (per-zone override, else global) and this function does the arithmetic. Same inputs ⇒ same output
-- as the live function, which the disposable proof demonstrates over an input sweep.
--
-- IMMUTABLE is the honest marker: given the same seven arguments the result never varies, because
-- nothing here reads config, tables, the clock or randomness.
create function public.typed_zone_pirate_intercept_risk_v1(
  p_base_risk       double precision,
  p_min_risk        double precision,
  p_max_risk        double precision,
  p_exposure_floor  double precision,
  p_stat_reference  double precision,
  p_combined_stats  double precision,
  p_exposure_fraction double precision
)
returns double precision
language sql
immutable
strict
parallel safe
security invoker
as $$
  select greatest(
    p_min_risk,
    least(
      p_max_risk,
      p_base_risk
        * (p_stat_reference / (p_stat_reference + greatest(p_combined_stats, 0)))
        * least(1.0, greatest(p_exposure_floor, p_exposure_fraction))
    )
  )
$$;

revoke execute on function public.typed_zone_pirate_intercept_risk_v1(
  double precision, double precision, double precision, double precision,
  double precision, double precision, double precision) from public, anon, authenticated;

comment on function public.typed_zone_pirate_intercept_risk_v1(
  double precision, double precision, double precision, double precision,
  double precision, double precision, double precision) is
  'TYPED-ZONE PLATFORM (0274): the pure pirate-interception risk curve, transcribed from '
  'pirate_intercept_compute_risk (0233) with every knob passed IN instead of read from game_config. '
  'IMMUTABLE/STRICT/PARALLEL SAFE — no config, table, clock or randomness. V1 is immutable: ship a '
  '_v2 sibling rather than replacing this.';

-- ── 2. typed_zone_effect_dispatch_v1 — the pure planner ─────────────────────────────────────────
-- jsonb in → jsonb out: {ok:true, plan} or {ok:false, error:{code, path, message}}.
-- Validation runs BEFORE planning and reports the FIRST failure with a precise path, so a malformed
-- request never yields a half-plan.
create function public.typed_zone_effect_dispatch_v1(p_request jsonb)
returns jsonb
language plpgsql
immutable
strict
parallel safe
security invoker
as $$
declare
  v_event      jsonb;
  v_cfg        jsonb;
  v_globals    jsonb;
  v_cands      jsonb;
  v_c          jsonb;
  v_e          jsonb;
  v_i          int;
  v_j          int;
  v_seen_zone  text[] := array[]::text[];
  v_seen_eff   text[];
  v_path       text;
  v_knob       text;
  v_ov         jsonb;
  v_res        jsonb;
  v_best       jsonb := null;
  v_best_expo  double precision;
  v_best_zone  text;
  v_risk       double precision;
  v_planned    jsonb := '[]'::jsonb;
  v_num        double precision;
begin
  -- ── step 1: top-level contract ───────────────────────────────────────────────────────────────
  if jsonb_typeof(p_request) <> 'object' then
    return public.typed_zone_dispatch_error_v1('invalid_contract_version', '', 'request must be an object');
  end if;
  if (p_request->>'contract_version') is distinct from '1' then
    return public.typed_zone_dispatch_error_v1('invalid_contract_version', 'contract_version',
             'only contract_version 1 is supported by this dispatcher');
  end if;

  -- ── step 2: event ────────────────────────────────────────────────────────────────────────────
  v_event := p_request->'event';
  if jsonb_typeof(v_event) <> 'object' then
    return public.typed_zone_dispatch_error_v1('invalid_event', 'event', 'event must be an object');
  end if;
  if (v_event->>'event_type') is null then
    return public.typed_zone_dispatch_error_v1('invalid_event', 'event.event_type', 'event_type is required');
  end if;
  if (v_event->>'event_type') <> 'fleet_leg_traversal' then
    return public.typed_zone_dispatch_error_v1('unsupported_event_type', 'event.event_type',
             format('V1 supports only fleet_leg_traversal, got %s', v_event->>'event_type'));
  end if;
  if not public.typed_zone_is_uuid_v1(v_event->>'event_id') then
    return public.typed_zone_dispatch_error_v1('invalid_event', 'event.event_id', 'event_id must be a uuid');
  end if;
  if not public.typed_zone_is_finite_v1(v_event->'combined_stats') then
    return public.typed_zone_dispatch_error_v1('invalid_event', 'event.combined_stats',
             'combined_stats must be a finite number');
  end if;

  -- ── step 3: runtime config (resolved globals passed IN — never read here) ─────────────────────
  v_cfg := p_request->'runtime_config';
  if jsonb_typeof(v_cfg) <> 'object' then
    return public.typed_zone_dispatch_error_v1('invalid_runtime_config', 'runtime_config',
             'runtime_config must be an object');
  end if;
  v_globals := v_cfg->'pirate_intercept_globals';
  if jsonb_typeof(v_globals) <> 'object' then
    return public.typed_zone_dispatch_error_v1('invalid_runtime_config',
             'runtime_config.pirate_intercept_globals', 'pirate_intercept_globals must be an object');
  end if;
  foreach v_knob in array array['base_risk','min_risk','max_risk','exposure_floor','stat_reference'] loop
    v_path := 'runtime_config.pirate_intercept_globals.' || v_knob;
    if not public.typed_zone_is_finite_v1(v_globals->v_knob) then
      return public.typed_zone_dispatch_error_v1('invalid_runtime_config', v_path,
               format('%s must be a finite number', v_knob));
    end if;
    v_num := (v_globals->>v_knob)::double precision;
    if v_knob = 'stat_reference' then
      if v_num <= 0 then
        return public.typed_zone_dispatch_error_v1('invalid_runtime_config', v_path, 'stat_reference must be > 0');
      end if;
    elsif v_num < 0 or v_num > 1 then
      return public.typed_zone_dispatch_error_v1('invalid_runtime_config', v_path,
               format('%s must be within [0,1]', v_knob));
    end if;
  end loop;
  if (v_globals->>'min_risk')::double precision > (v_globals->>'max_risk')::double precision then
    return public.typed_zone_dispatch_error_v1('invalid_runtime_config',
             'runtime_config.pirate_intercept_globals', 'min_risk must not exceed max_risk');
  end if;

  -- ── step 4: candidates ───────────────────────────────────────────────────────────────────────
  v_cands := p_request->'candidates';
  if jsonb_typeof(v_cands) <> 'array' then
    return public.typed_zone_dispatch_error_v1('invalid_candidate', 'candidates', 'candidates must be an array');
  end if;

  v_i := -1;
  for v_c in select * from jsonb_array_elements(v_cands) loop
    v_i := v_i + 1;
    v_path := format('candidates[%s]', v_i);

    if jsonb_typeof(v_c) <> 'object' then
      return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path, 'candidate must be an object');
    end if;
    if not public.typed_zone_is_uuid_v1(v_c->>'zone_id') then
      return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.zone_id', 'zone_id must be a uuid');
    end if;
    -- duplicates are NEVER silently merged: two rows for one zone means the caller is confused, and
    -- guessing which to keep would hide the bug behind a plausible plan.
    if (v_c->>'zone_id') = any (v_seen_zone) then
      return public.typed_zone_dispatch_error_v1('duplicate_zone_id', v_path || '.zone_id',
               format('zone_id %s appears more than once', v_c->>'zone_id'));
    end if;
    v_seen_zone := v_seen_zone || (v_c->>'zone_id');

    if coalesce(v_c->>'zone_kind', '') = '' then
      return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.zone_kind',
               'zone_kind must be a non-empty string');
    end if;
    if (v_c->>'zone_status') not in ('active', 'inactive') then
      return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.zone_status',
               'zone_status must be active or inactive');
    end if;
    if jsonb_typeof(v_c->'zone_revision') <> 'number'
       or (v_c->>'zone_revision')::double precision < 0
       or (v_c->>'zone_revision')::double precision <> floor((v_c->>'zone_revision')::double precision) then
      return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.zone_revision',
               'zone_revision must be an integer >= 0');
    end if;

    if (v_c->'match'->>'match_type') is distinct from 'fleet_leg_intersection' then
      return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.match.match_type',
               'match_type must be fleet_leg_intersection');
    end if;
    if not public.typed_zone_is_finite_v1(v_c->'match'->'exposure_fraction')
       or (v_c->'match'->>'exposure_fraction')::double precision < 0
       or (v_c->'match'->>'exposure_fraction')::double precision > 1 then
      return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.match.exposure_fraction',
               'exposure_fraction must be finite and within [0,1]');
    end if;
    if not public.typed_zone_is_finite_v1(v_c->'match'->'ambush_x')
       or not public.typed_zone_is_finite_v1(v_c->'match'->'ambush_y') then
      return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.match',
               'ambush_x and ambush_y must be finite');
    end if;

    if jsonb_typeof(v_c->'effects') <> 'array' then
      return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.effects',
               'effects must be an array');
    end if;

    -- ── step 5: effects on this candidate ──────────────────────────────────────────────────────
    v_seen_eff := array[]::text[];
    v_j := -1;
    for v_e in select * from jsonb_array_elements(v_c->'effects') loop
      v_j := v_j + 1;
      v_path := format('candidates[%s].effects[%s]', v_i, v_j);
      if jsonb_typeof(v_e) <> 'object' or (v_e->>'effect_type') is null then
        return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path, 'effect must be an object with effect_type');
      end if;
      if (v_e->>'effect_type') = any (v_seen_eff) then
        return public.typed_zone_dispatch_error_v1('duplicate_effect_type', v_path || '.effect_type',
                 format('effect_type %s appears more than once on this zone', v_e->>'effect_type'));
      end if;
      v_seen_eff := v_seen_eff || (v_e->>'effect_type');

      if (v_e->>'effect_type') <> 'pirate_intercept' then
        return public.typed_zone_dispatch_error_v1('unsupported_effect_type', v_path || '.effect_type',
                 format('V1 registers only pirate_intercept, got %s', v_e->>'effect_type'));
      end if;

      -- per-value validation of the overrides (null = inherit, always legal)
      v_ov := coalesce(v_e->'overrides', '{}'::jsonb);
      foreach v_knob in array array['base_risk','min_risk','max_risk','exposure_floor','stat_reference'] loop
        if v_ov ? v_knob and jsonb_typeof(v_ov->v_knob) <> 'null' then
          if not public.typed_zone_is_finite_v1(v_ov->v_knob) then
            return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.overrides.' || v_knob,
                     format('%s override must be a finite number', v_knob));
          end if;
          v_num := (v_ov->>v_knob)::double precision;
          if v_knob = 'stat_reference' then
            if v_num <= 0 then
              return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.overrides.stat_reference',
                       'stat_reference override must be > 0');
            end if;
          elsif v_num < 0 or v_num > 1 then
            return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.overrides.' || v_knob,
                     format('%s override must be within [0,1]', v_knob));
          end if;
        end if;
      end loop;

      -- ── step 6: RESOLVE, then validate the RESOLVED pair ─────────────────────────────────────
      -- Each value can be individually in range while the resolved configuration is inverted — e.g.
      -- global max_risk 0.50 with a zone min_risk override of 0.80. That is a distinct failure from
      -- a bad single value, so it gets its own code.
      v_res := jsonb_build_object(
        'base_risk',      coalesce(nullif(v_ov->'base_risk','null'::jsonb),      v_globals->'base_risk'),
        'min_risk',       coalesce(nullif(v_ov->'min_risk','null'::jsonb),       v_globals->'min_risk'),
        'max_risk',       coalesce(nullif(v_ov->'max_risk','null'::jsonb),       v_globals->'max_risk'),
        'exposure_floor', coalesce(nullif(v_ov->'exposure_floor','null'::jsonb), v_globals->'exposure_floor'),
        'stat_reference', coalesce(nullif(v_ov->'stat_reference','null'::jsonb), v_globals->'stat_reference'));

      if (v_res->>'min_risk')::double precision > (v_res->>'max_risk')::double precision then
        return public.typed_zone_dispatch_error_v1('invalid_resolved_effect_config', v_path || '.overrides',
                 'resolved min_risk exceeds resolved max_risk');
      end if;

      -- ── step 7: lifecycle + event compatibility ──────────────────────────────────────────────
      -- An INACTIVE zone is ignored, not invalid: it is a legitimate world state, not a caller error.
      if (v_c->>'zone_status') = 'active' then
        -- ── step 8: overlap resolution, max_exposure_then_zone_id_asc ──────────────────────────
        -- Deepest crossing wins; ties broken by the lowest zone_id. Transcribed from 0233's
        -- `order by exposure_fraction desc, zone_id asc limit 1`, encoded as data rather than left
        -- to an accident of query shape. Comparing uuids by text is exact here: the canonical
        -- lowercase hyphenated form sorts identically to Postgres's bytewise uuid order.
        if v_best is null
           or (v_c->'match'->>'exposure_fraction')::double precision > v_best_expo
           or ((v_c->'match'->>'exposure_fraction')::double precision = v_best_expo
               and (v_c->>'zone_id') < v_best_zone) then
          v_best := jsonb_build_object('candidate', v_c, 'resolved', v_res);
          v_best_expo := (v_c->'match'->>'exposure_fraction')::double precision;
          v_best_zone := v_c->>'zone_id';
        end if;
      end if;
    end loop;
  end loop;

  -- ── step 9: build the plan ───────────────────────────────────────────────────────────────────
  if v_best is not null then
    v_c   := v_best->'candidate';
    v_res := v_best->'resolved';
    v_risk := public.typed_zone_pirate_intercept_risk_v1(
      (v_res->>'base_risk')::double precision,
      (v_res->>'min_risk')::double precision,
      (v_res->>'max_risk')::double precision,
      (v_res->>'exposure_floor')::double precision,
      (v_res->>'stat_reference')::double precision,
      (v_event->>'combined_stats')::double precision,
      (v_c->'match'->>'exposure_fraction')::double precision);

    v_planned := jsonb_build_array(jsonb_build_object(
      'effect_type',      'pirate_intercept',
      'behavior_version', 1,
      'zone_id',          v_c->>'zone_id',
      'zone_kind',        v_c->>'zone_kind',
      'zone_revision',    (v_c->>'zone_revision')::bigint,
      'idempotency', jsonb_build_object(
        'event_id',         v_event->>'event_id',
        'zone_id',          v_c->>'zone_id',
        'effect_type',      'pirate_intercept',
        'behavior_version', 1),
      'selection', jsonb_build_object(
        'policy',            'max_exposure_then_zone_id_asc',
        'exposure_fraction', (v_c->'match'->>'exposure_fraction')::double precision,
        'ambush_x',          (v_c->'match'->>'ambush_x')::double precision,
        'ambush_y',          (v_c->'match'->>'ambush_y')::double precision),
      'resolved_config',  v_res,
      'risk',             v_risk));
  end if;

  return jsonb_build_object('ok', true, 'plan', jsonb_build_object(
    'contract_version', 1,
    'event_id',         v_event->>'event_id',
    'planned_effects',  v_planned));
end;
$$;

revoke execute on function public.typed_zone_effect_dispatch_v1(jsonb) from public, anon, authenticated;

comment on function public.typed_zone_effect_dispatch_v1(jsonb) is
  'TYPED-ZONE PLATFORM (0274): the PURE effect dispatcher. Request in, plan or typed failure out. '
  'Reads no table, no game_config and no clock; writes nothing; rolls no dice; calls no 0233 runtime '
  'function; performs no geometry. V1 registers exactly fleet_leg_traversal -> pirate_intercept and '
  'returns unsupported_effect_type for anything else rather than ignoring it. V1 is immutable: ship '
  'a _v2 sibling rather than replacing this.';

-- ── 3. SELF-ASSERT — pure, dark, and bit-for-bit equal to 0233 on resolved knobs ────────────────
do $tzd$
declare
  v_risk_def text;
  v_disp_def text;
  v_globals  jsonb;
  v_req      jsonb;
  v_out      jsonb;
  v_live     double precision;
  v_new      double precision;
  v_s        record;
begin
  -- (1) neither function touches state
  select pg_get_functiondef(to_regprocedure(
    'public.typed_zone_effect_dispatch_v1(jsonb)')) into v_disp_def;
  if v_disp_def ~* '\m(insert|update|delete|truncate)\M' then
    raise exception 'TYPED-ZONE 0274 self-assert FAIL: the dispatcher contains a write statement'; end if;
  if v_disp_def ~* 'danger_zones|zone_effect_pirate_intercept|game_config|cfg_num|cfg_bool|random\(|now\(|clock_timestamp' then
    raise exception 'TYPED-ZONE 0274 self-assert FAIL: the dispatcher reads state, config, randomness or the clock'; end if;
  if v_disp_def ~* 'pirate_intercept_compute_risk|pirate_intercept_leg_zone_hits|pirate_intercept_evaluate_leg' then
    raise exception 'TYPED-ZONE 0274 self-assert FAIL: the dispatcher calls a 0233 runtime function'; end if;
  if v_disp_def ~* 'st_intersects|st_length|st_makeline|st_buffer|st_closestpoint' then
    raise exception 'TYPED-ZONE 0274 self-assert FAIL: the dispatcher performs geometry'; end if;

  -- (2) the 0233 runtime is untouched and still the live authority
  select pg_get_functiondef(to_regprocedure(
    'public.pirate_intercept_compute_risk(double precision, double precision)')) into v_risk_def;
  if v_risk_def ~* 'typed_zone_' then
    raise exception 'TYPED-ZONE 0274 self-assert FAIL: the 0233 risk function references the typed-zone planner'; end if;

  -- (3) PARITY, computed against the real 0233 function over an input sweep with the CURRENT globals
  v_globals := jsonb_build_object(
    'base_risk',      coalesce(public.cfg_num('pirate_intercept_base_risk'),      0.35),
    'min_risk',       coalesce(public.cfg_num('pirate_intercept_min_risk'),       0.02),
    'max_risk',       coalesce(public.cfg_num('pirate_intercept_max_risk'),       0.90),
    'exposure_floor', coalesce(public.cfg_num('pirate_intercept_exposure_floor'), 0.15),
    'stat_reference', coalesce(public.cfg_num('pirate_intercept_stat_reference'), 120));

  for v_s in select * from (values (0,0.0),(10,0.05),(60,0.25),(120,0.5),(400,0.9),(5000,1.0))
    as s(stats double precision, expo double precision)
  loop
    v_live := public.pirate_intercept_compute_risk(v_s.stats, v_s.expo);
    v_new  := public.typed_zone_pirate_intercept_risk_v1(
      (v_globals->>'base_risk')::double precision,
      (v_globals->>'min_risk')::double precision,
      (v_globals->>'max_risk')::double precision,
      (v_globals->>'exposure_floor')::double precision,
      (v_globals->>'stat_reference')::double precision,
      v_s.stats, v_s.expo);
    if v_live is distinct from v_new then
      raise exception 'TYPED-ZONE 0274 self-assert FAIL: risk parity broke at stats=% expo=% (live % vs v1 %)',
        v_s.stats, v_s.expo, v_live, v_new;
    end if;
  end loop;

  -- (4) the dispatcher plans an all-inherit zone to exactly the live risk
  v_req := jsonb_build_object(
    'contract_version', 1,
    'event', jsonb_build_object('event_type','fleet_leg_traversal',
             'event_id','11111111-1111-1111-1111-111111111111','combined_stats',120),
    'runtime_config', jsonb_build_object('pirate_intercept_globals', v_globals),
    'candidates', jsonb_build_array(jsonb_build_object(
      'zone_id','22222222-2222-2222-2222-222222222222','zone_kind','pirate',
      'zone_status','active','zone_revision',0,
      'match', jsonb_build_object('match_type','fleet_leg_intersection',
               'exposure_fraction',0.5,'ambush_x',1,'ambush_y',2),
      'effects', jsonb_build_array(jsonb_build_object(
        'effect_type','pirate_intercept','overrides','{}'::jsonb)))));
  v_out := public.typed_zone_effect_dispatch_v1(v_req);
  if (v_out->>'ok') <> 'true' then
    raise exception 'TYPED-ZONE 0274 self-assert FAIL: a valid request did not plan: %', v_out; end if;
  if (v_out->'plan'->'planned_effects'->0->>'risk')::double precision
     is distinct from public.pirate_intercept_compute_risk(120, 0.5) then
    raise exception 'TYPED-ZONE 0274 self-assert FAIL: planned risk <> live risk for an all-inherit zone'; end if;

  -- (5) an unknown effect type is TYPED, never ignored
  v_req := jsonb_set(v_req, '{candidates,0,effects,0,effect_type}', '"mining_yield"'::jsonb);
  v_out := public.typed_zone_effect_dispatch_v1(v_req);
  if (v_out->>'ok') <> 'false' or (v_out->'error'->>'code') <> 'unsupported_effect_type' then
    raise exception 'TYPED-ZONE 0274 self-assert FAIL: an unknown effect type was not a typed failure: %', v_out; end if;

  -- (6) ACL: engine-only, no client execute
  if has_function_privilege('anon', 'public.typed_zone_effect_dispatch_v1(jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.typed_zone_effect_dispatch_v1(jsonb)', 'execute') then
    raise exception 'TYPED-ZONE 0274 self-assert FAIL: a client role can execute the dispatcher'; end if;

  raise notice 'TYPED-ZONE 0274 self-assert ok: two pure V1 functions created; the dispatcher writes nothing, reads no table/config/clock/randomness, calls no 0233 runtime function and does no geometry; the 0233 risk function is untouched and typed-zone-blind; risk parity is bit-identical to pirate_intercept_compute_risk across the input sweep; an all-inherit zone plans to exactly the live risk; an unknown effect type is a typed unsupported_effect_type rather than a silent skip; neither function is client-executable';
end $tzd$;
