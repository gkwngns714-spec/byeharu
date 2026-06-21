-- OSN-3 S3 — REAL-CHAIN schema/permission/RPC-boundary proof for the writer. Runs via psql against a
-- DISPOSABLE local Supabase stack whose schema is the ACTUAL migration chain 0001..0057 (NOT a stub,
-- NOT the shared/live DB). Proves mainship_space_begin_move is SECURITY DEFINER / owner postgres /
-- search_path=public / no dynamic SQL, executable by service_role ONLY (public/anon/authenticated
-- denied), that the four S2 helpers remain client-inaccessible, that the canonical client-RPC ACL
-- inventory survived the 0057 relock unchanged, that the new config guard exists, and that both flags
-- are false. Read-only (no mutation).

\set ON_ERROR_STOP on

\echo ''
\echo '================= S3 WRITER + S2 HELPER METADATA ================='
select p.proname,
       pg_get_function_identity_arguments(p.oid) as identity_args,
       p.prosecdef as security_definer, p.proconfig as function_config,
       pg_get_userbyid(p.proowner) as owner,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_x,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_x,
       has_function_privilege('service_role', p.oid, 'EXECUTE')  as srv_x,
       p.proacl::text as acl
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context',
                    'mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion')
order by p.proname;

-- ── the writer's boundary assertions ───────────────────────────────────────────────────────────
do $$
declare r record;
begin
  select p.oid, p.prosecdef, p.proconfig, p.proacl, pg_get_functiondef(p.oid) def, pg_get_userbyid(p.proowner) owner
    into r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'mainship_space_begin_move';
  if r.oid is null then raise exception 'PERM FAIL: mainship_space_begin_move not installed'; end if;
  if not r.prosecdef then raise exception 'PERM FAIL: writer is not SECURITY DEFINER'; end if;
  if r.proconfig is null or not ('search_path=public' = any(r.proconfig)) then raise exception 'PERM FAIL: writer search_path not pinned to public (%)', r.proconfig; end if;
  if r.owner <> 'postgres' then raise exception 'PERM FAIL: writer owner=% (expected postgres)', r.owner; end if;
  if strpos(lower(r.def), 'execute ''') > 0 or r.def ~* 'execute format' then raise exception 'PERM FAIL: writer appears to use dynamic EXECUTE'; end if;
  if has_function_privilege('anon', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: anon can EXECUTE the writer'; end if;
  if has_function_privilege('authenticated', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: authenticated can EXECUTE the writer'; end if;
  if not has_function_privilege('service_role', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: service_role cannot EXECUTE the writer'; end if;
  if r.proacl is null then raise exception 'PERM FAIL: writer has null proacl (defaults to PUBLIC EXECUTE)'; end if;
  if exists (select 1 from unnest(r.proacl) a where a::text like '=%') then raise exception 'PERM FAIL: writer grants EXECUTE to PUBLIC'; end if;
  raise notice 'PERM ok: mainship_space_begin_move — SECURITY DEFINER, search_path=public, owner=postgres, no dynamic SQL; anon/authenticated/PUBLIC denied, service_role allowed';
end $$;

-- ── the four S2 helpers stay client-inaccessible (unchanged by 0057) ─────────────────────────────
do $$
declare r record;
begin
  for r in
    select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion')
  loop
    if has_function_privilege('anon', r.oid, 'EXECUTE') or has_function_privilege('authenticated', r.oid, 'EXECUTE') then
      raise exception 'PERM FAIL: S2 helper % became client-executable', r.proname; end if;
    if not has_function_privilege('service_role', r.oid, 'EXECUTE') then
      raise exception 'PERM FAIL: S2 helper % lost service_role execute', r.proname; end if;
  end loop;
  raise notice 'PERM ok: four S2 helpers remain service_role-only (client-inaccessible)';
end $$;

-- ── canonical client-RPC ACL inventory preserved; no S3/S2 server fn is client-exposed ───────────
do $$
declare
  expected text[] := array['bootstrap_me','cancel_build_order','get_combat_reports','get_my_expedition_preview',
    'get_world_map','move_main_ship_to_location','repair_main_ship','request_leave_location','request_main_ship_return',
    'request_retreat','send_fleet_to_location','send_main_ship_expedition','train_units'];
  actual text[];
  server_only text[] := array['mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context',
    'mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion'];
begin
  select coalesce(array_agg(distinct p.proname order by p.proname), '{}') into actual
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  raise notice 'authenticated-executable public functions = %', actual;
  if actual && server_only then raise exception 'PERM FAIL: a server-only fn is authenticated-executable: %', actual; end if;
  if not (actual @> expected) then raise exception 'PERM FAIL: a canonical client RPC LOST execute. expected ⊆ actual; expected=% actual=%', expected, actual; end if;
  if not (expected @> actual) then raise notice 'NOTE: extra authenticated-executable public function(s) beyond the canonical list: %', (select array_agg(x) from unnest(actual) x where not (x = any(expected))); end if;
  if not has_function_privilege('anon', 'public.get_world_map()'::regprocedure, 'EXECUTE') then raise exception 'PERM FAIL: anon lost get_world_map'; end if;
  raise notice 'PERM ok: canonical client-RPC inventory preserved (no server fn exposed, no client RPC lost)';
end $$;

-- ── public-schema CREATE unavailable to PUBLIC/anon/authenticated (search_path=public safe) ──────
do $$
begin
  if has_schema_privilege('anon','public','CREATE') then raise exception 'PERM FAIL: anon can CREATE in public'; end if;
  if has_schema_privilege('authenticated','public','CREATE') then raise exception 'PERM FAIL: authenticated can CREATE in public'; end if;
  raise notice 'PERM ok: anon/authenticated cannot CREATE in public';
end $$;

-- ── the S3 config guard exists; both flags are false (read-only assertions) ──────────────────────
do $$
declare a text; b text; c text;
begin
  select value::text into a from game_config where key = 'mainship_send_enabled';
  select value::text into b from game_config where key = 'mainship_space_movement_enabled';
  select value::text into c from game_config where key = 'max_coordinate_travel_seconds';
  if a is distinct from 'false' then raise exception 'FLAG FAIL: mainship_send_enabled = %', a; end if;
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled = %', b; end if;
  if c is distinct from '86400' then raise exception 'CONFIG FAIL: max_coordinate_travel_seconds = % (expected 86400)', c; end if;
  raise notice 'FLAG/CONFIG ok: send=false, space_movement=false, max_coordinate_travel_seconds=86400';
end $$;

select 'OSN-3 S3 REAL-CHAIN PERMISSION PROOF: ALL PASSED' as result;
