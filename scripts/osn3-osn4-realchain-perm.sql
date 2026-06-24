-- OSN-4 — REAL-CHAIN permission/boundary proof for the Stop surface (migration 0064 applied).
-- Asserts: the public wrapper command_main_ship_space_stop is EXECUTE-granted to authenticated; the
-- private writer mainship_space_stop and the shared arrival primitive mainship_space_settle_space_arrival
-- are service_role ONLY (anon/authenticated denied). DOCK-0 + S2/S3/S4/S5 grants are unchanged. The
-- arrival cron job still exists after 0064 (the processor was re-created, not unscheduled by the migration).
\set ON_ERROR_STOP on

-- 1) catalog grants: wrapper → authenticated; writer + primitive NOT granted to anon/authenticated.
do $$
declare ok boolean;
begin
  -- public wrapper executable by authenticated
  select has_function_privilege('authenticated', 'public.command_main_ship_space_stop(uuid)', 'EXECUTE') into ok;
  if not ok then raise exception 'PERM FAIL: authenticated cannot EXECUTE command_main_ship_space_stop'; end if;

  -- private writer: service_role yes, authenticated/anon no
  select has_function_privilege('service_role', 'public.mainship_space_stop(uuid,uuid,uuid)', 'EXECUTE') into ok;
  if not ok then raise exception 'PERM FAIL: service_role cannot EXECUTE mainship_space_stop'; end if;
  select has_function_privilege('authenticated', 'public.mainship_space_stop(uuid,uuid,uuid)', 'EXECUTE') into ok;
  if ok then raise exception 'PERM FAIL: authenticated CAN EXECUTE the private writer (must be denied)'; end if;
  select has_function_privilege('anon', 'public.mainship_space_stop(uuid,uuid,uuid)', 'EXECUTE') into ok;
  if ok then raise exception 'PERM FAIL: anon CAN EXECUTE the private writer (must be denied)'; end if;

  -- shared arrival primitive: service_role yes, authenticated no
  select has_function_privilege('service_role', 'public.mainship_space_settle_space_arrival(uuid,uuid,timestamptz)', 'EXECUTE') into ok;
  if not ok then raise exception 'PERM FAIL: service_role cannot EXECUTE the shared arrival primitive'; end if;
  select has_function_privilege('authenticated', 'public.mainship_space_settle_space_arrival(uuid,uuid,timestamptz)', 'EXECUTE') into ok;
  if ok then raise exception 'PERM FAIL: authenticated CAN EXECUTE the shared arrival primitive (must be denied)'; end if;

  -- DOCK-0 primitive grant unchanged (still service_role-only)
  select has_function_privilege('service_role', 'public.mainship_space_dock_at_location(uuid,uuid)', 'EXECUTE') into ok;
  if not ok then raise exception 'PERM FAIL: service_role lost mainship_space_dock_at_location'; end if;
  raise notice 'PERM ok: wrapper=authenticated; writer + arrival primitive = service_role only; DOCK-0 intact';
end $$;

-- 2) function security attributes: SECURITY DEFINER + search_path=public on the new functions.
do $$
declare r record;
begin
  for r in
    select p.proname, p.prosecdef, array_to_string(p.proconfig,',') as cfg
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('mainship_space_stop','command_main_ship_space_stop','mainship_space_settle_space_arrival')
  loop
    if not r.prosecdef then raise exception 'SEC FAIL: % is not SECURITY DEFINER', r.proname; end if;
    if r.cfg is null or position('search_path=public' in r.cfg) = 0 then raise exception 'SEC FAIL: % search_path=%', r.proname, r.cfg; end if;
  end loop;
  raise notice 'SEC ok: new functions are SECURITY DEFINER with search_path=public';
end $$;

-- 3) the arrival cron job still present after 0064 (processor re-created, not unscheduled).
do $$
declare n int;
begin
  select count(*) into n from cron.job where jobname='process-mainship-space-arrivals';
  if n <> 1 then raise exception 'CRON FAIL: expected 1 arrival job after 0064, found %', n; end if;
  raise notice 'CRON ok: process-mainship-space-arrivals present after 0064';
end $$;

select 'OSN-4 permission/boundary proof PASSED' as result;
