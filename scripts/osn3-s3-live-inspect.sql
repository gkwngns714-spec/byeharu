-- OSN-3 S3 — AUTHORITATIVE LIVE read-only inspection (psql against live via the Supabase pooler).
-- Pure catalog/config SELECTs + row counts. NO mutation, NO writer/helper execution, NO fixtures, NO
-- test users, NO flag change. Authoritative source for the S3 writer's owner/ACL/signature, the S2
-- helpers' continued isolation, the canonical client-RPC inventory, flags, the cap, and the zero
-- coordinate-movement / zero S3-receipt state. Read-only only.

\set ON_ERROR_STOP on
\pset pager off

\echo ''
\echo '================= LIVE S3 WRITER + S2 HELPER METADATA ================='
select p.proname,
       pg_get_function_identity_arguments(p.oid) as identity_args,
       p.prosecdef as security_definer, p.proconfig as function_config,
       pg_get_userbyid(p.proowner) as owner,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_x,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_x,
       has_function_privilege('service_role', p.oid, 'EXECUTE')  as service_role_x,
       p.proacl::text as acl
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context',
                    'mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion')
order by p.proname;

-- ── the S3 writer: exists with the EXACT approved signature, owner/definer/search_path/ACL ──────────
do $$
declare r record; v_args text;
begin
  select p.oid, p.prosecdef, p.proconfig, p.proacl, pg_get_userbyid(p.proowner) owner,
         pg_get_function_identity_arguments(p.oid) args, pg_get_functiondef(p.oid) def
    into r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'mainship_space_begin_move';
  if r.oid is null then raise exception 'LIVE FAIL: mainship_space_begin_move not installed'; end if;
  v_args := r.args;
  if v_args <> 'p_player uuid, p_main_ship_id uuid, p_target_x double precision, p_target_y double precision, p_request_id uuid'
    then raise exception 'LIVE FAIL: writer signature mismatch: %', v_args; end if;
  if r.owner <> 'postgres' then raise exception 'LIVE FAIL: writer owner=% (expected postgres)', r.owner; end if;
  if not r.prosecdef then raise exception 'LIVE FAIL: writer not SECURITY DEFINER'; end if;
  if r.proconfig is null or not ('search_path=public' = any(r.proconfig)) then raise exception 'LIVE FAIL: writer search_path not pinned to public (%)', r.proconfig; end if;
  if r.def ~* 'execute format' or strpos(lower(r.def), 'execute ''') > 0 then raise exception 'LIVE FAIL: writer appears to use dynamic EXECUTE'; end if;
  if has_function_privilege('anon', r.oid, 'EXECUTE') then raise exception 'LIVE FAIL: anon can EXECUTE the writer'; end if;
  if has_function_privilege('authenticated', r.oid, 'EXECUTE') then raise exception 'LIVE FAIL: authenticated can EXECUTE the writer'; end if;
  if not has_function_privilege('service_role', r.oid, 'EXECUTE') then raise exception 'LIVE FAIL: service_role cannot EXECUTE the writer'; end if;
  if r.proacl is null then raise exception 'LIVE FAIL: writer has null proacl (defaults to PUBLIC EXECUTE)'; end if;
  if exists (select 1 from unnest(r.proacl) a where a::text like '=%') then raise exception 'LIVE FAIL: writer grants EXECUTE to PUBLIC'; end if;
  raise notice 'LIVE ok: mainship_space_begin_move(%) — owner=postgres, SECURITY DEFINER, search_path=public, no dynamic SQL; anon/authenticated/PUBLIC denied, service_role allowed', v_args;
end $$;

-- ── the four S2 helpers remain service_role-only / client-inaccessible ──────────────────────────────
do $$
declare r record; cnt int := 0;
begin
  for r in
    select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion')
  loop
    cnt := cnt + 1;
    if has_function_privilege('anon', r.oid, 'EXECUTE') or has_function_privilege('authenticated', r.oid, 'EXECUTE') then
      raise exception 'LIVE FAIL: S2 helper % is client-executable', r.proname; end if;
    if not has_function_privilege('service_role', r.oid, 'EXECUTE') then raise exception 'LIVE FAIL: S2 helper % lost service_role execute', r.proname; end if;
  end loop;
  if cnt <> 4 then raise exception 'LIVE FAIL: expected 4 S2 helpers, found %', cnt; end if;
  raise notice 'LIVE ok: four S2 helpers remain service_role-only (client-inaccessible)';
end $$;

-- ── canonical client-RPC inventory unchanged; no server fn is a player-facing RPC ───────────────────
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
  raise notice 'LIVE authenticated-executable public functions = %', actual;
  if actual && server_only then raise exception 'LIVE FAIL: a server-only fn is authenticated-executable: %', actual; end if;
  if not (actual @> expected) then raise exception 'LIVE FAIL: a canonical client RPC LOST execute. expected=% actual=%', expected, actual; end if;
  if not (expected @> actual) then raise notice 'LIVE NOTE: extra authenticated-executable public function(s): %', (select array_agg(x) from unnest(actual) x where not (x = any(expected))); end if;
  if not has_function_privilege('anon', 'public.get_world_map()'::regprocedure, 'EXECUTE') then raise exception 'LIVE FAIL: anon lost get_world_map'; end if;
  raise notice 'LIVE ok: canonical client-RPC inventory unchanged (no server fn exposed, no client RPC lost)';
end $$;

-- ── public-schema CREATE unavailable to PUBLIC/anon/authenticated ───────────────────────────────────
do $$
begin
  if has_schema_privilege('anon','public','CREATE') then raise exception 'LIVE FAIL: anon can CREATE in public'; end if;
  if has_schema_privilege('authenticated','public','CREATE') then raise exception 'LIVE FAIL: authenticated can CREATE in public'; end if;
  raise notice 'LIVE ok: anon/authenticated cannot CREATE in public schema';
end $$;

-- ── flags false, cap 86400, zero coordinate movements, zero S3 receipts (read-only) ─────────────────
do $$
declare a text; b text; c text; nm bigint; nr bigint;
begin
  select value::text into a from game_config where key = 'mainship_send_enabled';
  select value::text into b from game_config where key = 'mainship_space_movement_enabled';
  select value::text into c from game_config where key = 'max_coordinate_travel_seconds';
  if a is distinct from 'false' then raise exception 'LIVE FLAG FAIL: mainship_send_enabled = %', a; end if;
  if b is distinct from 'false' then raise exception 'LIVE FLAG FAIL: mainship_space_movement_enabled = %', b; end if;
  if c is distinct from '86400' then raise exception 'LIVE CONFIG FAIL: max_coordinate_travel_seconds = % (expected 86400)', c; end if;
  select count(*) into nm from main_ship_space_movements;
  if nm <> 0 then raise exception 'LIVE FAIL: main_ship_space_movements row count = % (expected 0)', nm; end if;
  select count(*) into nr from main_ship_space_command_receipts;
  if nr <> 0 then raise exception 'LIVE FAIL: main_ship_space_command_receipts row count = % (expected 0)', nr; end if;
  raise notice 'LIVE ok: send=false, space_movement=false, cap=86400, main_ship_space_movements=0, command_receipts=0';
end $$;

select 'OSN-3 S3 LIVE READ-ONLY CATALOG INSPECTION: ALL PASSED' as result;
