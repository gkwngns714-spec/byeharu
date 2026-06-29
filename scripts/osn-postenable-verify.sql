-- OSN-ENABLEMENT-2E — STRICTLY READ-ONLY post-ENABLE production snapshot.
--
-- Independent of the enable operation's own transaction log: this re-reads the LIVE state and emits only
-- `KEY=value` lines for the shell to reconcile into a fail-closed OVERALL_PASS. It NEVER writes, never enables
-- or disables a flag, never calls reveal_starter_ports / a movement command / a writer (the forbidden function
-- names appear ONLY inside single-quoted catalog lookups — to_regprocedure(...) — which return an oid and
-- cannot execute anything). It never creates a player, never prints rows/uuids/coords/secrets. All reads run
-- inside ONE BEGIN ... REPEATABLE READ READ ONLY snapshot that ROLLBACKs.
--
-- It asserts the EXPECTED CURRENT state STRUCTURALLY: head 0070 (OSN-COORD-GATE-1 deployed; the Phase-9
-- docked-port read surface remains live); three canonical ports active/public;
-- send=true; mainship_space_movement_enabled=TRUE (the inverse of every pre-enable verifier);
-- mainship_coordinate_travel_enabled=FALSE — read from the authoritative DB, with a fail-closed integrity
-- guard (the row must exist EXACTLY once and parse as a JSON boolean; cfg_bool() alone would mask a missing
-- row as false); the authenticated map boundary exposes exactly the three active ports; the OSN
-- command/readiness surface is authenticated-only + ownership-safe (writers/arrival service-role-only, anon
-- denied); the arbitrary-coordinate command (command_main_ship_space_move) is the ONLY public raw-coordinate
-- entry point and is authenticated-only with its raw coordinate writers service-role-only; the movement-owner
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

-- ── A. Deployment head (now 0070 — OSN-COORD-GATE-1) + fail-closed tracked-flag integrity ───────────────
SELECT 'HEAD='        || coalesce(max(version),'none') FROM supabase_migrations.schema_migrations;
SELECT 'N_AFTER='     || count(*) FROM supabase_migrations.schema_migrations WHERE version > '20260618000070';

-- A1. Fail-closed flag INTEGRITY. game_config.key is a PRIMARY KEY, so each key is present 0 or 1 times; we
--     require EXACTLY ONE row whose jsonb value extracts to a literal boolean ('true'/'false'). cfg_bool()
--     alone is INSUFFICIENT here: it coalesces a MISSING row to false, masking absence — these guards close
--     that, so a deleted/duplicated/non-boolean row fails the verification instead of reading as a silent false.
SELECT 'SEND_ROWS='  || count(*) FROM public.game_config WHERE key='mainship_send_enabled';
SELECT 'SPACE_ROWS=' || count(*) FROM public.game_config WHERE key='mainship_space_movement_enabled';
SELECT 'COORD_ROWS=' || count(*) FROM public.game_config WHERE key='mainship_coordinate_travel_enabled';
SELECT 'SEND_BOOL='  || coalesce((SELECT ((value #>> '{}') IN ('true','false'))::int::text FROM public.game_config WHERE key='mainship_send_enabled'),'0');
SELECT 'SPACE_BOOL=' || coalesce((SELECT ((value #>> '{}') IN ('true','false'))::int::text FROM public.game_config WHERE key='mainship_space_movement_enabled'),'0');
SELECT 'COORD_BOOL=' || coalesce((SELECT ((value #>> '{}') IN ('true','false'))::int::text FROM public.game_config WHERE key='mainship_coordinate_travel_enabled'),'0');

-- A2. Actual stored LIVE values, read from the authoritative DB ONLY (never inferred from migration text /
--     workflow logs / source code / defaults / the frontend constant). Extracted WITHOUT a throwing cast:
--     only a real boolean literal yields 1/0; a missing or non-boolean value yields 'x' (→ fail-closed below).
SELECT 'FLAG_SEND='  || coalesce((SELECT CASE WHEN (value #>> '{}') IN ('true','false') THEN ((value #>> '{}')::boolean)::int::text ELSE 'x' END FROM public.game_config WHERE key='mainship_send_enabled'),'x');
SELECT 'FLAG_SPACE=' || coalesce((SELECT CASE WHEN (value #>> '{}') IN ('true','false') THEN ((value #>> '{}')::boolean)::int::text ELSE 'x' END FROM public.game_config WHERE key='mainship_space_movement_enabled'),'x');
SELECT 'FLAG_COORD=' || coalesce((SELECT CASE WHEN (value #>> '{}') IN ('true','false') THEN ((value #>> '{}')::boolean)::int::text ELSE 'x' END FROM public.game_config WHERE key='mainship_coordinate_travel_enabled'),'x');
-- Raw observed coordinate-gate value, printed VERBATIM so any deviation is reported exactly, never normalized.
SELECT 'COORD_RAW='  || coalesce((SELECT value::text FROM public.game_config WHERE key='mainship_coordinate_travel_enabled'),'<<MISSING>>');

-- A3. Deviations from the approved CURRENT dark baseline: send=true, space=true, coordinate=FALSE. A missing
--     or non-'true'/'false' value counts as a deviation (compared against the exact expected literal).
SELECT 'CONFIG_DEVIATIONS=' || (
    (CASE WHEN (SELECT value #>> '{}' FROM public.game_config WHERE key='mainship_send_enabled')              = 'true'  THEN 0 ELSE 1 END)
  + (CASE WHEN (SELECT value #>> '{}' FROM public.game_config WHERE key='mainship_space_movement_enabled')    = 'true'  THEN 0 ELSE 1 END)
  + (CASE WHEN (SELECT value #>> '{}' FROM public.game_config WHERE key='mainship_coordinate_travel_enabled') = 'false' THEN 0 ELSE 1 END));

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
-- PHASE 9 (live since head 0069): the docked-port READ surface is authenticated-only + PUBLIC/anon denied.
SELECT 'ACL_DOCK_AUTH=' || coalesce((to_regprocedure('public.get_my_current_dock_services()') is not null
   AND has_function_privilege('authenticated', to_regprocedure('public.get_my_current_dock_services()')::oid, 'EXECUTE'))::int::text,'x');
SELECT 'ACL_DOCK_ANON_DENIED=' || coalesce((to_regprocedure('public.get_my_current_dock_services()') is not null
   AND NOT has_function_privilege('anon', to_regprocedure('public.get_my_current_dock_services()')::oid, 'EXECUTE'))::int::text,'x');

-- ── D2. OSN-COORD-GATE-1 (head 0070): the arbitrary-coordinate command surface, asserted from the CATALOG by
--        OID/type identity — NOT by any display-string formatting (OSN-COORD-VERIFY-2 replaced a brittle
--        identity-arguments display-string text compare that false-negatived in production). The canonical
--        raw-coordinate command public.command_main_ship_space_move(double precision,double precision,uuid):
--        (1) resolves non-null; (2)+(3) is exactly one pg_proc row in namespace public; (4) authenticated may
--        execute, anon may NOT, PUBLIC may NOT (checked from proacl, not inferred); (5) is the ONLY
--        authenticated-executable public function whose INPUT ARG TYPE OIDS are exactly (float8,float8,uuid) —
--        the caller-supplied raw-coordinate shape. The location-target command is (uuid,uuid) and the raw
--        writers are service-role-only with longer signatures, so all are excluded by arg-type OIDs, not text.
--        Forbidden names appear ONLY inside single-quoted to_regprocedure() lookups (cannot execute). ─────────
-- (1) resolved canonical procedure is non-null
SELECT 'COORD_CMD_RESOLVED=' || (to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)') is not null)::int::text;
-- (2)+(3) resolves to EXACTLY ONE pg_proc row whose schema is public
SELECT 'COORD_CMD_PROC_ROWS=' || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE p.oid = to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)') AND n.nspname='public');
-- (4a) executable by authenticated
SELECT 'ACL_COORD_CMD_AUTH=' || coalesce((SELECT has_function_privilege('authenticated', o, 'EXECUTE')::int::text
   FROM (SELECT to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)')::oid AS o) s WHERE o IS NOT NULL),'x');
-- (4b) NOT executable by anon
SELECT 'ACL_COORD_CMD_ANON_DENIED=' || coalesce((SELECT (NOT has_function_privilege('anon', o, 'EXECUTE'))::int::text
   FROM (SELECT to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)')::oid AS o) s WHERE o IS NOT NULL),'x');
-- (4c) NOT executable by PUBLIC — read from proacl directly (PUBLIC = grantee oid 0 in aclexplode). A NULL
--      proacl means the built-in default applies, under which PUBLIC HAS EXECUTE on functions → that is a FAIL.
SELECT 'COORD_CMD_PUBLIC_DENIED=' || coalesce((SELECT (NOT (p.proacl IS NULL OR EXISTS (
       SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')))::int::text
   FROM pg_proc p WHERE p.oid = to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)')),'x');
-- raw coordinate writers remain service-role-only (auth+anon denied) — by their own canonical signatures
SELECT 'ACL_COORD_WRITER_SVC_ONLY=' || coalesce((to_regprocedure('public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid)') is not null
   AND NOT has_function_privilege('authenticated', to_regprocedure('public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid)')::oid, 'EXECUTE')
   AND NOT has_function_privilege('anon',          to_regprocedure('public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid)')::oid, 'EXECUTE')
   AND has_function_privilege('service_role',      to_regprocedure('public.mainship_space_begin_move(uuid, uuid, double precision, double precision, uuid)')::oid, 'EXECUTE'))::int::text,'x');
SELECT 'ACL_COORD_CORE_SVC_ONLY=' || coalesce((to_regprocedure('public.mainship_space_begin_move_core(uuid, uuid, text, double precision, double precision, uuid, uuid)') is not null
   AND NOT has_function_privilege('authenticated', to_regprocedure('public.mainship_space_begin_move_core(uuid, uuid, text, double precision, double precision, uuid, uuid)')::oid, 'EXECUTE')
   AND NOT has_function_privilege('anon',          to_regprocedure('public.mainship_space_begin_move_core(uuid, uuid, text, double precision, double precision, uuid, uuid)')::oid, 'EXECUTE')
   AND has_function_privilege('service_role',      to_regprocedure('public.mainship_space_begin_move_core(uuid, uuid, text, double precision, double precision, uuid, uuid)')::oid, 'EXECUTE'))::int::text,'x');
-- (5) census by ARG-TYPE OIDS (no display string): exactly ONE public, authenticated-executable, normal
--     function whose 3 input arg type OIDs are float8,float8,uuid (pg_proc.proargtypes is a 0-based oidvector;
--     'double precision'::regtype / 'uuid'::regtype resolve the canonical type OIDs). location-target=(uuid,uuid)
--     and the service-role-only writers have other signatures, so none is counted.
SELECT 'COORD_SURFACE_COUNT=' || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prokind='f' AND p.pronargs=3
     AND p.proargtypes[0] = 'double precision'::regtype::oid
     AND p.proargtypes[1] = 'double precision'::regtype::oid
     AND p.proargtypes[2] = 'uuid'::regtype::oid
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE'));

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
