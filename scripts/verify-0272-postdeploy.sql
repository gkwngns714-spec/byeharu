-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- MIGRATION 0272 (ELITE STAT WIRING) — READ-ONLY POST-DEPLOYMENT VERIFIER
--
-- ██ READ-ONLY. THIS FILE PERFORMS NO WRITE OF ANY KIND. ██
--   It opens `begin transaction read only;` so PostgreSQL ITSELF rejects any write that ever sneaks
--   in, and closes with `rollback;`. There is no data-modifying statement, no DDL, no ACL change, no
--   config write and no RPC call anywhere in this file. It NEVER flips a flag, NEVER activates a
--   binding, NEVER touches encounter_runtime_state and NEVER cleans anything up. It is SAFE for a
--   human to run against production. It does NOT deploy anything and does NOT approve anything.
--
-- WHAT IT ANSWERS: "did deploying migration 0272 change EXACTLY the two things 0272 claims to change
-- (the resolve_location_encounter body and the additive encounter_elite_difficulty_multiplier config
-- key) and NOTHING else — no flag, no movement knob, no binding, no content revision, no elite_chance,
-- no encounter, no runtime-state row?"
--
-- It FAILS CLOSED: any single blocking condition ends the run with a non-zero exit and the marker
-- PD0272_BLOCKED. It reports EVERY blocking row it finds (it never stops at the first), so one run
-- yields the whole fix list.
--
-- ── THE TWO-PHASE (BEFORE / AFTER) DESIGN — this is what makes "unchanged" PROVABLE ────────────────
-- "Unchanged" cannot be asserted from a single post-deploy run; it has to be DIFFED. So this verifier
-- runs twice and emits a machine-diffable digest both times:
--
--   PHASE before  (run NOW, with the deployment run still waiting at its gate):
--       PGOPTIONS="-c pd0272.phase=before" psql "$DB_URL" -X -v ON_ERROR_STOP=1 \
--         -f scripts/verify-0272-postdeploy.sql | grep '^PD0272_SNAPSHOT ' | sort > /tmp/pd0272.before
--       Expected posture: migration head 20260618000271, elite config key ABSENT,
--       resolve_location_encounter body carries elite_policy 'disabled_v1' (the 0261 body).
--
--   PHASE after   (run once the deployment run has completed):
--       PGOPTIONS="-c pd0272.phase=after" psql "$DB_URL" -X -v ON_ERROR_STOP=1 \
--         -f scripts/verify-0272-postdeploy.sql | grep '^PD0272_SNAPSHOT ' | sort > /tmp/pd0272.after
--       Expected posture: migration head exactly 20260618000272, elite config key present = 2,
--       resolve_location_encounter body carries elite_policy 'multiplier_v1'.
--
--   THE PROOF:  diff /tmp/pd0272.before /tmp/pd0272.after
--       The ONLY lines that may differ are the five INTENDED ones, which the digest deliberately
--       prefixes `expected_to_change.`:
--           expected_to_change.migration_head
--           expected_to_change.migration_count
--           expected_to_change.cfg.encounter_elite_difficulty_multiplier
--           expected_to_change.fn.resolve_location_encounter.md5
--           expected_to_change.fn.resolve_location_encounter.elite_policy
--       EVERY other digest line is prefixed `must_not_change.` — any diff there is a defect, no matter
--       what this file's own hard-coded expectations say. `now`/timing values are deliberately NOT in
--       the digest so the diff is stable.
--
-- ── WHAT 0272 IS ALLOWED TO TOUCH (read from supabase/migrations/20260618000272_…sql) ──────────────
--   * `create or replace function public.resolve_location_encounter(p_location_id uuid, p_seed text)` — ONE function.
--   * one additive game_config row: encounter_elite_difficulty_multiplier = 2 (`on conflict do nothing`).
--   Explicitly NOT touched by 0272: process_combat_ticks (the migration header says so in as many
--   words), any flag, any table, any ACL, any content row, encounter_runtime_state.
--   THEREFORE: md5(prosrc) of process_combat_ticks MUST be byte-identical before and after, and that
--   is check PD02B — the single strongest statement this verifier makes.
--
-- ── OVERRIDES (connection GUCs — no file edit, no psql meta-commands, so it also pastes into the
--    Supabase SQL editor unchanged; any unset GUC falls back to the default below) ──────────────────
--   pd0272.phase                   before | after            (default: after)
--   pd0272.migration               default 20260618000272
--   pd0272.prev_migration          default 20260618000271
--   pd0272.elite_multiplier        default 2
--   pd0272.canary_binding          default 2f7bcf88-d810-47b4-8e04-748655688b55
--   pd0272.other_binding           default 2d491cde-e6fa-4087-8e80-3029522731cd
--   pd0272.runtime_location        default 75baf5d7-6b06-4567-84c9-de97938aa251   (Reaver)
--   pd0272.runtime_profile         default 4d8bd4ee-4b61-454f-b0bc-fbf058ee4dd9   (canary_encounter)
--   pd0272.runtime_last_spawn_at   default 2026-07-22T06:03:27.318703+00:00       ('' disables the pin)
--   pd0272.runtime_active_count    default 2
--   pd0272.skip_rls_reads          '1' skips the checks that need a role able to read combat_encounters
--
-- ── ANON-KEY LIMITATION, STATED PLAINLY ───────────────────────────────────────────────────────────
-- Several checks here CANNOT be done over PostgREST with the anon key, because pg_proc,
-- supabase_migrations.schema_migrations and combat_encounters are not anon-readable. If you have no
-- psql/SQL-editor access, run scripts/verify-0272-postdeploy-snapshot.mjs instead — it covers the
-- anon-readable subset and prints the EXACT statements you still owe. This SQL file is the complete
-- one; the .mjs is the partial one.
--
-- ── PASS/FAIL MARKERS (greppable) ─────────────────────────────────────────────────────────────────
--   PD0272_FINDING [BLOCK|WARN|INFO] <code> …    one line per finding (every blocking row, not just #1)
--   PD0272_SNAPSHOT <key>=<value>                the diffable digest (see above)
--   PD0272_PASS phase=<p> blockers=0             the phase's posture is exactly as required
--   PD0272_BLOCKED phase=<p> n=<N>               N blockers; the run then RAISES (non-zero exit)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

begin transaction read only;
set local statement_timeout = '60s';

-- ══════════ 0. phase + counters ══════════
do $pd$
declare v_phase text := lower(coalesce(nullif(current_setting('pd0272.phase', true), ''), 'after'));
begin
  if v_phase not in ('before', 'after') then
    raise exception 'PD0272: pd0272.phase must be "before" or "after" (got %)', v_phase;
  end if;
  perform set_config('pd0272.phase',    v_phase, true);
  perform set_config('pd0272.blockers', '0', true);
  perform set_config('pd0272.warns',    '0', true);
  raise notice '════════ MIGRATION 0272 POST-DEPLOYMENT VERIFIER — READ-ONLY ════════';
  raise notice 'phase          : %', v_phase;
  raise notice 'database now() : %', now();
  raise notice 'NOTHING IS WRITTEN BY THIS FILE.';
end $pd$;

-- ══════════ 1. PD01 — MIGRATION STATE (head, no over-shoot, the exact delta) ══════════
do $pd$
declare
  v_b     integer := current_setting('pd0272.blockers')::int;
  v_phase text := current_setting('pd0272.phase');
  v_want  text := coalesce(nullif(current_setting('pd0272.migration', true),      ''), '20260618000272');
  v_prev  text := coalesce(nullif(current_setting('pd0272.prev_migration', true), ''), '20260618000271');
  v_head  text;
  v_n     integer;
  v_beyond text;
  v_has   boolean;
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then
    raise notice 'PD0272_FINDING [BLOCK] PD01_LEDGER_UNREADABLE :: supabase_migrations.schema_migrations is not readable by this role. Migration state CANNOT be settled from here. OWNER MUST RUN (service_role / Supabase SQL editor): select max(version), count(*) from supabase_migrations.schema_migrations;';
    perform set_config('pd0272.blockers', (v_b + 1)::text, true);
    return;
  end if;

  select max(version)::text, count(*) into v_head, v_n from supabase_migrations.schema_migrations;
  select exists (select 1 from supabase_migrations.schema_migrations where version = v_want) into v_has;
  select string_agg(version::text, ', ' order by version)
    into v_beyond from supabase_migrations.schema_migrations where version > v_want;

  raise notice 'PD0272_FINDING [INFO] PD01_MIGRATION_HEAD head=% applied_count=% want=% prev=%',
    coalesce(v_head, '(none)'), v_n, v_want, v_prev;
  raise notice 'PD0272_SNAPSHOT expected_to_change.migration_head=%',  coalesce(v_head, '(none)');
  raise notice 'PD0272_SNAPSHOT expected_to_change.migration_count=%', v_n;

  if v_phase = 'before' then
    if v_head is distinct from v_prev then
      raise notice 'PD0272_FINDING [BLOCK] PD01_BEFORE_HEAD head=% want=% :: the BEFORE snapshot must be taken while the head is still the pre-0272 migration; this is not a pre-deploy state', coalesce(v_head, '(none)'), v_prev;
      v_b := v_b + 1;
    end if;
    if v_has then
      raise notice 'PD0272_FINDING [BLOCK] PD01_BEFORE_ALREADY_APPLIED version=% :: migration 0272 is ALREADY in the ledger — the deployment has run; take the AFTER snapshot instead (phase=after)', v_want;
      v_b := v_b + 1;
    end if;
  else
    if not v_has then
      raise notice 'PD0272_FINDING [BLOCK] PD01_NOT_APPLIED version=% head=% :: migration 0272 is NOT in the ledger — the deployment has not landed', v_want, coalesce(v_head, '(none)');
      v_b := v_b + 1;
    end if;
    if v_head is distinct from v_want then
      raise notice 'PD0272_FINDING [BLOCK] PD01_HEAD_NOT_EXACTLY_0272 head=% want=% :: the head is not exactly 0272', coalesce(v_head, '(none)'), v_want;
      v_b := v_b + 1;
    end if;
    if v_beyond is not null then
      raise notice 'PD0272_FINDING [BLOCK] PD01_MIGRATION_BEYOND_0272 versions=% :: migration(s) beyond 0272 were applied — this deployment carried more than the reviewed slice', v_beyond;
      v_b := v_b + 1;
    end if;
    if not exists (select 1 from supabase_migrations.schema_migrations where version = v_prev) then
      raise notice 'PD0272_FINDING [BLOCK] PD01_PREV_MISSING version=% :: the pre-0272 migration is absent from the ledger — the chain is not the reviewed one', v_prev;
      v_b := v_b + 1;
    end if;
  end if;
  perform set_config('pd0272.blockers', v_b::text, true);
end $pd$;

-- ══════════ 2. PD02 — THE DEPLOYED FUNCTION BODIES ══════════
-- PD02A: resolve_location_encounter must carry the 0272 body (after) / the 0261 body (before).
-- PD02B: process_combat_ticks md5 must be IDENTICAL across the two phases — 0272 does not re-create
--        it, so any md5 movement means the deployment carried something 0272 does not claim.
do $pd$
declare
  v_b     integer := current_setting('pd0272.blockers')::int;
  v_phase text := current_setting('pd0272.phase');
  v_res   text;
  v_tick  text;
  v_policy text;
begin
  -- pin by OID via to_regprocedure so the exact overload is named (identity-argument text omits
  -- parameter names, so matching on it is fragile).
  select p.prosrc into v_res  from pg_proc p where p.oid = to_regprocedure('public.resolve_location_encounter(uuid,text)');
  select p.prosrc into v_tick from pg_proc p where p.oid = to_regprocedure('public.process_combat_ticks()');

  if v_res is null then
    raise notice 'PD0272_FINDING [BLOCK] PD02A_RESOLVER_UNREADABLE :: pg_proc.prosrc for public.resolve_location_encounter(uuid,text) is NULL or the function is absent. If the role simply cannot read pg_proc, the deployed body CANNOT be compared from here. OWNER MUST RUN (service_role / Supabase SQL editor): select md5(prosrc), (position(''multiplier_v1'' in prosrc) > 0) as has_0272_policy, (position(''encounter_elite_difficulty_multiplier'' in prosrc) > 0) as reads_multiplier from pg_proc where oid = ''public.resolve_location_encounter(uuid,text)''::regprocedure;';
    v_b := v_b + 1;
  else
    v_policy := case
      when position('multiplier_v1' in v_res) > 0 and position('encounter_elite_difficulty_multiplier' in v_res) > 0 then 'multiplier_v1'
      when position('disabled_v1'   in v_res) > 0 then 'disabled_v1'
      else 'unknown' end;
    raise notice 'PD0272_SNAPSHOT expected_to_change.fn.resolve_location_encounter.md5=%',          md5(v_res);
    raise notice 'PD0272_SNAPSHOT expected_to_change.fn.resolve_location_encounter.elite_policy=%', v_policy;
    raise notice 'PD0272_FINDING [INFO] PD02A_RESOLVER_BODY elite_policy=% md5=%', v_policy, md5(v_res);

    if v_phase = 'before' then
      if v_policy is distinct from 'disabled_v1' then
        raise notice 'PD0272_FINDING [BLOCK] PD02A_BEFORE_BODY policy=% :: the deployed resolve_location_encounter is not the pre-0272 (0261 zero-elite, disabled_v1) body — this is not a pre-deploy state', v_policy;
        v_b := v_b + 1;
      end if;
    else
      -- the AFTER body must carry ALL FOUR 0272 tokens AND must have lost the 0261 policy tag.
      if v_policy is distinct from 'multiplier_v1' then
        raise notice 'PD0272_FINDING [BLOCK] PD02A_BODY_NOT_0272 policy=% :: the deployed resolve_location_encounter does not carry the 0272 elite body (needs the elite_policy multiplier_v1 tag AND a read of encounter_elite_difficulty_multiplier). A version number alone proves nothing about WHICH body landed.', v_policy;
        v_b := v_b + 1;
      end if;
      if position('disabled_v1' in v_res) > 0 then
        raise notice 'PD0272_FINDING [BLOCK] PD02A_BODY_STILL_0261 :: the deployed body still carries the 0261 disabled_v1 tag';
        v_b := v_b + 1;
      end if;
      if position('elite_chance' in v_res) = 0 then
        raise notice 'PD0272_FINDING [BLOCK] PD02A_BODY_NO_ELITE_INPUT :: the deployed body never reads elite_chance — the elite split is not wired';
        v_b := v_b + 1;
      end if;
      -- the determinism law (0041): the resolver must stay RNG-free.
      if position('random(' in v_res) > 0 or position('setseed' in v_res) > 0 then
        raise notice 'PD0272_FINDING [BLOCK] PD02A_BODY_RNG :: the deployed resolver contains random()/setseed — the 0041 determinism law is broken';
        v_b := v_b + 1;
      end if;
    end if;
  end if;

  if v_tick is null then
    raise notice 'PD0272_FINDING [BLOCK] PD02B_TICK_UNREADABLE :: pg_proc.prosrc for public.process_combat_ticks is NULL or the function is absent. OWNER MUST RUN (service_role / Supabase SQL editor): select md5(prosrc) from pg_proc where oid = ''public.process_combat_ticks()''::regprocedure;   -- the md5 MUST be identical before and after the deployment';
    v_b := v_b + 1;
  else
    raise notice 'PD0272_SNAPSHOT must_not_change.fn.process_combat_ticks.md5=%', md5(v_tick);
    raise notice 'PD0272_FINDING [INFO] PD02B_TICK_MD5 md5=% :: 0272 does NOT re-create process_combat_ticks; this md5 must be byte-identical in the BEFORE and AFTER snapshots', md5(v_tick);
    if position('v_resolver_engaged' in v_tick) = 0
       or position('resolve_location_encounter(e.location_id, e.id::text)' in v_tick) = 0 then
      raise notice 'PD0272_FINDING [BLOCK] PD02B_TICK_BODY :: the deployed process_combat_ticks no longer carries the E5 seeded resolved branch';
      v_b := v_b + 1;
    end if;
    -- 0272 must not have moved the runtime-state ledger authority out of the tick.
    if position('encounter_runtime_state' in v_tick) = 0 then
      raise notice 'PD0272_FINDING [BLOCK] PD02B_TICK_LEDGER :: the deployed process_combat_ticks no longer touches encounter_runtime_state — the cooldown ledger writer moved';
      v_b := v_b + 1;
    end if;
  end if;

  -- the whole resolver surface must still exist.
  declare v_missing text;
  begin
    select string_agg(fn, ', ') into v_missing
      from unnest(array['public.resolve_location_encounter(uuid,text)',
                        'public.resolve_encounter_reward_inputs(jsonb,integer,integer)',
                        'public.process_combat_ticks()',
                        'public.cfg_bool(text)',
                        'public.cfg_num(text)']) fn
     where to_regprocedure(fn) is null;
    if v_missing is not null then
      raise notice 'PD0272_FINDING [BLOCK] PD02C_FUNCTIONS_MISSING missing=% :: the resolver surface is incomplete', v_missing;
      v_b := v_b + 1;
    end if;
    raise notice 'PD0272_SNAPSHOT must_not_change.fn.surface_missing=%', coalesce(v_missing, '(none)');
  end;

  perform set_config('pd0272.blockers', v_b::text, true);
end $pd$;

-- ══════════ 3. PD03 — THE ADDITIVE ELITE MULTIPLIER CONFIG (the one intended config delta) ══════════
do $pd$
declare
  v_b     integer := current_setting('pd0272.blockers')::int;
  v_phase text := current_setting('pd0272.phase');
  v_want  text := coalesce(nullif(current_setting('pd0272.elite_multiplier', true), ''), '2');
  v_val   text;
  v_present boolean;
begin
  select true, g.value #>> '{}' into v_present, v_val
    from public.game_config g where g.key = 'encounter_elite_difficulty_multiplier';
  v_present := coalesce(v_present, false);
  raise notice 'PD0272_SNAPSHOT expected_to_change.cfg.encounter_elite_difficulty_multiplier=%',
    case when v_present then v_val else '(absent)' end;

  if v_phase = 'before' then
    if v_present then
      raise notice 'PD0272_FINDING [BLOCK] PD03_BEFORE_KEY_PRESENT value=% :: encounter_elite_difficulty_multiplier already exists — 0272 has already been applied; this is not a pre-deploy state. (Its ABSENCE is the independent pre-deploy signal.)', v_val;
      v_b := v_b + 1;
    else
      raise notice 'PD0272_FINDING [INFO] PD03_BEFORE_KEY_ABSENT :: encounter_elite_difficulty_multiplier is absent — the independent proof that 0272 has NOT been applied';
    end if;
  else
    if not v_present then
      raise notice 'PD0272_FINDING [BLOCK] PD03_KEY_MISSING :: encounter_elite_difficulty_multiplier is ABSENT after the deployment — 0272 section 1 did not land';
      v_b := v_b + 1;
    elsif v_val is distinct from v_want then
      raise notice 'PD0272_FINDING [BLOCK] PD03_VALUE got=% want=% :: the additive elite multiplier is not the seeded default (0272 seeds with on-conflict-do-nothing, so a differing value means a pre-existing or hand-tuned row)', v_val, v_want;
      v_b := v_b + 1;
    else
      raise notice 'PD0272_FINDING [INFO] PD03_KEY_OK value=% :: the additive elite multiplier landed with its expected value', v_val;
    end if;
  end if;
  perform set_config('pd0272.blockers', v_b::text, true);
end $pd$;

-- ══════════ 4. PD04..PD08 — CONFIGURATION UNCHANGED (every flag 0272 must NOT have moved) ══════════
-- Every key below goes into the digest under must_not_change.cfg.* so the BEFORE/AFTER diff is the
-- real authority; the hard-coded expectations are the second, independent opinion.
do $pd$
declare
  v_b integer := current_setting('pd0272.blockers')::int;
  v_val text;
  -- key, expected value, finding code, why it matters
  v_expect text[][] := array[
    -- PD04 the resolver gate itself
    ['encounter_resolver_enabled',            'false', 'PD04_RESOLVER_FLAG',   'the resolver must stay DARK; 0272 is a dark slice and changes no flag'],
    -- PD05 the E0/E1/E2 authoring prerequisites
    ['enemy_content_registry_enabled',        'true',  'PD05_AUTHORING_FLAG',  'E0 content registry'],
    ['encounter_authoring_enabled',           'true',  'PD05_AUTHORING_FLAG',  'E1 encounter authoring'],
    ['encounter_binding_authoring_enabled',   'true',  'PD05_AUTHORING_FLAG',  'E2 binding authoring'],
    -- PD06 combat posture
    ['spatial_combat_enabled',                'true',  'PD06_SPATIAL_COMBAT',  'the spatial combat arm'],
    -- PD07 movement posture
    ['fleet_movement_unified_enabled',        'true',  'PD07_MOVEMENT_FLAG',   'unified fleet movement'],
    ['mainship_send_enabled',                 'false', 'PD07_MOVEMENT_FLAG',   'legacy mainship send'],
    ['mainship_space_movement_enabled',       'false', 'PD07_MOVEMENT_FLAG',   'mainship space movement'],
    ['mainship_coordinate_travel_enabled',    'false', 'PD07_MOVEMENT_FLAG',   'coordinate travel (OSN-COORD gate)'],
    ['fleet_control_enabled',                 'false', 'PD07_MOVEMENT_FLAG',   'fleet control'],
    ['timed_docking_enabled',                 'false', 'PD07_MOVEMENT_FLAG',   'timed docking'],
    -- PD08 pirate intercept: the flag AND its four tuning knobs. These values are INTENDED per
    -- migration 0236 — they are NOT defects and must NOT be reported as such. They are pinned here
    -- ONLY so that a change to them by an unrelated deployment is caught.
    ['pirate_intercept_enabled',              'true',  'PD08_INTERCEPT',       'INTENDED per 0236'],
    ['pirate_intercept_base_risk',            '1.0',   'PD08_INTERCEPT_KNOB',  'INTENDED per 0236'],
    ['pirate_intercept_min_risk',             '0.98',  'PD08_INTERCEPT_KNOB',  'INTENDED per 0236'],
    ['pirate_intercept_max_risk',             '1.0',   'PD08_INTERCEPT_KNOB',  'INTENDED per 0236'],
    ['pirate_intercept_exposure_floor',       '1.0',   'PD08_INTERCEPT_KNOB',  'INTENDED per 0236']
  ];
  i integer;
begin
  for i in 1 .. array_length(v_expect, 1) loop
    select g.value #>> '{}' into v_val from public.game_config g where g.key = v_expect[i][1];
    raise notice 'PD0272_SNAPSHOT must_not_change.cfg.%=%', v_expect[i][1], coalesce(v_val, '(absent)');
    if v_val is null then
      raise notice 'PD0272_FINDING [BLOCK] %_MISSING key=% :: the key is absent from game_config (%)', v_expect[i][3], v_expect[i][1], v_expect[i][4];
      v_b := v_b + 1;
    elsif v_val <> v_expect[i][2]
      -- numeric keys may round-trip as 1 vs 1.0; compare numerically when both sides parse.
      and not (v_val ~ '^-?[0-9]+(\.[0-9]+)?$' and v_expect[i][2] ~ '^-?[0-9]+(\.[0-9]+)?$'
               and v_val::numeric = v_expect[i][2]::numeric) then
      raise notice 'PD0272_FINDING [BLOCK] % key=% got=% want=% :: this flag/knob MOVED — 0272 changes no configuration except the additive elite multiplier (%)',
        v_expect[i][3], v_expect[i][1], v_val, v_expect[i][2], v_expect[i][4];
      v_b := v_b + 1;
    end if;
  end loop;
  raise notice 'PD0272_FINDING [INFO] PD04_PD08_CONFIG :: % configuration key(s) checked against their expected values and emitted into the digest', array_length(v_expect, 1);

  -- a config key COUNT so an unexpected ADDITIONAL key added by the deployment is visible in the diff.
  select count(*)::text into v_val from public.game_config;
  raise notice 'PD0272_SNAPSHOT expected_to_change.cfg.row_count=%', v_val;
  raise notice 'PD0272_FINDING [INFO] PD04_CFG_ROWCOUNT rows=% :: exactly +1 (encounter_elite_difficulty_multiplier) is permitted between the BEFORE and AFTER digests', v_val;
  perform set_config('pd0272.blockers', v_b::text, true);
end $pd$;

-- ══════════ 5. PD09/PD10 — CONTENT STATE (bindings, elite_chance, the whole authored chain) ══════════
do $pd$
declare
  v_b integer := current_setting('pd0272.blockers')::int;
  v_canary text := coalesce(nullif(current_setting('pd0272.canary_binding', true), ''), '2f7bcf88-d810-47b4-8e04-748655688b55');
  v_other  text := coalesce(nullif(current_setting('pd0272.other_binding',  true), ''), '2d491cde-e6fa-4087-8e80-3029522731cd');
  r record; v_n integer; v_elite integer; v_id uuid;
begin
  -- PD09 bindings: BOTH must still be inactive at revision 2, and no third binding may exist.
  for r in
    select b.id, b.active, b.revision, b.weight, b.location_id, b.encounter_profile_id,
           coalesce(ep.key, '(missing)') as profile_key, coalesce(l.name, '(missing)') as loc_name
      from public.location_encounter_bindings b
      left join public.encounter_profiles ep on ep.id = b.encounter_profile_id
      left join public.locations l           on l.id  = b.location_id
     order by b.id::text collate pg_catalog."C"
  loop
    raise notice 'PD0272_SNAPSHOT must_not_change.binding.%=active:%|revision:%|weight:%|profile:%|location:%',
      r.id, r.active, r.revision, r.weight, r.profile_key, r.loc_name;
    if r.active then
      raise notice 'PD0272_FINDING [BLOCK] PD09_BINDING_ACTIVE binding=% profile=% location=% :: a binding is ACTIVE — 0272 activates nothing and the post-canary posture is both bindings inactive', r.id, r.profile_key, r.loc_name;
      v_b := v_b + 1;
    end if;
    if r.revision <> 2 then
      raise notice 'PD0272_FINDING [BLOCK] PD09_BINDING_REVISION binding=% got=% want=2 :: the binding was edited', r.id, r.revision;
      v_b := v_b + 1;
    end if;
    if r.id::text not in (v_canary, v_other) then
      raise notice 'PD0272_FINDING [BLOCK] PD09_BINDING_UNEXPECTED binding=% profile=% :: a binding exists that was not in the reviewed set', r.id, r.profile_key;
      v_b := v_b + 1;
    end if;
  end loop;
  select count(*) into v_n from public.location_encounter_bindings;
  raise notice 'PD0272_SNAPSHOT must_not_change.binding.row_count=%', v_n;
  if v_n <> 2 then
    raise notice 'PD0272_FINDING [BLOCK] PD09_BINDING_COUNT got=% want=2 :: the binding set changed', v_n;
    v_b := v_b + 1;
  end if;
  foreach v_id in array array[v_canary::uuid, v_other::uuid] loop
    if not exists (select 1 from public.location_encounter_bindings b where b.id = v_id) then
      raise notice 'PD0272_FINDING [BLOCK] PD09_BINDING_MISSING binding=% :: an expected binding disappeared', v_id;
      v_b := v_b + 1;
    end if;
  end loop;

  -- PD10 elite_chance: 0272 wires elite but authors NOTHING. Every member must still be elite_chance 0.
  select count(*) into v_n     from public.enemy_fleet_template_members;
  select count(*) into v_elite from public.enemy_fleet_template_members fm where coalesce(fm.elite_chance, 0) > 0;
  raise notice 'PD0272_SNAPSHOT must_not_change.template_member.row_count=%',   v_n;
  raise notice 'PD0272_SNAPSHOT must_not_change.template_member.elite_nonzero=%', v_elite;
  for r in select fm.id, fm.fleet_template_id, fm.enemy_archetype_id, fm.min_count, fm.max_count, fm.weight, fm.elite_chance
             from public.enemy_fleet_template_members fm order by fm.id::text collate pg_catalog."C" loop
    raise notice 'PD0272_SNAPSHOT must_not_change.template_member.%=min:%|max:%|weight:%|elite_chance:%|template:%|archetype:%',
      r.id, r.min_count, r.max_count, r.weight, r.elite_chance, r.fleet_template_id, r.enemy_archetype_id;
  end loop;
  if v_elite > 0 then
    raise notice 'PD0272_FINDING [BLOCK] PD10_ELITE_CHANCE_AUTHORED rows=% :: an enemy_fleet_template_members row now carries elite_chance > 0. 0272 wires elite but AUTHORS nothing — authoring elite content is a separate, owner-gated act.', v_elite;
    v_b := v_b + 1;
  else
    raise notice 'PD0272_FINDING [INFO] PD10_ELITE_CHANCE :: 0 of % template member(s) carry elite_chance > 0 (unchanged)', v_n;
  end if;

  perform set_config('pd0272.blockers', v_b::text, true);
end $pd$;

-- ══════════ 6. PD11 — THE REST OF THE AUTHORED CHAIN (profiles, templates, archetypes, rewards) ══════
do $pd$
declare v_b integer := current_setting('pd0272.blockers')::int; r record; v_n integer;
begin
  for r in select ep.id, ep.key, ep.active, ep.revision, ep.active_encounter_cap, ep.cooldown_seconds, ep.reward_override_id
             from public.encounter_profiles ep order by ep.key collate pg_catalog."C" loop
    raise notice 'PD0272_SNAPSHOT must_not_change.encounter_profile.%=active:%|revision:%|cap:%|cooldown_s:%|reward_override:%',
      r.key, r.active, r.revision, r.active_encounter_cap, r.cooldown_seconds, coalesce(r.reward_override_id::text, '(none)');
  end loop;
  for r in select m.id, m.encounter_profile_id, m.fleet_template_id, m.weight
             from public.encounter_profile_members m order by m.id::text collate pg_catalog."C" loop
    raise notice 'PD0272_SNAPSHOT must_not_change.encounter_profile_member.%=profile:%|template:%|weight:%',
      r.id, r.encounter_profile_id, r.fleet_template_id, r.weight;
  end loop;
  for r in select ft.id, ft.key, ft.active, ft.revision from public.enemy_fleet_templates ft order by ft.key collate pg_catalog."C" loop
    raise notice 'PD0272_SNAPSHOT must_not_change.fleet_template.%=active:%|revision:%|id:%', r.key, r.active, r.revision, r.id;
  end loop;
  for r in select a.id, a.key, a.active, a.revision, a.base_difficulty, a.unit_type_id, a.behavior_key, a.stat_overrides, a.default_reward_profile_id
             from public.enemy_archetypes a order by a.key collate pg_catalog."C" loop
    raise notice 'PD0272_SNAPSHOT must_not_change.archetype.%=active:%|revision:%|base_difficulty:%|unit_type:%|behavior:%|stat_overrides:%|default_reward:%',
      r.key, r.active, r.revision, r.base_difficulty, r.unit_type_id, r.behavior_key,
      coalesce(r.stat_overrides::text, '(null)'), coalesce(r.default_reward_profile_id::text, '(none)');
  end loop;
  for r in select rp.id, rp.key, rp.active, rp.revision, rp.resource_grants
             from public.reward_profiles rp order by rp.key collate pg_catalog."C" loop
    raise notice 'PD0272_SNAPSHOT must_not_change.reward_profile.%=active:%|revision:%|grants:%',
      r.key, r.active, r.revision, coalesce(r.resource_grants::text, '(null)');
  end loop;

  for r in select t as tbl from unnest(array['encounter_profiles','encounter_profile_members','enemy_fleet_templates',
                                             'enemy_fleet_template_members','enemy_archetypes','reward_profiles']) t loop
    execute format('select count(*) from public.%I', r.tbl) into v_n;
    raise notice 'PD0272_SNAPSHOT must_not_change.rowcount.%=%', r.tbl, v_n;
  end loop;

  raise notice 'PD0272_FINDING [INFO] PD11_CONTENT_CHAIN :: the whole authored chain is in the digest; the BEFORE/AFTER diff is the authority on "unchanged"';
  perform set_config('pd0272.blockers', v_b::text, true);
end $pd$;

-- ══════════ 7. PD12 — ENCOUNTER RUNTIME STATE (must be byte-identical across the deployment) ══════════
-- 0272 re-creates ONE function, resolve_location_encounter, whose ONLY interaction with
-- encounter_runtime_state is a READ (the cooldown `exists` probe). It contains no data-modifying
-- statement against that table. So deploying 0272 CANNOT move a runtime-state row, and any movement
-- means something else ran.
do $pd$
declare
  v_b integer := current_setting('pd0272.blockers')::int;
  v_loc  text := coalesce(nullif(current_setting('pd0272.runtime_location', true), ''), '75baf5d7-6b06-4567-84c9-de97938aa251');
  v_prof text := coalesce(nullif(current_setting('pd0272.runtime_profile',  true), ''), '4d8bd4ee-4b61-454f-b0bc-fbf058ee4dd9');
  v_last text := coalesce(current_setting('pd0272.runtime_last_spawn_at', true), '2026-07-22T06:03:27.318703+00:00');
  v_ac   text := coalesce(nullif(current_setting('pd0272.runtime_active_count', true), ''), '2');
  r record; v_n integer; v_res_last timestamptz; v_res_ac integer;
begin
  select count(*) into v_n from public.encounter_runtime_state;
  raise notice 'PD0272_SNAPSHOT must_not_change.runtime_state.row_count=%', v_n;
  for r in select s.location_id, s.encounter_profile_id, s.last_spawn_at, s.active_count
             from public.encounter_runtime_state s
            order by s.location_id::text collate pg_catalog."C", s.encounter_profile_id::text collate pg_catalog."C" loop
    raise notice 'PD0272_SNAPSHOT must_not_change.runtime_state.%|%=last_spawn_at:%|active_count:%',
      r.location_id, r.encounter_profile_id, r.last_spawn_at, r.active_count;
  end loop;

  if v_n <> 1 then
    raise notice 'PD0272_FINDING [BLOCK] PD12_ROW_COUNT got=% want=1 :: the encounter_runtime_state row set changed. Deploying 0272 cannot create or remove a runtime-state row (its one re-created function only READS the table).', v_n;
    v_b := v_b + 1;
  end if;

  select s.last_spawn_at, s.active_count into v_res_last, v_res_ac
    from public.encounter_runtime_state s
   where s.location_id = v_loc::uuid and s.encounter_profile_id = v_prof::uuid;
  if v_res_last is null then
    raise notice 'PD0272_FINDING [BLOCK] PD12_RESIDUAL_ROW_GONE location=% profile=% :: the known residual row disappeared. NOTHING in the repository deletes an encounter_runtime_state row — its disappearance means a manual or out-of-band write happened.', v_loc, v_prof;
    v_b := v_b + 1;
  else
    raise notice 'PD0272_FINDING [INFO] PD12_RESIDUAL_ROW last_spawn_at=% active_count=% :: the residual (Reaver, canary_encounter) row. active_count is a CUMULATIVE spawn counter (only ever incremented; there is NO decrement anywhere in the repository) and is NOT the cap authority — the cap is derived from combat_encounters. Only last_spawn_at is load-bearing, as the cooldown anchor.',
      v_res_last, v_res_ac;
    if v_last <> '' and v_res_last is distinct from v_last::timestamptz then
      raise notice 'PD0272_FINDING [BLOCK] PD12_LAST_SPAWN_MOVED got=% want=% :: last_spawn_at MOVED — a fresh encounter resolution happened. The resolver is supposed to be dark.', v_res_last, v_last;
      v_b := v_b + 1;
    end if;
    if v_res_ac::text <> v_ac then
      raise notice 'PD0272_FINDING [BLOCK] PD12_ACTIVE_COUNT_MOVED got=% want=% :: active_count MOVED. It is incremented ONLY by the resolved-spawn arm of process_combat_ticks at first resolution, so a change means the resolver spawned.', v_res_ac, v_ac;
      v_b := v_b + 1;
    end if;
  end if;
  perform set_config('pd0272.blockers', v_b::text, true);
end $pd$;

-- ══════════ 8. PD13 — NO ENCOUNTER SPAWNED (needs a role that can read combat_encounters) ══════════
do $pd$
declare
  v_b integer := current_setting('pd0272.blockers')::int;
  v_skip text := coalesce(current_setting('pd0272.skip_rls_reads', true), '');
  v_live integer; v_tagged integer; v_after integer; r record;
begin
  if v_skip = '1' then
    raise notice 'PD0272_FINDING [WARN] PD13_SKIPPED :: combat_encounters checks skipped by request (pd0272.skip_rls_reads=1). "No encounter spawned" is NOT settled by this run.';
    perform set_config('pd0272.warns', (current_setting('pd0272.warns')::int + 1)::text, true);
    perform set_config('pd0272.blockers', v_b::text, true);
    return;
  end if;
  if to_regclass('public.combat_encounters') is null then
    raise notice 'PD0272_FINDING [BLOCK] PD13_TABLE_MISSING :: public.combat_encounters does not exist';
    perform set_config('pd0272.blockers', (v_b + 1)::text, true);
    return;
  end if;

  select count(*) into v_live   from public.combat_encounters ce where ce.status in ('active', 'retreating');
  select count(*) into v_tagged from public.combat_encounters ce
   where ce.status in ('active', 'retreating') and ce.resolved_plan_json is not null;
  raise notice 'PD0272_SNAPSHOT must_not_change.combat_encounters.live=%',        v_live;
  raise notice 'PD0272_SNAPSHOT must_not_change.combat_encounters.live_tagged=%', v_tagged;
  select count(*) into v_after from public.combat_encounters ce where ce.resolved_plan_json is not null;
  raise notice 'PD0272_SNAPSHOT must_not_change.combat_encounters.tagged_total=%', v_after;

  -- ANY live encounter carrying a resolved plan while the resolver is dark is a defect.
  for r in select ce.id, ce.status, ce.location_id, ce.resolved_plan_json->>'encounter_profile_id' as prof
             from public.combat_encounters ce
            where ce.status in ('active','retreating') and ce.resolved_plan_json is not null
            order by ce.id::text collate pg_catalog."C" loop
    raise notice 'PD0272_FINDING [BLOCK] PD13_LIVE_RESOLVED_ENCOUNTER encounter=% status=% location=% profile=% :: a RESOLVED encounter is still live while encounter_resolver_enabled is false — the derived cap authority is non-zero and a canary would be suppressed', r.id, r.status, r.location_id, coalesce(r.prof, '(untagged)');
    v_b := v_b + 1;
  end loop;
  if v_tagged = 0 then
    raise notice 'PD0272_FINDING [INFO] PD13_NO_LIVE_RESOLVED :: no live resolved encounter exists — nothing spawned and the derived cap is clear';
  end if;
  if v_live > 0 and v_tagged = 0 then
    raise notice 'PD0272_FINDING [INFO] PD13_LEGACY_LIVE live=% :: live UNTAGGED (legacy synthetic) encounters exist; they are not resolver output and do not count against a profile cap', v_live;
  end if;
  perform set_config('pd0272.blockers', v_b::text, true);
end $pd$;

-- ══════════ 9. VERDICT ══════════
do $pd$
declare
  v_b integer := current_setting('pd0272.blockers')::int;
  v_w integer := current_setting('pd0272.warns')::int;
  v_phase text := current_setting('pd0272.phase');
begin
  raise notice '────────────────────────────────────────────────────────────────────────────';
  raise notice 'REMEMBER: a single PASS proves POSTURE, not "unchanged". Capture the digest in BOTH';
  raise notice 'phases and diff them — only the expected_to_change.* lines may differ:';
  raise notice '  psql … | grep ''^PD0272_SNAPSHOT '' | sort > /tmp/pd0272.<phase>';
  raise notice '  diff /tmp/pd0272.before /tmp/pd0272.after';
  if v_b = 0 then
    raise notice 'PD0272_PASS phase=% blockers=0 warnings=% :: the % posture is exactly as required. Nothing was written.', v_phase, v_w, v_phase;
  else
    raise notice 'PD0272_BLOCKED phase=% n=% warnings=% :: see every PD0272_FINDING [BLOCK] line above — each is a separate defect. Nothing was written.', v_phase, v_b, v_w;
    raise exception 'PD0272_BLOCKED phase=% n=%', v_phase, v_b;
  end if;
end $pd$;

rollback;
