-- OSN-3 S2 — AUTHORITATIVE LIVE read-only inspection (psql against the live DB via the Supabase pooler).
-- Pure catalog/config SELECTs + one row count. NO mutation, NO helper execution, NO fixtures, NO test
-- users, NO flag change. This is the authoritative source for owner/ACL/flags/row-count on live, because
-- `supabase db dump` strips ownership (--no-owner) and is lossy for privileges. Read-only only.

\set ON_ERROR_STOP on
\pset pager off

\echo ''
\echo '================= LIVE S2 HELPER METADATA ================='
select p.proname,
       pg_get_function_identity_arguments(p.oid) as identity_args,
       p.prosecdef as security_definer,
       p.proconfig as function_config,
       pg_get_userbyid(p.proowner) as owner,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_exec,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_exec,
       has_function_privilege('service_role', p.oid, 'EXECUTE')  as service_role_exec,
       p.proacl::text as acl
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'mainship_space_%'
order by p.proname;

-- ── per-helper boundary assertions (presence, signature surface, owner, definer, search_path, ACL) ──
do $$
declare r record; cnt int := 0;
begin
  for r in
    select p.oid, p.proname, p.prosecdef, p.proconfig, p.proacl,
           pg_get_userbyid(p.proowner) owner,
           pg_get_function_identity_arguments(p.oid) args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('mainship_space_lock_context','mainship_space_validate_context',
                        'mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion')
  loop
    cnt := cnt + 1;
    if r.owner <> 'postgres' then raise exception 'LIVE FAIL: % owner=% (expected postgres)', r.proname, r.owner; end if;
    if not r.prosecdef then raise exception 'LIVE FAIL: % is not SECURITY DEFINER', r.proname; end if;
    if r.proconfig is null or not ('search_path=public' = any(r.proconfig)) then raise exception 'LIVE FAIL: % search_path not pinned to public (%)', r.proname, r.proconfig; end if;
    if has_function_privilege('anon', r.oid, 'EXECUTE') then raise exception 'LIVE FAIL: anon can EXECUTE %', r.proname; end if;
    if has_function_privilege('authenticated', r.oid, 'EXECUTE') then raise exception 'LIVE FAIL: authenticated can EXECUTE %', r.proname; end if;
    if not has_function_privilege('service_role', r.oid, 'EXECUTE') then raise exception 'LIVE FAIL: service_role cannot EXECUTE %', r.proname; end if;
    if r.proacl is null then raise exception 'LIVE FAIL: % has null proacl (defaults to PUBLIC EXECUTE)', r.proname; end if;
    if exists (select 1 from unnest(r.proacl) a where a::text like '=%') then raise exception 'LIVE FAIL: % grants EXECUTE to PUBLIC', r.proname; end if;
    raise notice 'LIVE ok: % (%) — owner=postgres, SECURITY DEFINER, search_path=public; anon/authenticated/PUBLIC denied, service_role allowed', r.proname, r.args;
  end loop;
  if cnt <> 4 then raise exception 'LIVE FAIL: expected 4 S2 helpers on live, found %', cnt; end if;
end $$;

-- ── canonical client-RPC ACL inventory preserved; no S2 helper is a player-facing RPC ──
do $$
declare
  expected text[] := array['bootstrap_me','cancel_build_order','get_combat_reports','get_my_expedition_preview',
    'get_world_map','move_main_ship_to_location','repair_main_ship','request_leave_location','request_main_ship_return',
    'request_retreat','send_fleet_to_location','send_main_ship_expedition','train_units'];
  actual text[];
  s2 text[] := array['mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion'];
begin
  select coalesce(array_agg(distinct p.proname order by p.proname), '{}') into actual
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  raise notice 'LIVE authenticated-executable public functions = %', actual;
  if actual && s2 then raise exception 'LIVE FAIL: an S2 helper is authenticated-executable (player-facing RPC): %', actual; end if;
  if not (actual @> expected) then raise exception 'LIVE FAIL: a canonical client RPC LOST execute. expected=% actual=%', expected, actual; end if;
  if not (expected @> actual) then raise notice 'LIVE NOTE: extra authenticated-executable public function(s) beyond canonical list: %', (select array_agg(x) from unnest(actual) x where not (x = any(expected))); end if;
  if not has_function_privilege('anon', 'public.get_world_map()'::regprocedure, 'EXECUTE') then raise exception 'LIVE FAIL: anon lost get_world_map'; end if;
  raise notice 'LIVE ok: canonical client-RPC inventory preserved (no S2 helper exposed, no client RPC lost)';
end $$;

-- ── public-schema CREATE unavailable to PUBLIC/anon/authenticated ──
do $$
begin
  if has_schema_privilege('anon','public','CREATE') then raise exception 'LIVE FAIL: anon can CREATE in public'; end if;
  if has_schema_privilege('authenticated','public','CREATE') then raise exception 'LIVE FAIL: authenticated can CREATE in public'; end if;
  raise notice 'LIVE ok: anon/authenticated cannot CREATE in public schema';
end $$;

-- ── both feature flags must be false (read-only assertion; never updates a flag) ──
do $$
declare a text; b text;
begin
  select value::text into a from game_config where key = 'mainship_send_enabled';
  select value::text into b from game_config where key = 'mainship_space_movement_enabled';
  if a is distinct from 'false' then raise exception 'LIVE FLAG FAIL: mainship_send_enabled = %', a; end if;
  if b is distinct from 'false' then raise exception 'LIVE FLAG FAIL: mainship_space_movement_enabled = %', b; end if;
  raise notice 'LIVE ok: mainship_send_enabled=% mainship_space_movement_enabled=% (both false)', a, b;
end $$;

-- ── coordinate-movement table must be empty (no writer exists in S2) ──
do $$
declare n bigint;
begin
  select count(*) into n from main_ship_space_movements;
  if n <> 0 then raise exception 'LIVE FAIL: main_ship_space_movements row count = % (expected 0)', n; end if;
  raise notice 'LIVE ok: main_ship_space_movements row count = 0';
end $$;

select 'OSN-3 S2 LIVE READ-ONLY CATALOG INSPECTION: ALL PASSED' as result;
