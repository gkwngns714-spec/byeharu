-- ENEMY-CONTENT-REGISTRY ACTIVATION (E0) — the flag flip that lights the enemy_archetypes /
-- reward_profiles OWNER AUTHORING RPCs (migration 0257). This is STEP 1 of 4 in the E0→E1→E2→E3
-- combat-content activation chain (docs/COMBAT_CONTENT_PROGRAM.md).
--
-- ██ HUMAN ACTIVATION TOOL ██ — run BY THE HUMAN, deliberately, against prod. It is NOT run by CI and
-- nothing flips at build/deploy time. Each run of this file IS the recorded human go decision for the
-- server-side switch.
--
-- ██ THIS IS AN ACT SCRIPT, NOT A MIGRATION — DO NOT MOVE IT INTO supabase/migrations/ ██
--   A migration that RAISES wedges the deploy pipeline; an act that RAISES rolls itself back and blocks
--   nothing — the world stays exactly as it was, the owner fixes the named cause and re-runs when ready.
--
-- ── WHAT IT DOES (one transaction; COMMIT only if every assert passes) ────────────────────────────
--   PRECONDITIONS (read-only; no write happens unless all pass):
--     • migration head >= 20260618000257 (E0 is deployed);
--     • both E0 tables exist (reward_profiles, enemy_archetypes);
--     • all SIX E0 owner RPCs exist (reward_profile_create/update/set_active,
--       enemy_archetype_create/update/set_active — each (text, jsonb));
--     • the enemy_content_registry_enabled config key already exists (no typo can invent a key).
--   THE WRITE (via the owned set_game_config writer, 0046):
--     enemy_content_registry_enabled -> true   (the six owner authoring RPCs stop returning 'not_enabled')
--   SMOKE (read-only, PRE-COMMIT): the flag reads true raw AND through cfg_bool (0046) — the value the
--   RPC gates actually read. A failed assert rolls the WHOLE act back — nothing commits.
--   Any failed assert RAISES → the whole transaction rolls back → NOTHING is applied.
--
-- ── SCOPE / WHAT STAYS DARK ───────────────────────────────────────────────────────────────────────
--   E0 is the ROOT of the chain and has NO upstream dependency flag. Turning it on does NOT light E1/E2/E3:
--   the encounter-authoring RPCs (E1) are dual-gated and still return 'not_enabled', and the runtime
--   resolver (E3) stays INERT (its quad-flag is not lit) — combat is byte-identical. E0-on only opens the
--   owner's authoring surface for enemy templates + reward profiles. Even then only an owner (is_owner())
--   can write. NEXT in the chain: scripts/activate-encounter-authoring.sql (E1).
--
-- RE-RUN SEMANTICS: idempotent. set_game_config is an upsert to a fixed value; flipping an already-true
-- flag is a no-op (this act emits an ACTE0_ALREADY_ON notice and still re-asserts + re-commits identical
-- state). Safe to re-run.
--
-- ── WHAT IT DELIBERATELY DOES NOT TOUCH ───────────────────────────────────────────────────────────
--   Any table other than game_config (and that only via set_game_config). Any DDL, any migration, any
--   other window's config key.
--
-- ── INVOCATION (Management-API compatible: NO psql meta-commands; one BEGIN..COMMIT) ──────────────
--   node scripts/run-activation.mjs scripts/activate-enemy-content-registry.sql
--     (the repo's proven prod path on this machine — POST /v1/projects/<ref>/database/query with
--      SUPABASE_ACCESS_TOKEN from .env.local; the final PASS row after COMMIT is the success signal.)
--   Or: bash scripts/activate-enemy-content-registry.sh run ACTIVATE_ENEMY_CONTENT_REGISTRY
--   Or paste this whole file into the Supabase Dashboard SQL editor and run it once, or:
--   psql "<prod conn>" -X -v ON_ERROR_STOP=1 -f scripts/activate-enemy-content-registry.sql
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────────────────────────────
--   See the marked ROLLBACK section at the BOTTOM (commented out). The inverse write restores the exact
--   pre-flip state; the six RPCs return 'not_enabled' again on the next call. No content row is deleted
--   (authored archetypes/profiles persist, inert). If E1/E2/E3 were activated on top of E0, roll THEM
--   back first (top-down: E3 → E2 → E1 → E0) so no downstream flag is left lit over a dark E0.

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
  if v_head is null or v_head < '20260618000257' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000257 — deploy E0 (0257) before activating', coalesce(v_head, '(none)');
  end if;

  -- both E0 catalog tables exist.
  select string_agg(t, ', ') into v_missing
    from unnest(array['public.reward_profiles', 'public.enemy_archetypes']) t
   where to_regclass(t) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: E0 table(s) missing: % (0257 not deployed?)', v_missing;
  end if;

  -- all six E0 owner RPCs exist (by exact signature — 0257 fixed them as (text, jsonb)).
  select string_agg(fn, ', ') into v_missing
    from unnest(array[
      'public.reward_profile_create(text,jsonb)', 'public.reward_profile_update(text,jsonb)',
      'public.reward_profile_set_active(text,jsonb)', 'public.enemy_archetype_create(text,jsonb)',
      'public.enemy_archetype_update(text,jsonb)', 'public.enemy_archetype_set_active(text,jsonb)']) fn
   where to_regprocedure(fn) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: E0 RPC(s) missing: %', v_missing;
  end if;

  -- the key this act writes must already exist (refuse to invent a config row via a typo).
  if not exists (select 1 from public.game_config where key = 'enemy_content_registry_enabled') then
    raise exception 'PRECONDITION FAIL: game_config key enemy_content_registry_enabled missing (0257 seed not present)';
  end if;

  raise notice 'ACTE0_PASS_PRECONDITIONS ok: head % (>= 0257), 2 tables + 6 RPCs present, flag key present', v_head;
end $$;

-- ══════════ 2. THE WRITE (via the owned set_game_config writer, 0046) ══════════
do $$
declare v_before text;
begin
  select value #>> '{}' into v_before from public.game_config where key = 'enemy_content_registry_enabled';
  if v_before = 'true' then
    raise notice 'ACTE0_ALREADY_ON: enemy_content_registry_enabled is already true — re-flip is a no-op';
  end if;
  perform public.set_game_config('enemy_content_registry_enabled', 'true'::jsonb);
  raise notice 'ACTE0_PASS_WRITE ok: enemy_content_registry_enabled % -> true', coalesce(v_before, '(unset)');
end $$;

-- ══════════ 3. SMOKE (read-only, PRE-COMMIT: a failed assert still rolls the whole act back) ══════
do $$
begin
  if (select value #>> '{}' from public.game_config where key = 'enemy_content_registry_enabled') is distinct from 'true' then
    raise exception 'SMOKE FAIL: enemy_content_registry_enabled is not ''true'' after the write';
  end if;
  if not public.cfg_bool('enemy_content_registry_enabled') then
    raise exception 'SMOKE FAIL: cfg_bool(enemy_content_registry_enabled) is still false';
  end if;
  raise notice 'ACTE0_PASS_SMOKE ok: enemy_content_registry_enabled true, readable through cfg_bool — the E0 authoring RPCs are lit for owners';
end $$;

commit;

-- The success signal for the Management-API runner: the LAST statement's rows are what that path returns,
-- and this line is only reachable if every statement above succeeded and committed.
select 'ENEMY-CONTENT-REGISTRY ACTIVATION PASS (E0) — enemy_archetypes/reward_profiles owner RPCs are LIVE (owner-only). E1/E2/E3 remain dark; combat byte-identical. NEXT: scripts/activate-encounter-authoring.sql (E1). Rollback: the commented section at the bottom of this file.' as result;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- Flag-exact and world-safe: the inverse write restores the pre-flip state; the six RPCs return
-- 'not_enabled' again on their next call; authored content rows persist (inert). If E1/E2/E3 are lit,
-- roll them back FIRST (E3 → E2 → E1 → E0) so no downstream flag is left over a dark E0.
--
-- begin;
-- select public.set_game_config('enemy_content_registry_enabled', 'false'::jsonb);
-- select key, value from public.game_config where key = 'enemy_content_registry_enabled';
-- commit;
