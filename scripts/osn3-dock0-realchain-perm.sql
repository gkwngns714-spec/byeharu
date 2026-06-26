-- OSN-DOCK-0 — REAL-CHAIN permission/boundary proof for the private docking primitive
-- public.mainship_space_dock_at_location(uuid, uuid) and the re-created arrival processor, on the ACTUAL
-- migration chain (through 0061). Proves the security posture WITHOUT mutating any game state:
--   • the primitive is SECURITY DEFINER, owner postgres, explicit search_path=public, no dynamic SQL;
--   • EXECUTE is revoked from public/anon/authenticated and granted to service_role ONLY (no client surface);
--   • the arrival processor remains service_role-only;
--   • the migration added NO new anon/authenticated-callable function (the canonical client RPC inventory is
--     unchanged from 0060 — exactly the 14 client RPCs, none of them a docking/coordinate writer);
--   • the arrival cron job still exists exactly once @ "30 seconds".

\set ON_ERROR_STOP on

-- 1) primitive definition properties
do $$
declare v_sec boolean; v_owner name; v_cfg text[]; v_lang name; v_src text;
begin
  select p.prosecdef, r.rolname, p.proconfig, l.lanname, p.prosrc
    into v_sec, v_owner, v_cfg, v_lang, v_src
  from pg_proc p join pg_roles r on r.oid = p.proowner join pg_language l on l.oid = p.prolang
  where p.oid = 'public.mainship_space_dock_at_location(uuid,uuid)'::regprocedure;

  if v_sec is not true then raise exception 'PERM FAIL: docking primitive is not SECURITY DEFINER'; end if;
  if v_owner <> 'postgres' then raise exception 'PERM FAIL: docking primitive owner=% (expected postgres)', v_owner; end if;
  if v_cfg is null or not ('search_path=public' = any(v_cfg)) then raise exception 'PERM FAIL: docking primitive search_path not pinned to public (proconfig=%)', v_cfg; end if;
  if v_lang <> 'plpgsql' then raise exception 'PERM FAIL: docking primitive language=% (expected plpgsql)', v_lang; end if;
  if lower(v_src) like '%execute %' then raise exception 'PERM FAIL: docking primitive appears to use dynamic SQL (EXECUTE)'; end if;
  raise notice 'ok: docking primitive SECURITY DEFINER / owner postgres / search_path=public / plpgsql / no dynamic SQL';
end $$;

-- 2) EXECUTE grants on the primitive: service_role yes; anon/authenticated no (they inherit any PUBLIC grant,
--    so denying both also proves PUBLIC has no EXECUTE).
do $$
begin
  if not has_function_privilege('service_role', 'public.mainship_space_dock_at_location(uuid,uuid)', 'EXECUTE')
    then raise exception 'PERM FAIL: service_role cannot EXECUTE the docking primitive'; end if;
  if has_function_privilege('anon', 'public.mainship_space_dock_at_location(uuid,uuid)', 'EXECUTE')
    then raise exception 'PERM FAIL: anon CAN EXECUTE the docking primitive'; end if;
  if has_function_privilege('authenticated', 'public.mainship_space_dock_at_location(uuid,uuid)', 'EXECUTE')
    then raise exception 'PERM FAIL: authenticated CAN EXECUTE the docking primitive'; end if;
  raise notice 'ok: docking primitive EXECUTE = service_role only (anon/authenticated/PUBLIC denied)';
end $$;

-- 3) the arrival processor remains service_role-only.
do $$
begin
  if not has_function_privilege('service_role', 'public.process_mainship_space_arrivals()', 'EXECUTE')
    then raise exception 'PERM FAIL: service_role cannot EXECUTE the arrival processor'; end if;
  if has_function_privilege('anon', 'public.process_mainship_space_arrivals()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.process_mainship_space_arrivals()', 'EXECUTE')
    then raise exception 'PERM FAIL: a client role CAN EXECUTE the arrival processor'; end if;
  raise notice 'ok: arrival processor EXECUTE = service_role only';
end $$;

-- 4) the DOCK-0 migration introduced NO new client-callable function (its docking primitive is
--    service_role-only). Over the FULL applied chain (through 0067) the authenticated/anon EXECUTE surface is
--    the canonical inventory: the prior 15 RPCs PLUS the OSN-HUB-1A public location-target wrapper
--    command_main_ship_space_move_to_location (added by migration 0067) → 16 canonical RPCs.
do $$
declare v_list text; v_expected text :=
  'bootstrap_me,cancel_build_order,command_main_ship_space_move,command_main_ship_space_move_to_location,command_main_ship_space_stop,get_combat_reports,get_my_expedition_preview,'
  'get_world_map,move_main_ship_to_location,repair_main_ship,request_leave_location,request_main_ship_return,'
  'request_retreat,send_fleet_to_location,send_main_ship_expedition,train_units';
begin
  select string_agg(distinct p.proname, ',' order by p.proname) into v_list
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  if v_list is distinct from v_expected then
    raise exception 'PERM FAIL: client-callable surface drifted. expected=[%] actual=[%]', v_expected, v_list;
  end if;
  raise notice 'ok: client-callable surface is the 16 canonical RPCs (15 + OSN-HUB-1A command_main_ship_space_move_to_location); docking primitive absent from it';
end $$;

-- 5) the arrival cron job still exists exactly once @ "30 seconds".
do $$ declare n int; sched text;
begin
  select count(*), max(schedule) into n, sched from cron.job where jobname = 'process-mainship-space-arrivals';
  if n <> 1 then raise exception 'PERM FAIL: process-mainship-space-arrivals jobs=% (expected 1)', n; end if;
  if sched <> '30 seconds' then raise exception 'PERM FAIL: arrival cron schedule=%', sched; end if;
  raise notice 'ok: arrival cron present exactly once @ "30 seconds"';
end $$;

select 'OSN-DOCK-0 REAL-CHAIN PERMISSION/BOUNDARY PROOF: ALL PASSED' as result;
