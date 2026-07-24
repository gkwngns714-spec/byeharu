-- ════════════════════════════════════════════════════════════════════════════════════════════════════
-- ENCOUNTER BINDING — AUDIT TRACE (READ-ONLY)
--
-- Answers ONE forensic question: who activated / edited the canary encounter binding
--   2f7bcf88-d810-47b4-8e04-748655688b55  (Reaver ↔ canary_encounter),
-- when, by what command, and whether the actor was an authorized owner (app_owners) or not.
--
-- The readiness verifier proved the binding is active=true revision=3, but docs/ENCOUNTER_CANARY_PACKET.md
-- recorded active=false revision=2 and the owner does not recall changing it. world_editor_audit (0243)
-- records exactly one row per applied World Editor command, with actor / created_at / command_type /
-- before_snapshot / after_snapshot (0244). This SELECT-only trace reads that ledger.
--
-- ██ READ-ONLY: opens `begin transaction read only`, ends in `rollback`. PostgreSQL itself rejects any
-- ██ write. No INSERT/UPDATE/DELETE/DDL. It changes nothing.
-- ════════════════════════════════════════════════════════════════════════════════════════════════════
begin transaction read only;
set local statement_timeout = '30s';

do $$
declare
  v_has_audit boolean := to_regclass('public.world_editor_audit') is not null;
  v_has_owners boolean := to_regclass('public.app_owners') is not null;
begin
  raise notice '════════ ENCOUNTER BINDING AUDIT TRACE — READ-ONLY ════════';
  raise notice 'target binding : 2f7bcf88-d810-47b4-8e04-748655688b55 (Reaver / canary_encounter)';
  raise notice 'database now()  : %', now();
  raise notice 'world_editor_audit present : %', v_has_audit;
  raise notice 'app_owners present         : %', v_has_owners;
end $$;

-- ── 1. current binding row (the state the readiness verifier flagged) ─────────────────────────────
select
  'CURRENT_BINDING' as section,
  b.id, b.active, b.revision, b.weight,
  b.created_at, b.updated_at,
  b.notes,
  l.name as location_name, ep.key as profile_key
from public.location_encounter_bindings b
left join public.locations l on l.id = b.location_id
left join public.encounter_profiles ep on ep.id = b.encounter_profile_id
where b.id = '2f7bcf88-d810-47b4-8e04-748655688b55';

-- ── 2. THE ANSWER: every audit row that touched this binding, oldest → newest ─────────────────────
--    actor_is_owner = was the actor in the app_owners allow-list AT READ TIME (owners are not deleted
--    on de-authorization in this schema, but this still distinguishes an owner actor from a stranger).
select
  'AUDIT_TRAIL' as section,
  a.created_at,
  a.actor,
  exists (select 1 from public.app_owners o where o.user_id = a.actor) as actor_is_owner,
  a.command_type,
  (a.before_snapshot->>'active')   as before_active,
  (a.before_snapshot->>'revision') as before_rev,
  (a.after_snapshot->>'active')    as after_active,
  (a.after_snapshot->>'revision')  as after_rev,
  a.source_revision,
  a.request_id
from public.world_editor_audit a
where a.target_id = '2f7bcf88-d810-47b4-8e04-748655688b55'
   or a.after_snapshot->>'id'  = '2f7bcf88-d810-47b4-8e04-748655688b55'
   or a.before_snapshot->>'id' = '2f7bcf88-d810-47b4-8e04-748655688b55'
order by a.created_at asc;

-- ── 3. the app_owners allow-list (uuids only) so you can recognize the actor ──────────────────────
select 'APP_OWNERS' as section, o.user_id, o.created_at
from public.app_owners o
order by o.created_at asc;

-- ── 4. wider context: ALL encounter-binding audit rows, in case create/update/set_active were split
--    across rows or a different target_id label was used ────────────────────────────────────────────
select
  'ALL_BINDING_AUDIT' as section,
  a.created_at, a.actor,
  exists (select 1 from public.app_owners o where o.user_id = a.actor) as actor_is_owner,
  a.command_type, a.target_id,
  (a.after_snapshot->>'active') as after_active,
  (a.after_snapshot->>'revision') as after_rev
from public.world_editor_audit a
where a.command_type like 'location_encounter_binding%'
order by a.created_at asc;

rollback;
