-- ENCOUNTER-BINDING ACTIVATION (E2) — the flag flip that lights the location_encounter_bindings OWNER
-- AUTHORING RPCs (migration 0259). STEP 3 of 4 in the E0→E1→E2→E3 combat-content activation chain
-- (docs/COMBAT_CONTENT_PROGRAM.md).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. NOT run by CI; nothing
-- flips at build/deploy time. Each run of this file IS the recorded human go decision for the switch.
--
-- ██ THIS IS AN ACT SCRIPT, NOT A MIGRATION — DO NOT MOVE IT INTO supabase/migrations/ ██
--   An act that RAISES rolls itself back and blocks nothing; the owner fixes the named cause and re-runs.
--
-- ██ DEPENDENCY GUARD ██ — E2's three RPCs are TRI-GATED: each checks cfg_bool(enemy_content_registry_enabled)
--   (E0) AND cfg_bool(encounter_authoring_enabled) (E1) AND cfg_bool(encounter_binding_authoring_enabled)
--   (E2) FIRST (0259). THIS ACT REFUSES to flip unless BOTH E0 AND E1 are ALREADY true. Activate them
--   first, in order: scripts/activate-enemy-content-registry.sql (E0), scripts/activate-encounter-authoring.sql (E1).
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (read-only; no write unless all pass):
--     • migration head >= 20260618000259 (E2 is deployed);
--     • the E2 table exists (location_encounter_bindings);
--     • all THREE E2 owner RPCs exist (location_encounter_binding_create/update/set_active — (text, jsonb));
--     • ALL THREE config keys exist (encounter_binding_authoring_enabled, encounter_authoring_enabled,
--       enemy_content_registry_enabled).
--   DEPENDENCY GUARD (read-only; RAISE if unmet):
--     • cfg_bool(enemy_content_registry_enabled) (E0) AND cfg_bool(encounter_authoring_enabled) (E1) are
--       ALREADY true (the E2→E1→E0 chain — the tri gate).
--   THE WRITE (via the owned set_game_config writer, 0046):
--     encounter_binding_authoring_enabled -> true
--   SMOKE (read-only, PRE-COMMIT): the flag reads true raw AND through cfg_bool, and E0+E1 are still true.
--   Any failed assert RAISES → the whole transaction rolls back → NOTHING is applied.
--
-- ── SCOPE / WHAT STAYS DARK ───────────────────────────────────────────────────────────────────────
--   E2-on opens ONLY the owner's location→encounter binding surface. The runtime resolver (E3) stays
--   INERT (its fourth flag is not lit) — combat is byte-identical. NEXT (and final, the behavior-changing
--   flip): scripts/activate-encounter-resolver.sql (E3).
--
-- RE-RUN SEMANTICS: idempotent. set_game_config upserts to a fixed value; an already-true flag flips as a
-- no-op (emits ACTE2_ALREADY_ON and re-commits identical state). Safe to re-run.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ───────────────────────────────────────────────────────────
--   Any table other than game_config (via set_game_config only). Any DDL, any migration, any other
--   window's config key. It never turns E0/E1 on for you — they are preconditions, not side effects.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ──────────────
--   node scripts/run-activation.mjs scripts/activate-encounter-binding.sql
--   Or: bash scripts/activate-encounter-binding.sh run ACTIVATE_ENCOUNTER_BINDING
--   Or paste into the Supabase Dashboard SQL editor, or psql -X -v ON_ERROR_STOP=1 -f <this file>.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). The inverse write restores the pre-flip
--   state; the three RPCs return 'not_enabled' again; authored bindings persist (inert). If E3 is lit,
--   roll it back FIRST (E3 → E2) so the resolver's quad gate is never left lit over a dark E2.

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
  if v_head is null or v_head < '20260618000259' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000259 — deploy E2 (0259) before activating', coalesce(v_head, '(none)');
  end if;

  -- the E2 binding table exists.
  if to_regclass('public.location_encounter_bindings') is null then
    raise exception 'PRECONDITION FAIL: public.location_encounter_bindings missing (0259 not deployed?)';
  end if;

  -- all three E2 owner RPCs exist.
  select string_agg(fn, ', ') into v_missing
    from unnest(array[
      'public.location_encounter_binding_create(text,jsonb)',
      'public.location_encounter_binding_update(text,jsonb)',
      'public.location_encounter_binding_set_active(text,jsonb)']) fn
   where to_regprocedure(fn) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: E2 RPC(s) missing: %', v_missing;
  end if;

  -- all three keys this act reads/writes must already exist.
  select string_agg(k, ', ') into v_missing
    from unnest(array['encounter_binding_authoring_enabled', 'encounter_authoring_enabled',
                      'enemy_content_registry_enabled']) k
   where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  raise notice 'ACTE2_PASS_PRECONDITIONS ok: head % (>= 0259), binding table + 3 RPCs present, 3 flag keys present', v_head;
end $$;

-- ══════════ 2. DEPENDENCY GUARD (read-only; RAISE unless E0 AND E1 are already live) ══════════
do $$
begin
  if not public.cfg_bool('enemy_content_registry_enabled') then
    raise exception 'DEPENDENCY FAIL: enemy_content_registry_enabled (E0) is not true — E2 is TRI-GATED on E0 AND E1 AND E2; activate E0 first (scripts/activate-enemy-content-registry.sql)';
  end if;
  if not public.cfg_bool('encounter_authoring_enabled') then
    raise exception 'DEPENDENCY FAIL: encounter_authoring_enabled (E1) is not true — E2 is TRI-GATED on E0 AND E1 AND E2; activate E1 first (scripts/activate-encounter-authoring.sql)';
  end if;
  raise notice 'ACTE2_PASS_DEPENDENCY ok: E0 + E1 are already true — the tri gate is satisfiable';
end $$;

-- ══════════ 3. THE WRITE (via the owned set_game_config writer, 0046) ══════════
do $$
declare v_before text;
begin
  select value #>> '{}' into v_before from public.game_config where key = 'encounter_binding_authoring_enabled';
  if v_before = 'true' then
    raise notice 'ACTE2_ALREADY_ON: encounter_binding_authoring_enabled is already true — re-flip is a no-op';
  end if;
  perform public.set_game_config('encounter_binding_authoring_enabled', 'true'::jsonb);
  raise notice 'ACTE2_PASS_WRITE ok: encounter_binding_authoring_enabled % -> true', coalesce(v_before, '(unset)');
end $$;

-- ══════════ 4. SMOKE (read-only, PRE-COMMIT: a failed assert still rolls the whole act back) ══════
do $$
begin
  if (select value #>> '{}' from public.game_config where key = 'encounter_binding_authoring_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: encounter_binding_authoring_enabled is not ''true'' after the write';
  end if;
  if not public.cfg_bool('encounter_binding_authoring_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(encounter_binding_authoring_enabled) is still false';
  end if;
  if not public.cfg_bool('enemy_content_registry_enabled') or not public.cfg_bool('encounter_authoring_enabled') then
    raise exception 'SMOKE FAIL: E0 or E1 went false during the act — the tri gate would reject';
  end if;
  raise notice 'ACTE2_PASS_SMOKE ok: encounter_binding_authoring_enabled true (with E0+E1 still true) — the E2 binding RPCs are lit for owners';
end $$;

commit;

select 'ENCOUNTER-BINDING ACTIVATION PASS (E2) — location_encounter_bindings owner RPCs are LIVE (owner-only; tri-gated on E0+E1). E3 (the runtime resolver) remains INERT; combat byte-identical. NEXT (the behavior-changing flip): scripts/activate-encounter-resolver.sql (E3). Rollback: the commented section at the bottom of this file.' as result;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- Flag-exact and world-safe: the inverse write restores the pre-flip state; the three RPCs return
-- 'not_enabled' again; authored bindings persist (inert). If E3 is lit, roll it back FIRST (E3 → E2) so
-- the resolver's quad gate is never left lit over a dark E2 (harmless — E3 fails closed — but keep the
-- chain consistent).
--
-- begin;
-- select public.set_game_config('encounter_binding_authoring_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'encounter_binding_authoring_enabled';
-- commit;
