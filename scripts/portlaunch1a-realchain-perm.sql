-- PORT-LAUNCH-1A — REAL-CHAIN permission/boundary proof for the two new functions on the ACTUAL migration
-- chain (through 0068). Proves the security posture WITHOUT mutating any game state. Disposable stack only.

\set ON_ERROR_STOP on

-- 1) reveal_starter_ports: SECURITY DEFINER / owner postgres / search_path=public / plpgsql; service_role-only.
do $$
declare v_sec boolean; v_owner name; v_cfg text[]; v_lang name;
begin
  select p.prosecdef, r.rolname, p.proconfig, l.lanname
    into v_sec, v_owner, v_cfg, v_lang
  from pg_proc p join pg_roles r on r.oid = p.proowner join pg_language l on l.oid = p.prolang
  where p.oid = 'public.reveal_starter_ports()'::regprocedure;
  if v_sec is not true then raise exception 'PERM FAIL: reveal_starter_ports not SECURITY DEFINER'; end if;
  if v_owner <> 'postgres' then raise exception 'PERM FAIL: reveal_starter_ports owner=% (expected postgres)', v_owner; end if;
  if v_cfg is null or not ('search_path=public' = any(v_cfg)) then raise exception 'PERM FAIL: reveal_starter_ports search_path not pinned to public (%)', v_cfg; end if;
  if v_lang <> 'plpgsql' then raise exception 'PERM FAIL: reveal_starter_ports language=% (expected plpgsql)', v_lang; end if;
  if not has_function_privilege('service_role', 'public.reveal_starter_ports()', 'EXECUTE')
    then raise exception 'PERM FAIL: service_role cannot EXECUTE reveal_starter_ports'; end if;
  if has_function_privilege('anon', 'public.reveal_starter_ports()', 'EXECUTE')
    then raise exception 'PERM FAIL: anon CAN EXECUTE reveal_starter_ports'; end if;
  if has_function_privilege('authenticated', 'public.reveal_starter_ports()', 'EXECUTE')
    then raise exception 'PERM FAIL: authenticated CAN EXECUTE reveal_starter_ports'; end if;
  raise notice 'ok: reveal_starter_ports = SECDEF / owner postgres / search_path public / plpgsql / service_role-only (anon+authenticated denied, no client wrapper)';
end $$;

-- 2) get_osn_movement_readiness: SECURITY DEFINER / owner postgres / search_path=public; authenticated yes; anon no.
--    (service_role EXECUTE is intentionally NOT asserted: on hosted prod Supabase default privileges grant it,
--     but the disposable local stack does not reproduce that — the dedicated prod verifier owns that policy.)
do $$
declare v_sec boolean; v_owner name; v_cfg text[];
begin
  select p.prosecdef, r.rolname, p.proconfig into v_sec, v_owner, v_cfg
  from pg_proc p join pg_roles r on r.oid = p.proowner
  where p.oid = 'public.get_osn_movement_readiness()'::regprocedure;
  if v_sec is not true then raise exception 'PERM FAIL: get_osn_movement_readiness not SECURITY DEFINER'; end if;
  if v_owner <> 'postgres' then raise exception 'PERM FAIL: get_osn_movement_readiness owner=% (expected postgres)', v_owner; end if;
  if v_cfg is null or not ('search_path=public' = any(v_cfg)) then raise exception 'PERM FAIL: get_osn_movement_readiness search_path not pinned to public (%)', v_cfg; end if;
  if not has_function_privilege('authenticated', 'public.get_osn_movement_readiness()', 'EXECUTE')
    then raise exception 'PERM FAIL: authenticated cannot EXECUTE get_osn_movement_readiness'; end if;
  if has_function_privilege('anon', 'public.get_osn_movement_readiness()', 'EXECUTE')
    then raise exception 'PERM FAIL: anon CAN EXECUTE get_osn_movement_readiness'; end if;
  raise notice 'ok: get_osn_movement_readiness = SECDEF / owner postgres / search_path public / authenticated-only (anon denied)';
end $$;

-- 3) EXACT canonical authenticated surface = 17 (incl. get_osn_movement_readiness); reveal_starter_ports + all
--    OSN internals stay OFF the client surface. Any drift/overload/missing/unexpected is a hard failure.
do $$
declare actual text[]; n_total int; n_distinct int;
  expected text[] := array[   -- alphabetically sorted (matches array_agg order by proname)
    'bootstrap_me','cancel_build_order','command_main_ship_space_move','command_main_ship_space_move_to_location',
    'command_main_ship_space_stop','get_combat_reports','get_my_expedition_preview','get_osn_movement_readiness',
    'get_world_map','move_main_ship_to_location','repair_main_ship','request_leave_location','request_main_ship_return',
    'request_retreat','send_fleet_to_location','send_main_ship_expedition','train_units'];
begin
  select array_agg(p.proname order by p.proname), count(*), count(distinct p.proname)
    into actual, n_total, n_distinct
  from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.prokind = 'f' and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if n_total <> 17 then raise exception 'PERM FAIL: authenticated surface count = % (expected exactly 17): %', n_total, actual; end if;
  if n_distinct <> 17 then raise exception 'PERM FAIL: overloaded/duplicate authenticated callable (% grants / % names): %', n_total, n_distinct, actual; end if;
  if actual is distinct from expected then raise exception 'PERM FAIL: authenticated surface != canonical 17. actual=%', actual; end if;
  if 'reveal_starter_ports' = any(actual) then raise exception 'PERM FAIL: reveal_starter_ports is client-callable (must be service_role-only)'; end if;
  raise notice 'ok: authenticated surface is EXACTLY the canonical 17 (16 + get_osn_movement_readiness); reveal_starter_ports + OSN internals absent';
end $$;

-- 4) representative OSN internals remain service_role-only (non-regression with the new re-lock).
do $$
begin
  if has_function_privilege('authenticated', 'public.mainship_space_resolve_origin(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.mainship_space_resolve_origin(uuid)', 'EXECUTE')
    then raise exception 'PERM FAIL: a client role CAN EXECUTE mainship_space_resolve_origin'; end if;
  if has_function_privilege('authenticated', 'public.mainship_space_location_target_legal(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.mainship_space_location_target_legal(uuid)', 'EXECUTE')
    then raise exception 'PERM FAIL: a client role CAN EXECUTE mainship_space_location_target_legal'; end if;
  raise notice 'ok: OSN resolver + target-legality remain service_role-only after the 0068 re-lock';
end $$;

select 'PORT-LAUNCH-1A REAL-CHAIN PERMISSION/BOUNDARY PROOF: ALL PASSED' as result;
