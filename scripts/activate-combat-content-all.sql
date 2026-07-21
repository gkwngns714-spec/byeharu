-- COMBAT-CONTENT FULL ACTIVATION (E0→E1→E2→E3, ALL FOUR) — a single-transaction convenience flip for a
-- one-shot go-live. It asserts every object across migrations 0257-0260, then flips the four flags IN
-- STRICT DEPENDENCY ORDER (E0, E1, E2, E3) in ONE transaction. STEP-BY-STEP EQUIVALENT: running the four
-- per-flag acts in order (activate-enemy-content-registry → activate-encounter-authoring →
-- activate-encounter-binding → activate-encounter-resolver). See docs/COMBAT_CONTENT_PROGRAM.md.
--
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
-- ██ THIS FLIPS ALL FOUR FLAGS — INCLUDING encounter_resolver_enabled (E3), WHICH MAKES COMBAT LIVE. ██
-- ██ E0/E1/E2 are dark authoring flags (combat byte-identical); E3 is the fourth of the quad-flag read
-- ██ once per tick in process_combat_ticks (v_resolver_engaged) — the moment all four are true the
-- ██ runtime resolver plans encounters from the authored content chain and combat behavior CHANGES at
-- ██ bound, active locations. If you want to light ONLY the authoring surfaces and leave combat unchanged,
-- ██ DO NOT run this file — run the per-flag acts up to E2 and stop.
-- ██ ROLLBACK: set encounter_resolver_enabled to false first (combat byte-identical again in one tick),
-- ██ then optionally the other three. See the commented ROLLBACK section at the bottom.
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT run by CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision for the switch.
--
-- ██ THIS IS AN ACT SCRIPT, NOT A MIGRATION — DO NOT MOVE IT INTO supabase/migrations/ ██
--   An act that RAISES rolls itself back and blocks nothing; the owner fixes the named cause and re-runs.
--
-- ── WHAT IT DOES (ONE transaction; the ORDER is load-bearing) ──────────────────────────────────────
--   1. PRECONDITIONS (read-only; RAISE if unmet): migration head >= 20260618000260 (the whole E0-E3
--      chain is deployed); every E0-E3 object present — the E0 tables + 6 RPCs, the E1 tables + 6 RPCs,
--      the E2 table + 3 RPCs, the E3 resolver fns + process_combat_ticks resolved branch (pinned by
--      prosrc) + encounter_runtime_state; all four config keys present.
--   2. THE WRITES (LAST; ONE DO block, so no execution model can half-flip), in STRICT ORDER:
--        enemy_content_registry_enabled       -> true   (E0)
--        encounter_authoring_enabled          -> true   (E1)
--        encounter_binding_authoring_enabled  -> true   (E2)
--        encounter_resolver_enabled           -> true   (E3 — combat goes live)
--   3. SMOKE (read-only, PRE-COMMIT): all four flags read true through cfg_bool (the value the tick reads).
--   Any failed assert RAISES → the whole transaction rolls back → NOTHING is applied (all-or-nothing).
--
-- Because this single act flips the flags itself in dependency order, it needs no "upstream already-true"
-- guard (the per-flag acts carry those for a staged rollout). Every intermediate state is internal to the
-- one transaction and never observed by the running game.
--
-- RE-RUN SEMANTICS: idempotent. Every write is a set_game_config upsert to a fixed value; re-running after
-- success re-asserts and re-commits identical state. Safe to re-run.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ──────────────
--   node scripts/run-activation.mjs scripts/activate-combat-content-all.sql
--   Or: bash scripts/activate-combat-content-all.sh run ACTIVATE_COMBAT_CONTENT_ALL
--   Or paste into the Supabase Dashboard SQL editor, or psql -X -v ON_ERROR_STOP=1 -f <this file>.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ 1. PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head    text;
  v_missing text;
  v_tick    text;
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000260' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000260 — deploy the whole E0-E3 chain (0257-0260) before activating', coalesce(v_head, '(none)');
  end if;

  -- E0 tables + E1 tables + E2 table + E3 runtime-state table.
  select string_agg(t, ', ') into v_missing
    from unnest(array[
      'public.reward_profiles', 'public.enemy_archetypes',
      'public.enemy_fleet_templates', 'public.enemy_fleet_template_members',
      'public.encounter_profiles', 'public.encounter_profile_members',
      'public.location_encounter_bindings', 'public.encounter_runtime_state']) t
   where to_regclass(t) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: table(s) missing: % (E0-E3 not fully deployed?)', v_missing;
  end if;

  -- every owner RPC across E0 (6) + E1 (6) + E2 (3) + the E3 resolver fns (2) + process_combat_ticks.
  select string_agg(fn, ', ') into v_missing
    from unnest(array[
      'public.reward_profile_create(text,jsonb)', 'public.reward_profile_update(text,jsonb)',
      'public.reward_profile_set_active(text,jsonb)', 'public.enemy_archetype_create(text,jsonb)',
      'public.enemy_archetype_update(text,jsonb)', 'public.enemy_archetype_set_active(text,jsonb)',
      'public.enemy_fleet_template_create(text,jsonb)', 'public.enemy_fleet_template_update(text,jsonb)',
      'public.enemy_fleet_template_set_active(text,jsonb)', 'public.encounter_profile_create(text,jsonb)',
      'public.encounter_profile_update(text,jsonb)', 'public.encounter_profile_set_active(text,jsonb)',
      'public.location_encounter_binding_create(text,jsonb)', 'public.location_encounter_binding_update(text,jsonb)',
      'public.location_encounter_binding_set_active(text,jsonb)',
      'public.resolve_location_encounter(uuid)', 'public.resolve_encounter_reward_inputs(jsonb,integer,integer)',
      'public.process_combat_ticks()']) fn
   where to_regprocedure(fn) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: RPC/function(s) missing: %', v_missing;
  end if;

  -- the deployed process_combat_ticks body must carry the 0260 resolved branch (pinned by prosrc).
  select p.prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_tick is null
     or position('v_resolver_engaged' in v_tick) = 0
     or position('resolve_location_encounter(e.location_id)' in v_tick) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed process_combat_ticks does not carry the 0260 resolved branch — E3 not applied';
  end if;

  -- all four keys must already exist.
  select string_agg(k, ', ') into v_missing
    from unnest(array['enemy_content_registry_enabled', 'encounter_authoring_enabled',
                      'encounter_binding_authoring_enabled', 'encounter_resolver_enabled']) k
   where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  raise notice 'ACTALL_PASS_PRECONDITIONS ok: head % (>= 0260), 8 tables + 17 RPCs/fns present, resolved branch pinned, 4 flag keys present', v_head;
end $$;

-- ══════════ 2. THE WRITES (LAST; ONE block: atomic; STRICT ORDER E0 -> E1 -> E2 -> E3) ══════════
do $$
declare
  v_before text;
  k        text;
begin
  foreach k in array array[
      'enemy_content_registry_enabled',      -- E0
      'encounter_authoring_enabled',         -- E1
      'encounter_binding_authoring_enabled', -- E2
      'encounter_resolver_enabled'] loop     -- E3 (combat goes live)
    select value #>> '{}' into v_before from public.game_config where key = k;
    if v_before = 'true' then
      raise notice 'ACTALL_ALREADY_ON: % is already true — re-flip is a no-op', k;
    end if;
    perform public.set_game_config(k, 'true'::jsonb);
    raise notice 'write: % % -> true', k, coalesce(v_before, '(unset)');
  end loop;
  raise notice 'ACTALL_PASS_WRITES ok: all four flags -> true in strict order E0->E1->E2->E3 (one block, one commit) — THE RESOLVER IS NOW LIVE';
end $$;

-- ══════════ 3. SMOKE (read-only, PRE-COMMIT: a failed assert still rolls the whole act back) ══════
do $$
declare k text;
begin
  foreach k in array array['enemy_content_registry_enabled', 'encounter_authoring_enabled',
                           'encounter_binding_authoring_enabled', 'encounter_resolver_enabled'] loop
    if not public.cfg_bool(k) then
      raise exception 'SMOKE FAIL: cfg_bool(%) is still false', k;
    end if;
    raise notice 'ACTALL_PASS_FLAG %: true (confirmed)', k;
  end loop;
  raise notice 'ACTALL_PASS_SMOKE ok: the quad-flag is all-true through cfg_bool — v_resolver_engaged reads true; combat resolves from authored content';
end $$;

commit;

select 'COMBAT-CONTENT FULL ACTIVATION PASS (E0->E1->E2->E3) — all four flags LIVE. ██ COMBAT BEHAVIOR IS NOW LIVE ██: process_combat_ticks plans encounters from the authored content chain at bound, active locations. ROLLBACK = set encounter_resolver_enabled to false first (combat byte-identical again in one tick), then optionally the other three — see the commented section at the bottom of this file.' as result;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- Undo in the REVERSE / behavior-first order: E3 FIRST (the one-line combat undo — the resolved branch
-- goes inert and combat is byte-identical again on the next tick), then E2, E1, E0 if you want to close
-- the authoring surfaces too. Authored content and encounter_runtime_state rows persist untouched (the
-- resolved arm that reads them is unreachable while E3 is off).
--
-- begin;
-- select public.set_game_config('encounter_resolver_enabled',          'false'::jsonb);  -- E3 first: combat byte-identical again
-- select public.set_game_config('encounter_binding_authoring_enabled', 'false'::jsonb);  -- E2
-- select public.set_game_config('encounter_authoring_enabled',         'false'::jsonb);  -- E1
-- select public.set_game_config('enemy_content_registry_enabled',      'false'::jsonb);  -- E0
-- select key, value from public.game_config
--  where key in ('enemy_content_registry_enabled','encounter_authoring_enabled',
--                'encounter_binding_authoring_enabled','encounter_resolver_enabled')
--  order by key;
-- commit;
