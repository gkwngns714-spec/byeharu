-- OSN-3 S4 — REAL-CHAIN permission/RPC-boundary proof for the arrival processor. Runs via psql against a
-- DISPOSABLE local Supabase stack on the ACTUAL chain 0001..0058 (real roles/RLS/grants/cron). Proves the
-- processor is SECURITY DEFINER / owner postgres / search_path=public / no dynamic SQL, executable by
-- service_role ONLY (PUBLIC/anon/authenticated denied), that the S3 writer + four S2 helpers remain
-- client-inaccessible, that the canonical client-RPC ACL inventory survived the 0058 relock unchanged,
-- and the pg_cron job is registered. Read-only (no mutation).

\set ON_ERROR_STOP on

\echo ''
\echo '================= S4 PROCESSOR + S3 WRITER + S2 HELPER METADATA ================='
select p.proname, pg_get_function_identity_arguments(p.oid) as identity_args,
       p.prosecdef as security_definer, p.proconfig as function_config, pg_get_userbyid(p.proowner) as owner,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_x,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_x,
       has_function_privilege('service_role', p.oid, 'EXECUTE') as srv_x, p.proacl::text as acl
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname='public'
  and p.proname in ('process_mainship_space_arrivals','mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion')
order by p.proname;

-- ── the processor's boundary assertions ────────────────────────────────────────────────────────
do $$
declare r record;
begin
  select p.oid, p.prosecdef, p.proconfig, p.proacl, pg_get_userbyid(p.proowner) owner, pg_get_function_identity_arguments(p.oid) args, pg_get_functiondef(p.oid) def
    into r from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='process_mainship_space_arrivals';
  if r.oid is null then raise exception 'PERM FAIL: process_mainship_space_arrivals not installed'; end if;
  if r.args <> '' then raise exception 'PERM FAIL: processor signature mismatch (args=%)', r.args; end if;
  if not r.prosecdef then raise exception 'PERM FAIL: processor not SECURITY DEFINER'; end if;
  if r.proconfig is null or not ('search_path=public' = any(r.proconfig)) then raise exception 'PERM FAIL: processor search_path not pinned to public (%)', r.proconfig; end if;
  if r.owner <> 'postgres' then raise exception 'PERM FAIL: processor owner=% (expected postgres)', r.owner; end if;
  if r.def ~* 'execute format' or strpos(lower(r.def), 'execute ''') > 0 then raise exception 'PERM FAIL: processor appears to use dynamic EXECUTE'; end if;
  if has_function_privilege('anon', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: anon can EXECUTE the processor'; end if;
  if has_function_privilege('authenticated', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: authenticated can EXECUTE the processor'; end if;
  if not has_function_privilege('service_role', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: service_role cannot EXECUTE the processor'; end if;
  if r.proacl is null then raise exception 'PERM FAIL: processor has null proacl (defaults to PUBLIC EXECUTE)'; end if;
  if exists (select 1 from unnest(r.proacl) a where a::text like '=%') then raise exception 'PERM FAIL: processor grants EXECUTE to PUBLIC'; end if;
  raise notice 'PERM ok: process_mainship_space_arrivals() — SECURITY DEFINER, search_path=public, owner=postgres, no dynamic SQL; anon/authenticated/PUBLIC denied, service_role allowed';
end $$;

-- ── S3 writer + four S2 helpers remain client-inaccessible (unchanged by 0058) ────────────────────
do $$
declare r record; c int := 0;
begin
  for r in select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in ('mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion') loop
    c := c + 1;
    if has_function_privilege('anon', r.oid, 'EXECUTE') or has_function_privilege('authenticated', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: % is client-executable', r.proname; end if;
    if not has_function_privilege('service_role', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: % lost service_role execute', r.proname; end if;
  end loop;
  if c <> 5 then raise exception 'PERM FAIL: expected 5 server-only space fns, found %', c; end if;
  raise notice 'PERM ok: S3 writer + four S2 helpers remain service_role-only (client-inaccessible)';
end $$;

-- ── canonical client-RPC ACL inventory preserved; no server fn is player-facing ───────────────────
do $$
declare
  expected text[] := array['bootstrap_me','cancel_build_order','get_combat_reports','get_my_expedition_preview','get_world_map','move_main_ship_to_location','repair_main_ship','request_leave_location','request_main_ship_return','request_retreat','send_fleet_to_location','send_main_ship_expedition','train_units'];
  actual text[];
  server_only text[] := array['process_mainship_space_arrivals','mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion'];
begin
  select coalesce(array_agg(distinct p.proname order by p.proname),'{}') into actual
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  raise notice 'authenticated-executable public functions = %', actual;
  if actual && server_only then raise exception 'PERM FAIL: a server-only fn is authenticated-executable: %', actual; end if;
  if not (actual @> expected) then raise exception 'PERM FAIL: a canonical client RPC LOST execute. expected=% actual=%', expected, actual; end if;
  if not (expected @> actual) then raise notice 'NOTE: extra authenticated-executable fn(s): %', (select array_agg(x) from unnest(actual) x where not (x = any(expected))); end if;
  if not has_function_privilege('anon', 'public.get_world_map()'::regprocedure, 'EXECUTE') then raise exception 'PERM FAIL: anon lost get_world_map'; end if;
  raise notice 'PERM ok: canonical client-RPC inventory preserved (no server fn exposed, no client RPC lost)';
end $$;

-- ── public-schema CREATE denied; the arrival cron job exists with the established cadence ─────────
do $$
declare n int; sched text; cmd text;
begin
  if has_schema_privilege('anon','public','CREATE') or has_schema_privilege('authenticated','public','CREATE') then raise exception 'PERM FAIL: client role can CREATE in public'; end if;
  select count(*), max(schedule), max(command) into n, sched, cmd from cron.job where jobname='process-mainship-space-arrivals';
  if n <> 1 then raise exception 'CRON FAIL: expected 1 arrival job, found %', n; end if;
  if sched <> '30 seconds' then raise exception 'CRON FAIL: schedule=%', sched; end if;
  if position('process_mainship_space_arrivals' in cmd) = 0 then raise exception 'CRON FAIL: command=%', cmd; end if;
  raise notice 'PERM ok: anon/authenticated cannot CREATE in public; cron job process-mainship-space-arrivals @ "30 seconds" present';
end $$;

-- ── space-movement flag + cap at migration defaults (read-only; fixtures simulate the activated state) ──
do $$ declare b text; c text; begin
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  select value::text into c from game_config where key='max_coordinate_travel_seconds';
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled=%', b; end if;
  if c is distinct from '86400' then raise exception 'CONFIG FAIL: max_coordinate_travel_seconds=%', c; end if;
  raise notice 'PERM ok: mainship_space_movement_enabled=false, max_coordinate_travel_seconds=86400 (chain defaults)';
end $$;

select 'OSN-3 S4 REAL-CHAIN PERMISSION PROOF: ALL PASSED' as result;
