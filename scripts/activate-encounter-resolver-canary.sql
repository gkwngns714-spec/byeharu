-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- ██ SCRIPT B — LIGHT THE ENCOUNTER RESOLVER FOR THE CANARY ██
--
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
-- ██ OWNER-RUN ONLY. THIS FILE MUST NOT BE EXECUTED BY AN AGENT, BY CI, OR BY ANY AUTOMATION.      ██
-- ██ IT HAS NOT BEEN EXECUTED. RUNNING IT CHANGES LIVE COMBAT FOR A REAL, POPULATED PRODUCTION     ██
-- ██ GAME AND IS THE OWNER'S DECISION ALONE.                                                       ██
-- ██                                                                                               ██
-- ██ THIS IS APPROVAL 2 OF 2 AND IT IS THE BEHAVIOUR-CHANGING FLIP.                                ██
-- ██ SCRIPT A (scripts/activate-canary-binding.sql) MUST HAVE BEEN RUN FIRST, AS A SEPARATE        ██
-- ██ DECISION. SCRIPT A AND SCRIPT B MUST NEVER BE COMBINED INTO ONE FILE OR ONE RUN.              ██
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
--
-- WHAT IT DOES: set_game_config('encounter_resolver_enabled', true). One key. Nothing else.
-- That completes the QUAD-flag (E0 + E1 + E2 + E3) and process_combat_ticks starts planning encounters
-- from the authored content chain at ACTIVE, BOUND locations. This script writes NO content and touches
-- NO binding — it only reads them to decide whether the flip is safe.
--
-- PRECONDITIONS (read-only; RAISE ⇒ the whole transaction rolls back and nothing is applied):
--   1. Migration head >= 20260618000261 and process_combat_ticks carries the E5 resolved branch.
--   2. E0 + E1 + E2 are already true (the resolver is quad-gated; without them this flip is inert).
--   3. EXACTLY ONE location_encounter_bindings row is active, and it is the canary
--      2f7bcf88-d810-47b4-8e04-748655688b55. Zero active bindings ⇒ Script A has not been run. Two or
--      more ⇒ the canary is not isolated and an unaudited chain would go live with it.
--   4. MIGRATION-0272 / ELITE CONSISTENCY: no ACTIVE binding reaches a fleet member with
--      elite_chance > 0 while the elite stat-wiring migration 20260618000272 is undeployed. E5 (0261)
--      made the resolver ZERO-ELITE — it does not even read elite_chance — so any elite intent would be
--      silently dropped. Once 0272 IS deployed the guard relaxes to that migration's own semantics.
--   5. The canary's cooldown anchor is clear: encounter_runtime_state may already hold a RESIDUAL row
--      for (Reaver, canary_encounter) from the brief 2026-07-22 window. active_count there is a
--      CUMULATIVE spawn counter and is NOT the cap authority (the cap is derived from combat_encounters),
--      but last_spawn_at IS the cooldown anchor: if it is newer than cooldown_seconds ago the first
--      canary spawn would be suppressed. Refused, with the remaining wait printed.
--   6. The derived cap is free: no active/retreating combat_encounters at the location are already
--      tagged with the canary profile.
--
-- BEFORE RUNNING: the READ-ONLY verifier should have returned CANARY_READY_PASS before Script A —
--   DB_URL=… ./scripts/encounter-canary-readiness.sh
--
-- INVOCATION (Management-API compatible: NO psql meta-commands; ONE BEGIN..COMMIT):
--   node scripts/run-activation.mjs scripts/activate-encounter-resolver-canary.sql
--   Or paste into the Supabase Dashboard SQL editor, or psql -X -v ON_ERROR_STOP=1 -f <this file>.
--
-- ██ USE AN EXPENDABLE FLEET. ██ pirate_intercept_enabled and spatial_combat_enabled are both true in
-- production, so the TRIP to the canary location can itself trigger an en-route ambush that has nothing
-- to do with the canary. Never send a fleet you cannot afford to lose. (See
-- docs/ENCOUNTER_CANARY_PACKET.md — "fleet recovery".)
--
-- ROLLBACK: see the clearly-marked ROLLBACK section at the BOTTOM of this file (commented out). It is a
-- single set-to-false; the resolved branch goes inert on the very next tick and combat is byte-identical
-- to today again. No content is lost.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ 0. BEFORE snapshot ══════════
select 'BEFORE' as phase, g.key, g.value
  from public.game_config g
 where g.key in ('encounter_resolver_enabled','enemy_content_registry_enabled',
                 'encounter_authoring_enabled','encounter_binding_authoring_enabled',
                 'spatial_combat_enabled','pirate_intercept_enabled')
 order by g.key;

-- ══════════ 1. PRECONDITIONS (read-only; RAISE ⇒ nothing is applied) ══════════
do $$
declare
  v_canary uuid := '2f7bcf88-d810-47b4-8e04-748655688b55'::uuid;
  v_elite_mig text := '20260618000272';
  v_head text; v_tick text; v_active uuid; n integer; v_elapsed double precision;
  b record; ep record; l record; k text;
begin
  -- (1) deployment surface.
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000261' then
    raise exception 'ACTB FAIL: migration head % < 20260618000261 — the E3/E5 resolver is not deployed', coalesce(v_head, '(none)');
  end if;
  select p.prosrc into v_tick from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_tick is null or position('v_resolver_engaged' in v_tick) = 0
     or position('resolve_location_encounter(e.location_id, e.id::text)' in v_tick) = 0 then
    raise exception 'ACTB FAIL: the deployed process_combat_ticks does not carry the E5 seeded resolved branch';
  end if;

  -- (2) the quad prerequisites.
  foreach k in array array['enemy_content_registry_enabled','encounter_authoring_enabled','encounter_binding_authoring_enabled'] loop
    if not public.cfg_bool(k) then
      raise exception 'ACTB FAIL: % is false — the resolver is QUAD-gated; this flip would be inert', k;
    end if;
  end loop;

  -- (3) EXACTLY ONE active binding, and it is the canary.
  select count(*) into n from public.location_encounter_bindings where active is true;
  if n = 0 then
    raise exception 'ACTB FAIL: NO binding is active — run Script A (scripts/activate-canary-binding.sql) first, as a separate decision';
  end if;
  if n > 1 then
    raise exception 'ACTB FAIL: % bindings are active — the canary is not isolated; lighting the resolver would take every one of them live at once', n;
  end if;
  select id into v_active from public.location_encounter_bindings where active is true;
  if v_active <> v_canary then
    raise exception 'ACTB FAIL: the single active binding is % — it is NOT the audited canary %', v_active, v_canary;
  end if;
  select * into b from public.location_encounter_bindings where id = v_canary;
  select * into ep from public.encounter_profiles where id = b.encounter_profile_id;
  select * into l  from public.locations          where id = b.location_id;
  if ep.id is null or not ep.active then raise exception 'ACTB FAIL: the canary encounter profile is missing or inactive'; end if;
  if l.id is null or l.status is distinct from 'active' then raise exception 'ACTB FAIL: the canary location is missing or not active'; end if;

  -- (4) MIGRATION-0272 / ELITE CONSISTENCY over every ACTIVE binding.
  select count(*) into n
    from public.location_encounter_bindings b2
    join public.locations l2                    on l2.id = b2.location_id and l2.status = 'active'
    join public.encounter_profiles ep2          on ep2.id = b2.encounter_profile_id and ep2.active is true
    join public.encounter_profile_members epm    on epm.encounter_profile_id = ep2.id
    join public.enemy_fleet_templates ft         on ft.id = epm.fleet_template_id and ft.active is true
    join public.enemy_fleet_template_members fm  on fm.fleet_template_id = ft.id
    join public.enemy_archetypes a               on a.id = fm.enemy_archetype_id and a.active is true
   where b2.active is true and fm.elite_chance > 0;
  if n > 0 and v_head < v_elite_mig then
    raise exception 'ACTB FAIL: % active binding(s) reach a fleet member with elite_chance>0, but the elite stat-wiring migration % is NOT deployed (head %). E5 (0261) made the resolver zero-elite — that authored intent would be silently dropped. Zero the elite_chance values, or deploy % first.', n, v_elite_mig, v_head, v_elite_mig;
  end if;
  if n > 0 then
    raise notice 'ACTB_NOTE_ELITE: % active binding(s) carry elite content and head % >= % — the elite path is deployed; confirm that is intended for a canary run', n, v_head, v_elite_mig;
  end if;

  -- (5) the cooldown anchor (residual runtime state).
  select extract(epoch from (now() - s.last_spawn_at)) into v_elapsed
    from public.encounter_runtime_state s
   where s.location_id = b.location_id and s.encounter_profile_id = b.encounter_profile_id;
  if v_elapsed is not null then
    raise notice 'ACTB_NOTE_RUNTIME_STATE: a RESIDUAL encounter_runtime_state row exists for (%, %) — last spawn % second(s) ago, cooldown %s. active_count on that row is a CUMULATIVE spawn counter, NOT a live-encounter count.',
      l.name, ep.key, round(v_elapsed::numeric, 1), ep.cooldown_seconds;
    if ep.cooldown_seconds > 0 and v_elapsed < ep.cooldown_seconds then
      raise exception 'ACTB FAIL: the residual last_spawn_at is INSIDE the % s cooldown window (% s elapsed) — the first canary spawn would be suppressed. Wait % more second(s) and re-run.',
        ep.cooldown_seconds, round(v_elapsed::numeric, 1), ceil(ep.cooldown_seconds - v_elapsed);
    end if;
  end if;

  -- (6) the DERIVED cap must be free.
  select count(*) into n from public.combat_encounters ce
   where ce.location_id = b.location_id and ce.status in ('active','retreating')
     and ce.resolved_plan_json->>'encounter_profile_id' = ep.id::text;
  if n >= ep.active_encounter_cap then
    raise exception 'ACTB FAIL: % combat encounter(s) at % are already tagged with % and the cap is % — the resolver would return NULL and the canary would never spawn', n, l.name, ep.key, ep.active_encounter_cap;
  end if;

  raise notice 'ACTB_PASS_PRECONDITIONS ok: head %, quad prerequisites lit, EXACTLY ONE active binding and it is the canary %, elite/0272 consistent, cooldown anchor clear, derived cap free', v_head, v_canary;
end $$;

-- ══════════ 2. THE EXPECTED COMBAT RESULT (read-only; printed BEFORE the flip) ══════════
do $$
declare
  v_canary uuid := '2f7bcf88-d810-47b4-8e04-748655688b55'::uuid;
  b record; ep record; l record; a record; g jsonb; v_reward uuid;
  v_hp double precision; v_atk double precision; v_metal double precision; v_legacy double precision;
  v_danger integer := 1;
begin
  select * into b  from public.location_encounter_bindings where id = v_canary;
  select * into ep from public.encounter_profiles          where id = b.encounter_profile_id;
  select * into l  from public.locations                   where id = b.location_id;
  select a2.* into a
    from public.encounter_profile_members m
    join public.enemy_fleet_templates ft        on ft.id = m.fleet_template_id and ft.active is true
    join public.enemy_fleet_template_members fm on fm.fleet_template_id = ft.id
    join public.enemy_archetypes a2              on a2.id = fm.enemy_archetype_id and a2.active is true
   where m.encounter_profile_id = ep.id
   order by fm.id limit 1;
  v_reward := coalesce(ep.reward_override_id, a.default_reward_profile_id);
  select rp.resource_grants into g from public.reward_profiles rp where rp.id = v_reward;

  v_hp    := a.base_difficulty * coalesce(public.cfg_num('enemy_hp_base'), 14)
             * (1 + v_danger * coalesce(public.cfg_num('enemy_hp_danger_scale'), 0.6));
  v_atk   := a.base_difficulty * coalesce(public.cfg_num('enemy_attack_base'), 1.0)
             * (1 + v_danger * coalesce(public.cfg_num('enemy_attack_danger_scale'), 0.25));
  v_metal := public.resolve_encounter_reward_inputs(g, l.reward_tier, v_danger);
  v_legacy := round(coalesce(public.cfg_num('reward_metal_base'), 10) * greatest(l.reward_tier, 1)
              * (1 + coalesce(public.cfg_num('reward_danger_scale'), 0.25) * v_danger)
              * coalesce(public.cfg_num('reward_multiplier'), 1.0));

  raise notice '════════ EXPECTED COMBAT RESULT AT % (wave 1, danger %) ════════', l.name, v_danger;
  raise notice '  enemy wave      : 1 x % (unit_type %, archetype base_difficulty %)', a.key, a.unit_type_id, a.base_difficulty;
  raise notice '  enemy hp        : ~%  (before combat_damage_variance_pct)', round(v_hp::numeric, 2);
  raise notice '  enemy attack    : ~%', round(v_atk::numeric, 2);
  raise notice '  reward on clear : % metal  (authored profile; the LEGACY synthetic wave would have paid %)', v_metal, v_legacy;
  raise notice '  legacy wave hp  : ~%  <- what this location spawned BEFORE the canary (location base_difficulty %)',
    round((l.base_difficulty * coalesce(public.cfg_num('enemy_hp_base'), 14) * (1 + v_danger * coalesce(public.cfg_num('enemy_hp_danger_scale'), 0.6)))::numeric, 2), l.base_difficulty;
  raise notice '  cap / cooldown  : % concurrent, % s between spawns', ep.active_encounter_cap, ep.cooldown_seconds;
  raise notice '  HOW TO CONFIRM  : combat_encounters.resolved_plan_json is NON-NULL and tagged encounter_profile_id=%; combat_units holds exactly 1 enemy row', ep.id;
end $$;

-- ══════════ 3. THE WRITE — ██ COMBAT BEHAVIOUR CHANGES ON THIS COMMIT ██ ══════════
do $$
declare v_before text;
begin
  select value #>> '{}' into v_before from public.game_config where key = 'encounter_resolver_enabled';
  if v_before = 'true' then
    raise notice 'ACTB_ALREADY_ON: encounter_resolver_enabled is already true — this re-flip is a no-op';
  end if;
  perform public.set_game_config('encounter_resolver_enabled', 'true'::jsonb);
  raise notice 'ACTB_PASS_WRITE ok: encounter_resolver_enabled % -> true — THE CANARY IS NOW LIVE', coalesce(v_before, '(unset)');
end $$;

-- ══════════ 4. SMOKE (read-only, PRE-COMMIT: a failed assert still rolls the whole act back) ══════════
do $$
declare n integer;
begin
  if not (public.cfg_bool('enemy_content_registry_enabled')
          and public.cfg_bool('encounter_authoring_enabled')
          and public.cfg_bool('encounter_binding_authoring_enabled')
          and public.cfg_bool('encounter_resolver_enabled')) then
    raise exception 'ACTB SMOKE FAIL: the quad-flag is not all-true after the write — the resolver would stay inert';
  end if;
  select count(*) into n from public.location_encounter_bindings where active is true;
  if n <> 1 then
    raise exception 'ACTB SMOKE FAIL: % active binding(s) at commit time (want exactly 1 — the canary)', n;
  end if;
  raise notice 'ACTB_PASS_SMOKE ok: quad-flag all true, exactly one active binding (the canary)';
end $$;

-- ══════════ 5. AFTER snapshot (pre-COMMIT) ══════════
select 'AFTER' as phase, g.key, g.value
  from public.game_config g
 where g.key in ('encounter_resolver_enabled','enemy_content_registry_enabled',
                 'encounter_authoring_enabled','encounter_binding_authoring_enabled',
                 'spatial_combat_enabled','pirate_intercept_enabled')
 order by g.key;

commit;

select 'SCRIPT B PASS — ██ THE ENCOUNTER CANARY IS LIVE ██. encounter_resolver_enabled is true and exactly one binding (the canary) is active. Watch combat_encounters.resolved_plan_json and combat_units at the bound location. ROLLBACK = set encounter_resolver_enabled back to false (see the commented section at the bottom of this file) — the resolved branch goes inert on the next tick and combat is byte-identical again.' as result;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- THE ONE-LINE UNDO for the behaviour change. The quad-flag is no longer all-lit, v_resolver_engaged
-- reads false, the resolved spawn arm becomes unreachable, and combat is byte-identical to pre-canary on
-- the very next tick. World-safe: encounter_runtime_state rows are read only by the (now unreachable)
-- resolved arm, and all authored content persists untouched. This rolls back SCRIPT B ONLY — the binding
-- stays active but inert. To also undo Script A, use the ROLLBACK section of
-- scripts/activate-canary-binding.sql, in that order (B first, then A).
--
-- begin;
-- select public.set_game_config('encounter_resolver_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'encounter_resolver_enabled';
-- commit;
