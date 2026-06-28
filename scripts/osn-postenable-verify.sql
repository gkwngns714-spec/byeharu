-- OSN-ENABLEMENT-2E — STRICTLY READ-ONLY post-ENABLE production snapshot.
--
-- Independent of the enable operation's own transaction log: this re-reads the LIVE state and emits only
-- `KEY=value` lines for the shell to reconcile into a fail-closed OVERALL_PASS. It NEVER writes, never enables
-- or disables a flag, never calls reveal_starter_ports / a movement command / a writer (the forbidden function
-- names appear ONLY inside single-quoted catalog lookups — to_regprocedure(...) — which return an oid and
-- cannot execute anything). It never creates a player, never prints rows/uuids/coords/secrets. All reads run
-- inside ONE BEGIN ... REPEATABLE READ READ ONLY snapshot that ROLLBACKs.
--
-- It asserts the EXPECTED CURRENT state STRUCTURALLY: head 0069 (Phase-9 docked-port read surface live);
-- three canonical ports active/public;
-- send=true; mainship_space_movement_enabled=TRUE (the inverse of every pre-enable verifier); the
-- authenticated map boundary exposes exactly the three active ports; the OSN command/readiness surface is
-- authenticated-only + ownership-safe (writers/arrival service-role-only, anon denied); the movement-owner
-- exclusivity / idempotency / dock-arrival structure is intact; no fleet holds both a legacy and an OSN
-- movement; and the readiness boundary is present + authenticated with >=2 active destination ports.
--
-- This is a STRUCTURAL / CONFIGURATION proof ONLY. It does NOT prove a concrete live player's
-- osn_available=true (that needs an anchored authenticated session, which a read-only verifier cannot create
-- safely). The live player-journey behavior — readiness osn_available=true, current-port exclusion, eligible
-- destinations, command dispatch, in-transit UI, arrival/dock — is proven by OSN-ENABLEMENT-1B (disposable
-- authenticated journey + rendered PortNavPanel). The two phases together are the complete evidence.
-- It tests BOTH (1) canonical catalog/config state AND (2) the authenticated read boundary (get_world_map +
-- the readiness/command function ACLs).

\set ON_ERROR_STOP on
\pset pager off

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL default_transaction_read_only = on;

SELECT 'RO=' || current_setting('transaction_read_only');

-- ── A. Deployment + flags (POST-ENABLE: space flag is now TRUE) ─────────────────────────────────────────
SELECT 'HEAD='        || coalesce(max(version),'none') FROM supabase_migrations.schema_migrations;
SELECT 'N_AFTER='     || count(*) FROM supabase_migrations.schema_migrations WHERE version > '20260618000069';
SELECT 'FLAG_SEND='   || coalesce(public.cfg_bool('mainship_send_enabled')::int::text,'x');
SELECT 'FLAG_SPACE='  || coalesce(public.cfg_bool('mainship_space_movement_enabled')::int::text,'x');
SELECT 'CONFIG_DEVIATIONS=' || ((CASE WHEN public.cfg_bool('mainship_send_enabled') THEN 0 ELSE 1 END)
                              +  (CASE WHEN public.cfg_bool('mainship_space_movement_enabled') THEN 0 ELSE 1 END));

-- ── B. Canonical starter-port catalog state (the three are ACTIVE) ──────────────────────────────────────
SELECT 'CANON_EXIST='  || count(*) FROM public.locations WHERE id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');
SELECT 'CANON_ACTIVE=' || count(*) FROM public.locations WHERE id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003') AND status='active';
SELECT 'CANON_HIDDEN=' || count(*) FROM public.locations WHERE id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003') AND status='hidden';
SELECT 'P1_OK=' || (EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='b1a00001-0066-4a00-8a00-000000000001' AND l.name='Haven Reach'         AND l.physical_role='city' AND l.status='active' AND l.activity_type='none' AND l.x=-50 AND l.y=-30 AND z.name='Wreck Belt'      AND z.status='active' AND s.name='Outer Haven'   AND s.sector_index=1 AND s.status='active'))::int;
SELECT 'P2_OK=' || (EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='b1a00002-0066-4a00-8a00-000000000002' AND l.name='Slagworks Anchorage' AND l.physical_role='port' AND l.status='active' AND l.activity_type='none' AND l.x=70  AND l.y=-10 AND z.name='Ion Storm Route' AND z.status='active' AND s.name='Crimson Nebula' AND s.sector_index=2 AND s.status='active'))::int;
SELECT 'P3_OK=' || (EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='b1a00003-0066-4a00-8a00-000000000003' AND l.name='Driftmarch Waypost'  AND l.physical_role='port' AND l.status='active' AND l.activity_type='none' AND l.x=10  AND l.y=80  AND z.name='Ion Storm Route' AND z.status='active' AND s.name='Crimson Nebula' AND s.sector_index=2 AND s.status='active'))::int;
SELECT 'N_ROLED='       || count(*) FROM public.locations WHERE physical_role<>'unclassified';
SELECT 'N_ROLED_UNEXP=' || count(*) FROM public.locations WHERE physical_role<>'unclassified' AND id NOT IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');

-- ── C. Authenticated/public map boundary (get_world_map) — exactly the three active ports ───────────────
SELECT 'MAP_CANON_VISIBLE=' || (SELECT count(*) FROM jsonb_path_query(public.get_world_map(), '$.sectors[*].zones[*].locations[*]') AS loc
                                  WHERE (loc->>'id') IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003'));
SELECT 'MAP_UNEXPECTED_STARTER=' || (SELECT count(*) FROM jsonb_path_query(public.get_world_map(), '$.sectors[*].zones[*].locations[*]') AS loc
                                       WHERE (loc->>'id') ~ '^b1a0000[0-9]-0066' AND (loc->>'id') NOT IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003'));
SELECT 'MAP_INACTIVE_LEAK=' || (SELECT count(*) FROM jsonb_path_query(public.get_world_map(), '$.sectors[*].zones[*].locations[*]') AS loc WHERE (loc->>'status') <> 'active');

-- ── D. OSN command surface ACL (authenticated-only + ownership-safe). Forbidden names appear ONLY inside
--       single-quoted to_regprocedure() lookups (oid resolution; cannot execute the function). ──────────
SELECT 'ACL_MOVE_TO_LOC_AUTH=' || coalesce((to_regprocedure('public.command_main_ship_space_move_to_location(uuid,uuid)') is not null
   AND has_function_privilege('authenticated', to_regprocedure('public.command_main_ship_space_move_to_location(uuid,uuid)')::oid, 'EXECUTE'))::int::text,'x');
SELECT 'ACL_WRITER_SVC_ONLY=' || coalesce((to_regprocedure('public.mainship_space_stop(uuid,uuid,uuid)') is not null
   AND NOT has_function_privilege('authenticated', to_regprocedure('public.mainship_space_stop(uuid,uuid,uuid)')::oid, 'EXECUTE')
   AND NOT has_function_privilege('anon',          to_regprocedure('public.mainship_space_stop(uuid,uuid,uuid)')::oid, 'EXECUTE')
   AND has_function_privilege('service_role',      to_regprocedure('public.mainship_space_stop(uuid,uuid,uuid)')::oid, 'EXECUTE'))::int::text,'x');
SELECT 'ACL_DOCK_SVC_ONLY=' || coalesce((to_regprocedure('public.mainship_space_dock_at_location(uuid,uuid)') is not null
   AND NOT has_function_privilege('authenticated', to_regprocedure('public.mainship_space_dock_at_location(uuid,uuid)')::oid, 'EXECUTE')
   AND has_function_privilege('service_role',      to_regprocedure('public.mainship_space_dock_at_location(uuid,uuid)')::oid, 'EXECUTE'))::int::text,'x');
SELECT 'ACL_READINESS_AUTH=' || coalesce((to_regprocedure('public.get_osn_movement_readiness()') is not null
   AND has_function_privilege('authenticated', to_regprocedure('public.get_osn_movement_readiness()')::oid, 'EXECUTE'))::int::text,'x');
SELECT 'ACL_READINESS_ANON_DENIED=' || coalesce((to_regprocedure('public.get_osn_movement_readiness()') is not null
   AND NOT has_function_privilege('anon', to_regprocedure('public.get_osn_movement_readiness()')::oid, 'EXECUTE'))::int::text,'x');
-- dock/arrival structural contract: the arrival processor is service-role-only (auth+anon denied).
SELECT 'ACL_ARRIVAL_SVC_ONLY=' || coalesce((to_regprocedure('public.process_mainship_space_arrivals()') is not null
   AND NOT has_function_privilege('authenticated', to_regprocedure('public.process_mainship_space_arrivals()')::oid, 'EXECUTE')
   AND NOT has_function_privilege('anon',          to_regprocedure('public.process_mainship_space_arrivals()')::oid, 'EXECUTE')
   AND has_function_privilege('service_role',      to_regprocedure('public.process_mainship_space_arrivals()')::oid, 'EXECUTE'))::int::text,'x');
-- PHASE 9 (head 0069): the docked-port READ surface is authenticated-only + PUBLIC/anon denied.
SELECT 'ACL_DOCK_AUTH=' || coalesce((to_regprocedure('public.get_my_current_dock_services()') is not null
   AND has_function_privilege('authenticated', to_regprocedure('public.get_my_current_dock_services()')::oid, 'EXECUTE'))::int::text,'x');
SELECT 'ACL_DOCK_ANON_DENIED=' || coalesce((to_regprocedure('public.get_my_current_dock_services()') is not null
   AND NOT has_function_privilege('anon', to_regprocedure('public.get_my_current_dock_services()')::oid, 'EXECUTE'))::int::text,'x');

-- ── E. Movement-owner exclusivity / idempotency structure (must stay intact once OSN is live) ───────────
SELECT 'STRUCT_EXCL=' || (SELECT count(*) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace nn ON nn.oid=t.relnamespace
   WHERE nn.nspname='public' AND t.relname='fleets' AND c.contype='c'
     AND pg_get_constraintdef(c.oid) ilike '%active_movement_id%' AND pg_get_constraintdef(c.oid) ilike '%active_space_movement_id%');
SELECT 'STRUCT_IDX_SHIP='  || (SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='main_ship_space_movements_one_active_per_ship');
SELECT 'STRUCT_IDX_FLEET=' || (SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='main_ship_space_movements_one_active_per_fleet');
SELECT 'STRUCT_RECEIPT='   || (SELECT count(*) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace nn ON nn.oid=t.relnamespace
   WHERE nn.nspname='public' AND t.relname='main_ship_space_command_receipts' AND c.contype='u' AND pg_get_constraintdef(c.oid) ilike '%request_id%');

-- ── F. No conflicting legacy/OSN movement ownership currently present ────────────────────────────────────
SELECT 'LEGACY_OSN_OVERLAP=' || (SELECT count(*) FROM public.fleets WHERE active_movement_id IS NOT NULL AND active_space_movement_id IS NOT NULL);

-- ── G. Readiness boundary STRUCTURAL fact: >=2 active canonical destination ports exist (so the eligibility
--       computation has destinations). This is a structural count, NOT a live player's osn_available result —
--       the player-journey behavior is proven by OSN-ENABLEMENT-1B.
SELECT 'ELIGIBLE_ACTIVE_PORTS=' || (SELECT count(*) FROM public.locations WHERE id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003') AND status='active');

ROLLBACK;
