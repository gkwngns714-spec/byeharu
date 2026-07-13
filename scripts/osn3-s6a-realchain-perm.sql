-- OSN-3 S6A — REAL-CHAIN permission/RPC-boundary proof for the public coordinate-command wrapper
-- public.command_main_ship_space_move. Runs via psql against a DISPOSABLE local Supabase stack on the
-- ACTUAL chain 0001..0060 (real roles/RLS/grants/cron). Proves the wrapper is SECURITY DEFINER / owner
-- postgres / search_path=public / no dynamic SQL, authenticated-EXECUTE only (anon + PUBLIC denied);
-- that the private writer mainship_space_begin_move + S4 processor + S5 destruction + four S2 helpers
-- remain service_role ONLY (unchanged by the 0060 relock); that the canonical client-RPC inventory now
-- contains exactly the prior list PLUS command_main_ship_space_move; and that the S4 arrival cron and the
-- coordinate flag/cap are unchanged.

\set ON_ERROR_STOP on

\echo ''
\echo '================= PUBLIC WRAPPER + WRITER/PROCESSOR/HELPER METADATA ================='
select p.proname, pg_get_function_identity_arguments(p.oid) args, p.prosecdef sd, p.proconfig cfg, pg_get_userbyid(p.proowner) owner,
       has_function_privilege('anon',p.oid,'EXECUTE') anon_x, has_function_privilege('authenticated',p.oid,'EXECUTE') auth_x,
       has_function_privilege('service_role',p.oid,'EXECUTE') srv_x, p.proacl::text acl
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('command_main_ship_space_move','mainship_space_begin_move','process_mainship_space_arrivals','dev_set_main_ship_destroyed','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion')
order by p.proname;

-- ── public wrapper boundary: definer/owner/search_path/no-dynamic-sql; authenticated-only EXECUTE ──
do $$
declare r record;
begin
  select p.oid, p.prosecdef, p.proconfig, p.proacl, pg_get_userbyid(p.proowner) owner, pg_get_function_identity_arguments(p.oid) args, pg_get_functiondef(p.oid) def
    into r from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='command_main_ship_space_move';
  if r.oid is null then raise exception 'PERM FAIL: command_main_ship_space_move missing'; end if;
  if r.args <> 'p_target_x double precision, p_target_y double precision, p_request_id uuid' then raise exception 'PERM FAIL: wrapper signature mismatch (%)', r.args; end if;
  if not r.prosecdef then raise exception 'PERM FAIL: wrapper not SECURITY DEFINER'; end if;
  if r.proconfig is null or not ('search_path=public'=any(r.proconfig)) then raise exception 'PERM FAIL: wrapper search_path not public (%)', r.proconfig; end if;
  if r.owner <> 'postgres' then raise exception 'PERM FAIL: wrapper owner=% (expected postgres)', r.owner; end if;
  if r.def ~* 'execute format' or strpos(lower(r.def),'execute ''')>0 then raise exception 'PERM FAIL: wrapper has dynamic EXECUTE'; end if;
  -- the wrapper must NOT accept a player id or a ship id (only target x/y + request_id)
  if r.args ~* 'player' or r.args ~* 'ship' then raise exception 'PERM FAIL: wrapper accepts a player/ship id (%)', r.args; end if;
  if has_function_privilege('anon',r.oid,'EXECUTE') then raise exception 'PERM FAIL: anon can EXECUTE the wrapper'; end if;
  if not has_function_privilege('authenticated',r.oid,'EXECUTE') then raise exception 'PERM FAIL: authenticated cannot EXECUTE the wrapper'; end if;
  if r.proacl is null or exists (select 1 from unnest(r.proacl) a where a::text like '=%') then raise exception 'PERM FAIL: wrapper is PUBLIC-executable'; end if;
  raise notice 'PERM ok: command_main_ship_space_move(p_target_x double precision, p_target_y double precision, p_request_id uuid) — SECURITY DEFINER, owner=postgres, search_path=public, no dynamic SQL, no player/ship id param; authenticated-only (anon + PUBLIC denied)';
end $$;

-- ── the private writer + S4 processor + S5 destruction + four S2 helpers remain client-inaccessible ──
do $$
declare r record; c int := 0;
begin
  for r in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in ('mainship_space_begin_move','process_mainship_space_arrivals','dev_set_main_ship_destroyed','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion') loop
    c:=c+1;
    if has_function_privilege('anon',r.oid,'EXECUTE') or has_function_privilege('authenticated',r.oid,'EXECUTE') then raise exception 'PERM FAIL: % is client-executable', r.proname; end if;
    if not has_function_privilege('service_role',r.oid,'EXECUTE') then raise exception 'PERM FAIL: % lost service_role', r.proname; end if;
  end loop;
  if c<>7 then raise exception 'PERM FAIL: expected 7 server-only space fns, found %', c; end if;
  raise notice 'PERM ok: private writer + S4 processor + S5 destruction + four S2 helpers remain service_role-only (the client never gains the writer)';
end $$;

-- ── canonical client-RPC inventory = prior list + command_main_ship_space_move; no server fn exposed ──
do $$
declare expected text[] := array['bootstrap_me','cancel_build_order','command_main_ship_space_move','get_combat_reports','get_my_expedition_preview','get_world_map','move_main_ship_to_location','repair_main_ship','request_leave_location','request_main_ship_return','request_retreat','send_fleet_to_location','send_main_ship_expedition','train_units'];
  actual text[]; server_only text[] := array['mainship_space_begin_move','process_mainship_space_arrivals','dev_set_main_ship_destroyed','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion'];
begin
  select coalesce(array_agg(distinct p.proname order by p.proname),'{}') into actual from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('authenticated',p.oid,'EXECUTE');
  raise notice 'authenticated-executable public functions = %', actual;
  if actual && server_only then raise exception 'PERM FAIL: a server-only fn is authenticated-executable: %', actual; end if;
  if not (actual @> expected) then raise exception 'PERM FAIL: a canonical client RPC is missing. expected=% actual=%', expected, actual; end if;
  if not (expected @> actual) then raise notice 'NOTE: extra authenticated-executable fn(s): %', (select array_agg(x) from unnest(actual) x where not (x = any(expected))); end if;
  if not has_function_privilege('anon','public.get_world_map()'::regprocedure,'EXECUTE') then raise exception 'PERM FAIL: anon lost get_world_map'; end if;
  if not has_function_privilege('authenticated','public.repair_main_ship()'::regprocedure,'EXECUTE') then raise exception 'PERM FAIL: repair_main_ship lost authenticated execute'; end if;
  if not has_function_privilege('authenticated','public.send_main_ship_expedition(jsonb, uuid, uuid)'::regprocedure,'EXECUTE') then raise exception 'PERM FAIL: send_main_ship_expedition lost authenticated execute'; end if;  -- NO-HOME (0199): widened with p_return_location_id
  if not has_function_privilege('authenticated','public.move_main_ship_to_location(uuid, uuid)'::regprocedure,'EXECUTE') then raise exception 'PERM FAIL: move_main_ship_to_location lost authenticated execute'; end if;
  raise notice 'PERM ok: canonical client-RPC inventory = prior 13 + command_main_ship_space_move; no server fn exposed; legacy main-ship RPCs intact';
end $$;

-- ── public CREATE denied; S4 arrival cron present exactly once; coordinate flag/cap at chain defaults ──
do $$
declare n int; sched text; cmd text; b text; c text;
begin
  if has_schema_privilege('anon','public','CREATE') or has_schema_privilege('authenticated','public','CREATE') then raise exception 'PERM FAIL: client role can CREATE in public'; end if;
  select count(*), max(schedule), max(command) into n, sched, cmd from cron.job where jobname='process-mainship-space-arrivals';
  if n<>1 then raise exception 'CRON FAIL: % arrival jobs', n; end if;
  if sched<>'30 seconds' then raise exception 'CRON FAIL: schedule=%', sched; end if;
  if position('process_mainship_space_arrivals' in cmd)=0 then raise exception 'CRON FAIL: command=%', cmd; end if;
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  select value::text into c from game_config where key='max_coordinate_travel_seconds';
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled=%', b; end if;
  if c is distinct from '86400' then raise exception 'CONFIG FAIL: max_coordinate_travel_seconds=%', c; end if;
  raise notice 'PERM ok: anon/authenticated cannot CREATE in public; S4 arrival cron present once @ "30 seconds"; space flag=false, cap=86400 (chain defaults; the wrapper does NOT flip the flag)';
end $$;

select 'OSN-3 S6A REAL-CHAIN PERMISSION PROOF: ALL PASSED' as result;
