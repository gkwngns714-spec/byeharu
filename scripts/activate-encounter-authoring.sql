-- ENCOUNTER-AUTHORING ACTIVATION (E1) — the flag flip that lights the fleet-template / encounter-profile
-- OWNER AUTHORING RPCs (migration 0258). STEP 2 of 4 in the E0→E1→E2→E3 combat-content activation chain
-- (docs/COMBAT_CONTENT_PROGRAM.md).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT run by CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision for the switch.
--
-- ██ THIS IS AN ACT SCRIPT, NOT A MIGRATION — DO NOT MOVE IT INTO supabase/migrations/ ██
--   An act that RAISES rolls itself back and blocks nothing; the world stays as it was, the owner fixes
--   the named cause and re-runs when ready.
--
-- ██ DEPENDENCY GUARD ██ — E1's six RPCs are DUAL-GATED: each checks cfg_bool(enemy_content_registry_enabled)
--   (E0) AND cfg_bool(encounter_authoring_enabled) (E1) FIRST (0258). Lighting E1 while E0 is dark would
--   author encounter content whose RPCs still reject — so THIS ACT REFUSES to flip unless E0 is ALREADY
--   true. Activate E0 first: scripts/activate-enemy-content-registry.sql.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (read-only; no write unless all pass):
--     • migration head >= 20260618000258 (E1 is deployed);
--     • all FOUR E1 tables exist (enemy_fleet_templates + _members, encounter_profiles + _members);
--     • all SIX E1 owner RPCs exist (enemy_fleet_template_create/update/set_active,
--       encounter_profile_create/update/set_active — each (text, jsonb));
--     • BOTH config keys exist (encounter_authoring_enabled, enemy_content_registry_enabled).
--   DEPENDENCY GUARD (read-only; RAISE if unmet):
--     • cfg_bool(enemy_content_registry_enabled) is ALREADY true (E0 must be live — the dual gate).
--   THE WRITE (via the owned set_game_config writer, 0046):
--     encounter_authoring_enabled -> true
--   SMOKE (read-only, PRE-COMMIT): the flag reads true raw AND through cfg_bool, and E0 is still true.
--   Any failed assert RAISES → the whole transaction rolls back → NOTHING is applied.
--
-- ── SCOPE / WHAT STAYS DARK ───────────────────────────────────────────────────────────────────────
--   E1-on opens ONLY the owner's fleet/encounter authoring surface. E2 (location bindings) still returns
--   'not_enabled' (tri-gated), and the runtime resolver (E3) stays INERT — combat is byte-identical.
--   NEXT in the chain: scripts/activate-encounter-binding.sql (E2).
--
-- RE-RUN SEMANTICS: idempotent. set_game_config upserts to a fixed value; an already-true flag flips as a
-- no-op (emits ACTE1_ALREADY_ON and re-commits identical state). Safe to re-run.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ───────────────────────────────────────────────────────────
--   Any table other than game_config (via set_game_config only). Any DDL, any migration, any other
--   window's config key. It never turns E0 on for you — E0 is a precondition, not a side effect.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ──────────────
--   node scripts/run-activation.mjs scripts/activate-encounter-authoring.sql
--   Or: bash scripts/activate-encounter-authoring.sh run ACTIVATE_ENCOUNTER_AUTHORING
--   Or paste into the Supabase Dashboard SQL editor, or psql -X -v ON_ERROR_STOP=1 -f <this file>.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). The inverse write restores the pre-flip
--   state; the six RPCs return 'not_enabled' again; authored content persists (inert). If E2/E3 are lit,
--   roll them back FIRST (E3 → E2 → E1) so no downstream flag is left over a dark E1.

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
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000258' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000258 — deploy E1 (0258) before activating', coalesce(v_head, '(none)');
  end if;

  -- all four E1 tables exist.
  select string_agg(t, ', ') into v_missing
    from unnest(array['public.enemy_fleet_templates', 'public.enemy_fleet_template_members',
                      'public.encounter_profiles', 'public.encounter_profile_members']) t
   where to_regclass(t) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: E1 table(s) missing: % (0258 not deployed?)', v_missing;
  end if;

  -- all six E1 owner RPCs exist.
  select string_agg(fn, ', ') into v_missing
    from unnest(array[
      'public.enemy_fleet_template_create(text,jsonb)', 'public.enemy_fleet_template_update(text,jsonb)',
      'public.enemy_fleet_template_set_active(text,jsonb)', 'public.encounter_profile_create(text,jsonb)',
      'public.encounter_profile_update(text,jsonb)', 'public.encounter_profile_set_active(text,jsonb)']) fn
   where to_regprocedure(fn) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: E1 RPC(s) missing: %', v_missing;
  end if;

  -- both keys this act reads/writes must already exist.
  select string_agg(k, ', ') into v_missing
    from unnest(array['encounter_authoring_enabled', 'enemy_content_registry_enabled']) k
   where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  raise notice 'ACTE1_PASS_PRECONDITIONS ok: head % (>= 0258), 4 tables + 6 RPCs present, 2 flag keys present', v_head;
end $$;

-- ══════════ 2. DEPENDENCY GUARD (read-only; RAISE if E0 is not already live) ══════════
do $$
begin
  if not public.cfg_bool('enemy_content_registry_enabled') then
    raise exception 'DEPENDENCY FAIL: enemy_content_registry_enabled (E0) is not true — E1''s RPCs are DUAL-GATED on E0 AND E1; activate E0 first (scripts/activate-enemy-content-registry.sql), then re-run this act';
  end if;
  raise notice 'ACTE1_PASS_DEPENDENCY ok: E0 (enemy_content_registry_enabled) is already true — the dual gate is satisfiable';
end $$;

-- ══════════ 3. THE WRITE (via the owned set_game_config writer, 0046) ══════════
do $$
declare v_before text;
begin
  select value #>> '{}' into v_before from public.game_config where key = 'encounter_authoring_enabled';
  if v_before = 'true' then
    raise notice 'ACTE1_ALREADY_ON: encounter_authoring_enabled is already true — re-flip is a no-op';
  end if;
  perform public.set_game_config('encounter_authoring_enabled', 'true'::jsonb);
  raise notice 'ACTE1_PASS_WRITE ok: encounter_authoring_enabled % -> true', coalesce(v_before, '(unset)');
end $$;

-- ══════════ 4. SMOKE (read-only, PRE-COMMIT: a failed assert still rolls the whole act back) ══════
do $$
begin
  if (select value #>> '{}' from public.game_config where key = 'encounter_authoring_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: encounter_authoring_enabled is not ''true'' after the write';
  end if;
  if not public.cfg_bool('encounter_authoring_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(encounter_authoring_enabled) is still false';
  end if;
  if not public.cfg_bool('enemy_content_registry_enabled') then
    raise exception 'SMOKE FAIL: E0 (enemy_content_registry_enabled) went false during the act — the dual gate would reject';
  end if;
  raise notice 'ACTE1_PASS_SMOKE ok: encounter_authoring_enabled true (with E0 still true) — the E1 authoring RPCs are lit for owners';
end $$;

commit;

select 'ENCOUNTER-AUTHORING ACTIVATION PASS (E1) — fleet-template/encounter-profile owner RPCs are LIVE (owner-only; dual-gated on E0). E2/E3 remain dark; combat byte-identical. NEXT: scripts/activate-encounter-binding.sql (E2). Rollback: the commented section at the bottom of this file.' as result;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- Flag-exact and world-safe: the inverse write restores the pre-flip state; the six RPCs return
-- 'not_enabled' again; authored content persists (inert). If E2/E3 are lit, roll them back FIRST
-- (E3 → E2 → E1). Leaving E1 off while E2/E3 stay on would strand the tri/quad gate (harmless — they
-- fail closed — but the chain would be inconsistent).
--
-- begin;
-- select public.set_game_config('encounter_authoring_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'encounter_authoring_enabled';
-- commit;
