-- PORT-LAUNCH-2E — STRICTLY READ-ONLY post-reveal production snapshot.
--
-- Independent of the reveal workflow's own transaction log: this re-reads the LIVE state and emits only
-- `KEY=value` lines (counts / booleans / the migration version) for the shell to reconcile into a fail-closed
-- OVERALL_PASS. It NEVER writes, never calls reveal_starter_ports() (it does not appear here), never enables a
-- flag, never prints rows/UUIDs/coords/player data/secrets. All reads run inside ONE
-- BEGIN ... REPEATABLE READ READ ONLY snapshot that ROLLBACKs.
--
-- It asserts the EXPECTED POST-REVEAL state (the three canonical starter ports are ACTIVE/public) — the exact
-- inverse of the dark-state verifier (which asserts them hidden); the dark-state verifier is left untouched.
-- It tests BOTH (1) the server-side canonical catalog state AND (2) the authenticated/public map boundary via
-- the existing get_world_map() wrapper (which filters status='active' and exposes id/name/type — never role).

\set ON_ERROR_STOP on
\pset pager off

BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL default_transaction_read_only = on;

-- Read-only gate proven BEFORE any catalog query.
SELECT 'RO=' || current_setting('transaction_read_only');

-- ── A. Deployment + flags ────────────────────────────────────────────────────────────────────────────────
SELECT 'HEAD='    || coalesce(max(version),'none') FROM supabase_migrations.schema_migrations;
SELECT 'N_AFTER=' || count(*) FROM supabase_migrations.schema_migrations WHERE version > '20260618000068';
SELECT 'FLAG_SEND='  || coalesce(public.cfg_bool('mainship_send_enabled')::int::text,'x');
SELECT 'FLAG_SPACE=' || coalesce(public.cfg_bool('mainship_space_movement_enabled')::int::text,'x');

-- ── B. Canonical starter-port catalog state (POST-REVEAL: exactly the three are ACTIVE) ──────────────────
-- Fixed 0066 identities. Each port must now be ACTIVE with its approved identity + active parent hierarchy.
SELECT 'CANON_EXIST='  || count(*) FROM public.locations WHERE id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');
SELECT 'CANON_ACTIVE=' || count(*) FROM public.locations WHERE id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003') AND status='active';
SELECT 'CANON_HIDDEN=' || count(*) FROM public.locations WHERE id IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003') AND status='hidden';
SELECT 'P1_OK=' || (EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='b1a00001-0066-4a00-8a00-000000000001' AND l.name='Haven Reach'         AND l.physical_role='city' AND l.status='active' AND l.activity_type='none' AND l.x=-50 AND l.y=-30 AND z.name='Wreck Belt'      AND z.status='active' AND s.name='Outer Haven'   AND s.sector_index=1 AND s.status='active'))::int;
SELECT 'P2_OK=' || (EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='b1a00002-0066-4a00-8a00-000000000002' AND l.name='Slagworks Anchorage' AND l.physical_role='port' AND l.status='active' AND l.activity_type='none' AND l.x=70  AND l.y=-10 AND z.name='Ion Storm Route' AND z.status='active' AND s.name='Crimson Nebula' AND s.sector_index=2 AND s.status='active'))::int;
SELECT 'P3_OK=' || (EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='b1a00003-0066-4a00-8a00-000000000003' AND l.name='Driftmarch Waypost'  AND l.physical_role='port' AND l.status='active' AND l.activity_type='none' AND l.x=10  AND l.y=80  AND z.name='Ion Storm Route' AND z.status='active' AND s.name='Crimson Nebula' AND s.sector_index=2 AND s.status='active'))::int;
-- No UNEXPECTED starter-port state: the only role-bearing locations are the three canonical ports, and the
-- canonical anchors + docking services are intact (active, exactly one per port) — reveal only flips status.
SELECT 'N_ROLED='       || count(*) FROM public.locations WHERE physical_role<>'unclassified';
SELECT 'N_ROLED_UNEXP=' || count(*) FROM public.locations WHERE physical_role<>'unclassified' AND id NOT IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');
SELECT 'ANCHOR_OK=' || ((SELECT count(*) FROM public.space_anchors WHERE kind='location' AND status='active' AND id IN ('b1a0a001-0066-4a00-8a00-0000000000a1','b1a0a002-0066-4a00-8a00-0000000000a2','b1a0a003-0066-4a00-8a00-0000000000a3'))=3 AND (SELECT count(*) FROM public.space_anchors WHERE kind='location' AND status='active')=3)::int;
SELECT 'SVC_OK=' || ((SELECT count(*) FROM public.location_services WHERE service='docking' AND status='active' AND id IN ('b1a05001-0066-4a00-8a00-000000000051','b1a05002-0066-4a00-8a00-000000000052','b1a05003-0066-4a00-8a00-000000000053'))=3)::int;
SELECT 'SVC_UNEXP=' || count(*) FROM public.location_services WHERE id NOT IN ('b1a05001-0066-4a00-8a00-000000000051','b1a05002-0066-4a00-8a00-000000000052','b1a05003-0066-4a00-8a00-000000000053');

-- ── C. Authenticated/public read boundary (get_world_map) — exactly the three active ports exposed ───────
-- (2) the intended public surface returns the three canonical active ports, and NO hidden/unexpected
-- starter-port record. get_world_map() filters status='active', so any hidden port is structurally absent.
SELECT 'MAP_CANON_VISIBLE=' || (SELECT count(*) FROM jsonb_path_query(public.get_world_map(), '$.sectors[*].zones[*].locations[*]') AS loc
                                  WHERE (loc->>'id') IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003'));
SELECT 'MAP_UNEXPECTED_STARTER=' || (SELECT count(*) FROM jsonb_path_query(public.get_world_map(), '$.sectors[*].zones[*].locations[*]') AS loc
                                       WHERE (loc->>'id') ~ '^b1a0000[0-9]-0066' AND (loc->>'id') NOT IN ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003'));
-- defensive text leak check: no hidden-only marker; the three names appear (active), no surprise starter id.
SELECT 'MAP_PORT_NAMES=' || ((public.get_world_map()::text ~ 'Haven Reach')::int + (public.get_world_map()::text ~ 'Slagworks Anchorage')::int + (public.get_world_map()::text ~ 'Driftmarch Waypost')::int);
SELECT 'MAP_INACTIVE_LEAK=' || (SELECT count(*) FROM jsonb_path_query(public.get_world_map(), '$.sectors[*].zones[*].locations[*]') AS loc WHERE (loc->>'status') <> 'active');

ROLLBACK;
