-- Byeharu — TYPED-ZONE EFFECT DISPATCH V2 (migration 0279). Slice 6b of the typed-zone platform.
-- A NEW versioned planner. V1 IS NOT TOUCHED. Nothing calls V2 yet.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY A NEW VERSION RATHER THAN AN EDIT
-- V1 registers exactly fleet_leg_traversal -> pirate_intercept and returns unsupported_effect_type
-- for anything else. Teaching it about combat would change what an ALREADY-PLANNED effect means: a
-- plan recorded under behavior_version 1 could no longer be re-derived, and an idempotency key that
-- once identified one act would now identify a different one. So V1 stays frozen as historical
-- behaviour and V2 is a sibling, exactly as the versioning law requires.
--
-- V1 and V2 can coexist indefinitely. Nothing forces a caller to move, and the cutover that would
-- move one is a separate act behind its own flag.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT V2 ADDS
--   contract_version 2, behavior_version 2
--   fleet_leg_traversal -> pirate_intercept   (semantics IDENTICAL to V1 — proven, not assumed)
--   fleet_leg_traversal -> combat             (new)
--
-- EFFECT TYPES RESOLVE INDEPENDENTLY. A zone carrying both effects yields TWO planned effects, each
-- selected among the zones that carry that effect. That is the composable model doing its job: the
-- combat effect does not compete with the pirate effect for a single slot, and neither suppresses
-- the other.
--
-- BUT EACH EFFECT TYPE STILL SELECTS ONE ZONE. Both use max_exposure_then_zone_id_asc. For pirate
-- that is 0233 parity. For combat it is a deliberate safety choice: spawning from every overlapping
-- combat zone would multiply encounters by however many polygons happen to intersect, which is the
-- duplicate-side-effect trap. One zone acts; overlap changes WHICH, never HOW MANY.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- STILL PURE, ON THE SAME TERMS AS V1
-- No table read, no game_config read, no clock, no randomness, no write, no geometry, no call into
-- any 0233 runtime function. Combat's own capability gate (typed_zone_combat_runtime_enabled AND
-- encounter_resolver_enabled) is NOT read here — a pure planner cannot read flags. The CALLER passes
-- the resolved decision in, and the self-assert proves the planner never reaches for it itself.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regprocedure('public.typed_zone_effect_dispatch_v1(jsonb)') is null then
    raise exception 'TYPED-ZONE 0279: V1 is missing — V2 is a sibling, not a replacement';
  end if;
  if to_regclass('public.zone_effect_combat') is null then
    raise exception 'TYPED-ZONE 0279: zone_effect_combat (0278) is missing';
  end if;
  if to_regprocedure('public.typed_zone_effect_dispatch_v2(jsonb)') is not null then
    raise exception 'TYPED-ZONE 0279: a V2 already exists — versions are immutable; ship a _v3 sibling';
  end if;
end $pre$;

-- ── 1. typed_zone_effect_dispatch_v2 ────────────────────────────────────────────────────────────
create function public.typed_zone_effect_dispatch_v2(p_request jsonb)
returns jsonb
language plpgsql
immutable
strict
parallel safe
security invoker
as $$
declare
  v_event     jsonb;
  v_cfg       jsonb;
  v_globals   jsonb;
  v_cands     jsonb;
  v_c         jsonb;
  v_e         jsonb;
  v_i         int;
  v_j         int;
  v_seen_zone text[] := array[]::text[];
  v_seen_eff  text[];
  v_path      text;
  v_knob      text;
  v_ov        jsonb;
  v_res       jsonb;
  v_num       double precision;
  v_combat_ok boolean;
  -- one winner PER EFFECT TYPE — effect types never compete for a single slot
  v_best_p    jsonb := null;  v_bp_expo double precision; v_bp_zone text;
  v_best_c    jsonb := null;  v_bc_expo double precision; v_bc_zone text;
  v_planned   jsonb := '[]'::jsonb;
  v_risk      double precision;
begin
  if jsonb_typeof(p_request) <> 'object' then
    return public.typed_zone_dispatch_error_v1('invalid_contract_version', '', 'request must be an object');
  end if;
  if (p_request->>'contract_version') is distinct from '2' then
    return public.typed_zone_dispatch_error_v1('invalid_contract_version', 'contract_version',
             'only contract_version 2 is supported by this dispatcher');
  end if;

  -- ── event ────────────────────────────────────────────────────────────────────────────────────
  v_event := p_request->'event';
  if jsonb_typeof(v_event) <> 'object' then
    return public.typed_zone_dispatch_error_v1('invalid_event', 'event', 'event must be an object');
  end if;
  if (v_event->>'event_type') is null then
    return public.typed_zone_dispatch_error_v1('invalid_event', 'event.event_type', 'event_type is required');
  end if;
  if (v_event->>'event_type') <> 'fleet_leg_traversal' then
    return public.typed_zone_dispatch_error_v1('unsupported_event_type', 'event.event_type',
             format('V2 supports only fleet_leg_traversal, got %s', v_event->>'event_type'));
  end if;
  if not public.typed_zone_is_uuid_v1(v_event->>'event_id') then
    return public.typed_zone_dispatch_error_v1('invalid_event', 'event.event_id', 'event_id must be a uuid');
  end if;
  if not public.typed_zone_is_finite_v1(v_event->'combined_stats') then
    return public.typed_zone_dispatch_error_v1('invalid_event', 'event.combined_stats',
             'combined_stats must be a finite number');
  end if;

  -- ── runtime config ───────────────────────────────────────────────────────────────────────────
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

  -- COMBAT CAPABILITY IS AN INPUT, NEVER A READ. The planner is pure, so it cannot consult the two
  -- runtime flags itself; the caller resolves their conjunction and passes the answer in. (The names
  -- are deliberately not written here: the self-assert greps this body for them, because a planner
  -- that mentions a flag is one refactor away from reading it.) Absent ⇒ false ⇒ combat plans
  -- nothing, which is the fail-closed direction.
  if v_cfg ? 'combat_enabled' and jsonb_typeof(v_cfg->'combat_enabled') <> 'boolean' then
    return public.typed_zone_dispatch_error_v1('invalid_runtime_config', 'runtime_config.combat_enabled',
             'combat_enabled must be a boolean when present');
  end if;
  v_combat_ok := coalesce((v_cfg->>'combat_enabled')::boolean, false);

  -- ── candidates ───────────────────────────────────────────────────────────────────────────────
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

    v_seen_eff := array[]::text[];
    v_j := -1;
    for v_e in select * from jsonb_array_elements(v_c->'effects') loop
      v_j := v_j + 1;
      v_path := format('candidates[%s].effects[%s]', v_i, v_j);
      if jsonb_typeof(v_e) <> 'object' or (v_e->>'effect_type') is null then
        return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path,
                 'effect must be an object with effect_type');
      end if;
      if (v_e->>'effect_type') = any (v_seen_eff) then
        return public.typed_zone_dispatch_error_v1('duplicate_effect_type', v_path || '.effect_type',
                 format('effect_type %s appears more than once on this zone', v_e->>'effect_type'));
      end if;
      v_seen_eff := v_seen_eff || (v_e->>'effect_type');

      if (v_e->>'effect_type') = 'pirate_intercept' then
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
        if (v_c->>'zone_status') = 'active' then
          if v_best_p is null
             or (v_c->'match'->>'exposure_fraction')::double precision > v_bp_expo
             or ((v_c->'match'->>'exposure_fraction')::double precision = v_bp_expo
                 and (v_c->>'zone_id') < v_bp_zone) then
            v_best_p := jsonb_build_object('candidate', v_c, 'resolved', v_res);
            v_bp_expo := (v_c->'match'->>'exposure_fraction')::double precision;
            v_bp_zone := v_c->>'zone_id';
          end if;
        end if;

      elsif (v_e->>'effect_type') = 'combat' then
        v_ov := coalesce(v_e->'config', '{}'::jsonb);
        if not public.typed_zone_is_uuid_v1(v_ov->>'encounter_profile_id') then
          return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.config.encounter_profile_id',
                   'encounter_profile_id must be a uuid');
        end if;
        if not public.typed_zone_is_finite_v1(v_ov->'spawn_chance')
           or (v_ov->>'spawn_chance')::double precision < 0
           or (v_ov->>'spawn_chance')::double precision > 1 then
          return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.config.spawn_chance',
                   'spawn_chance must be finite and within [0,1]');
        end if;
        if jsonb_typeof(v_ov->'max_concurrent') <> 'number'
           or (v_ov->>'max_concurrent')::double precision < 1 then
          return public.typed_zone_dispatch_error_v1('invalid_candidate', v_path || '.config.max_concurrent',
                   'max_concurrent must be an integer >= 1');
        end if;
        -- COMBAT IS GATED. When the caller says the capability is closed the effect validates but
        -- plans nothing: a closed gate is a legitimate world state, not a malformed request.
        if v_combat_ok and (v_c->>'zone_status') = 'active' then
          if v_best_c is null
             or (v_c->'match'->>'exposure_fraction')::double precision > v_bc_expo
             or ((v_c->'match'->>'exposure_fraction')::double precision = v_bc_expo
                 and (v_c->>'zone_id') < v_bc_zone) then
            v_best_c := jsonb_build_object('candidate', v_c, 'config', v_ov);
            v_bc_expo := (v_c->'match'->>'exposure_fraction')::double precision;
            v_bc_zone := v_c->>'zone_id';
          end if;
        end if;

      else
        return public.typed_zone_dispatch_error_v1('unsupported_effect_type', v_path || '.effect_type',
                 format('V2 registers pirate_intercept and combat, got %s', v_e->>'effect_type'));
      end if;
    end loop;
  end loop;

  -- ── build the plan: at most ONE entry per effect type, in registry order ─────────────────────
  if v_best_p is not null then
    v_c   := v_best_p->'candidate';
    v_res := v_best_p->'resolved';
    v_risk := public.typed_zone_pirate_intercept_risk_v1(
      (v_res->>'base_risk')::double precision, (v_res->>'min_risk')::double precision,
      (v_res->>'max_risk')::double precision,  (v_res->>'exposure_floor')::double precision,
      (v_res->>'stat_reference')::double precision,
      (v_event->>'combined_stats')::double precision,
      (v_c->'match'->>'exposure_fraction')::double precision);
    v_planned := v_planned || jsonb_build_array(jsonb_build_object(
      'effect_type', 'pirate_intercept', 'behavior_version', 2,
      'zone_id', v_c->>'zone_id', 'zone_kind', v_c->>'zone_kind',
      'zone_revision', (v_c->>'zone_revision')::bigint,
      'idempotency', jsonb_build_object('event_id', v_event->>'event_id', 'zone_id', v_c->>'zone_id',
                       'effect_type', 'pirate_intercept', 'behavior_version', 2),
      'selection', jsonb_build_object('policy', 'max_exposure_then_zone_id_asc',
        'exposure_fraction', (v_c->'match'->>'exposure_fraction')::double precision,
        'ambush_x', (v_c->'match'->>'ambush_x')::double precision,
        'ambush_y', (v_c->'match'->>'ambush_y')::double precision),
      'resolved_config', v_res, 'risk', v_risk));
  end if;

  if v_best_c is not null then
    v_c   := v_best_c->'candidate';
    v_res := v_best_c->'config';
    v_planned := v_planned || jsonb_build_array(jsonb_build_object(
      'effect_type', 'combat', 'behavior_version', 2,
      'zone_id', v_c->>'zone_id', 'zone_kind', v_c->>'zone_kind',
      'zone_revision', (v_c->>'zone_revision')::bigint,
      'idempotency', jsonb_build_object('event_id', v_event->>'event_id', 'zone_id', v_c->>'zone_id',
                       'effect_type', 'combat', 'behavior_version', 2),
      'selection', jsonb_build_object('policy', 'max_exposure_then_zone_id_asc',
        'exposure_fraction', (v_c->'match'->>'exposure_fraction')::double precision,
        'ambush_x', (v_c->'match'->>'ambush_x')::double precision,
        'ambush_y', (v_c->'match'->>'ambush_y')::double precision),
      'resolved_config', v_res));
  end if;

  return jsonb_build_object('ok', true, 'plan', jsonb_build_object(
    'contract_version', 2, 'event_id', v_event->>'event_id', 'planned_effects', v_planned));
end;
$$;

revoke execute on function public.typed_zone_effect_dispatch_v2(jsonb) from public, anon, authenticated;

comment on function public.typed_zone_effect_dispatch_v2(jsonb) is
  'TYPED-ZONE PLATFORM (0279): the V2 pure planner. Adds the combat effect beside pirate_intercept; '
  'effect types resolve INDEPENDENTLY (a zone carrying both yields two planned effects) but each '
  'still selects ONE zone, so overlap changes WHICH zone acts, never HOW MANY. Combat additionally '
  'requires runtime_config.combat_enabled, which the CALLER resolves — a pure planner cannot read '
  'flags. V1 is untouched and remains valid. V2 is immutable: ship a _v3 sibling.';

-- ── 2. SELF-ASSERT ──────────────────────────────────────────────────────────────────────────────
do $tzv2$
declare
  v_def  text; v_v1 text; v_g jsonb; v_req jsonb; v_out jsonb; v_out1 jsonb;
begin
  select pg_get_functiondef(to_regprocedure('public.typed_zone_effect_dispatch_v2(jsonb)')) into v_def;
  select pg_get_functiondef(to_regprocedure('public.typed_zone_effect_dispatch_v1(jsonb)')) into v_v1;

  -- (1) V1 IS UNTOUCHED and still combat-blind
  if v_v1 ilike '%combat%' then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: V1 learned about combat — V1 is immutable'; end if;

  -- (2) V2 IS PURE on the same terms as V1
  if v_def ~* '\m(insert|update|delete|truncate)\M' then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: V2 contains a write'; end if;
  -- The table names are matched EXACTLY, not by the 'zone_effect_' prefix: that prefix also occurs
  -- inside this function's own name (typed_zone_effect_dispatch_v2), so a prefix match would abort
  -- the deploy on the function itself. Found by a test before it ever ran.
  if v_def ~* 'danger_zones|zone_effect_pirate_intercept|zone_effect_combat|game_config|cfg_num\(|cfg_bool\(|random\(|clock_timestamp' then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: V2 reads state, config, randomness or the clock'; end if;
  if v_def ~* 'typed_zone_combat_capability_v1' then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: V2 reads the capability itself — it must be an input'; end if;
  if v_def ~* 'st_intersects|st_length|st_makeline' then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: V2 performs geometry'; end if;

  v_g := jsonb_build_object('base_risk',0.35,'min_risk',0.02,'max_risk',0.90,
                            'exposure_floor',0.15,'stat_reference',120);

  -- (3) PIRATE PARITY WITH V1 — same inputs, same risk. Proven, not assumed.
  v_req := jsonb_build_object('contract_version',1,
    'event', jsonb_build_object('event_type','fleet_leg_traversal',
             'event_id','11111111-1111-1111-1111-111111111111','combined_stats',120),
    'runtime_config', jsonb_build_object('pirate_intercept_globals', v_g),
    'candidates', jsonb_build_array(jsonb_build_object(
      'zone_id','22222222-2222-2222-2222-222222222222','zone_kind','pirate','zone_status','active',
      'zone_revision',0,
      'match', jsonb_build_object('match_type','fleet_leg_intersection','exposure_fraction',0.4,
               'ambush_x',1,'ambush_y',2),
      'effects', jsonb_build_array(jsonb_build_object('effect_type','pirate_intercept','overrides','{}'::jsonb)))));
  v_out1 := public.typed_zone_effect_dispatch_v1(v_req);
  v_out  := public.typed_zone_effect_dispatch_v2(jsonb_set(v_req,'{contract_version}','2'::jsonb));
  if (v_out->'plan'->'planned_effects'->0->>'risk')::double precision
     is distinct from (v_out1->'plan'->'planned_effects'->0->>'risk')::double precision then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: V2 pirate risk diverges from V1';
  end if;

  -- (4) COMBAT IS GATED: with combat_enabled absent/false it validates but plans nothing
  v_req := jsonb_set(jsonb_set(v_req,'{contract_version}','2'::jsonb),
    '{candidates,0,effects}', jsonb_build_array(
      jsonb_build_object('effect_type','pirate_intercept','overrides','{}'::jsonb),
      jsonb_build_object('effect_type','combat','config', jsonb_build_object(
        'encounter_profile_id','33333333-3333-3333-3333-333333333333',
        'spawn_chance',1,'max_concurrent',1))));
  v_out := public.typed_zone_effect_dispatch_v2(v_req);
  if (v_out->>'ok') <> 'true' then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: a valid two-effect request was rejected: %', v_out; end if;
  if jsonb_array_length(v_out->'plan'->'planned_effects') <> 1 then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: combat planned while the gate was closed'; end if;

  -- (5) with the gate OPEN, BOTH effects plan — independently
  v_out := public.typed_zone_effect_dispatch_v2(
    jsonb_set(v_req,'{runtime_config,combat_enabled}','true'::jsonb));
  if jsonb_array_length(v_out->'plan'->'planned_effects') <> 2 then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: expected two planned effects with the gate open: %', v_out;
  end if;
  if (v_out->'plan'->'planned_effects'->0->>'effect_type') <> 'pirate_intercept'
     or (v_out->'plan'->'planned_effects'->1->>'effect_type') <> 'combat' then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: planned effects are not in registry order';
  end if;
  if (v_out->'plan'->'planned_effects'->1->'idempotency'->>'behavior_version') <> '2' then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: the idempotency identity does not carry behavior_version 2';
  end if;

  -- (6) an unknown effect type is still TYPED
  v_out := public.typed_zone_effect_dispatch_v2(
    jsonb_set(v_req,'{candidates,0,effects,1,effect_type}','"mining_yield"'::jsonb));
  if (v_out->'error'->>'code') <> 'unsupported_effect_type' then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: an unknown effect type was not typed: %', v_out; end if;

  -- (7) a V1 request is REJECTED by V2 and vice versa — versions do not silently accept each other
  if (public.typed_zone_effect_dispatch_v2(jsonb_set(v_req,'{contract_version}','1'::jsonb))
      ->'error'->>'code') <> 'invalid_contract_version' then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: V2 accepted a contract_version 1 request'; end if;

  -- (8) ACL
  if has_function_privilege('anon', 'public.typed_zone_effect_dispatch_v2(jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.typed_zone_effect_dispatch_v2(jsonb)', 'execute') then
    raise exception 'TYPED-ZONE 0279 self-assert FAIL: a client role can execute V2'; end if;

  raise notice 'TYPED-ZONE 0279 self-assert ok: V1 is untouched and still combat-blind; V2 is pure (no write, no table/config/clock/randomness, no geometry) and does NOT read the combat capability itself — it is an input; V2 reproduces V1 pirate risk exactly on identical inputs; combat validates but plans NOTHING while the gate is closed, and with it open BOTH effects plan independently in registry order with behavior_version 2; an unknown effect type is a typed failure; V2 rejects a contract_version 1 request; V2 is engine-only';
end $tzv2$;
