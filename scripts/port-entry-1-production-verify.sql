-- PORT-ENTRY-1-VERIFY-1 — STRICTLY READ-ONLY production verification of the deployed PORT-ENTRY-1 surface.
--
-- Independent live-catalog proof that production (head 0072) contains EXACTLY the three intended PORT-ENTRY-1
-- functions with the expected signatures, return type, language, owner, SECURITY DEFINER, hardened search_path,
-- raw pg_proc.prosrc identity (md5, compared against the deterministic migration-derived hash passed in by the
-- shell via -v), and ACLs — and that migration 0072 introduced no new table / data / flag mutation and no
-- unexpected public RPC. NEVER writes; never creates a user/fixture; never invokes a PORT-ENTRY mutation RPC or
-- the private writer. The ONLY function it EXECUTES is the existing no-auth read-only readiness projection
-- get_osn_movement_readiness() (no JWT → no-ship branch → coordinate_travel_available=false), which is
-- read-only by construction. Forbidden names appear ONLY inside single-quoted to_regprocedure() catalog lookups
-- (oid resolution; cannot execute). All reads run inside ONE REPEATABLE READ READ ONLY snapshot that ROLLBACKs.
--
-- The shell passes the expected prosrc md5 of each function via psql -v (exp_writer / exp_commission /
-- exp_normalize), derived deterministically from supabase/migrations/20260618000072_*.sql in the checked-out
-- commit. The disposable proof validates that derivation equals the catalog prosrc on the real chain.

\set ON_ERROR_STOP on
\pset pager off

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL default_transaction_read_only = on;
SELECT 'RO=' || current_setting('transaction_read_only');

-- ── A. Migration head: exactly 0072, none after ─────────────────────────────────────────────────────────────
SELECT 'HEAD='    || coalesce(max(version),'none') FROM supabase_migrations.schema_migrations;
SELECT 'N_AFTER=' || count(*) FROM supabase_migrations.schema_migrations WHERE version > '20260618000072';
SELECT 'HAS_0072=' || (exists(select 1 from supabase_migrations.schema_migrations where version='20260618000072'))::int::text;

-- ── B. The three functions: existence + canonical attributes (by OID identity) ──────────────────────────────
-- writer: public.port_entry_commission_writer(uuid)
SELECT 'W_RESOLVED='  || (to_regprocedure('public.port_entry_commission_writer(uuid)') is not null)::int::text;
SELECT 'W_RET_JSONB=' || coalesce((SELECT (p.prorettype='jsonb'::regtype)::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.port_entry_commission_writer(uuid)')),'x');
SELECT 'W_PLPGSQL='   || coalesce((SELECT (l.lanname='plpgsql')::int::text FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang WHERE p.oid=to_regprocedure('public.port_entry_commission_writer(uuid)')),'x');
SELECT 'W_SECDEF='    || coalesce((SELECT p.prosecdef::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.port_entry_commission_writer(uuid)')),'x');
SELECT 'W_SEARCHPATH='|| coalesce((SELECT (p.proconfig @> array['search_path=public'])::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.port_entry_commission_writer(uuid)')),'x');
SELECT 'W_OWNER='     || coalesce((SELECT r.rolname FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner WHERE p.oid=to_regprocedure('public.port_entry_commission_writer(uuid)')),'x');
SELECT 'W_PROSRC_OK=' || coalesce((SELECT (md5(p.prosrc)=:'exp_writer')::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.port_entry_commission_writer(uuid)')),'x');
-- commission: public.commission_first_main_ship()
SELECT 'C_RESOLVED='  || (to_regprocedure('public.commission_first_main_ship()') is not null)::int::text;
SELECT 'C_RET_JSONB=' || coalesce((SELECT (p.prorettype='jsonb'::regtype)::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.commission_first_main_ship()')),'x');
SELECT 'C_PLPGSQL='   || coalesce((SELECT (l.lanname='plpgsql')::int::text FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang WHERE p.oid=to_regprocedure('public.commission_first_main_ship()')),'x');
SELECT 'C_SECDEF='    || coalesce((SELECT p.prosecdef::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.commission_first_main_ship()')),'x');
SELECT 'C_SEARCHPATH='|| coalesce((SELECT (p.proconfig @> array['search_path=public'])::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.commission_first_main_ship()')),'x');
SELECT 'C_OWNER='     || coalesce((SELECT r.rolname FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner WHERE p.oid=to_regprocedure('public.commission_first_main_ship()')),'x');
SELECT 'C_PROSRC_OK=' || coalesce((SELECT (md5(p.prosrc)=:'exp_commission')::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.commission_first_main_ship()')),'x');
-- normalize: public.normalize_main_ship_dock()
SELECT 'N_RESOLVED='  || (to_regprocedure('public.normalize_main_ship_dock()') is not null)::int::text;
SELECT 'N_RET_JSONB=' || coalesce((SELECT (p.prorettype='jsonb'::regtype)::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.normalize_main_ship_dock()')),'x');
SELECT 'N_PLPGSQL='   || coalesce((SELECT (l.lanname='plpgsql')::int::text FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang WHERE p.oid=to_regprocedure('public.normalize_main_ship_dock()')),'x');
SELECT 'N_SECDEF='    || coalesce((SELECT p.prosecdef::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.normalize_main_ship_dock()')),'x');
SELECT 'N_SEARCHPATH='|| coalesce((SELECT (p.proconfig @> array['search_path=public'])::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.normalize_main_ship_dock()')),'x');
SELECT 'N_OWNER='     || coalesce((SELECT r.rolname FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner WHERE p.oid=to_regprocedure('public.normalize_main_ship_dock()')),'x');
SELECT 'N_PROSRC_OK=' || coalesce((SELECT (md5(p.prosrc)=:'exp_normalize')::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.normalize_main_ship_dock()')),'x');

-- ── C. ACLs (live has_function_privilege + PUBLIC from proacl) ───────────────────────────────────────────────
-- writer: PUBLIC/anon/authenticated DENIED; service_role ALLOWED.
SELECT 'ACL_W_PUBLIC_DENIED=' || coalesce((SELECT (NOT (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee=0 AND a.privilege_type='EXECUTE')))::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.port_entry_commission_writer(uuid)')),'x');
SELECT 'ACL_W_ANON_DENIED=' || coalesce((NOT has_function_privilege('anon',          to_regprocedure('public.port_entry_commission_writer(uuid)')::oid,'EXECUTE'))::int::text,'x');
SELECT 'ACL_W_AUTH_DENIED=' || coalesce((NOT has_function_privilege('authenticated',  to_regprocedure('public.port_entry_commission_writer(uuid)')::oid,'EXECUTE'))::int::text,'x');
SELECT 'ACL_W_SVC_ALLOWED=' || coalesce((    has_function_privilege('service_role',   to_regprocedure('public.port_entry_commission_writer(uuid)')::oid,'EXECUTE'))::int::text,'x');
-- commission: PUBLIC/anon DENIED; authenticated ALLOWED. service_role status emitted descriptively.
SELECT 'ACL_C_PUBLIC_DENIED=' || coalesce((SELECT (NOT (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee=0 AND a.privilege_type='EXECUTE')))::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.commission_first_main_ship()')),'x');
SELECT 'ACL_C_ANON_DENIED=' || coalesce((NOT has_function_privilege('anon',           to_regprocedure('public.commission_first_main_ship()')::oid,'EXECUTE'))::int::text,'x');
SELECT 'ACL_C_AUTH_ALLOWED=' || coalesce((   has_function_privilege('authenticated',   to_regprocedure('public.commission_first_main_ship()')::oid,'EXECUTE'))::int::text,'x');
SELECT 'ACL_C_SVC=' || coalesce((            has_function_privilege('service_role',    to_regprocedure('public.commission_first_main_ship()')::oid,'EXECUTE'))::int::text,'x');
-- normalize: PUBLIC/anon DENIED; authenticated ALLOWED. service_role status emitted descriptively.
SELECT 'ACL_N_PUBLIC_DENIED=' || coalesce((SELECT (NOT (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee=0 AND a.privilege_type='EXECUTE')))::int::text FROM pg_proc p WHERE p.oid=to_regprocedure('public.normalize_main_ship_dock()')),'x');
SELECT 'ACL_N_ANON_DENIED=' || coalesce((NOT has_function_privilege('anon',            to_regprocedure('public.normalize_main_ship_dock()')::oid,'EXECUTE'))::int::text,'x');
SELECT 'ACL_N_AUTH_ALLOWED=' || coalesce((   has_function_privilege('authenticated',    to_regprocedure('public.normalize_main_ship_dock()')::oid,'EXECUTE'))::int::text,'x');
SELECT 'ACL_N_SVC=' || coalesce((            has_function_privilege('service_role',     to_regprocedure('public.normalize_main_ship_dock()')::oid,'EXECUTE'))::int::text,'x');

-- ── D. No unexpected public surface from 0072: the ONLY public functions whose name begins with the PORT-ENTRY
--       prefixes are exactly the three approved ones; and exactly two are authenticated-executable. ──────────
SELECT 'PE_FN_COUNT=' || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND (p.proname IN ('port_entry_commission_writer','commission_first_main_ship','normalize_main_ship_dock')));
SELECT 'PE_FN_UNEXPECTED=' || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND (p.proname LIKE 'port_entry%' OR p.proname='commission_first_main_ship' OR p.proname='normalize_main_ship_dock')
     AND p.proname NOT IN ('port_entry_commission_writer','commission_first_main_ship','normalize_main_ship_dock'));
SELECT 'PE_AUTH_EXEC_COUNT=' || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname IN ('port_entry_commission_writer','commission_first_main_ship','normalize_main_ship_dock')
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE'));

-- ── D2. FULL canonical authenticated client-RPC inventory — the COMPLETE set of authenticated-executable public
--        functions must EQUAL the approved set EXACTLY (a missing expected RPC, an expected RPC without
--        authenticated EXECUTE, OR an unexpected authenticated-executable public function under ANY name all
--        fail). Comparison is by OID (robust); identity-argument strings are emitted for SAFE LOGGING only.
--        The mutation-RPC names appear here ONLY as single-quoted expected signatures (the read-only safety scan
--        strips quoted strings, so they are not treated as executable references).
WITH expected(sig) AS (VALUES
  ('public.get_world_map()'),
  ('public.bootstrap_me()'),
  ('public.send_fleet_to_location(uuid, uuid, jsonb)'),
  ('public.request_leave_location(uuid)'),
  ('public.request_retreat(uuid)'),
  ('public.get_combat_reports()'),
  ('public.train_units(uuid, text, integer)'),
  ('public.cancel_build_order(uuid)'),
  ('public.get_my_expedition_preview(jsonb, text)'),
  ('public.get_osn_movement_readiness()'),
  ('public.send_main_ship_expedition(jsonb, uuid, uuid)'),   -- NO-HOME (0199): widened with p_return_location_id
  ('public.request_main_ship_return(uuid)'),
  ('public.repair_main_ship()'),
  ('public.move_main_ship_to_location(uuid, uuid)'),
  ('public.command_main_ship_space_move(double precision, double precision, uuid)'),
  ('public.command_main_ship_space_stop(uuid)'),
  ('public.command_main_ship_space_move_to_location(uuid, uuid)'),
  ('public.get_my_current_dock_services()'),
  ('public.commission_first_main_ship()'),
  ('public.normalize_main_ship_dock()')
),
exp_oid AS (SELECT sig, to_regprocedure(sig)::oid AS oid FROM expected),
obs AS (SELECT p.oid, (n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')') AS ident
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.prokind='f' AND has_function_privilege('authenticated', p.oid, 'EXECUTE'))
SELECT m FROM (
  SELECT 1 AS ord, 'INV_EXPECTED_N=' || (SELECT count(*) FROM expected) AS m
  UNION ALL SELECT 2, 'INV_UNRESOLVED=' || (SELECT count(*) FROM exp_oid WHERE oid IS NULL)
  UNION ALL SELECT 3, 'INV_OBSERVED_N=' || (SELECT count(*) FROM obs)
  UNION ALL SELECT 4, 'INV_MISSING=' || (SELECT count(*) FROM exp_oid e WHERE e.oid IS NULL OR NOT EXISTS (SELECT 1 FROM obs o WHERE o.oid=e.oid))
  UNION ALL SELECT 5, 'INV_EXTRA=' || (SELECT count(*) FROM obs o WHERE NOT EXISTS (SELECT 1 FROM exp_oid e WHERE e.oid=o.oid))
  UNION ALL SELECT 6, 'INV_MISSING_LIST=' || coalesce((SELECT string_agg(e.sig, ',' ORDER BY e.sig) FROM exp_oid e WHERE e.oid IS NULL OR NOT EXISTS (SELECT 1 FROM obs o WHERE o.oid=e.oid)),'<none>')
  UNION ALL SELECT 7, 'INV_EXTRA_LIST=' || coalesce((SELECT string_agg(o.ident, ',' ORDER BY o.ident) FROM obs o WHERE NOT EXISTS (SELECT 1 FROM exp_oid e WHERE e.oid=o.oid)),'<none>')
  UNION ALL SELECT 8, 'INV_OBSERVED_LIST=' || coalesce((SELECT string_agg(o.ident, ',' ORDER BY o.ident) FROM obs o),'<none>')
) s ORDER BY ord;

-- ── E. No PORT-ENTRY-specific NEW TABLE introduced by 0072 (it is function-only) ─────────────────────────────
SELECT 'PE_TABLE_COUNT=' || (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='r' AND (c.relname LIKE 'port_entry%' OR c.relname LIKE 'commission%'));

-- ── F. Flags (read live from game_config; fail-closed integrity — row exists exactly once + boolean literal) ──
SELECT 'SEND_ROWS='  || count(*) FROM public.game_config WHERE key='mainship_send_enabled';
SELECT 'SPACE_ROWS=' || count(*) FROM public.game_config WHERE key='mainship_space_movement_enabled';
SELECT 'COORD_ROWS=' || count(*) FROM public.game_config WHERE key='mainship_coordinate_travel_enabled';
SELECT 'FLAG_SEND='  || coalesce((SELECT CASE WHEN (value #>> '{}') IN ('true','false') THEN ((value #>> '{}')::boolean)::int::text ELSE 'x' END FROM public.game_config WHERE key='mainship_send_enabled'),'x');
SELECT 'FLAG_SPACE=' || coalesce((SELECT CASE WHEN (value #>> '{}') IN ('true','false') THEN ((value #>> '{}')::boolean)::int::text ELSE 'x' END FROM public.game_config WHERE key='mainship_space_movement_enabled'),'x');
SELECT 'FLAG_COORD=' || coalesce((SELECT CASE WHEN (value #>> '{}') IN ('true','false') THEN ((value #>> '{}')::boolean)::int::text ELSE 'x' END FROM public.game_config WHERE key='mainship_coordinate_travel_enabled'),'x');

-- ── G. Coordinate dark-state, catalog/read-only ONLY (never invoke the raw coordinate command) ───────────────
-- the raw coordinate command surface still exists (catalog), and the no-auth readiness projection reports the
-- capability false. get_osn_movement_readiness() is read-only; with no JWT it returns the no-ship early branch.
SELECT 'COORD_CMD_PRESENT=' || (to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)') is not null)::int::text;
WITH r AS MATERIALIZED (SELECT public.get_osn_movement_readiness() AS j)
SELECT 'RDN_COORD_NOAUTH=' || coalesce((j->>'coordinate_travel_available'),'<<absent>>') FROM r;
SELECT 'RDN_HAS_COORD_FIELD=' || (SELECT (public.get_osn_movement_readiness() ? 'coordinate_travel_available')::int::text);

ROLLBACK;
