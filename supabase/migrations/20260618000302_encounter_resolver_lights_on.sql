-- 0302 — ENCOUNTER RESOLVER: LIGHTS ON. The last dark capability flag flips true.
--
-- THE ORDER. The owner, 2026-07-27, after 0300 lit everything else: "don't make anything dark."
-- 0300 deliberately HELD encounter_resolver_enabled dark (it is the one flag with a history of
-- destroying a real asset — the owner's Fleet 1 was lost through the combat-damage path, fixed by
-- 0262). The owner has now given the explicit go to light it too, so it lands here — but as a
-- FAIL-CLOSED assert, not a blind write.
--
-- WHY A MIGRATION AND NOT scripts/activate-encounter-resolver.sql: that act script needs a
-- SUPABASE_ACCESS_TOKEN (Management API) that does not exist on the operator's machine — it lives
-- only as a CI secret. The deploy pipeline is the one path with credentials. This migration therefore
-- carries the act script's PRECONDITIONS + DEPENDENCY GUARD verbatim in intent: if the deployed
-- resolver body is not the sound E3/E5 body, or the quad-chain E0/E1/E2 is not already true, this
-- migration RAISES and the whole deploy rolls back — nothing is lit. That is the correct failure:
-- a resolver that cannot prove itself sound must not go live.
--
-- BLAST RADIUS (verified on prod 2026-07-27 before authoring):
--   • combat_encounters live rows = 0 (nothing in flight).
--   • location_encounter_bindings: ONE active binding — 2f7bcf88 (canary_encounter at Reaver):
--     difficulty 1, cap 1, cooldown 30s, archetype canary_pirate base_difficulty 1, elite_chance 0.
--   • So lighting the resolver activates exactly the DESIGNED low-stakes canary at one location.
--   • The Fleet-1-killing bug (player empty weapons_json -> 0 damage) was fixed by 0262 (deployed).
--
-- ROLLBACK: a simple set-to-false. Flip encounter_resolver_enabled back to false and the resolved
-- branch of process_combat_ticks goes inert again — combat byte-identical, no content lost. The
-- one-liner is in the ROLLBACK block at the bottom (commented).
--
-- SCOPE: one config write via the owned set_game_config writer. No DDL, no function re-create, no
-- grant change, no other config key touched.

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- ══════════ 1. PRECONDITIONS (read-only; no write happens unless all pass) ══════════
do $$
declare
  v_head    text;
  v_missing text;
  v_tick    text;
begin
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000260' then
    raise exception 'PRECONDITION FAIL: migration head % < 20260618000260 — E3 (0260) not deployed', coalesce(v_head, '(none)');
  end if;

  select string_agg(fn, ', ') into v_missing
    from unnest(array[
      'public.resolve_location_encounter(uuid,text)',
      'public.resolve_encounter_reward_inputs(jsonb,integer,integer)',
      'public.process_combat_ticks()']) fn
   where to_regprocedure(fn) is null;
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: E3 function(s) missing: %', v_missing;
  end if;

  if to_regclass('public.encounter_runtime_state') is null then
    raise exception 'PRECONDITION FAIL: public.encounter_runtime_state missing';
  end if;

  -- pin the deployed tick body to the E5 seeded resolved branch (version number alone proves nothing).
  select p.prosrc into v_tick from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_tick is null
     or position('v_resolver_engaged' in v_tick) = 0
     or position('resolve_location_encounter(e.location_id, e.id::text)' in v_tick) = 0 then
    raise exception 'PRECONDITION FAIL: deployed process_combat_ticks lacks the E5 seeded resolved branch — E3/E5 not applied';
  end if;

  select string_agg(k, ', ') into v_missing
    from unnest(array['encounter_resolver_enabled', 'encounter_binding_authoring_enabled',
                      'encounter_authoring_enabled', 'enemy_content_registry_enabled']) k
   where not exists (select 1 from public.game_config g where g.key = k);
  if v_missing is not null then
    raise exception 'PRECONDITION FAIL: game_config key(s) missing: %', v_missing;
  end if;

  raise notice 'E302_PASS_PRECONDITIONS: head % (>=0260), resolver fns + tick (resolved branch pinned) + runtime_state + 4 flag keys present', v_head;
end $$;

-- ══════════ 2. DEPENDENCY GUARD (read-only; RAISE unless E0 AND E1 AND E2 are already true) ══════════
do $$
begin
  if not public.cfg_bool('enemy_content_registry_enabled') then
    raise exception 'DEPENDENCY FAIL: enemy_content_registry_enabled (E0) not true — resolver is quad-gated';
  end if;
  if not public.cfg_bool('encounter_authoring_enabled') then
    raise exception 'DEPENDENCY FAIL: encounter_authoring_enabled (E1) not true — resolver is quad-gated';
  end if;
  if not public.cfg_bool('encounter_binding_authoring_enabled') then
    raise exception 'DEPENDENCY FAIL: encounter_binding_authoring_enabled (E2) not true — resolver is quad-gated';
  end if;
  raise notice 'E302_PASS_DEPENDENCY: E0+E1+E2 already true — flipping E3 completes the quad-flag; resolver goes LIVE';
end $$;

-- ══════════ 3. THE WRITE (via the owned set_game_config writer) ══════════
select public.set_game_config('encounter_resolver_enabled', 'true');

-- ══════════ 4. SMOKE (read-only, PRE-COMMIT) ══════════
do $$
begin
  if not public.cfg_bool('encounter_resolver_enabled') then
    raise exception 'SMOKE FAIL: encounter_resolver_enabled did not read true after the write';
  end if;
  if not (public.cfg_bool('enemy_content_registry_enabled')
          and public.cfg_bool('encounter_authoring_enabled')
          and public.cfg_bool('encounter_binding_authoring_enabled')) then
    raise exception 'SMOKE FAIL: the quad-flag is not all-true after the write';
  end if;
  raise notice 'E302_PASS_SMOKE: encounter_resolver_enabled=true and the E0+E1+E2+E3 quad-flag is all-lit — resolver is LIVE';
end $$;

commit;

-- ══════════ ROLLBACK (commented; run by hand to return combat to byte-identical) ══════════
-- select public.set_game_config('encounter_resolver_enabled', 'false');
