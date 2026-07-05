-- OSN-HUB-1A / PORT-LAUNCH-1A — STRICTLY READ-ONLY production catalog snapshot (migration head 0068).
--
-- One read-only REPEATABLE READ snapshot that emits ONLY `KEY=value` lines (PASS/FAIL booleans, small
-- aggregate counts, the migration version, per-function descriptor metadata, and base64 of the raw stored
-- PL/pgSQL body for parity). It NEVER writes, never calls a write-capable RPC (is_home_port_eligible / cfg_bool
-- / get_world_map are STABLE reads; assign_home_port is referenced ONLY inside a quoted catalog string, never
-- invoked), never enables anything, never prints raw rows / UUIDs / coordinates / player data / function
-- bodies / secrets. The shell wrapper (osn-hub1a-production-catalog-verify.sh) reconciles these into a verdict
-- and performs the local-vs-production parity comparison. The snapshot always rolls back; it never writes.
--
-- The base64 body lines (HB_*) are the raw stored p.prosrc (version-stable), NOT pg_get_functiondef; the shell
-- compares ONLY SHA-256 hashes of them (a hash and a descriptor flag are non-sensitive), and never prints them.

\set ON_ERROR_STOP on
\pset pager off

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL default_transaction_read_only = on;

-- Read-only gate proven BEFORE any catalog query.
SELECT 'RO=' || current_setting('transaction_read_only');

-- ── A. Deployment + dark state ───────────────────────────────────────────────────────────────────────────
SELECT 'HEAD='    || coalesce(max(version),'none') FROM supabase_migrations.schema_migrations;
SELECT 'N_AFTER=' || count(*) FROM supabase_migrations.schema_migrations WHERE version > '20260618000068';

SELECT 'FLAG_SEND_N='     || count(*)                              FROM public.game_config WHERE key='mainship_send_enabled';
SELECT 'FLAG_SEND_TYPE='  || coalesce((SELECT pg_typeof(value)::text FROM public.game_config WHERE key='mainship_send_enabled'),'none');
SELECT 'FLAG_SEND='       || coalesce(public.cfg_bool('mainship_send_enabled')::int::text,'x');
SELECT 'FLAG_SPACE_N='    || count(*)                              FROM public.game_config WHERE key='mainship_space_movement_enabled';
SELECT 'FLAG_SPACE_TYPE=' || coalesce((SELECT pg_typeof(value)::text FROM public.game_config WHERE key='mainship_space_movement_enabled'),'none');
SELECT 'FLAG_SPACE='      || coalesce(public.cfg_bool('mainship_space_movement_enabled')::int::text,'x');

-- active/open coordinate movements (dark = zero ACTIVE; terminal history is NOT asserted to be zero)
SELECT 'N_ACTIVE_MOVES='  || count(*) FROM public.main_ship_space_movements WHERE status='moving';
-- coherence: a fleet space-pointer must reference an active 'moving' movement of that same fleet (and only it)
SELECT 'N_FLEET_SPACE_PTR=' || count(*) FROM public.fleets WHERE active_space_movement_id IS NOT NULL;
SELECT 'N_PTR_INCOHERENT='  || count(*)
  FROM public.fleets f
  WHERE f.active_space_movement_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.main_ship_space_movements m
                    WHERE m.id=f.active_space_movement_id AND m.fleet_id=f.id AND m.status='moving');
SELECT 'N_MOVE_UNPTR='    || count(*)
  FROM public.main_ship_space_movements m
  WHERE m.status='moving'
    AND NOT EXISTS (SELECT 1 FROM public.fleets f WHERE f.active_space_movement_id=m.id AND f.id=m.fleet_id);

-- player/world mutation guards
SELECT 'N_HOMEPORT='    || count(*) FROM public.player_home_port;
SELECT 'N_BASE_ANCHOR=' || count(*) FROM public.space_anchors WHERE kind='base';

-- arrival-cron coherence (OSN engine heartbeat unchanged by the dark 0068 deploy): exactly one job @ 30 seconds
SELECT 'N_ARRIVAL_CRON='     || count(*)                           FROM cron.job WHERE jobname='process-mainship-space-arrivals';
SELECT 'ARRIVAL_CRON_SCHED=' || coalesce(max(schedule),'none')      FROM cron.job WHERE jobname='process-mainship-space-arrivals';

-- PORT-LAUNCH-2B pre-reveal precondition: NO current state references any of the three fixed starter ports
-- in a way that would make a future reveal/recovery unsafe. Each count MUST be 0 (the ports are dark and
-- un-interacted). Exact precondition for the fixed three ports only — NOT generic world cleanup.
SELECT 'STP_PRESENCE='  || count(*) FROM public.location_presence WHERE status='active'
  AND location_id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');
SELECT 'STP_FLEET='     || count(*) FROM public.fleets WHERE status IN ('idle','moving','present','returning')
  AND current_location_id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');
SELECT 'STP_LEGACY_MV=' || count(*) FROM public.fleet_movements WHERE status='moving'
  AND (target_location_id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003')
       OR origin_location_id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003'));
SELECT 'STP_OSN_MV='    || count(*) FROM public.main_ship_space_movements WHERE status='moving' AND target_kind='location'
  AND target_location_id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');
SELECT 'STP_HOMEPORT='  || count(*) FROM public.player_home_port
  WHERE location_id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');

-- ── B. Hidden-port / world-state protection (no names/IDs/coords in OUTPUT — only booleans/counts) ────────
-- Fixed identities are from migration 0066 (still on main); the shell fail-closes unless each literal is
-- present verbatim in the checked-out 0066 migration, so the verifier can never drift from the catalog.
SELECT 'P1_OK=' || (EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='b1a00001-0066-4a00-8a00-000000000001' AND l.name='Haven'         AND l.physical_role='city' AND l.status='hidden' AND l.activity_type='none' AND l.x=-50 AND l.y=-30 AND z.name='Wreck Belt'      AND z.status='active' AND s.name='Outer Haven'   AND s.sector_index=1 AND s.status='active'))::int;
SELECT 'P2_OK=' || (EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='b1a00002-0066-4a00-8a00-000000000002' AND l.name='Slagworks' AND l.physical_role='port' AND l.status='hidden' AND l.activity_type='none' AND l.x=70  AND l.y=-10 AND z.name='Ion Storm Route' AND z.status='active' AND s.name='Crimson Nebula' AND s.sector_index=2 AND s.status='active'))::int;
SELECT 'P3_OK=' || (EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='b1a00003-0066-4a00-8a00-000000000003' AND l.name='Driftmarch'  AND l.physical_role='port' AND l.status='hidden' AND l.activity_type='none' AND l.x=10  AND l.y=80  AND z.name='Ion Storm Route' AND z.status='active' AND s.name='Crimson Nebula' AND s.sector_index=2 AND s.status='active'))::int;
SELECT 'N_ROLED='       || count(*) FROM public.locations WHERE physical_role<>'unclassified';
SELECT 'N_ROLED_UNEXP=' || count(*) FROM public.locations WHERE physical_role<>'unclassified' AND id NOT IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');
SELECT 'A1_OK=' || ((EXISTS(SELECT 1 FROM public.space_anchors WHERE id='b1a0a001-0066-4a00-8a00-0000000000a1' AND location_id='b1a00001-0066-4a00-8a00-000000000001' AND kind='location' AND status='active' AND space_x=-50 AND space_y=-30)) AND (SELECT count(*) FROM public.space_anchors WHERE location_id='b1a00001-0066-4a00-8a00-000000000001' AND kind='location' AND status='active')=1)::int;
SELECT 'A2_OK=' || ((EXISTS(SELECT 1 FROM public.space_anchors WHERE id='b1a0a002-0066-4a00-8a00-0000000000a2' AND location_id='b1a00002-0066-4a00-8a00-000000000002' AND kind='location' AND status='active' AND space_x=70  AND space_y=-10)) AND (SELECT count(*) FROM public.space_anchors WHERE location_id='b1a00002-0066-4a00-8a00-000000000002' AND kind='location' AND status='active')=1)::int;
SELECT 'A3_OK=' || ((EXISTS(SELECT 1 FROM public.space_anchors WHERE id='b1a0a003-0066-4a00-8a00-0000000000a3' AND location_id='b1a00003-0066-4a00-8a00-000000000003' AND kind='location' AND status='active' AND space_x=10  AND space_y=80 )) AND (SELECT count(*) FROM public.space_anchors WHERE location_id='b1a00003-0066-4a00-8a00-000000000003' AND kind='location' AND status='active')=1)::int;
SELECT 'N_ANCHOR_LOC=' || count(*) FROM public.space_anchors WHERE kind='location' AND status='active';
SELECT 'N_ANCHOR_UNEXP=' || count(*) FROM public.space_anchors WHERE kind='location' AND status='active' AND id NOT IN ('b1a0a001-0066-4a00-8a00-0000000000a1','b1a0a002-0066-4a00-8a00-0000000000a2','b1a0a003-0066-4a00-8a00-0000000000a3');
SELECT 'S1_OK=' || ((EXISTS(SELECT 1 FROM public.location_services WHERE id='b1a05001-0066-4a00-8a00-000000000051' AND location_id='b1a00001-0066-4a00-8a00-000000000001' AND service='docking' AND status='active')) AND (SELECT count(*) FROM public.location_services WHERE location_id='b1a00001-0066-4a00-8a00-000000000001' AND service='docking' AND status='active')=1)::int;
SELECT 'S2_OK=' || ((EXISTS(SELECT 1 FROM public.location_services WHERE id='b1a05002-0066-4a00-8a00-000000000052' AND location_id='b1a00002-0066-4a00-8a00-000000000002' AND service='docking' AND status='active')) AND (SELECT count(*) FROM public.location_services WHERE location_id='b1a00002-0066-4a00-8a00-000000000002' AND service='docking' AND status='active')=1)::int;
SELECT 'S3_OK=' || ((EXISTS(SELECT 1 FROM public.location_services WHERE id='b1a05003-0066-4a00-8a00-000000000053' AND location_id='b1a00003-0066-4a00-8a00-000000000003' AND service='docking' AND status='active')) AND (SELECT count(*) FROM public.location_services WHERE location_id='b1a00003-0066-4a00-8a00-000000000003' AND service='docking' AND status='active')=1)::int;
SELECT 'N_SVC_UNEXP=' || count(*) FROM public.location_services WHERE id NOT IN ('b1a05001-0066-4a00-8a00-000000000051','b1a05002-0066-4a00-8a00-000000000052','b1a05003-0066-4a00-8a00-000000000053');
SELECT 'N_ORIG='   || count(*) FROM public.locations WHERE name IN ('Refuge','Lull','Snare','Reaver','Blackden') AND physical_role='unclassified' AND status='active';
SELECT 'MAP_LEAK='    || (public.get_world_map()::text ~ '"name" *: *"(Haven|Slagworks|Driftmarch)"')::int;
SELECT 'MAP_LEAK_ID=' || (public.get_world_map()::text ~ 'b1a0000[123]-0066')::int;
SELECT 'ELIG1=' || public.is_home_port_eligible('b1a00001-0066-4a00-8a00-000000000001')::int;
SELECT 'ELIG2=' || public.is_home_port_eligible('b1a00002-0066-4a00-8a00-000000000002')::int;
SELECT 'ELIG3=' || public.is_home_port_eligible('b1a00003-0066-4a00-8a00-000000000003')::int;

-- ── C. Public authenticated RPC surface (exact 17, with overload detection) ──────────────────────────────
SELECT 'AUTH_SURFACE='   || coalesce(string_agg(proname, ',' ORDER BY proname), '') FROM (SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f' AND has_function_privilege('authenticated',p.oid,'EXECUTE')) q;
SELECT 'N_AUTH='         || count(*)                  FROM (SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f' AND has_function_privilege('authenticated',p.oid,'EXECUTE')) q;
SELECT 'N_AUTH_DISTINCT='|| count(DISTINCT proname)   FROM (SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f' AND has_function_privilege('authenticated',p.oid,'EXECUTE')) q;
-- which of the canonical 17 does anon hold (must be exactly get_world_map)
SELECT 'ANON_ON_17='     || coalesce(string_agg(v.name, ',' ORDER BY v.name), '')
  FROM (VALUES ('bootstrap_me'),('cancel_build_order'),('command_main_ship_space_move'),('command_main_ship_space_move_to_location'),('command_main_ship_space_stop'),('get_combat_reports'),('get_my_expedition_preview'),('get_osn_movement_readiness'),('get_world_map'),('move_main_ship_to_location'),('repair_main_ship'),('request_leave_location'),('request_main_ship_return'),('request_retreat'),('send_fleet_to_location'),('send_main_ship_expedition'),('train_units')) v(name)
  JOIN pg_proc p ON p.proname=v.name JOIN pg_namespace n ON n.oid=p.pronamespace AND n.nspname='public'
  WHERE has_function_privilege('anon', p.oid, 'EXECUTE');
SELECT 'GWM_ANON=' || has_function_privilege('anon','public.get_world_map()','EXECUTE')::int;
SELECT 'GWM_AUTH=' || has_function_privilege('authenticated','public.get_world_map()','EXECUTE')::int;

-- ── D. Internal OSN / World-HUB ACL boundaries (service_role-only; anon+authenticated denied) ────────────
-- I_<tag>_EXIST / _SRVX / _ANONX / _AUTHX for each internal (by EXACT signature).
SELECT 'I_'||tag||'_EXIST='||(to_regprocedure(sig) IS NOT NULL)::int FROM (VALUES
  ('lock','public.mainship_space_lock_context(uuid,boolean)'),
  ('validate','public.mainship_space_validate_context(uuid)'),
  ('resolve','public.mainship_space_resolve_origin(uuid)'),
  ('excl','public.mainship_space_assert_cross_domain_exclusion(uuid)'),
  ('legal','public.mainship_space_location_target_legal(uuid)'),
  ('core','public.mainship_space_begin_move_core(uuid,uuid,text,double precision,double precision,uuid,uuid)'),
  ('begin','public.mainship_space_begin_move(uuid,uuid,double precision,double precision,uuid)'),
  ('proc','public.process_mainship_space_arrivals()'),
  ('settle','public.mainship_space_settle_space_arrival(uuid,uuid,timestamptz)'),
  ('dock','public.mainship_space_dock_at_location(uuid,uuid)'),
  ('stop','public.mainship_space_stop(uuid,uuid,uuid)'),
  ('elig','public.is_home_port_eligible(uuid)'),
  ('assign','public.assign_home_port(uuid,uuid)')
) v(tag,sig);
SELECT 'I_'||tag||'_SRVX='||coalesce((has_function_privilege('service_role', to_regprocedure(sig), 'EXECUTE'))::int::text,'x') FROM (VALUES
  ('lock','public.mainship_space_lock_context(uuid,boolean)'),('validate','public.mainship_space_validate_context(uuid)'),('resolve','public.mainship_space_resolve_origin(uuid)'),('excl','public.mainship_space_assert_cross_domain_exclusion(uuid)'),('legal','public.mainship_space_location_target_legal(uuid)'),('core','public.mainship_space_begin_move_core(uuid,uuid,text,double precision,double precision,uuid,uuid)'),('begin','public.mainship_space_begin_move(uuid,uuid,double precision,double precision,uuid)'),('proc','public.process_mainship_space_arrivals()'),('settle','public.mainship_space_settle_space_arrival(uuid,uuid,timestamptz)'),('dock','public.mainship_space_dock_at_location(uuid,uuid)'),('stop','public.mainship_space_stop(uuid,uuid,uuid)'),('elig','public.is_home_port_eligible(uuid)'),('assign','public.assign_home_port(uuid,uuid)')
) v(tag,sig) WHERE to_regprocedure(sig) IS NOT NULL;
SELECT 'I_'||tag||'_ANONX='||coalesce((has_function_privilege('anon', to_regprocedure(sig), 'EXECUTE'))::int::text,'x') FROM (VALUES
  ('lock','public.mainship_space_lock_context(uuid,boolean)'),('validate','public.mainship_space_validate_context(uuid)'),('resolve','public.mainship_space_resolve_origin(uuid)'),('excl','public.mainship_space_assert_cross_domain_exclusion(uuid)'),('legal','public.mainship_space_location_target_legal(uuid)'),('core','public.mainship_space_begin_move_core(uuid,uuid,text,double precision,double precision,uuid,uuid)'),('begin','public.mainship_space_begin_move(uuid,uuid,double precision,double precision,uuid)'),('proc','public.process_mainship_space_arrivals()'),('settle','public.mainship_space_settle_space_arrival(uuid,uuid,timestamptz)'),('dock','public.mainship_space_dock_at_location(uuid,uuid)'),('stop','public.mainship_space_stop(uuid,uuid,uuid)'),('elig','public.is_home_port_eligible(uuid)'),('assign','public.assign_home_port(uuid,uuid)')
) v(tag,sig) WHERE to_regprocedure(sig) IS NOT NULL;
SELECT 'I_'||tag||'_AUTHX='||coalesce((has_function_privilege('authenticated', to_regprocedure(sig), 'EXECUTE'))::int::text,'x') FROM (VALUES
  ('lock','public.mainship_space_lock_context(uuid,boolean)'),('validate','public.mainship_space_validate_context(uuid)'),('resolve','public.mainship_space_resolve_origin(uuid)'),('excl','public.mainship_space_assert_cross_domain_exclusion(uuid)'),('legal','public.mainship_space_location_target_legal(uuid)'),('core','public.mainship_space_begin_move_core(uuid,uuid,text,double precision,double precision,uuid,uuid)'),('begin','public.mainship_space_begin_move(uuid,uuid,double precision,double precision,uuid)'),('proc','public.process_mainship_space_arrivals()'),('settle','public.mainship_space_settle_space_arrival(uuid,uuid,timestamptz)'),('dock','public.mainship_space_dock_at_location(uuid,uuid)'),('stop','public.mainship_space_stop(uuid,uuid,uuid)'),('elig','public.is_home_port_eligible(uuid)'),('assign','public.assign_home_port(uuid,uuid)')
) v(tag,sig) WHERE to_regprocedure(sig) IS NOT NULL;

-- table ACL boundaries (server-owned catalog tables stay client-inaccessible; player_home_port owner-read only)
SELECT 'SA_CLIENT='  || (has_table_privilege('anon','public.space_anchors','SELECT') OR has_table_privilege('authenticated','public.space_anchors','SELECT') OR has_table_privilege('anon','public.space_anchors','INSERT') OR has_table_privilege('authenticated','public.space_anchors','INSERT'))::int;
SELECT 'LS_CLIENT='  || (has_table_privilege('anon','public.location_services','SELECT') OR has_table_privilege('authenticated','public.location_services','SELECT') OR has_table_privilege('anon','public.location_services','INSERT') OR has_table_privilege('authenticated','public.location_services','INSERT'))::int;
SELECT 'PHP_AUTH_SELECT=' || has_table_privilege('authenticated','public.player_home_port','SELECT')::int;
SELECT 'PHP_AUTH_WRITE='  || (has_table_privilege('authenticated','public.player_home_port','INSERT') OR has_table_privilege('authenticated','public.player_home_port','UPDATE') OR has_table_privilege('authenticated','public.player_home_port','DELETE'))::int;
SELECT 'PHP_ANON='        || (has_table_privilege('anon','public.player_home_port','SELECT') OR has_table_privilege('anon','public.player_home_port','INSERT'))::int;
SELECT 'PHP_RLS=' || (SELECT relrowsecurity::int FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='player_home_port');

-- ── E. Catalog parity for the 7 functions 0067 changed/added + the 2 functions 0068 added ───────────────
-- HB_<tag> = base64 of raw stored prosrc; D_<tag>_<field> = descriptor. The shell hashes HB_* and compares
-- reference (disposable 0001..0068) vs production; descriptors are compared field-by-field. The two 0068
-- additions are reveal (public.reveal_starter_ports, service_role-only) and readiness
-- (public.get_osn_movement_readiness, authenticated read-only).
SELECT 'EXIST_'||tag||'='||(to_regprocedure(sig) IS NOT NULL)::int FROM (VALUES
  ('legal','public.mainship_space_location_target_legal(uuid)'),
  ('core','public.mainship_space_begin_move_core(uuid,uuid,text,double precision,double precision,uuid,uuid)'),
  ('begin','public.mainship_space_begin_move(uuid,uuid,double precision,double precision,uuid)'),
  ('resolve','public.mainship_space_resolve_origin(uuid)'),
  ('dock','public.mainship_space_dock_at_location(uuid,uuid)'),
  ('stop','public.mainship_space_stop(uuid,uuid,uuid)'),
  ('cmd','public.command_main_ship_space_move_to_location(uuid,uuid)'),
  ('reveal','public.reveal_starter_ports()'),
  ('readiness','public.get_osn_movement_readiness()')
) v(tag,sig);
SELECT kv FROM (VALUES
  ('legal','public.mainship_space_location_target_legal(uuid)'),
  ('core','public.mainship_space_begin_move_core(uuid,uuid,text,double precision,double precision,uuid,uuid)'),
  ('begin','public.mainship_space_begin_move(uuid,uuid,double precision,double precision,uuid)'),
  ('resolve','public.mainship_space_resolve_origin(uuid)'),
  ('dock','public.mainship_space_dock_at_location(uuid,uuid)'),
  ('stop','public.mainship_space_stop(uuid,uuid,uuid)'),
  ('cmd','public.command_main_ship_space_move_to_location(uuid,uuid)'),
  ('reveal','public.reveal_starter_ports()'),
  ('readiness','public.get_osn_movement_readiness()')
) v(tag,sig)
JOIN pg_proc p   ON p.oid = to_regprocedure(v.sig)
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language  l ON l.oid = p.prolang
CROSS JOIN LATERAL (VALUES
  ('HB_'||v.tag||'='   || translate(encode(convert_to(p.prosrc,'UTF8'),'base64'), E'\n\r','')),
  ('D_'||v.tag||'_LANG='   || l.lanname),
  ('D_'||v.tag||'_OWNER='  || pg_get_userbyid(p.proowner)),
  ('D_'||v.tag||'_SECDEF=' || p.prosecdef::text),
  ('D_'||v.tag||'_SP='     || coalesce(array_to_string(p.proconfig,','),'')),
  ('D_'||v.tag||'_ARGS='   || pg_get_function_identity_arguments(p.oid)),
  ('D_'||v.tag||'_SRVX='   || has_function_privilege('service_role',p.oid,'EXECUTE')::text),
  ('D_'||v.tag||'_ANONX='  || has_function_privilege('anon',p.oid,'EXECUTE')::text),
  ('D_'||v.tag||'_AUTHX='  || has_function_privilege('authenticated',p.oid,'EXECUTE')::text),
  ('D_'||v.tag||'_PUBX='   || coalesce((SELECT bool_or(a.grantee=0) FROM aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) a WHERE a.privilege_type='EXECUTE'), false)::text)
) AS e(kv);

ROLLBACK;
