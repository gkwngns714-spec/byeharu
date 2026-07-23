-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- ENCOUNTER CANARY — READ-ONLY READINESS VERIFIER (§3.3)
--
-- ██ READ-ONLY. THIS FILE PERFORMS NO WRITE OF ANY KIND. ██
--   It opens `begin transaction read only;` so PostgreSQL ITSELF rejects any INSERT/UPDATE/DELETE/DDL
--   that ever sneaks in, and closes with `rollback;`. There is no INSERT, no UPDATE, no DELETE, no
--   CREATE, no set_game_config, no RPC call anywhere in this file. It is SAFE to run against production
--   by a human. It NEVER activates a binding and NEVER flips a flag — that is what
--   scripts/activate-canary-binding.sql (Script A) and scripts/activate-encounter-resolver-canary.sql
--   (Script B) are for, and they are OWNER-RUN ONLY.
--
-- WHAT IT ANSWERS: "if the owner ran Script A and then Script B right now, would the encounter canary
-- fire exactly the ONE intended encounter, and nothing else?"  It FAILS CLOSED: any single blocking
-- condition ends the run with a non-zero exit and the marker CANARY_READY_BLOCKED. It reports EVERY
-- blocking row it finds (it does not stop at the first) so one run yields the whole fix list.
--
-- ── HOW IT IDENTIFIES THE CHAIN ────────────────────────────────────────────────────────────────────
-- Primary pin: the binding UUID. Fallback: the encounter-profile KEY (so the same file runs unchanged
-- against a disposable CI database whose UUIDs differ). Both are overridable WITHOUT editing the file
-- and WITHOUT psql meta-commands (so it also pastes cleanly into the Supabase SQL editor), via
-- connection-level GUCs:
--
--   PGOPTIONS="-c canary.binding_id=<uuid> -c canary.profile_key=canary_encounter" \
--     psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/encounter-canary-readiness.sql
--
--   canary.binding_id            default 2f7bcf88-d810-47b4-8e04-748655688b55  (prod canary, binding B)
--   canary.profile_key           default canary_encounter
--   canary.expect_binding_rev    default 2     ('' disables the revision pin)
--   canary.expect_profile_rev    default 1
--   canary.expect_template_rev   default 1
--   canary.expect_archetype_rev  default 2     (LIVE value; the packet's "rev 1" was stale)
--   canary.expect_reward_rev     default 1
--   canary.min_cooldown_seconds  default 1     (a profile with cooldown 0 has NO throttle — binding A
--                                               was rejected for exactly this)
--   canary.max_active_cap        default 1     (the canary must admit at most ONE concurrent encounter)
--   canary.elite_migration       default 20260618000272  (the elite stat-wiring migration. TWO roles:
--                                               a head BELOW it is a hard BLOCKER (CH01), and an
--                                               elite_chance>0 member below it is a BLOCKER (CH18).
--                                               '' disables both — a deliberate pre-elite canary.)
--   canary.expect_runtime_active_count    default 2   ('' unpins) — the KNOWN residual active_count
--   canary.expect_runtime_last_spawn_at   default 2026-07-22T06:03:27.318703+00:00 ('' unpins)
--                                               Together these make CH22 fail closed on runtime state
--                                               this packet cannot explain, while NOT rejecting the
--                                               intentionally retained harmless residual row.
--
-- ── THE CHOSEN CHAIN (production, read live 2026-07-23) ────────────────────────────────────────────
--   binding 2f7bcf88-… (active=false, rev 2)
--     → location  Reaver 75baf5d7-… (status=active, activity_type=hunt_pirates, base_difficulty 15, reward_tier 2)
--     → profile   canary_encounter 4d8bd4ee-… (active, rev 1, difficulty 1, cap 1, cooldown 30s, no reward override)
--       → member  7ec49abe-… weight 1
--         → template canary_fleet e8be2946-… (active, rev 1)
--           → member 16172dce-… min 1 / max 1 / weight 1 / elite_chance 0
--             → archetype canary_pirate b7f4a217-… (active, rev 2, pirate_synthetic, spatial_synthetic,
--                                                   base_difficulty 1, stat_overrides {})
--               → reward canary_reward b742b762-… (active, rev 1, metal base 7, danger_coeff .25,
--                                                   multiplier_ref reward_multiplier)
--
-- ── RESIDUAL RUNTIME STATE (do NOT assume a clean slate) ───────────────────────────────────────────
--   encounter_runtime_state already holds ONE row for (Reaver, canary_encounter) with active_count=2
--   from the brief 2026-07-22 live window. active_count is a CUMULATIVE spawn counter — it is only ever
--   incremented, never decremented, and it is NOT the cap authority. The cap authority is DERIVED at
--   resolve time by counting combat_encounters at the location in status active/retreating whose
--   resolved_plan_json->>'encounter_profile_id' equals the profile (0261 resolver, step (e)). This
--   verifier therefore checks the DERIVED cap and treats active_count as INFO-and-PIN only, never as a
--   cap input. The row's last_spawn_at IS load-bearing: it is the cooldown anchor, and a last_spawn_at
--   newer than cooldown_seconds ago WOULD suppress the very first canary spawn — that is checked as CH22.
--   The full writer/reader matrix behind these statements (one writer, one reader; no decrement, no
--   cleanup, no reaction to binding deactivation or resolver disablement) is
--   docs/ENCOUNTER_RUNTIME_STATE_AUDIT.md, which classifies the residual row HISTORICAL-HARMLESS. It is
--   INTENTIONALLY RETAINED — this verifier PINS it (CH22) rather than rejecting it, and NEVER cleans it
--   up. This file contains no cleanup path and must never gain one.
--
-- ── FAIL-CLOSED RUNTIME/ENCOUNTER CHECKS ADDED BY THE AUDIT ────────────────────────────────────────
--   CH01 head below canary.elite_migration                         BLOCK
--   CH22 canary-pair runtime state differing from the pinned residual   BLOCK
--   CH24 runtime state referencing a MISSING binding (a true orphan)    BLOCK
--        (an INACTIVE binding is the intended pre-activation state — deliberately NOT flagged)
--   CH24 ANOTHER (location, profile) pair carrying LIVE resolved state  BLOCK
--   CH26 ANY unresolved combat_encounters at the canary location        BLOCK
--   CH27 ANY live resolver-produced encounter anywhere while dark       BLOCK
--
-- ── PASS/FAIL MARKERS (greppable) ──────────────────────────────────────────────────────────────────
--   CANARY_FINDING [BLOCK|WARN|INFO] <code> …   one line per finding (every blocking row, not just #1)
--   CANARY_READY_PASS                            zero blockers — the chain is ready for Script A
--   CANARY_READY_BLOCKED n=<N>                   N blockers; the run then RAISES (non-zero exit)
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

begin transaction read only;
set local statement_timeout = '60s';

-- ══════════ 0. resolve the configuration + the chain identity (read-only) ══════════
do $$
declare
  v_binding uuid;
  v_bid     text := coalesce(nullif(current_setting('canary.binding_id', true), ''), '2f7bcf88-d810-47b4-8e04-748655688b55');
  v_pkey    text := coalesce(nullif(current_setting('canary.profile_key', true), ''), 'canary_encounter');
  v_n       integer;
begin
  perform set_config('canary.blockers', '0',  true);
  perform set_config('canary.codes',    '',   true);
  perform set_config('canary.warns',    '0',  true);

  raise notice '════════ ENCOUNTER CANARY READINESS — READ-ONLY VERIFIER ════════';
  raise notice 'target binding_id (pin) : %', v_bid;
  raise notice 'target profile_key (fb) : %', v_pkey;
  raise notice 'database now()          : %', now();

  -- primary pin by UUID.
  select b.id into v_binding from public.location_encounter_bindings b where b.id::text = v_bid;
  -- fallback: the (single) binding whose profile carries the canary key.
  if v_binding is null then
    select count(*) into v_n
      from public.location_encounter_bindings b
      join public.encounter_profiles ep on ep.id = b.encounter_profile_id
     where ep.key = v_pkey;
    if v_n = 1 then
      select b.id into v_binding
        from public.location_encounter_bindings b
        join public.encounter_profiles ep on ep.id = b.encounter_profile_id
       where ep.key = v_pkey;
      raise notice 'CANARY_FINDING [INFO] CH04_BINDING_RESOLVED_BY_KEY binding=% :: the pinned UUID was not present; resolved by profile key %', v_binding, v_pkey;
    elsif v_n > 1 then
      raise notice 'CANARY_FINDING [BLOCK] CH04_BINDING_AMBIGUOUS profile_key=% count=% :: more than one binding carries the canary profile key — the target is ambiguous', v_pkey, v_n;
      perform set_config('canary.blockers', (current_setting('canary.blockers')::int + 1)::text, true);
    end if;
  end if;

  if v_binding is null then
    raise notice 'CANARY_FINDING [BLOCK] CH04_BINDING_MISSING binding_id=% profile_key=% :: no location_encounter_bindings row matches the pinned UUID or the profile key — nothing to activate', v_bid, v_pkey;
    perform set_config('canary.blockers', (current_setting('canary.blockers')::int + 1)::text, true);
    perform set_config('canary.binding', '', true);
  else
    perform set_config('canary.binding', v_binding::text, true);
  end if;
end $$;

-- ══════════ 1. DEPLOYMENT SURFACE — CH01 migration head, CH25 resolver body, functions/tables ══════════
do $$
declare v_head text; v_missing text; v_tick text; v_b integer := current_setting('canary.blockers')::int;
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  raise notice 'CANARY_FINDING [INFO] CH01_MIGRATION_HEAD head=% :: elite gate migration = %',
    coalesce(v_head, '(none)'), coalesce(nullif(current_setting('canary.elite_migration', true), ''), '20260618000272');
  if v_head is null or v_head < '20260618000261' then
    raise notice 'CANARY_FINDING [BLOCK] CH01_MIGRATION_HEAD head=% :: E3/E5 (0260/0261) not deployed — the resolver does not exist yet', coalesce(v_head, '(none)');
    v_b := v_b + 1;
  -- CH01 ELITE-WIRING FLOOR: the canary must not be run against a resolver older than the elite
  -- stat-wiring migration. Below it the resolver is zero-elite (0261) and silently drops any elite
  -- intent, so what fires is NOT the chain the packet describes. Set canary.elite_migration='' to
  -- deliberately run a pre-elite canary.
  elsif nullif(current_setting('canary.elite_migration', true), '') is distinct from ''
        and v_head < coalesce(nullif(current_setting('canary.elite_migration', true), ''), '20260618000272') then
    raise notice 'CANARY_FINDING [BLOCK] CH01_BELOW_ELITE_MIGRATION head=% needs=% :: the production migration head is BELOW the elite stat-wiring migration — deploy it before running the canary',
      coalesce(v_head, '(none)'), coalesce(nullif(current_setting('canary.elite_migration', true), ''), '20260618000272');
    v_b := v_b + 1;
  end if;

  select string_agg(fn, ', ') into v_missing
    from unnest(array['public.resolve_location_encounter(uuid,text)',
                      'public.resolve_encounter_reward_inputs(jsonb,integer,integer)',
                      'public.process_combat_ticks()',
                      'public.cfg_bool(text)',
                      'public.cfg_num(text)']) fn
   where to_regprocedure(fn) is null;
  if v_missing is not null then
    raise notice 'CANARY_FINDING [BLOCK] CH25_FUNCTIONS_MISSING missing=% :: the resolver surface is incomplete', v_missing;
    v_b := v_b + 1;
  end if;

  select string_agg(t, ', ') into v_missing
    from unnest(array['public.location_encounter_bindings','public.encounter_profiles','public.encounter_profile_members',
                      'public.enemy_fleet_templates','public.enemy_fleet_template_members','public.enemy_archetypes',
                      'public.reward_profiles','public.encounter_runtime_state','public.combat_encounters']) t
   where to_regclass(t) is null;
  if v_missing is not null then
    raise notice 'CANARY_FINDING [BLOCK] CH25_TABLES_MISSING missing=% :: the content/runtime surface is incomplete', v_missing;
    v_b := v_b + 1;
  end if;

  -- the DEPLOYED process_combat_ticks must carry the E5 seeded resolved branch (a version number alone
  -- proves nothing about WHICH body landed).
  select p.prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_tick is null
     or position('v_resolver_engaged' in v_tick) = 0
     or position('resolve_location_encounter(e.location_id, e.id::text)' in v_tick) = 0 then
    raise notice 'CANARY_FINDING [BLOCK] CH25_TICK_BODY :: the deployed process_combat_ticks does not carry the E5 seeded resolved branch (no v_resolver_engaged / resolve_location_encounter(e.location_id, e.id::text))';
    v_b := v_b + 1;
  else
    raise notice 'CANARY_FINDING [INFO] CH25_TICK_BODY :: process_combat_ticks carries the E5 seeded resolved branch';
  end if;
  perform set_config('canary.blockers', v_b::text, true);
end $$;

-- ══════════ 2. FLAG POSTURE — CH02 resolver must be OFF, CH03 the E0/E1/E2 prerequisites ══════════
do $$
declare v_b integer := current_setting('canary.blockers')::int; k text; v_on boolean; v_missing text;
begin
  select string_agg(k2, ', ') into v_missing
    from unnest(array['enemy_content_registry_enabled','encounter_authoring_enabled',
                      'encounter_binding_authoring_enabled','encounter_resolver_enabled']) k2
   where not exists (select 1 from public.game_config g where g.key = k2);
  if v_missing is not null then
    raise notice 'CANARY_FINDING [BLOCK] CH02_FLAG_KEYS_MISSING missing=% :: the quad-flag keys are not all seeded', v_missing;
    v_b := v_b + 1;
  end if;

  if to_regprocedure('public.cfg_bool(text)') is not null then
    v_on := public.cfg_bool('encounter_resolver_enabled');
    if v_on then
      raise notice 'CANARY_FINDING [BLOCK] CH02_RESOLVER_ALREADY_ON :: encounter_resolver_enabled is ALREADY true — the resolver is live; this is not a pre-activation state. Roll it back (set false) before running the canary sequence.';
      v_b := v_b + 1;
    else
      raise notice 'CANARY_FINDING [INFO] CH02_RESOLVER_OFF :: encounter_resolver_enabled=false (correct pre-activation posture)';
    end if;

    foreach k in array array['enemy_content_registry_enabled','encounter_authoring_enabled','encounter_binding_authoring_enabled'] loop
      if not public.cfg_bool(k) then
        raise notice 'CANARY_FINDING [BLOCK] CH03_QUAD_PREREQ_OFF flag=% :: the resolver is QUAD-gated; with this false Script B would light a flag that stays inert', k;
        v_b := v_b + 1;
      end if;
    end loop;
    raise notice 'CANARY_FINDING [INFO] CH03_QUAD_PREREQ :: E0/E1/E2 authoring flags checked';
  end if;
  perform set_config('canary.blockers', v_b::text, true);
end $$;

-- ══════════ 3. THE BINDING — CH05 must be INACTIVE, CH06 revision, CH07 no OTHER active binding ══════
do $$
declare
  v_b integer := current_setting('canary.blockers')::int;
  v_binding uuid := nullif(current_setting('canary.binding', true), '')::uuid;
  v_exp text := coalesce(current_setting('canary.expect_binding_rev', true), '2');
  r record; n integer := 0;
begin
  if v_binding is not null then
    select b.id, b.active, b.revision, b.weight, b.location_id, b.encounter_profile_id
      into r from public.location_encounter_bindings b where b.id = v_binding;
    raise notice 'CANARY_FINDING [INFO] CH05_BINDING binding=% active=% revision=% weight=% :: the target binding', r.id, r.active, r.revision, r.weight;
    if r.active then
      raise notice 'CANARY_FINDING [BLOCK] CH05_BINDING_ALREADY_ACTIVE binding=% :: the canary binding is ALREADY active — Script A has already run (or someone activated it); this is not a pre-activation state', r.id;
      v_b := v_b + 1;
    end if;
    if v_exp <> '' and r.revision::text <> v_exp then
      raise notice 'CANARY_FINDING [BLOCK] CH06_BINDING_REVISION binding=% got=% want=% :: the binding was edited since the packet was written — re-audit the chain before activating', r.id, r.revision, v_exp;
      v_b := v_b + 1;
    end if;
  end if;

  -- CH07: ANY other active binding ANYWHERE is a blocker — the canary must be the only live encounter
  -- source in the world, or a second, unaudited chain fires the moment Script B lights the resolver.
  for r in
    select b.id, b.active, b.revision, l.name as loc_name, l.status as loc_status, ep.key as profile_key
      from public.location_encounter_bindings b
      left join public.locations l           on l.id  = b.location_id
      left join public.encounter_profiles ep on ep.id = b.encounter_profile_id
     where b.active is true and (v_binding is null or b.id <> v_binding)
     order by b.id
  loop
    raise notice 'CANARY_FINDING [BLOCK] CH07_OTHER_ACTIVE_BINDING binding=% location=% loc_status=% profile=% :: an ADDITIONAL binding is active — deactivate it or the canary is not isolated', r.id, coalesce(r.loc_name,'(missing)'), coalesce(r.loc_status,'(missing)'), coalesce(r.profile_key,'(missing)');
    v_b := v_b + 1; n := n + 1;
  end loop;
  if n = 0 then
    raise notice 'CANARY_FINDING [INFO] CH07_ISOLATION :: no other active location_encounter_bindings exist — the canary would be the ONLY live encounter source';
  end if;
  perform set_config('canary.blockers', v_b::text, true);
end $$;

-- ══════════ 4. THE LOCATION — CH08 exists, CH09 active, CH10 activity/ambush posture ══════════
do $$
declare
  v_b integer := current_setting('canary.blockers')::int;
  v_binding uuid := nullif(current_setting('canary.binding', true), '')::uuid;
  v_loc uuid; r record;
begin
  if v_binding is null then perform set_config('canary.blockers', v_b::text, true); return; end if;
  select b.location_id into v_loc from public.location_encounter_bindings b where b.id = v_binding;

  select l.id, l.name, l.status, l.activity_type, l.base_difficulty, l.reward_tier, l.x, l.y, l.min_power_required
    into r from public.locations l where l.id = v_loc;
  if r.id is null then
    raise notice 'CANARY_FINDING [BLOCK] CH08_LOCATION_MISSING location_id=% :: the bound location row does not exist', v_loc;
    v_b := v_b + 1;
  else
    raise notice 'CANARY_FINDING [INFO] CH08_LOCATION location=% name=% status=% activity=% base_difficulty=% reward_tier=% pos=(%,%) min_power=%',
      r.id, r.name, r.status, r.activity_type, r.base_difficulty, r.reward_tier, r.x, r.y, r.min_power_required;
    if r.status is distinct from 'active' then
      raise notice 'CANARY_FINDING [BLOCK] CH09_LOCATION_INACTIVE location=% status=% :: the resolver filters to status=active — the canary would never fire', r.id, r.status;
      v_b := v_b + 1;
    end if;
    if r.activity_type is distinct from 'hunt_pirates' then
      raise notice 'CANARY_FINDING [WARN] CH10_LOCATION_ACTIVITY location=% activity=% :: expected hunt_pirates (the send_ship_group_hunt entry point)', r.id, r.activity_type;
      perform set_config('canary.warns', (current_setting('canary.warns')::int + 1)::text, true);
    end if;
  end if;

  -- travel-ambush posture: with pirate_intercept_enabled AND spatial_combat_enabled true, the TRIP to the
  -- location can itself start a combat that has nothing to do with the canary. Informational, not blocking
  -- — but the owner must send an EXPENDABLE fleet.
  if to_regprocedure('public.cfg_bool(text)') is not null then
    raise notice 'CANARY_FINDING [WARN] CH10_AMBUSH_POSTURE pirate_intercept_enabled=% spatial_combat_enabled=% :: travel to the canary location can itself trigger an en-route ambush — use an EXPENDABLE fleet, never a fleet you cannot lose',
      public.cfg_bool('pirate_intercept_enabled'), public.cfg_bool('spatial_combat_enabled');
    perform set_config('canary.warns', (current_setting('canary.warns')::int + 1)::text, true);
  end if;
  perform set_config('canary.blockers', v_b::text, true);
end $$;

-- ══════════ 5. THE PROFILE — CH11 exists/active/revision, CH12 cooldown, CH13 cap, CH14 membership ══
do $$
declare
  v_b integer := current_setting('canary.blockers')::int;
  v_binding uuid := nullif(current_setting('canary.binding', true), '')::uuid;
  v_ep uuid; r record; n integer := 0;
  v_exp  text := coalesce(current_setting('canary.expect_profile_rev', true), '1');
  v_mincd integer := coalesce(nullif(current_setting('canary.min_cooldown_seconds', true), ''), '1')::integer;
  v_maxcap integer := coalesce(nullif(current_setting('canary.max_active_cap', true), ''), '1')::integer;
begin
  if v_binding is null then perform set_config('canary.blockers', v_b::text, true); return; end if;
  select b.encounter_profile_id into v_ep from public.location_encounter_bindings b where b.id = v_binding;

  select ep.id, ep.key, ep.active, ep.revision, ep.difficulty, ep.active_encounter_cap, ep.cooldown_seconds, ep.reward_override_id
    into r from public.encounter_profiles ep where ep.id = v_ep;
  if r.id is null then
    raise notice 'CANARY_FINDING [BLOCK] CH11_PROFILE_MISSING profile_id=% :: the bound encounter profile does not exist', v_ep;
    perform set_config('canary.blockers', (v_b + 1)::text, true); return;
  end if;
  raise notice 'CANARY_FINDING [INFO] CH11_PROFILE profile=% key=% active=% revision=% difficulty=% cap=% cooldown_s=% reward_override=%',
    r.id, r.key, r.active, r.revision, r.difficulty, r.active_encounter_cap, r.cooldown_seconds, coalesce(r.reward_override_id::text, '(null → archetype default)');

  if not r.active then
    raise notice 'CANARY_FINDING [BLOCK] CH11_PROFILE_INACTIVE profile=% key=% :: the resolver requires ep.active — the canary would resolve to NULL and combat would fall back to the legacy synthetic wave', r.id, r.key;
    v_b := v_b + 1;
  end if;
  if v_exp <> '' and r.revision::text <> v_exp then
    raise notice 'CANARY_FINDING [BLOCK] CH11_PROFILE_REVISION profile=% got=% want=% :: the profile changed since the packet — re-audit', r.id, r.revision, v_exp;
    v_b := v_b + 1;
  end if;

  -- CH12 COOLDOWN VIOLATION: cooldown_seconds = 0 means NO throttle — one cleared encounter can respawn
  -- on the very next tick, without limit. This is exactly why binding A (profile pirate_basic,
  -- cooldown_seconds=0) was REJECTED as the canary.
  if r.cooldown_seconds < v_mincd then
    raise notice 'CANARY_FINDING [BLOCK] CH12_COOLDOWN_VIOLATION profile=% key=% cooldown_s=% min=% :: a canary MUST be throttled; cooldown 0 gives the resolver no spawn brake at all', r.id, r.key, r.cooldown_seconds, v_mincd;
    v_b := v_b + 1;
  end if;

  -- CH13 FLEET-CAP VIOLATION: active_encounter_cap bounds concurrent resolved encounters at the location.
  if r.active_encounter_cap > v_maxcap then
    raise notice 'CANARY_FINDING [BLOCK] CH13_CAP_VIOLATION profile=% key=% cap=% max=% :: the canary must admit at most % concurrent encounter(s)', r.id, r.key, r.active_encounter_cap, v_maxcap, v_maxcap;
    v_b := v_b + 1;
  end if;

  -- CH14 MEMBERSHIP: at least ONE member, and at least one whose fleet template is ACTIVE (the resolver
  -- joins ft.active is true; zero survivors ⇒ NULL plan ⇒ no canary).
  for r in
    select m.id, m.fleet_template_id, m.weight, ft.key as ft_key, ft.active as ft_active
      from public.encounter_profile_members m
      left join public.enemy_fleet_templates ft on ft.id = m.fleet_template_id
     where m.encounter_profile_id = v_ep
     order by m.id
  loop
    n := n + 1;
    raise notice 'CANARY_FINDING [INFO] CH14_PROFILE_MEMBER member=% template=% key=% template_active=% weight=%',
      r.id, r.fleet_template_id, coalesce(r.ft_key,'(missing)'), coalesce(r.ft_active::text,'(missing)'), r.weight;
    if r.ft_key is null then
      raise notice 'CANARY_FINDING [BLOCK] CH15_TEMPLATE_MISSING member=% template=% :: the referenced fleet template does not exist', r.id, r.fleet_template_id;
      v_b := v_b + 1;
    elsif not r.ft_active then
      raise notice 'CANARY_FINDING [BLOCK] CH15_TEMPLATE_INACTIVE member=% template=% key=% :: the resolver skips inactive templates', r.id, r.fleet_template_id, r.ft_key;
      v_b := v_b + 1;
    end if;
  end loop;
  if n = 0 then
    raise notice 'CANARY_FINDING [BLOCK] CH14_PROFILE_MEMBERSHIP_EMPTY profile=% :: the encounter profile has NO members — the resolver returns NULL and the canary never fires', v_ep;
    v_b := v_b + 1;
  end if;
  perform set_config('canary.blockers', v_b::text, true);
end $$;

-- ══════════ 6. TEMPLATES + MEMBERS + ARCHETYPES — CH15/CH16/CH17, and CH18 the ELITE / 0272 gate ══════
do $$
declare
  v_b integer := current_setting('canary.blockers')::int;
  v_binding uuid := nullif(current_setting('canary.binding', true), '')::uuid;
  v_ep uuid; r record; n_tm integer; n_units_max integer := 0; v_ceiling integer;
  v_exp_ft text := coalesce(current_setting('canary.expect_template_rev', true), '1');
  v_exp_ar text := coalesce(current_setting('canary.expect_archetype_rev', true), '2');
  v_head text; v_elite_mig text := coalesce(nullif(current_setting('canary.elite_migration', true), ''), '20260618000272');
  v_elite_ok boolean;
begin
  if v_binding is null then perform set_config('canary.blockers', v_b::text, true); return; end if;
  select b.encounter_profile_id into v_ep from public.location_encounter_bindings b where b.id = v_binding;
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  v_elite_ok := v_head is not null and v_head >= v_elite_mig;
  v_ceiling := greatest(1, coalesce(case when to_regprocedure('public.cfg_num(text)') is not null
                                         then public.cfg_num('enemy_synthetic_max_units') end, 6)::integer);

  for r in
    select ft.id as ft_id, ft.key as ft_key, ft.active as ft_active, ft.revision as ft_rev
      from public.encounter_profile_members m
      join public.enemy_fleet_templates ft on ft.id = m.fleet_template_id
     where m.encounter_profile_id = v_ep
     order by ft.id
  loop
    if v_exp_ft <> '' and r.ft_rev::text <> v_exp_ft then
      raise notice 'CANARY_FINDING [BLOCK] CH15_TEMPLATE_REVISION template=% key=% got=% want=% :: the fleet template changed since the packet — re-audit', r.ft_id, r.ft_key, r.ft_rev, v_exp_ft;
      v_b := v_b + 1;
    end if;

    select count(*) into n_tm from public.enemy_fleet_template_members fm where fm.fleet_template_id = r.ft_id;
    if n_tm = 0 then
      raise notice 'CANARY_FINDING [BLOCK] CH16_TEMPLATE_MEMBERSHIP_EMPTY template=% key=% :: the fleet template has NO members — the resolver materialises zero units and returns NULL', r.ft_id, r.ft_key;
      v_b := v_b + 1;
    end if;
  end loop;

  -- every reachable template member + its archetype.
  for r in
    select fm.id as fm_id, fm.fleet_template_id, ft.key as ft_key,
           fm.enemy_archetype_id, fm.min_count, fm.max_count, fm.weight, fm.elite_chance,
           a.key as a_key, a.active as a_active, a.revision as a_rev, a.unit_type_id, a.behavior_key,
           a.base_difficulty, a.stat_overrides, a.default_reward_profile_id
      from public.encounter_profile_members m
      join public.enemy_fleet_templates ft        on ft.id = m.fleet_template_id
      join public.enemy_fleet_template_members fm on fm.fleet_template_id = ft.id
      left join public.enemy_archetypes a          on a.id = fm.enemy_archetype_id
     where m.encounter_profile_id = v_ep
     order by fm.id
  loop
    raise notice 'CANARY_FINDING [INFO] CH16_TEMPLATE_MEMBER member=% template=% archetype=% key=% min=% max=% weight=% elite_chance=% base_difficulty=% unit_type=% behavior=% active=% rev=%',
      r.fm_id, r.ft_key, r.enemy_archetype_id, coalesce(r.a_key,'(missing)'), r.min_count, r.max_count, r.weight,
      r.elite_chance, r.base_difficulty, coalesce(r.unit_type_id,'(missing)'), coalesce(r.behavior_key,'(missing)'),
      coalesce(r.a_active::text,'(missing)'), coalesce(r.a_rev::text,'(missing)');

    n_units_max := n_units_max + coalesce(r.max_count, 0);

    -- CH17 ARCHETYPE validity.
    if r.a_key is null then
      raise notice 'CANARY_FINDING [BLOCK] CH17_ARCHETYPE_MISSING member=% archetype=% :: the referenced archetype does not exist', r.fm_id, r.enemy_archetype_id;
      v_b := v_b + 1;
    else
      if not r.a_active then
        raise notice 'CANARY_FINDING [BLOCK] CH17_ARCHETYPE_INACTIVE member=% archetype=% key=% :: the resolver skips inactive archetypes; if ALL are inactive the plan is NULL', r.fm_id, r.enemy_archetype_id, r.a_key;
        v_b := v_b + 1;
      end if;
      if v_exp_ar <> '' and r.a_rev::text <> v_exp_ar then
        raise notice 'CANARY_FINDING [BLOCK] CH17_ARCHETYPE_REVISION archetype=% key=% got=% want=% :: the archetype changed since the packet — re-audit', r.enemy_archetype_id, r.a_key, r.a_rev, v_exp_ar;
        v_b := v_b + 1;
      end if;
      if not exists (select 1 from public.unit_types ut where ut.id = r.unit_type_id) then
        raise notice 'CANARY_FINDING [BLOCK] CH17_ARCHETYPE_UNIT_TYPE archetype=% unit_type=% :: unknown unit_type_id — the spawned combat_units row would reference a non-existent identity', r.enemy_archetype_id, r.unit_type_id;
        v_b := v_b + 1;
      end if;
      if r.behavior_key is distinct from 'spatial_synthetic' then
        raise notice 'CANARY_FINDING [WARN] CH17_ARCHETYPE_BEHAVIOR archetype=% behavior=% :: only spatial_synthetic is exercised by the spatial combat arm', r.enemy_archetype_id, r.behavior_key;
        perform set_config('canary.warns', (current_setting('canary.warns')::int + 1)::text, true);
      end if;
      if r.base_difficulty is null or r.base_difficulty <= 0 then
        raise notice 'CANARY_FINDING [BLOCK] CH17_ARCHETYPE_DIFFICULTY archetype=% base_difficulty=% :: a 0/NULL base_difficulty spawns a 0-hp enemy', r.enemy_archetype_id, r.base_difficulty;
        v_b := v_b + 1;
      end if;
    end if;

    if r.min_count is null or r.max_count is null or r.min_count > r.max_count or r.max_count <= 0 then
      raise notice 'CANARY_FINDING [BLOCK] CH16_MEMBER_COUNTS member=% min=% max=% :: an unusable count range', r.fm_id, r.min_count, r.max_count;
      v_b := v_b + 1;
    end if;

    -- CH18 ELITE / 0272 GATE. E5 (0261) made the resolver ZERO-ELITE: elite_chance is not even read, so an
    -- elite member is authored intent that would be silently dropped. Until the elite stat-wiring migration
    -- (0272) is deployed, ANY reachable elite member is a BLOCKER.
    if coalesce(r.elite_chance, 0) > 0 and not v_elite_ok then
      raise notice 'CANARY_FINDING [BLOCK] CH18_ELITE_WITHOUT_0272 member=% archetype=% elite_chance=% head=% needs=% :: an elite member is present but the elite stat-wiring migration is NOT deployed — the resolver is zero-elite (0261) and would silently drop this intent',
        r.fm_id, r.enemy_archetype_id, r.elite_chance, coalesce(v_head,'(none)'), v_elite_mig;
      v_b := v_b + 1;
    elsif coalesce(r.elite_chance, 0) > 0 then
      raise notice 'CANARY_FINDING [WARN] CH18_ELITE_PRESENT member=% elite_chance=% :: elite content is reachable and 0272 IS deployed — confirm the elite stat wiring is what you intend for a canary', r.fm_id, r.elite_chance;
      perform set_config('canary.warns', (current_setting('canary.warns')::int + 1)::text, true);
    end if;
  end loop;

  -- CH16 FLEET-SIZE (unit-ceiling) VIOLATION: the resolver clamps the TOTAL rolled count to
  -- enemy_synthetic_max_units. A max-count sum above the ceiling means the authored fleet cannot spawn as
  -- authored — unacceptable for a canary whose whole point is a KNOWN, exact outcome.
  if n_units_max > v_ceiling then
    raise notice 'CANARY_FINDING [BLOCK] CH16_FLEET_CAP_VIOLATION sum_max_count=% ceiling=% :: the authored fleet can exceed the synthetic unit ceiling and would be silently clamped', n_units_max, v_ceiling;
    v_b := v_b + 1;
  else
    raise notice 'CANARY_FINDING [INFO] CH16_FLEET_SIZE sum_max_count=% ceiling=% :: the authored fleet fits under the unit ceiling', n_units_max, v_ceiling;
  end if;
  perform set_config('canary.blockers', v_b::text, true);
end $$;

-- ══════════ 7. REWARDS — CH19 resolution/active, CH20 supported resource types ══════════
do $$
declare
  v_b integer := current_setting('canary.blockers')::int;
  v_binding uuid := nullif(current_setting('canary.binding', true), '')::uuid;
  v_ep uuid; v_override uuid; v_shared uuid; v_conflict boolean := false;
  v_exp text := coalesce(current_setting('canary.expect_reward_rev', true), '1');
  r record; g jsonb; k text; v_reward uuid;
begin
  if v_binding is null then perform set_config('canary.blockers', v_b::text, true); return; end if;
  select b.encounter_profile_id into v_ep from public.location_encounter_bindings b where b.id = v_binding;
  select ep.reward_override_id into v_override from public.encounter_profiles ep where ep.id = v_ep;

  -- mirror the resolver's step (g): override wins; else the ONE default shared by every SPAWNING
  -- archetype; divergent defaults with no override ⇒ NOT runtime-eligible (plan NULL).
  for r in
    select distinct a.default_reward_profile_id
      from public.encounter_profile_members m
      join public.enemy_fleet_templates ft        on ft.id = m.fleet_template_id and ft.active is true
      join public.enemy_fleet_template_members fm on fm.fleet_template_id = ft.id
      join public.enemy_archetypes a               on a.id = fm.enemy_archetype_id and a.active is true
     where m.encounter_profile_id = v_ep and fm.max_count > 0
  loop
    if v_shared is null then v_shared := r.default_reward_profile_id;
    elsif r.default_reward_profile_id is distinct from v_shared then v_conflict := true; end if;
  end loop;

  if v_override is not null then
    v_reward := v_override;
    raise notice 'CANARY_FINDING [INFO] CH19_REWARD_SOURCE :: encounter-profile OVERRIDE %', v_reward;
  elsif v_conflict then
    raise notice 'CANARY_FINDING [BLOCK] CH19_REWARD_CONFLICT profile=% :: the spawning archetypes carry DIVERGENT default reward profiles and there is no override — the resolver refuses to pick and returns NULL (the canary would silently degrade to the legacy synthetic wave)', v_ep;
    v_b := v_b + 1;
  else
    v_reward := v_shared;
    raise notice 'CANARY_FINDING [INFO] CH19_REWARD_SOURCE :: shared archetype DEFAULT %', coalesce(v_reward::text, '(none)');
  end if;

  if v_reward is null and not v_conflict then
    raise notice 'CANARY_FINDING [BLOCK] CH19_REWARD_MISSING profile=% :: no reward profile is reachable (no spawning archetype) — the plan resolves to NULL', v_ep;
    v_b := v_b + 1;
  elsif v_reward is not null then
    select rp.id, rp.key, rp.active, rp.revision, rp.resource_grants into r from public.reward_profiles rp where rp.id = v_reward;
    if r.id is null then
      raise notice 'CANARY_FINDING [BLOCK] CH19_REWARD_INVALID reward=% :: the reward profile row does not exist', v_reward;
      v_b := v_b + 1;
    else
      raise notice 'CANARY_FINDING [INFO] CH19_REWARD reward=% key=% active=% revision=% grants=%', r.id, r.key, r.active, r.revision, r.resource_grants;
      if not r.active then
        raise notice 'CANARY_FINDING [BLOCK] CH19_REWARD_INACTIVE reward=% key=% :: the resolver requires rp.active — an inactive reward profile makes the whole plan NULL', r.id, r.key;
        v_b := v_b + 1;
      end if;
      if v_exp <> '' and r.revision::text <> v_exp then
        raise notice 'CANARY_FINDING [BLOCK] CH19_REWARD_REVISION reward=% got=% want=% :: the reward profile changed since the packet — re-audit', r.id, r.revision, v_exp;
        v_b := v_b + 1;
      end if;

      -- CH20 SUPPORTED RESOURCE TYPES. resolve_encounter_reward_inputs (0260 §4) reads ONLY
      -- resource_grants->'metal'->{base,danger_coeff} and the config key named by multiplier_ref.
      -- Any OTHER resource key is authored intent that pays NOTHING — a canary must not carry a
      -- silently-ignored grant.
      g := r.resource_grants;
      if g is null or jsonb_typeof(g) <> 'object' or not (g ? 'metal') then
        raise notice 'CANARY_FINDING [BLOCK] CH20_REWARD_NO_METAL reward=% grants=% :: resource_grants has no metal entry — the reward adapter would compute NULL', r.id, g;
        v_b := v_b + 1;
      else
        for k in select jsonb_object_keys(g) loop
          if k <> 'metal' then
            raise notice 'CANARY_FINDING [BLOCK] CH20_REWARD_UNSUPPORTED_RESOURCE reward=% resource=% :: only "metal" is honoured by resolve_encounter_reward_inputs — this entry would be silently ignored', r.id, k;
            v_b := v_b + 1;
          end if;
        end loop;
        if (g->'metal'->>'base') is null or (g->'metal'->>'base')::double precision <= 0 then
          raise notice 'CANARY_FINDING [BLOCK] CH20_REWARD_BASE reward=% base=% :: metal.base must be a positive number', r.id, (g->'metal'->>'base');
          v_b := v_b + 1;
        end if;
        if (g->'metal'->>'danger_coeff') is null then
          raise notice 'CANARY_FINDING [BLOCK] CH20_REWARD_DANGER_COEFF reward=% :: metal.danger_coeff is missing', r.id;
          v_b := v_b + 1;
        end if;
        if (g->'metal'->>'multiplier_ref') is null
           or not exists (select 1 from public.game_config gc where gc.key = (g->'metal'->>'multiplier_ref')) then
          raise notice 'CANARY_FINDING [BLOCK] CH20_REWARD_MULTIPLIER_REF reward=% ref=% :: multiplier_ref must name an existing game_config key', r.id, (g->'metal'->>'multiplier_ref');
          v_b := v_b + 1;
        end if;
      end if;
    end if;
  end if;
  perform set_config('canary.blockers', v_b::text, true);
end $$;

-- ══════════ 8. RUNTIME STATE + DERIVED CAP — CH21 expected plan, CH22 cooldown anchor, CH23 live cap ══
do $$
declare
  v_b integer := current_setting('canary.blockers')::int;
  v_binding uuid := nullif(current_setting('canary.binding', true), '')::uuid;
  v_loc uuid; v_ep uuid; v_cap integer; v_cd integer; r record;
  v_elapsed double precision; v_live integer; v_any integer;
  v_tier integer; v_danger integer := 1; v_bd double precision; v_metal double precision; v_hp double precision;
  v_grants jsonb; v_reward uuid; v_override uuid;
begin
  if v_binding is null then perform set_config('canary.blockers', v_b::text, true); return; end if;
  select b.location_id, b.encounter_profile_id into v_loc, v_ep from public.location_encounter_bindings b where b.id = v_binding;
  select ep.active_encounter_cap, ep.cooldown_seconds, ep.reward_override_id into v_cap, v_cd, v_override
    from public.encounter_profiles ep where ep.id = v_ep;

  -- CH22 the cooldown anchor. active_count is CUMULATIVE (only ever incremented) and is NOT the cap
  -- authority — it must NOT be read as "N live encounters". last_spawn_at IS load-bearing.
  select s.last_spawn_at, s.active_count into r from public.encounter_runtime_state s
   where s.location_id = v_loc and s.encounter_profile_id = v_ep;
  if r.last_spawn_at is null then
    raise notice 'CANARY_FINDING [INFO] CH22_RUNTIME_STATE :: no encounter_runtime_state row for (location, profile) — a clean cooldown anchor';
  else
    v_elapsed := extract(epoch from (now() - r.last_spawn_at));
    raise notice 'CANARY_FINDING [INFO] CH22_RUNTIME_STATE last_spawn_at=% active_count=% elapsed_s=% cooldown_s=% :: RESIDUAL row from an earlier live window. active_count is a CUMULATIVE spawn counter (never decremented) — it does NOT mean % live encounters; the cap authority is derived from combat_encounters (CH23).',
      r.last_spawn_at, r.active_count, round(v_elapsed::numeric, 1), v_cd, r.active_count;
    if v_cd > 0 and v_elapsed < v_cd then
      raise notice 'CANARY_FINDING [BLOCK] CH22_COOLDOWN_VIOLATION elapsed_s=% cooldown_s=% :: the residual last_spawn_at is INSIDE the cooldown window — the first canary spawn would be suppressed; wait % more second(s)',
        round(v_elapsed::numeric, 1), v_cd, ceil(v_cd - v_elapsed);
      v_b := v_b + 1;
    end if;
    -- CH22 UNEXPLAINED RUNTIME STATE. The KNOWN residual (from the 2026-07-22 live window) is
    -- intentionally retained and must NOT be rejected — so it is PINNED rather than forbidden. Any
    -- OTHER value means the pair moved since the audit, i.e. state this packet cannot explain.
    -- Set canary.expect_runtime_active_count='' / canary.expect_runtime_last_spawn_at='' to unpin.
    declare
      v_exp_ac  text := coalesce(current_setting('canary.expect_runtime_active_count', true), '2');
      v_exp_ls  text := coalesce(current_setting('canary.expect_runtime_last_spawn_at', true), '2026-07-22T06:03:27.318703+00:00');
    begin
      if v_exp_ac <> '' and r.active_count::text <> v_exp_ac then
        raise notice 'CANARY_FINDING [BLOCK] CH22_UNEXPLAINED_ACTIVE_COUNT got=% want=% :: the canary pair carries runtime state this packet cannot explain — active_count moved since the audit, so a spawn happened that was not accounted for. Re-audit before activating.',
          r.active_count, v_exp_ac;
        v_b := v_b + 1;
      end if;
      if v_exp_ls <> '' and r.last_spawn_at is distinct from v_exp_ls::timestamptz then
        raise notice 'CANARY_FINDING [BLOCK] CH22_UNEXPLAINED_LAST_SPAWN got=% want=% :: last_spawn_at moved since the audit — an unaccounted resolution happened. Re-audit before activating.',
          r.last_spawn_at, v_exp_ls;
        v_b := v_b + 1;
      end if;
    end;
  end if;

  -- CH24 ORPHANED / OTHER-PAIR RUNTIME STATE.
  --   (a) ORPHAN: a runtime row whose (location, profile) pair has NO location_encounter_bindings row
  --       at all. Nothing in the codebase ever deletes a runtime-state row (no cleanup, no decrement,
  --       no reaction to binding deactivation), so an orphan means the binding was deleted underneath
  --       it and the chain the packet describes no longer matches reality. BLOCK.
  --       An INACTIVE binding is NOT an orphan — that is the intended pre-activation state and is
  --       deliberately not flagged.
  --   (b) OTHER PAIR WITH LIVE RESOLVED STATE: another pair whose profile still has live tagged
  --       combat_encounters is a second, unaudited encounter source. BLOCK. A merely historical row
  --       for another pair stays a WARN.
  for r in
    select s.location_id, s.encounter_profile_id, s.last_spawn_at, s.active_count,
           exists (select 1 from public.location_encounter_bindings b
                    where b.location_id = s.location_id and b.encounter_profile_id = s.encounter_profile_id) as has_binding,
           (select count(*) from public.combat_encounters ce
             where ce.location_id = s.location_id and ce.status in ('active','retreating')
               and ce.resolved_plan_json->>'encounter_profile_id' = s.encounter_profile_id::text) as live_tagged
      from public.encounter_runtime_state s
     order by s.location_id::text collate pg_catalog."C", s.encounter_profile_id::text collate pg_catalog."C"
  loop
    if not r.has_binding then
      raise notice 'CANARY_FINDING [BLOCK] CH24_RUNTIME_STATE_ORPHAN location=% profile=% active_count=% :: this runtime-state row references a (location, profile) pair with NO binding row — the binding was removed underneath it. Nothing in the codebase cleans runtime state, so this is drift the packet cannot account for.',
        r.location_id, r.encounter_profile_id, r.active_count;
      v_b := v_b + 1;
    end if;
    if r.live_tagged > 0 and not (r.location_id = v_loc and r.encounter_profile_id = v_ep) then
      raise notice 'CANARY_FINDING [BLOCK] CH24_OTHER_PAIR_LIVE location=% profile=% live_tagged=% :: ANOTHER (location, profile) pair carries LIVE resolved encounters — the canary would not be the only live encounter source',
        r.location_id, r.encounter_profile_id, r.live_tagged;
      v_b := v_b + 1;
    end if;
  end loop;

  -- any remaining runtime rows for OTHER pairs are historical drift only (informational).
  select count(*) into v_any from public.encounter_runtime_state s
   where not (s.location_id = v_loc and s.encounter_profile_id = v_ep);
  if v_any > 0 then
    raise notice 'CANARY_FINDING [WARN] CH22_RUNTIME_STATE_OTHER rows=% :: encounter_runtime_state carries rows for other (location, profile) pairs (historical; CH24 blocks the ones that are live or orphaned)', v_any;
    perform set_config('canary.warns', (current_setting('canary.warns')::int + 1)::text, true);
  end if;

  -- CH23 the DERIVED cap — the real authority (0261 resolver step (e)).
  select count(*) into v_live from public.combat_encounters ce
   where ce.location_id = v_loc and ce.status in ('active','retreating')
     and ce.resolved_plan_json->>'encounter_profile_id' = v_ep::text;
  select count(*) into v_any from public.combat_encounters ce
   where ce.location_id = v_loc and ce.status in ('active','retreating');
  raise notice 'CANARY_FINDING [INFO] CH23_DERIVED_CAP tagged_live=% cap=% all_live_at_location=% :: the cap authority is combat_encounters, not active_count', v_live, v_cap, v_any;
  if v_live >= v_cap then
    raise notice 'CANARY_FINDING [BLOCK] CH23_CAP_VIOLATION tagged_live=% cap=% :: the derived cap is ALREADY reached — the resolver would return NULL and the canary would never spawn', v_live, v_cap;
    v_b := v_b + 1;
  end if;

  -- CH26 UNRESOLVED ENCOUNTERS AT THE CANARY LOCATION. Even an UNTAGGED (legacy synthetic) live
  -- encounter at the canary location means combat is already in progress there: the canary's outcome
  -- would not be attributable, and the fleet the owner sends could join an existing fight. FAIL CLOSED.
  if v_any > 0 then
    raise notice 'CANARY_FINDING [BLOCK] CH26_UNRESOLVED_ENCOUNTERS location=% live=% tagged=% :: combat_encounters at the canary location are still unresolved (status active/retreating). Let them finish before activating — a canary run must start from a quiet location.',
      v_loc, v_any, v_live;
    v_b := v_b + 1;
  else
    raise notice 'CANARY_FINDING [INFO] CH26_LOCATION_QUIET location=% :: no unresolved combat_encounters at the canary location', v_loc;
  end if;

  -- CH27 LIVE RESOLVED ENCOUNTER ANYWHERE while the resolver is dark. The resolved arm cannot run
  -- with encounter_resolver_enabled=false, so a live tagged encounter anywhere is unaccounted state.
  select count(*) into v_any from public.combat_encounters ce
   where ce.status in ('active','retreating') and ce.resolved_plan_json is not null;
  if v_any > 0 then
    raise notice 'CANARY_FINDING [BLOCK] CH27_LIVE_RESOLVED_ANYWHERE rows=% :: resolved (resolver-produced) encounters are LIVE somewhere in the world while the resolver is supposed to be dark — the pre-activation state is not clean',
      v_any;
    v_b := v_b + 1;
  else
    raise notice 'CANARY_FINDING [INFO] CH27_NO_LIVE_RESOLVED :: no live resolver-produced encounter exists anywhere';
  end if;

  -- CH21 the EXPECTED plan + combat outcome (informational, computed from the live chain + live config).
  select l.reward_tier into v_tier from public.locations l where l.id = v_loc;
  select a.base_difficulty into v_bd
    from public.encounter_profile_members m
    join public.enemy_fleet_templates ft        on ft.id = m.fleet_template_id and ft.active is true
    join public.enemy_fleet_template_members fm on fm.fleet_template_id = ft.id
    join public.enemy_archetypes a               on a.id = fm.enemy_archetype_id and a.active is true
   where m.encounter_profile_id = v_ep
   order by fm.id limit 1;
  if v_override is not null then v_reward := v_override; else
    select a.default_reward_profile_id into v_reward
      from public.encounter_profile_members m
      join public.enemy_fleet_templates ft        on ft.id = m.fleet_template_id and ft.active is true
      join public.enemy_fleet_template_members fm on fm.fleet_template_id = ft.id
      join public.enemy_archetypes a               on a.id = fm.enemy_archetype_id and a.active is true
     where m.encounter_profile_id = v_ep order by fm.id limit 1;
  end if;
  select rp.resource_grants into v_grants from public.reward_profiles rp where rp.id = v_reward;
  if v_bd is not null and to_regprocedure('public.cfg_num(text)') is not null then
    v_hp := v_bd * coalesce(public.cfg_num('enemy_hp_base'), 14)
                 * (1 + v_danger * coalesce(public.cfg_num('enemy_hp_danger_scale'), 0.6));
    raise notice 'CANARY_FINDING [INFO] CH21_EXPECTED_WAVE1 archetype_base_difficulty=% enemy_hp(variance=1)=% legacy_synthetic_hp_would_be=% :: the canary enemy is far weaker than the location''s legacy synthetic wave',
      v_bd, round(v_hp::numeric, 2),
      round((( select l.base_difficulty from public.locations l where l.id = v_loc)
             * coalesce(public.cfg_num('enemy_hp_base'), 14)
             * (1 + v_danger * coalesce(public.cfg_num('enemy_hp_danger_scale'), 0.6)))::numeric, 2);
  end if;
  if v_grants is not null and to_regprocedure('public.resolve_encounter_reward_inputs(jsonb,integer,integer)') is not null then
    v_metal := public.resolve_encounter_reward_inputs(v_grants, v_tier, v_danger);
    raise notice 'CANARY_FINDING [INFO] CH21_EXPECTED_REWARD wave1_metal=% legacy_metal_would_be=% reward_tier=% danger=% :: the authored reward is distinguishable from the legacy formula',
      v_metal,
      round(coalesce(public.cfg_num('reward_metal_base'), 10) * greatest(v_tier, 1)
            * (1 + coalesce(public.cfg_num('reward_danger_scale'), 0.25) * v_danger)
            * coalesce(public.cfg_num('reward_multiplier'), 1.0)),
      v_tier, v_danger;
  end if;
  perform set_config('canary.blockers', v_b::text, true);
end $$;

-- ══════════ 9. VERDICT ══════════
do $$
declare v_b integer := current_setting('canary.blockers')::int; v_w integer := current_setting('canary.warns')::int;
begin
  raise notice '════════ VERDICT ════════';
  if v_b = 0 then
    raise notice 'CANARY_READY_PASS blockers=0 warnings=% :: the chain is READY. Nothing has been written. THE OWNER may now run scripts/activate-canary-binding.sql (Script A), and then — as a SECOND, separate decision — scripts/activate-encounter-resolver-canary.sql (Script B). Each script re-verifies its own preconditions; this verifier is the PRE-activation gate (after Script A the binding is active by design, so this verifier will correctly report CH05_BINDING_ALREADY_ACTIVE if re-run).', v_w;
  else
    raise notice 'CANARY_READY_BLOCKED n=% warnings=% :: see every CANARY_FINDING [BLOCK] line above — each is a separate fix. DO NOT run Script A or Script B.', v_b, v_w;
  end if;
end $$;

-- The dependency table, as a normal result set (handy for the packet / for pasting into a report).
select 'binding'   as layer, b.id::text as id, coalesce(l.name, '(missing)') as key_or_name,
       b.active::text as active, b.revision::text as revision,
       format('location=%s status=%s activity=%s', b.location_id, coalesce(l.status,'(missing)'), coalesce(l.activity_type,'(missing)')) as detail
  from public.location_encounter_bindings b
  left join public.locations l on l.id = b.location_id
 where b.id::text = coalesce(nullif(current_setting('canary.binding', true), ''), '00000000-0000-0000-0000-000000000000')
union all
select 'profile', ep.id::text, ep.key, ep.active::text, ep.revision::text,
       format('difficulty=%s cap=%s cooldown_s=%s reward_override=%s', ep.difficulty, ep.active_encounter_cap, ep.cooldown_seconds, coalesce(ep.reward_override_id::text,'(null)'))
  from public.encounter_profiles ep
 where ep.id = (select b.encounter_profile_id from public.location_encounter_bindings b
                 where b.id::text = coalesce(nullif(current_setting('canary.binding', true), ''), '00000000-0000-0000-0000-000000000000'))
union all
select 'template', ft.id::text, ft.key, ft.active::text, ft.revision::text, format('profile_member_weight=%s', m.weight)
  from public.encounter_profile_members m
  join public.enemy_fleet_templates ft on ft.id = m.fleet_template_id
 where m.encounter_profile_id = (select b.encounter_profile_id from public.location_encounter_bindings b
                                  where b.id::text = coalesce(nullif(current_setting('canary.binding', true), ''), '00000000-0000-0000-0000-000000000000'))
union all
select 'archetype', a.id::text, a.key, a.active::text, a.revision::text,
       format('unit_type=%s behavior=%s base_difficulty=%s min=%s max=%s weight=%s elite_chance=%s',
              a.unit_type_id, a.behavior_key, a.base_difficulty, fm.min_count, fm.max_count, fm.weight, fm.elite_chance)
  from public.encounter_profile_members m
  join public.enemy_fleet_templates ft        on ft.id = m.fleet_template_id
  join public.enemy_fleet_template_members fm on fm.fleet_template_id = ft.id
  join public.enemy_archetypes a               on a.id = fm.enemy_archetype_id
 where m.encounter_profile_id = (select b.encounter_profile_id from public.location_encounter_bindings b
                                  where b.id::text = coalesce(nullif(current_setting('canary.binding', true), ''), '00000000-0000-0000-0000-000000000000'))
union all
select 'reward', rp.id::text, rp.key, rp.active::text, rp.revision::text, rp.resource_grants::text
  from public.reward_profiles rp
 where rp.id in (
   select coalesce(ep.reward_override_id, a.default_reward_profile_id)
     from public.encounter_profiles ep
     join public.encounter_profile_members m       on m.encounter_profile_id = ep.id
     join public.enemy_fleet_templates ft          on ft.id = m.fleet_template_id
     join public.enemy_fleet_template_members fm   on fm.fleet_template_id = ft.id
     join public.enemy_archetypes a                on a.id = fm.enemy_archetype_id
    where ep.id = (select b.encounter_profile_id from public.location_encounter_bindings b
                    where b.id::text = coalesce(nullif(current_setting('canary.binding', true), ''), '00000000-0000-0000-0000-000000000000')));

-- ══════════ 10. FAIL CLOSED — raise (non-zero exit) if anything blocks ══════════
do $$
declare v_b integer := current_setting('canary.blockers')::int;
begin
  if v_b > 0 then
    raise exception 'ENCOUNTER CANARY READINESS FAILED: % blocking condition(s) — see the CANARY_FINDING [BLOCK] lines above. NOTHING was written (read-only transaction).', v_b;
  end if;
end $$;

rollback;
