-- OSN-3 S5 — REAL-CHAIN permission/RPC-boundary proof for the coordinate-complete destruction primitive.
-- Runs via psql against a DISPOSABLE local Supabase stack on the ACTUAL chain 0001..0059 (real roles/
-- RLS/grants/cron). Proves dev_set_main_ship_destroyed is SECURITY DEFINER / owner postgres /
-- search_path=public, service_role ONLY (PUBLIC/anon/authenticated denied, no player wrapper); that the
-- S4 processor + S3 writer + four S2 helpers remain service_role-only; that the canonical client-RPC ACL
-- inventory survived the 0059 relock unchanged; and that the S4 arrival cron is still present exactly once.

\set ON_ERROR_STOP on

\echo ''
\echo '================= DESTRUCTION PRIMITIVE + S4/S3/S2 SERVER FN METADATA ================='
select p.proname, pg_get_function_identity_arguments(p.oid) args, p.prosecdef sd, p.proconfig cfg, pg_get_userbyid(p.proowner) owner,
       has_function_privilege('anon',p.oid,'EXECUTE') anon_x, has_function_privilege('authenticated',p.oid,'EXECUTE') auth_x,
       has_function_privilege('service_role',p.oid,'EXECUTE') srv_x, p.proacl::text acl
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('dev_set_main_ship_destroyed','process_mainship_space_arrivals','mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion')
order by p.proname;

-- ── destruction primitive boundary ──────────────────────────────────────────────────────────────
do $$
declare r record;
begin
  select p.oid, p.prosecdef, p.proconfig, p.proacl, pg_get_userbyid(p.proowner) owner, pg_get_function_identity_arguments(p.oid) args, pg_get_functiondef(p.oid) def
    into r from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='dev_set_main_ship_destroyed';
  if r.oid is null then raise exception 'PERM FAIL: dev_set_main_ship_destroyed missing'; end if;
  if r.args <> 'p_player uuid' then raise exception 'PERM FAIL: destruction signature mismatch (%)', r.args; end if;
  if not r.prosecdef then raise exception 'PERM FAIL: not SECURITY DEFINER'; end if;
  if r.proconfig is null or not ('search_path=public'=any(r.proconfig)) then raise exception 'PERM FAIL: search_path not public (%)', r.proconfig; end if;
  if r.owner <> 'postgres' then raise exception 'PERM FAIL: owner=% (expected postgres)', r.owner; end if;
  if r.def ~* 'execute format' or strpos(lower(r.def),'execute ''')>0 then raise exception 'PERM FAIL: dynamic EXECUTE present'; end if;
  if has_function_privilege('anon',r.oid,'EXECUTE') then raise exception 'PERM FAIL: anon can EXECUTE'; end if;
  if has_function_privilege('authenticated',r.oid,'EXECUTE') then raise exception 'PERM FAIL: authenticated can EXECUTE'; end if;
  if not has_function_privilege('service_role',r.oid,'EXECUTE') then raise exception 'PERM FAIL: service_role cannot EXECUTE'; end if;
  if r.proacl is null or exists (select 1 from unnest(r.proacl) a where a::text like '=%') then raise exception 'PERM FAIL: PUBLIC-executable'; end if;
  raise notice 'PERM ok: dev_set_main_ship_destroyed(p_player uuid) — SECURITY DEFINER, owner=postgres, search_path=public, no dynamic SQL, no player wrapper; anon/authenticated/PUBLIC denied, service_role allowed';
end $$;

-- ── S4 processor + S3 writer + four S2 helpers remain client-inaccessible (unchanged by 0059) ─────
do $$
declare r record; c int := 0;
begin
  for r in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in ('process_mainship_space_arrivals','mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion') loop
    c:=c+1;
    if has_function_privilege('anon',r.oid,'EXECUTE') or has_function_privilege('authenticated',r.oid,'EXECUTE') then raise exception 'PERM FAIL: % client-executable', r.proname; end if;
    if not has_function_privilege('service_role',r.oid,'EXECUTE') then raise exception 'PERM FAIL: % lost service_role', r.proname; end if;
  end loop;
  if c<>6 then raise exception 'PERM FAIL: expected 6 server-only space fns, found %', c; end if;
  raise notice 'PERM ok: S4 processor + S3 writer + four S2 helpers remain service_role-only';
end $$;

-- ── canonical client-RPC inventory preserved; no server fn is player-facing ───────────────────────
do $$
declare expected text[] := array['bootstrap_me','cancel_build_order','get_combat_reports','get_my_expedition_preview','get_world_map','move_main_ship_to_location','repair_main_ship','request_leave_location','request_main_ship_return','request_retreat','send_fleet_to_location','send_main_ship_expedition','train_units'];
  actual text[]; server_only text[] := array['dev_set_main_ship_destroyed','process_mainship_space_arrivals','mainship_space_begin_move','mainship_space_lock_context','mainship_space_validate_context','mainship_space_resolve_origin','mainship_space_assert_cross_domain_exclusion'];
begin
  select coalesce(array_agg(distinct p.proname order by p.proname),'{}') into actual from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('authenticated',p.oid,'EXECUTE');
  raise notice 'authenticated-executable public functions = %', actual;
  if actual && server_only then raise exception 'PERM FAIL: a server-only fn is authenticated-executable: %', actual; end if;
  if not (actual @> expected) then raise exception 'PERM FAIL: a canonical client RPC lost execute. expected=% actual=%', expected, actual; end if;
  if not (expected @> actual) then raise notice 'NOTE: extra authenticated-executable fn(s): %', (select array_agg(x) from unnest(actual) x where not (x = any(expected))); end if;
  if not has_function_privilege('anon','public.get_world_map()'::regprocedure,'EXECUTE') then raise exception 'PERM FAIL: anon lost get_world_map'; end if;
  raise notice 'PERM ok: canonical client-RPC inventory preserved (no server fn exposed, no client RPC lost)';
end $$;

-- ── public CREATE denied; S4 arrival cron still present exactly once (unchanged by 0059) ───────────
do $$
declare n int; sched text; cmd text;
begin
  if has_schema_privilege('anon','public','CREATE') or has_schema_privilege('authenticated','public','CREATE') then raise exception 'PERM FAIL: client role can CREATE in public'; end if;
  select count(*), max(schedule), max(command) into n, sched, cmd from cron.job where jobname='process-mainship-space-arrivals';
  if n<>1 then raise exception 'CRON FAIL: % arrival jobs', n; end if;
  if sched<>'30 seconds' then raise exception 'CRON FAIL: schedule=%', sched; end if;
  if position('process_mainship_space_arrivals' in cmd)=0 then raise exception 'CRON FAIL: command=%', cmd; end if;
  raise notice 'PERM ok: anon/authenticated cannot CREATE in public; S4 arrival cron present exactly once @ "30 seconds" (untouched by 0059)';
end $$;

-- ── repair_main_ship remains a client RPC (unchanged); space flag + cap at chain defaults ─────────
do $$ declare b text; c text; begin
  if not has_function_privilege('authenticated','public.repair_main_ship()'::regprocedure,'EXECUTE') then raise exception 'PERM FAIL: repair_main_ship lost authenticated execute'; end if;
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  select value::text into c from game_config where key='max_coordinate_travel_seconds';
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled=%', b; end if;
  if c is distinct from '86400' then raise exception 'CONFIG FAIL: max_coordinate_travel_seconds=%', c; end if;
  raise notice 'PERM ok: repair_main_ship still authenticated-executable; mainship_space_movement_enabled=false, cap=86400 (chain defaults)';
end $$;

select 'OSN-3 S5 REAL-CHAIN PERMISSION PROOF: ALL PASSED' as result;
