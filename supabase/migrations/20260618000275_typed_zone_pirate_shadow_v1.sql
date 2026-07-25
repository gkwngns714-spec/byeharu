-- Byeharu — TYPED-ZONE PIRATE SHADOW COMPARISON (migration 0275). Slice 3 of the typed-zone platform.
-- READ-ONLY. No flag, no cutover, no write, no encounter. The live 0233 path stays the sole authority.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHAT THIS SLICE IS FOR
-- Slice 2 built a pure planner but proved it only against literal inputs. This slice points it at the
-- REAL WORLD and asks one question: for a given leg, does the typed-zone planner choose the same zone
-- and compute the same risk as the deployed 0233 runtime? Until that answer is yes over real geometry
-- and real config, no cutover is defensible.
--
-- The comparison is a DIFF, not a switch. Nothing here changes what a player experiences, because
-- nothing here writes, rolls, or is called by the live movement path.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- WHY THE SHADOW COMPARES DECISIONS, NOT OUTCOMES
-- pirate_intercept_evaluate_leg is not re-runnable for comparison: it rolls random(), INSERTs a
-- pirate_intercepts row, cancels the movement and can mint a presence + encounter. Calling it twice —
-- or calling it at all from a verifier — would create duplicate encounters, which is exactly the
-- failure this slice exists to avoid.
--
-- So the shadow reproduces its DECISION INPUTS instead, which are pure and read-only:
--     pirate_intercept_leg_zone_hits(ox,oy,tx,ty)   — the candidate set + exposure + ambush point
--     order by exposure_fraction desc, zone_id asc  — the selection the evaluator performs inline
--     pirate_intercept_compute_risk(stats, exposure) — the risk it then rolls against
-- Everything after the roll (cancel, presence, encounter, forced stop) is executor behaviour and is
-- deliberately out of scope: it consumes the decision, it does not make one.
--
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- THE ONE SCHEMA ADDITION: danger_zones.revision
-- The dispatch contract carries zone_revision on every candidate so a plan can be tied to the exact
-- configuration it came from. Nothing tracked that, so this adds an additive, defaulted column and
-- NOTHING ELSE — no trigger, no backfill of anything but the default, no read path change. It is a
-- counter for future authoring commands to bump; today every row simply reads 0.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. preconditions ────────────────────────────────────────────────────────────────────────────
do $pre$
begin
  if to_regprocedure('public.typed_zone_effect_dispatch_v1(jsonb)') is null then
    raise exception 'TYPED-ZONE 0275: typed_zone_effect_dispatch_v1 (0274) is missing — slice 2 must land first';
  end if;
  if to_regprocedure('public.pirate_intercept_leg_zone_hits(double precision, double precision, double precision, double precision)') is null
     or to_regprocedure('public.pirate_intercept_compute_risk(double precision, double precision)') is null then
    raise exception 'TYPED-ZONE 0275: the 0233 pirate runtime is missing — there is nothing to shadow';
  end if;
  if to_regclass('public.zone_effect_pirate_intercept') is null then
    raise exception 'TYPED-ZONE 0275: zone_effect_pirate_intercept (0273) is missing';
  end if;
end $pre$;

-- ── 1. danger_zones.revision — additive, defaulted, inert ───────────────────────────────────────
alter table public.danger_zones
  add column if not exists revision integer not null default 0;

comment on column public.danger_zones.revision is
  'TYPED-ZONE PLATFORM (0275): aggregate revision of the zone INCLUDING its effect set, carried into '
  'every dispatch candidate so a plan can be tied to the configuration it was derived from. Additive '
  'and inert: no trigger bumps it yet — future typed-zone authoring commands own that.';

-- ── 2. typed_zone_pirate_candidates_v1 — the READ side of the new path ──────────────────────────
-- This is the counterpart the pure dispatcher deliberately lacks: it is where reading is ALLOWED.
-- It resolves the globals with the SAME cfg_num(..., literal-fallback) behaviour 0233 uses, so the
-- comparison is not quietly advantaged by a different default, and it emits a request shaped exactly
-- as the V1 contract specifies.
--
-- STABLE, not immutable: it reads tables and config. It still writes nothing.
create function public.typed_zone_pirate_candidates_v1(
  p_event_id uuid,
  p_ox double precision, p_oy double precision,
  p_tx double precision, p_ty double precision,
  p_combined_stats double precision
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'contract_version', 1,
    'event', jsonb_build_object(
      'event_type',     'fleet_leg_traversal',
      'event_id',       p_event_id,
      'combined_stats', coalesce(p_combined_stats, 0)),
    'runtime_config', jsonb_build_object(
      'pirate_intercept_globals', jsonb_build_object(
        'base_risk',      coalesce(public.cfg_num('pirate_intercept_base_risk'),      0.35),
        'min_risk',       coalesce(public.cfg_num('pirate_intercept_min_risk'),       0.02),
        'max_risk',       coalesce(public.cfg_num('pirate_intercept_max_risk'),       0.90),
        'exposure_floor', coalesce(public.cfg_num('pirate_intercept_exposure_floor'), 0.15),
        'stat_reference', coalesce(public.cfg_num('pirate_intercept_stat_reference'), 120))),
    'candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
               'zone_id',       z.id,
               'zone_kind',     z.zone_kind,
               'zone_status',   z.status,
               'zone_revision', z.revision,
               'match', jsonb_build_object(
                 'match_type',        'fleet_leg_intersection',
                 'exposure_fraction', h.exposure_fraction,
                 'ambush_x',          h.ambush_x,
                 'ambush_y',          h.ambush_y),
               -- COMPOSABLE: the effect set is whatever effect rows exist for this zone. Today only
               -- pirate_intercept has a table, so the array is 0 or 1 long; a future sibling table
               -- adds itself here without changing anything above.
               'effects', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'effect_type', 'pirate_intercept',
                          'overrides', jsonb_build_object(
                            'base_risk',      e.base_risk,
                            'min_risk',       e.min_risk,
                            'max_risk',       e.max_risk,
                            'exposure_floor', e.exposure_floor,
                            'stat_reference', e.stat_reference)))
                   from public.zone_effect_pirate_intercept e
                  where e.zone_id = z.id), '[]'::jsonb))
             order by z.id)
        from public.pirate_intercept_leg_zone_hits(p_ox, p_oy, p_tx, p_ty) h
        join public.danger_zones z on z.id = h.zone_id
    ), '[]'::jsonb))
$$;

revoke execute on function public.typed_zone_pirate_candidates_v1(
  uuid, double precision, double precision, double precision, double precision, double precision)
  from public, anon, authenticated;

comment on function public.typed_zone_pirate_candidates_v1(
  uuid, double precision, double precision, double precision, double precision, double precision) is
  'TYPED-ZONE PLATFORM (0275): builds a V1 dispatch request for one fleet leg from the LIVE world — '
  'the read side the pure dispatcher deliberately lacks. Resolves globals with the same '
  'cfg_num(..., fallback) behaviour 0233 uses. STABLE and write-free.';

-- ── 3. typed_zone_pirate_shadow_compare_v1 — the DIFF ───────────────────────────────────────────
-- Runs both paths over one leg and reports whether they agree. Returns a structured verdict rather
-- than raising, so a verifier can sweep many legs and summarise.
--
-- It NEVER calls pirate_intercept_evaluate_leg: that would roll, write and potentially mint an
-- encounter. It compares the decision the evaluator WOULD make, reproduced from its own pure parts.
create function public.typed_zone_pirate_shadow_compare_v1(
  p_ox double precision, p_oy double precision,
  p_tx double precision, p_ty double precision,
  p_combined_stats double precision
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_event_id   uuid := '00000000-0000-4000-8000-000000000000';  -- fixed: the diff must be deterministic
  v_live       record;
  v_live_risk  double precision;
  v_req        jsonb;
  v_out        jsonb;
  v_plan       jsonb;
  v_new_zone   uuid;
  v_new_risk   double precision;
  v_new_expo   double precision;
  v_mismatch   text[] := array[]::text[];
  v_live_n     int;
  v_new_n      int;
begin
  -- ── the LIVE decision, reproduced from the evaluator's own pure parts ────────────────────────
  -- exactly the evaluator's inline selection: deepest crossing wins, ties to the lowest zone_id
  select * into v_live
    from public.pirate_intercept_leg_zone_hits(p_ox, p_oy, p_tx, p_ty)
   order by exposure_fraction desc, zone_id asc
   limit 1;

  select count(*) into v_live_n
    from public.pirate_intercept_leg_zone_hits(p_ox, p_oy, p_tx, p_ty);

  -- ── the NEW decision ────────────────────────────────────────────────────────────────────────
  v_req := public.typed_zone_pirate_candidates_v1(v_event_id, p_ox, p_oy, p_tx, p_ty, p_combined_stats);
  v_out := public.typed_zone_effect_dispatch_v1(v_req);

  if (v_out->>'ok') <> 'true' then
    return jsonb_build_object(
      'agree', false,
      'reason', 'dispatcher_rejected',
      'error', v_out->'error',
      'live_candidate_count', v_live_n);
  end if;

  v_plan  := v_out->'plan';
  v_new_n := jsonb_array_length(v_plan->'planned_effects');

  -- ── neither path found anything: agreement ──────────────────────────────────────────────────
  if v_live.zone_id is null and v_new_n = 0 then
    return jsonb_build_object('agree', true, 'reason', 'no_crossing',
             'live_candidate_count', v_live_n, 'planned_count', 0);
  end if;

  -- ── one path found something the other did not ───────────────────────────────────────────────
  if v_live.zone_id is null then v_mismatch := v_mismatch || 'new_planned_where_live_found_nothing'; end if;
  if v_new_n = 0 then v_mismatch := v_mismatch || 'live_selected_where_new_planned_nothing'; end if;

  if array_length(v_mismatch, 1) is null then
    v_new_zone := (v_plan->'planned_effects'->0->>'zone_id')::uuid;
    v_new_expo := (v_plan->'planned_effects'->0->'selection'->>'exposure_fraction')::double precision;
    v_new_risk := (v_plan->'planned_effects'->0->>'risk')::double precision;
    v_live_risk := public.pirate_intercept_compute_risk(p_combined_stats, v_live.exposure_fraction);

    -- SELECTED ZONE must match: the whole overlap policy hangs on this.
    if v_new_zone is distinct from v_live.zone_id then
      v_mismatch := v_mismatch || 'selected_zone';
    end if;
    -- EXPOSURE must match: it comes from the same PostGIS call, so any drift means the candidate
    -- builder mangled it in transit.
    if v_new_expo is distinct from v_live.exposure_fraction then
      v_mismatch := v_mismatch || 'exposure_fraction';
    end if;
    -- RISK must match bit-for-bit while every zone still inherits its globals. A zone carrying a real
    -- override is EXPECTED to diverge — that is the feature — so the verdict reports it separately
    -- rather than calling it a failure.
    if v_new_risk is distinct from v_live_risk then
      if exists (
        select 1 from public.zone_effect_pirate_intercept e
         where e.zone_id = v_live.zone_id
           and (e.base_risk is not null or e.min_risk is not null or e.max_risk is not null
                or e.exposure_floor is not null or e.stat_reference is not null))
      then
        v_mismatch := v_mismatch || 'risk_diverged_by_override';
      else
        v_mismatch := v_mismatch || 'risk';
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'agree', array_length(v_mismatch, 1) is null,
    'mismatch', to_jsonb(v_mismatch),
    'live', jsonb_build_object(
      'zone_id',           v_live.zone_id,
      'exposure_fraction', v_live.exposure_fraction,
      'risk',              v_live_risk,
      'candidate_count',   v_live_n),
    'new', jsonb_build_object(
      'zone_id',           v_new_zone,
      'exposure_fraction', v_new_expo,
      'risk',              v_new_risk,
      'planned_count',     v_new_n));
end;
$$;

revoke execute on function public.typed_zone_pirate_shadow_compare_v1(
  double precision, double precision, double precision, double precision, double precision)
  from public, anon, authenticated;

comment on function public.typed_zone_pirate_shadow_compare_v1(
  double precision, double precision, double precision, double precision, double precision) is
  'TYPED-ZONE PLATFORM (0275): READ-ONLY shadow diff of the live 0233 pirate decision against the V1 '
  'typed-zone plan for one leg. Never calls pirate_intercept_evaluate_leg (which rolls, writes and can '
  'mint an encounter) — it reproduces that evaluator''s decision from its own pure parts. Writes '
  'nothing; changes nothing; the live path remains the sole authority.';

-- ── 4. SELF-ASSERT — additive, read-only, and no cutover ────────────────────────────────────────
do $tzs$
declare
  v_eval_def text;
  v_shadow   text;
  v_cand     text;
  v_zone_n   int;
  v_rev_bad  int;
begin
  -- (1) the revision column landed, defaulted, and disturbed nothing
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='danger_zones' and column_name='revision') then
    raise exception 'TYPED-ZONE 0275 self-assert FAIL: danger_zones.revision was not added'; end if;
  select count(*) into v_rev_bad from public.danger_zones where revision is null or revision <> 0;
  if v_rev_bad > 0 then
    raise exception 'TYPED-ZONE 0275 self-assert FAIL: % zone(s) did not default to revision 0', v_rev_bad; end if;

  -- (2) NO CUTOVER: the live evaluator does not know the typed-zone path exists
  select pg_get_functiondef(to_regprocedure('public.pirate_intercept_evaluate_leg(uuid)')) into v_eval_def;
  if v_eval_def ilike '%typed_zone_%' then
    raise exception 'TYPED-ZONE 0275 self-assert FAIL: the live leg evaluator references the typed-zone path'; end if;

  -- (3) the shadow must never invoke the writing/rolling evaluator
  select pg_get_functiondef(to_regprocedure(
    'public.typed_zone_pirate_shadow_compare_v1(double precision, double precision, double precision, double precision, double precision)')) into v_shadow;
  if v_shadow ilike '%pirate_intercept_evaluate_leg%' then
    raise exception 'TYPED-ZONE 0275 self-assert FAIL: the shadow calls the evaluator — that would roll and write'; end if;
  if v_shadow ~* '\m(insert|update|delete|truncate)\M' then
    raise exception 'TYPED-ZONE 0275 self-assert FAIL: the shadow contains a write statement'; end if;
  if v_shadow ~* '\mrandom\(' then
    raise exception 'TYPED-ZONE 0275 self-assert FAIL: the shadow rolls dice'; end if;

  select pg_get_functiondef(to_regprocedure(
    'public.typed_zone_pirate_candidates_v1(uuid, double precision, double precision, double precision, double precision, double precision)')) into v_cand;
  if v_cand ~* '\m(insert|update|delete|truncate)\M' then
    raise exception 'TYPED-ZONE 0275 self-assert FAIL: the candidate builder contains a write statement'; end if;

  -- (4) the candidate builder resolves globals with the SAME literal fallbacks 0233 uses, so the
  --     comparison cannot be quietly advantaged by a different default
  if strpos(v_cand, '0.35') = 0 or strpos(v_cand, '0.02') = 0 or strpos(v_cand, '0.90') = 0
     or strpos(v_cand, '0.15') = 0 or strpos(v_cand, '120') = 0 then
    raise exception 'TYPED-ZONE 0275 self-assert FAIL: the candidate builder does not mirror the 0233 fallbacks'; end if;

  -- (5) ACL: engine-only
  if has_function_privilege('anon', 'public.typed_zone_pirate_shadow_compare_v1(double precision, double precision, double precision, double precision, double precision)', 'execute')
     or has_function_privilege('authenticated', 'public.typed_zone_pirate_shadow_compare_v1(double precision, double precision, double precision, double precision, double precision)', 'execute') then
    raise exception 'TYPED-ZONE 0275 self-assert FAIL: a client role can execute the shadow'; end if;

  -- (6) the flags stay dark — this slice is a diff, never a cutover
  if coalesce(public.cfg_bool('typed_zone_pirate_intercept_runtime_enabled'), true) then
    raise exception 'TYPED-ZONE 0275 self-assert FAIL: the runtime flag is not false'; end if;

  select count(*) into v_zone_n from public.danger_zones;
  raise notice 'TYPED-ZONE 0275 self-assert ok: danger_zones.revision added additive+defaulted (all % zone(s) at 0); NO cutover (the live leg evaluator is typed-zone-blind); the shadow never calls pirate_intercept_evaluate_leg and contains no write and no random(); the candidate builder is write-free and mirrors the 0233 literal fallbacks exactly; both new functions are engine-only; typed_zone_pirate_intercept_runtime_enabled is still false', v_zone_n;
end $tzs$;
