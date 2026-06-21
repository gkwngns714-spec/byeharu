-- OSN-3 S2 — REAL-CHAIN schema/permission/RPC-boundary proof. Runs via psql against a DISPOSABLE
-- local Supabase stack whose schema is the ACTUAL migration chain 0001..0056 (NOT a stub, NOT the
-- shared/live DB). Inspects the installed helpers, proves the SECURITY DEFINER/private boundary at
-- runtime against the real roles (anon/authenticated/service_role), verifies the canonical client-RPC
-- ACL inventory survived the 0056 relock, and asserts both flags are false. Read-only (no mutation).

\set ON_ERROR_STOP on

\echo ''
\echo '================= INSTALLED S2 HELPER DEFINITIONS (from the applied migration chain) ================='
select pg_get_functiondef(p.oid) as installed_definition
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'mainship_space_%'
order by p.proname;

\echo ''
\echo '================= pg_proc METADATA ================='
select n.nspname as schema, p.proname,
       pg_get_function_identity_arguments(p.oid) as identity_args,
       p.prosecdef as security_definer, p.proconfig as function_config,
       pg_get_userbyid(p.proowner) as owner, p.proacl::text as acl
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'mainship_space_%'
order by p.proname;

-- ── per-helper boundary assertions ─────────────────────────────────────────────────────────────
do $$
declare r record; cnt int := 0;
begin
  for r in
    select p.oid, p.proname, p.prosecdef, p.proconfig, p.proacl, pg_get_functiondef(p.oid) def, pg_get_userbyid(p.proowner) owner
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion')
  loop
    cnt := cnt + 1;
    if not r.prosecdef then raise exception 'PERM FAIL: % is not SECURITY DEFINER', r.proname; end if;
    if r.proconfig is null or not ('search_path=public' = any(r.proconfig)) then raise exception 'PERM FAIL: % search_path not pinned to public (%)', r.proname, r.proconfig; end if;
    if strpos(lower(r.def), 'execute ') > 0 then raise exception 'PERM FAIL: % appears to use dynamic EXECUTE', r.proname; end if;
    if has_function_privilege('anon', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: anon can EXECUTE %', r.proname; end if;
    if has_function_privilege('authenticated', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: authenticated can EXECUTE %', r.proname; end if;
    if not has_function_privilege('service_role', r.oid, 'EXECUTE') then raise exception 'PERM FAIL: service_role cannot EXECUTE %', r.proname; end if;
    -- PUBLIC must have no EXECUTE: proacl must be non-null (else default = PUBLIC execute) and have no empty-grantee ('=...') entry
    if r.proacl is null then raise exception 'PERM FAIL: % has null proacl (defaults to PUBLIC EXECUTE)', r.proname; end if;
    if exists (select 1 from unnest(r.proacl) a where a::text like '=%') then raise exception 'PERM FAIL: % grants EXECUTE to PUBLIC', r.proname; end if;
    raise notice 'PERM ok: % — SECURITY DEFINER, search_path=public, owner=%, no dynamic SQL; anon/authenticated/PUBLIC denied, service_role allowed', r.proname, r.owner;
  end loop;
  if cnt <> 4 then raise exception 'PERM FAIL: expected 4 S2 helpers installed, found %', cnt; end if;
end $$;

-- ── canonical client-RPC ACL inventory (the 0056 relock must preserve exactly the expected set) ───
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
  raise notice 'authenticated-executable public functions = %', actual;
  if actual && s2 then raise exception 'PERM FAIL: an S2 helper is authenticated-executable: %', actual; end if;
  if not (actual @> expected) then raise exception 'PERM FAIL: a canonical client RPC LOST execute. expected ⊆ actual; expected=% actual=%', expected, actual; end if;
  -- surface (do not hard-fail) any unexpected extra authenticated-executable public function for review
  if not (expected @> actual) then raise notice 'NOTE: extra authenticated-executable public function(s) beyond the canonical list: %', (select array_agg(x) from unnest(actual) x where not (x = any(expected))); end if;
  -- anon should be able to execute only get_world_map among these
  if not has_function_privilege('anon', 'public.get_world_map()'::regprocedure, 'EXECUTE') then raise exception 'PERM FAIL: anon lost get_world_map'; end if;
  raise notice 'PERM ok: canonical client-RPC inventory preserved (no S2 helper exposed, no client RPC lost)';
end $$;

-- ── public-schema CREATE must be unavailable to PUBLIC/anon/authenticated (so search_path=public is safe) ──
do $$
begin
  if has_schema_privilege('anon','public','CREATE') then raise exception 'PERM FAIL: anon can CREATE in public'; end if;
  if has_schema_privilege('authenticated','public','CREATE') then raise exception 'PERM FAIL: authenticated can CREATE in public'; end if;
  raise notice 'PERM ok: anon/authenticated cannot CREATE in public (no object-injection vector → search_path=public safe)';
end $$;

-- ── both feature flags must be false (read-only assertion; the proof never updates a flag) ─────────
do $$
declare a text; b text;
begin
  select value::text into a from game_config where key = 'mainship_send_enabled';
  select value::text into b from game_config where key = 'mainship_space_movement_enabled';
  if a is distinct from 'false' then raise exception 'FLAG FAIL: mainship_send_enabled = %', a; end if;
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled = %', b; end if;
  raise notice 'FLAG ok: mainship_send_enabled=% mainship_space_movement_enabled=% (both false)', a, b;
end $$;

select 'OSN-3 S2 REAL-CHAIN PERMISSION PROOF: ALL PASSED' as result;
