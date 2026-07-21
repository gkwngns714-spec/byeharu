-- ENCOUNTER-RESOLVER ACTIVATION (E3) — ██ THE ONE FLIP THAT CHANGES COMBAT BEHAVIOR ██. Lighting this
-- flag completes the QUAD-FLAG that makes the runtime resolver in process_combat_ticks LIVE (migration
-- 0260). STEP 4 of 4 (final) in the E0→E1→E2→E3 combat-content activation chain
-- (docs/COMBAT_CONTENT_PROGRAM.md).
--
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
-- ██ THIS IS THE BEHAVIOR-CHANGING FLIP. E0/E1/E2 opened only OWNER AUTHORING surfaces and left combat
-- ██ byte-identical. THIS flag is the fourth and last of the quad-flag read once per tick in
-- ██ process_combat_ticks (v_resolver_engaged, 0260:494-497). While ANY of the four is false the resolved
-- ██ spawn arm is UNREACHABLE and combat is byte-identical to pre-E3. The moment all four are true, the
-- ██ resolver plans encounters from the authored content chain (archetypes → fleets → encounters →
-- ██ location bindings) and combat behavior at bound, active locations CHANGES.
-- ██ ROLLBACK IS A SIMPLE SET-TO-FALSE: flip encounter_resolver_enabled back to false and the resolved
-- ██ branch goes INERT again — combat is byte-identical once more. No content is lost; nothing to unwind.
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT run by CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision for the switch.
--
-- ██ THIS IS AN ACT SCRIPT, NOT A MIGRATION — DO NOT MOVE IT INTO supabase/migrations/ ██
--   An act that RAISES rolls itself back and blocks nothing; the owner fixes the named cause and re-runs.
--
-- ██ DEPENDENCY GUARD ██ — the resolver is QUAD-GATED (0260:181-186 and process_combat_ticks
--   :494-497): E0 AND E1 AND E2 AND E3 must all be true or the resolved branch returns NULL / stays inert.
--   THIS ACT REFUSES to flip unless E0 AND E1 AND E2 are ALREADY true. Activate them first, in order:
--   E0 (activate-enemy-content-registry.sql) → E1 (activate-encounter-authoring.sql) →
--   E2 (activate-encounter-binding.sql).
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (read-only; no write unless all pass):
--     • migration head >= 20260618000260 (E3 is deployed);
--     • the two E3 resolver functions exist: resolve_location_encounter(uuid),
--       resolve_encounter_reward_inputs(jsonb, integer, integer);
--     • process_combat_ticks() exists AND its body carries the resolved branch — the prosrc references
--       v_resolver_engaged AND resolve_location_encounter(e.location_id) (the 0260 resolved arm, not a
--       pre-E3 body wearing the same version number);
--     • the encounter_runtime_state table exists (the resolver's cooldown/active_count anchor);
--     • ALL FOUR config keys exist.
--   DEPENDENCY GUARD (read-only; RAISE if unmet):
--     • cfg_bool(enemy_content_registry_enabled) (E0) AND cfg_bool(encounter_authoring_enabled) (E1) AND
--       cfg_bool(encounter_binding_authoring_enabled) (E2) are ALREADY true (the quad chain).
--   THE WRITE (via the owned set_game_config writer, 0046):
--     encounter_resolver_enabled -> true   ← THIS lights the resolver; combat behavior changes.
--   SMOKE (read-only, PRE-COMMIT): the flag reads true raw AND through cfg_bool, and E0+E1+E2 are still
--   true (so the quad-flag is genuinely all-lit).
--   Any failed assert RAISES → the whole transaction rolls back → NOTHING is applied.
--
-- RE-RUN SEMANTICS: idempotent. set_game_config upserts to a fixed value; an already-true flag flips as a
-- no-op (emits ACTE3_ALREADY_ON and re-commits identical state). Safe to re-run.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ───────────────────────────────────────────────────────────
--   Any table other than game_config (via set_game_config only). Any DDL, any migration, any other
--   window's config key. It never turns E0/E1/E2 on for you — they are preconditions, not side effects.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ──────────────
--   node scripts/run-activation.mjs scripts/activate-encounter-resolver.sql
--   Or: bash scripts/activate-encounter-resolver.sh run ACTIVATE_ENCOUNTER_RESOLVER
--   Or paste into the Supabase Dashboard SQL editor, or psql -X -v ON_ERROR_STOP=1 -f <this file>.
--   Recommended: observe combat at a bound, active location immediately after the flip, and keep the
--   one-line rollback below at hand — it returns combat to byte-identical instantly.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). A SIMPLE SET-TO-FALSE: the resolved
--   branch goes inert and combat is byte-identical again. World-safe: encounter_runtime_state rows are
--   read only by the resolved arm (unreachable while off) and authored content persists untouched.

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
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000260 — deploy E3 (0260) before activating', coalesce(v_head, '(none)');
  end if;

  -- the two resolver functions + the recreated combat tick fn exist (by exact signature).
  select string_agg(fn, ', ') into v_missing
    from unnest(array[
      'public.resolve_location_encounter(uuid)',
      'public.resolve_encounter_reward_inputs(jsonb,integer,integer)',
      'public.process_combat_ticks()']) fn
   where to_regprocedure(fn) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: E3 function(s) missing: % (0260 not deployed?)', v_missing;
  end if;

  -- the resolver's runtime-state anchor table exists.
  if to_regclass('public.encounter_runtime_state') is null then
    raise exception 'PRECONDITION FAIL: public.encounter_runtime_state missing (0260 not deployed?)';
  end if;

  -- the deployed process_combat_ticks body must carry the 0260 RESOLVED BRANCH — the version number
  -- alone proves nothing about WHICH body landed. Pin it by prosrc: the resolver-engaged quad read
  -- (v_resolver_engaged) AND the resolved spawn call (resolve_location_encounter(e.location_id)).
  select p.prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_tick is null
     or position('v_resolver_engaged' in v_tick) = 0
     or position('resolve_location_encounter(e.location_id)' in v_tick) = 0 then
    raise exception 'PRECONDITION FAIL: the deployed process_combat_ticks does not carry the 0260 resolved branch (no v_resolver_engaged / resolve_location_encounter(e.location_id)) — E3 not applied';
  end if;

  -- all four keys must already exist.
  select string_agg(k, ', ') into v_missing
    from unnest(array['encounter_resolver_enabled', 'encounter_binding_authoring_enabled',
                      'encounter_authoring_enabled', 'enemy_content_registry_enabled']) k
   where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  raise notice 'ACTE3_PASS_PRECONDITIONS ok: head % (>= 0260), 2 resolver fns + process_combat_ticks (resolved branch pinned by prosrc) + encounter_runtime_state present, 4 flag keys present', v_head;
end $$;

-- ══════════ 2. DEPENDENCY GUARD (read-only; RAISE unless E0 AND E1 AND E2 are already live) ══════════
do $$
begin
  if not public.cfg_bool('enemy_content_registry_enabled') then
    raise exception 'DEPENDENCY FAIL: enemy_content_registry_enabled (E0) is not true — the resolver is QUAD-GATED on E0+E1+E2+E3; activate E0 first (scripts/activate-enemy-content-registry.sql)';
  end if;
  if not public.cfg_bool('encounter_authoring_enabled') then
    raise exception 'DEPENDENCY FAIL: encounter_authoring_enabled (E1) is not true — the resolver is QUAD-GATED; activate E1 first (scripts/activate-encounter-authoring.sql)';
  end if;
  if not public.cfg_bool('encounter_binding_authoring_enabled') then
    raise exception 'DEPENDENCY FAIL: encounter_binding_authoring_enabled (E2) is not true — the resolver is QUAD-GATED; activate E2 first (scripts/activate-encounter-binding.sql)';
  end if;
  raise notice 'ACTE3_PASS_DEPENDENCY ok: E0 + E1 + E2 are already true — flipping E3 completes the quad-flag and the resolver goes LIVE';
end $$;

-- ══════════ 3. THE WRITE — ██ COMBAT BEHAVIOR CHANGES ON THIS COMMIT ██ (via set_game_config, 0046) ══
do $$
declare v_before text;
begin
  select value #>> '{}' into v_before from public.game_config where key = 'encounter_resolver_enabled';
  if v_before = 'true' then
    raise notice 'ACTE3_ALREADY_ON: encounter_resolver_enabled is already true — re-flip is a no-op (resolver was already live)';
  end if;
  perform public.set_game_config('encounter_resolver_enabled', 'true'::jsonb);
  raise notice 'ACTE3_PASS_WRITE ok: encounter_resolver_enabled % -> true — THE RESOLVER IS NOW LIVE (combat at bound, active locations plans from authored content)', coalesce(v_before, '(unset)');
end $$;

-- ══════════ 4. SMOKE (read-only, PRE-COMMIT: a failed assert still rolls the whole act back) ══════
do $$
begin
  if (select value #>> '{}' from public.game_config where key = 'encounter_resolver_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: encounter_resolver_enabled is not ''true'' after the write';
  end if;
  if not (public.cfg_bool('enemy_content_registry_enabled')
          and public.cfg_bool('encounter_authoring_enabled')
          and public.cfg_bool('encounter_binding_authoring_enabled')
          and public.cfg_bool('encounter_resolver_enabled')) then
    raise exception 'SMOKE FAIL: the quad-flag is not all-true after the write — the resolver would stay inert';
  end if;
  raise notice 'ACTE3_PASS_SMOKE ok: all four flags true through cfg_bool — v_resolver_engaged reads true; the resolved branch is LIVE';
end $$;

commit;

select 'ENCOUNTER-RESOLVER ACTIVATION PASS (E3) — ██ COMBAT BEHAVIOR IS NOW LIVE ██. All four flags are true; process_combat_ticks plans encounters from the authored content chain at bound, active locations. ROLLBACK = set encounter_resolver_enabled to false (the resolved branch goes inert; combat byte-identical again) — see the commented section at the bottom of this file.' as result;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- THE ONE-LINE UNDO for the behavior change: set encounter_resolver_enabled back to false. The quad-flag
-- is no longer all-lit, so v_resolver_engaged reads false, the resolved spawn arm is unreachable, and
-- combat is byte-identical to pre-E3 on the very next tick. World-safe: encounter_runtime_state rows are
-- read only by the (now unreachable) resolved arm; authored content persists untouched. Leaving E0/E1/E2
-- on after this rollback is fine — they are dark AUTHORING flags with no combat effect.
--
-- begin;
-- select public.set_game_config('encounter_resolver_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'encounter_resolver_enabled';
-- commit;
