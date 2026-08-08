-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- ██ SCRIPT A — ACTIVATE THE ENCOUNTER CANARY BINDING ██
--
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
-- ██ OWNER-RUN ONLY. THIS FILE MUST NOT BE EXECUTED BY AN AGENT, BY CI, OR BY ANY AUTOMATION.      ██
-- ██ IT HAS NOT BEEN EXECUTED. RUNNING IT IS A PRODUCTION WRITE AND IS THE OWNER'S DECISION ALONE. ██
-- ██                                                                                               ██
-- ██ THIS IS APPROVAL 1 OF 2. IT DOES NOT START ANY COMBAT ON ITS OWN.                             ██
-- ██ SCRIPT A ACTIVATES THE BINDING. SCRIPT B LIGHTS THE RESOLVER. THEY ARE TWO SEPARATE OWNER     ██
-- ██ APPROVALS AND MUST NEVER BE COMBINED INTO ONE FILE OR ONE RUN.                                ██
-- ██████████████████████████████████████████████████████████████████████████████████████████████████
--
-- WHAT IT DOES: sets active = true on EXACTLY ONE row of public.location_encounter_bindings —
--   2f7bcf88-d810-47b4-8e04-748655688b55  (Reaver ↔ canary_encounter).
-- Nothing else. No flag. No content. No second row.
--
-- WHY THIS IS SAFE ON ITS OWN: the runtime resolver is QUAD-gated. With encounter_resolver_enabled
-- false, resolve_location_encounter returns NULL before it ever reads a binding (0261, gate (a)), so an
-- active binding is INERT. Combat stays byte-identical to today. The disposable exact-chain proof
-- (.github/workflows/encounter-canary-proof.yml, marker ECP_PASS_BINDING_ONLY_NO_SPAWN) demonstrates
-- exactly this: activating ONLY the binding, with the resolver off, produces no runtime encounter.
--
-- BEFORE RUNNING: run the READ-ONLY verifier and get CANARY_READY_PASS —
--   DB_URL=… ./scripts/encounter-canary-readiness.sh
--
-- PRECONDITIONS (read-only; the UPDATE happens only if EVERY one passes, else the txn rolls back):
--   1. encounter_resolver_enabled is FALSE. (If it is already true, activating a binding is a LIVE
--      combat change with no second gate — refused.)
--   2. NO other binding anywhere is active. (The canary must be the only encounter source.)
--   3. The target binding exists, is currently INACTIVE, and is at revision 2.
--   4. The whole chain re-verifies: location active + hunt_pirates; profile active with cooldown > 0 and
--      cap 1; a non-empty active fleet template; a non-empty template membership; every archetype active
--      with a real unit_type and base_difficulty > 0; the reward profile active, metal-only, base > 0;
--      no reachable elite_chance > 0 while the elite stat-wiring migration (20260618000272) is undeployed.
--   5. The migration head is at least 20260618000261 and process_combat_ticks carries the E5 resolved
--      branch.
--
-- INVOCATION (Management-API compatible: NO psql meta-commands; ONE BEGIN..COMMIT):
--   node scripts/run-activation.mjs scripts/activate-canary-binding.sql
--   Or paste into the Supabase Dashboard SQL editor, or psql -X -v ON_ERROR_STOP=1 -f <this file>.
--
-- ROLLBACK: see the clearly-marked ROLLBACK section at the BOTTOM of this file (commented out). It is a
-- single inverse UPDATE — the binding goes inert again immediately and no content is lost.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════

begin;
set local time zone 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '30s';
set local idle_in_transaction_session_timeout = '60s';

-- ══════════ 0. BEFORE snapshot ══════════
select 'BEFORE' as phase, b.id, b.active, b.revision, b.weight, l.name as location, l.status as location_status,
       ep.key as profile, ep.active as profile_active, ep.cooldown_seconds, ep.active_encounter_cap
  from public.location_encounter_bindings b
  left join public.locations l           on l.id  = b.location_id
  left join public.encounter_profiles ep on ep.id = b.encounter_profile_id
 where b.id = '2f7bcf88-d810-47b4-8e04-748655688b55'::uuid;

-- ══════════ 1. PRECONDITIONS + FULL CHAIN RE-VERIFICATION (read-only; RAISE ⇒ nothing is written) ══════════
do $$
declare
  v_bind  uuid := '2f7bcf88-d810-47b4-8e04-748655688b55'::uuid;
  v_elite_mig text := '20260618000272';
  v_head  text;
  v_tick  text;
  b       record;
  l       record;
  ep      record;
  r       record;
  n       integer;
  v_units integer := 0;
  v_ceiling integer;
  v_reward uuid;
  v_shared uuid;
  v_conflict boolean := false;
  g       jsonb;
  k       text;
begin
  -- (5) deployment surface.
  select max(version)::text into v_head from supabase_migrations.schema_migrations;
  if v_head is null or v_head < '20260618000261' then
    raise exception 'ACTA FAIL: migration head % < 20260618000261 — the E3/E5 resolver is not deployed', coalesce(v_head, '(none)');
  end if;
  select p.prosrc into v_tick from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname = 'public' and p.proname = 'process_combat_ticks';
  if v_tick is null or position('v_resolver_engaged' in v_tick) = 0
     or position('resolve_location_encounter(e.location_id, e.id::text)' in v_tick) = 0 then
    raise exception 'ACTA FAIL: the deployed process_combat_ticks does not carry the E5 seeded resolved branch';
  end if;

  -- (1) the resolver MUST still be dark.
  if public.cfg_bool('encounter_resolver_enabled') then
    raise exception 'ACTA FAIL: encounter_resolver_enabled is TRUE — activating a binding now is an immediate LIVE combat change with no second gate. Set the resolver false first, then run Script A, then Script B.';
  end if;

  -- (3) the target binding.
  select * into b from public.location_encounter_bindings where id = v_bind;
  if not found then
    raise exception 'ACTA FAIL: binding % does not exist', v_bind;
  end if;
  if b.active then
    raise exception 'ACTA FAIL: binding % is ALREADY active — Script A has already been run', v_bind;
  end if;
  if b.revision <> 2 then
    raise exception 'ACTA FAIL: binding % is at revision % (want 2) — it changed since the canary packet was audited; re-run scripts/encounter-canary-readiness.sh and re-audit before activating', v_bind, b.revision;
  end if;

  -- (2) isolation: no OTHER active binding anywhere.
  select count(*) into n from public.location_encounter_bindings where active is true and id <> v_bind;
  if n > 0 then
    raise exception 'ACTA FAIL: % other binding(s) are ALREADY active — the canary would not be isolated. Deactivate them (or re-audit) before activating.', n;
  end if;

  -- (4) chain: location.
  select * into l from public.locations where id = b.location_id;
  if not found then raise exception 'ACTA FAIL: the bound location % does not exist', b.location_id; end if;
  if l.status is distinct from 'active' then
    raise exception 'ACTA FAIL: the bound location % is status % (want active) — the resolver filters to active locations', l.name, l.status;
  end if;
  if l.activity_type is distinct from 'hunt_pirates' then
    raise exception 'ACTA FAIL: the bound location % has activity_type % (want hunt_pirates)', l.name, l.activity_type;
  end if;

  -- (4) chain: encounter profile.
  select * into ep from public.encounter_profiles where id = b.encounter_profile_id;
  if not found then raise exception 'ACTA FAIL: the bound encounter profile % does not exist', b.encounter_profile_id; end if;
  if not ep.active then raise exception 'ACTA FAIL: encounter profile % is INACTIVE', ep.key; end if;
  if ep.cooldown_seconds <= 0 then
    raise exception 'ACTA FAIL: encounter profile % has cooldown_seconds % — a canary MUST be throttled (this is exactly why the pirate_basic chain was rejected)', ep.key, ep.cooldown_seconds;
  end if;
  if ep.active_encounter_cap <> 1 then
    raise exception 'ACTA FAIL: encounter profile % has active_encounter_cap % (want 1 for a canary)', ep.key, ep.active_encounter_cap;
  end if;

  -- (4) chain: at least one ACTIVE fleet template with a non-empty membership.
  select count(*) into n
    from public.encounter_profile_members m
    join public.enemy_fleet_templates ft on ft.id = m.fleet_template_id and ft.active is true
   where m.encounter_profile_id = ep.id;
  if n = 0 then raise exception 'ACTA FAIL: encounter profile % has no ACTIVE fleet template member', ep.key; end if;

  v_ceiling := greatest(1, coalesce(public.cfg_num('enemy_synthetic_max_units'), 6)::integer);
  n := 0;
  for r in
    select fm.id, fm.min_count, fm.max_count, fm.elite_chance, fm.enemy_archetype_id,
           a.key as a_key, a.active as a_active, a.unit_type_id, a.base_difficulty, a.default_reward_profile_id
      from public.encounter_profile_members m
      join public.enemy_fleet_templates ft        on ft.id = m.fleet_template_id and ft.active is true
      join public.enemy_fleet_template_members fm on fm.fleet_template_id = ft.id
      left join public.enemy_archetypes a          on a.id = fm.enemy_archetype_id
     where m.encounter_profile_id = ep.id
  loop
    n := n + 1;
    if r.a_key is null then raise exception 'ACTA FAIL: template member % references a missing archetype %', r.id, r.enemy_archetype_id; end if;
    if not r.a_active then raise exception 'ACTA FAIL: archetype % is INACTIVE', r.a_key; end if;
    if not exists (select 1 from public.unit_types ut where ut.id = r.unit_type_id) then
      raise exception 'ACTA FAIL: archetype % references unknown unit_type_id %', r.a_key, r.unit_type_id;
    end if;
    if r.base_difficulty is null or r.base_difficulty <= 0 then
      raise exception 'ACTA FAIL: archetype % has base_difficulty % (must be > 0)', r.a_key, r.base_difficulty;
    end if;
    if r.min_count is null or r.max_count is null or r.min_count > r.max_count or r.max_count <= 0 then
      raise exception 'ACTA FAIL: template member % has an unusable count range [%, %]', r.id, r.min_count, r.max_count;
    end if;
    if coalesce(r.elite_chance, 0) > 0 and v_head < v_elite_mig then
      raise exception 'ACTA FAIL: template member % carries elite_chance % but the elite stat-wiring migration % is NOT deployed (head %) — the resolver is zero-elite (0261) and would silently drop that authored intent', r.id, r.elite_chance, v_elite_mig, v_head;
    end if;
    v_units := v_units + r.max_count;
    if v_shared is null then v_shared := r.default_reward_profile_id;
    elsif r.default_reward_profile_id is distinct from v_shared then v_conflict := true; end if;
  end loop;
  if n = 0 then raise exception 'ACTA FAIL: the fleet template membership is EMPTY — the resolver would materialise no units'; end if;
  if v_units > v_ceiling then
    raise exception 'ACTA FAIL: the authored fleet can roll % units, above the ceiling % — it would be silently clamped', v_units, v_ceiling;
  end if;

  -- (4) chain: reward.
  if ep.reward_override_id is not null then v_reward := ep.reward_override_id;
  elsif v_conflict then raise exception 'ACTA FAIL: the spawning archetypes carry DIVERGENT default reward profiles with no override — the resolver refuses to pick and the plan would be NULL';
  else v_reward := v_shared; end if;
  select * into r from public.reward_profiles where id = v_reward;
  if not found then raise exception 'ACTA FAIL: reward profile % does not exist', v_reward; end if;
  if not r.active then raise exception 'ACTA FAIL: reward profile % is INACTIVE', r.key; end if;
  g := r.resource_grants;
  if g is null or jsonb_typeof(g) <> 'object' or not (g ? 'metal') then
    raise exception 'ACTA FAIL: reward profile % has no metal entry — the reward adapter would compute NULL', r.key;
  end if;
  for k in select jsonb_object_keys(g) loop
    if k <> 'metal' then
      raise exception 'ACTA FAIL: reward profile % declares resource "%" — only metal is honoured by resolve_encounter_reward_inputs', r.key, k;
    end if;
  end loop;
  if (g->'metal'->>'base') is null or (g->'metal'->>'base')::double precision <= 0 then
    raise exception 'ACTA FAIL: reward profile % metal.base must be > 0', r.key;
  end if;
  if (g->'metal'->>'multiplier_ref') is null
     or not exists (select 1 from public.game_config gc where gc.key = (g->'metal'->>'multiplier_ref')) then
    raise exception 'ACTA FAIL: reward profile % multiplier_ref must name an existing game_config key', r.key;
  end if;

  raise notice 'ACTA_PASS_PRECONDITIONS ok: resolver dark, binding % inactive at revision 2, no other active binding, chain re-verified end to end (location % / profile % cooldown %s cap % / % template member(s) / reward % metal base %)',
    v_bind, l.name, ep.key, ep.cooldown_seconds, ep.active_encounter_cap, n, r.key, (g->'metal'->>'base');
end $$;

-- ══════════ 2. THE WRITE — ONE ROW, ONE COLUMN OF INTENT ══════════
-- The ONLY write in this file. It touches exactly one binding and no other table.
update public.location_encounter_bindings
   set active = true,
       revision = revision + 1,
       updated_at = now()
 where id = '2f7bcf88-d810-47b4-8e04-748655688b55'::uuid
   and active is false;

do $$
declare n integer;
begin
  select count(*) into n from public.location_encounter_bindings
   where id = '2f7bcf88-d810-47b4-8e04-748655688b55'::uuid and active is true;
  if n <> 1 then raise exception 'ACTA FAIL: the binding did not activate (matched % row(s))', n; end if;
  select count(*) into n from public.location_encounter_bindings where active is true;
  if n <> 1 then raise exception 'ACTA FAIL: % binding(s) are active after the write (want exactly 1)', n; end if;
  raise notice 'ACTA_PASS_WRITE ok: exactly ONE binding is active and it is the canary. The resolver is still dark, so this is INERT — no combat has changed.';
end $$;

-- ══════════ 3. AFTER snapshot (pre-COMMIT) ══════════
select 'AFTER' as phase, b.id, b.active, b.revision, b.weight, l.name as location, l.status as location_status,
       ep.key as profile, ep.active as profile_active, ep.cooldown_seconds, ep.active_encounter_cap
  from public.location_encounter_bindings b
  left join public.locations l           on l.id  = b.location_id
  left join public.encounter_profiles ep on ep.id = b.encounter_profile_id
 where b.id = '2f7bcf88-d810-47b4-8e04-748655688b55'::uuid;

commit;

select 'SCRIPT A PASS — the canary binding 2f7bcf88-d810-47b4-8e04-748655688b55 is ACTIVE and is the ONLY active binding. It is INERT: encounter_resolver_enabled is still false, so combat is unchanged. Approval 2 of 2 is scripts/activate-encounter-resolver-canary.sql (Script B) — a SEPARATE decision, never combined with this one.' as result;

-- ════════════════════════════════ ROLLBACK (manual; commented out) ════════════════════════════════
-- The exact inverse of the single UPDATE above. Deactivating the binding makes the canary unreachable
-- to the resolver immediately (the resolver picks only from bindings where active is true, 0261 step
-- (c)); no content is lost and nothing needs unwinding. Safe to run at any time, resolver on or off.
-- If the resolver is currently LIVE, roll Script B back FIRST (it is the behaviour-changing flip), then
-- this.
--
-- begin;
-- update public.location_encounter_bindings
--    set active = false, revision = revision + 1, updated_at = now()
--  where id = '2f7bcf88-d810-47b4-8e04-748655688b55'::uuid
--    and active is true;
-- select id, active, revision from public.location_encounter_bindings
--  where id = '2f7bcf88-d810-47b4-8e04-748655688b55'::uuid;
-- commit;
