-- OSN-HUB-1A — REAL-CHAIN permission/boundary proof (disposable Supabase; chain 0001..0067).
-- Proves the new public wrapper is the ONLY new authenticated-callable function; the new internal core writer
-- + target-legality predicate + every existing OSN engine function stay service_role-only; clients gain no
-- access to space_anchors / location_services; and target_location_id is owner-read only (no anon table read).

\set ON_ERROR_STOP on

-- 1) Attributes of the new functions: SECURITY DEFINER, owner postgres, search_path=public, no dynamic SQL.
do $$
declare r record; want text[] := array[
  'command_main_ship_space_move_to_location','mainship_space_begin_move_core','mainship_space_location_target_legal'];
begin
  for r in
    select p.proname, p.prosecdef, pg_get_userbyid(p.proowner) as owner,
           array_to_string(p.proconfig,',') as cfg, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname = any(want)
  loop
    if not r.prosecdef then raise exception 'PERM FAIL: % is not SECURITY DEFINER', r.proname; end if;
    if r.owner <> 'postgres' then raise exception 'PERM FAIL: % owner=% (expected postgres)', r.proname, r.owner; end if;
    if coalesce(r.cfg,'') not like '%search_path=public%' then raise exception 'PERM FAIL: % search_path not pinned: %', r.proname, r.cfg; end if;
    if r.def ilike '%execute format(%' or r.def ~* 'execute\s+''' then raise exception 'PERM FAIL: % appears to use dynamic SQL', r.proname; end if;
  end loop;
  raise notice 'PERM ok: new functions are SECURITY DEFINER / owner=postgres / search_path=public / no dynamic SQL';
end $$;

-- 2) EXECUTE ACL — the public wrapper is authenticated-only; every engine internal is service_role-only.
do $$
declare
  v_wrapper regprocedure := to_regprocedure('public.command_main_ship_space_move_to_location(uuid,uuid)');
  v_core    regprocedure := to_regprocedure('public.mainship_space_begin_move_core(uuid,uuid,text,double precision,double precision,uuid,uuid)');
  v_legal   regprocedure := to_regprocedure('public.mainship_space_location_target_legal(uuid)');
  v_begin   regprocedure := to_regprocedure('public.mainship_space_begin_move(uuid,uuid,double precision,double precision,uuid)');
  v_resolve regprocedure := to_regprocedure('public.mainship_space_resolve_origin(uuid)');
  v_dock    regprocedure := to_regprocedure('public.mainship_space_dock_at_location(uuid,uuid)');
  v_proc    regprocedure := to_regprocedure('public.process_mainship_space_arrivals()');
  v_lock    regprocedure := to_regprocedure('public.mainship_space_lock_context(uuid,boolean)');
  v_valid   regprocedure := to_regprocedure('public.mainship_space_validate_context(uuid)');
  v_excl    regprocedure := to_regprocedure('public.mainship_space_assert_cross_domain_exclusion(uuid)');
  v_settle  regprocedure := to_regprocedure('public.mainship_space_settle_space_arrival(uuid,uuid,timestamptz)');
  v_stop    regprocedure := to_regprocedure('public.mainship_space_stop(uuid,uuid,uuid)');
begin
  if v_wrapper is null or v_core is null or v_legal is null then raise exception 'PERM FAIL: a new function is not installed'; end if;

  -- public wrapper: authenticated YES, anon NO
  if not has_function_privilege('authenticated', v_wrapper, 'EXECUTE') then raise exception 'PERM FAIL: wrapper not executable by authenticated'; end if;
  if     has_function_privilege('anon',          v_wrapper, 'EXECUTE') then raise exception 'PERM FAIL: wrapper executable by anon'; end if;

  -- every required OSN engine internal: service_role MUST be able to execute it, anon AND authenticated MUST NOT.
  declare server_only regprocedure[] := array[v_core,v_legal,v_begin,v_resolve,v_dock,v_proc,v_lock,v_valid,v_excl,v_settle,v_stop]; p regprocedure;
  begin
    foreach p in array server_only loop
      if p is null then raise exception 'PERM FAIL: a required engine internal is missing from the catalog'; end if;
      if not has_function_privilege('service_role', p, 'EXECUTE') then raise exception 'PERM FAIL: service_role CANNOT execute % (required)', p; end if;
      if has_function_privilege('anon', p, 'EXECUTE')          then raise exception 'PERM FAIL: anon can execute % (must be denied)', p; end if;
      if has_function_privilege('authenticated', p, 'EXECUTE') then raise exception 'PERM FAIL: authenticated can execute % (must be denied)', p; end if;
    end loop;
  end;
  raise notice 'PERM ok: wrapper authenticated-only; core+legality+begin_move+resolve+dock+processor+lock+validate+exclusion+settle+stop are service_role-executable AND anon/authenticated-denied';
end $$;

-- 3) No broadening of server-owned catalog tables: anon/authenticated have NO privilege on space_anchors /
--    location_services. target_location_id is exposed ONLY via the owner-read main_ship_space_movements RLS.
do $$
begin
  if has_table_privilege('anon','public.space_anchors','SELECT')          then raise exception 'PERM FAIL: anon can read space_anchors'; end if;
  if has_table_privilege('authenticated','public.space_anchors','SELECT') then raise exception 'PERM FAIL: authenticated can read space_anchors'; end if;
  if has_table_privilege('anon','public.location_services','SELECT')          then raise exception 'PERM FAIL: anon can read location_services'; end if;
  if has_table_privilege('authenticated','public.location_services','SELECT') then raise exception 'PERM FAIL: authenticated can read location_services'; end if;
  -- owner-read movement model carries target_location_id; authenticated SELECT is gated by RLS (own rows only).
  if not has_table_privilege('authenticated','public.main_ship_space_movements','SELECT') then raise exception 'PERM FAIL: authenticated lost owner-read on movements'; end if;
  if has_table_privilege('anon','public.main_ship_space_movements','SELECT') then raise exception 'PERM FAIL: anon can read movements'; end if;
  raise notice 'PERM ok: space_anchors/location_services have NO client privilege; movements stay authenticated-owner-read only (target_location_id never leaks to anon)';
end $$;

-- 4) EXACT canonical authenticated surface — the prior 15 + the ONE new wrapper = exactly 16. Any missing
--    function, any UNEXPECTED authenticated-executable function, any overloaded/duplicate public callable
--    shape, or a count != 16 is a HARD FAILURE (no NOTICE-and-continue). This proves no additional
--    client-writable RPC has silently appeared — not merely that the new wrapper exists.
do $$
declare
  actual     text[];
  n_total    integer;
  n_distinct integer;
  expected   text[] := array[   -- MUST stay alphabetically sorted (matches array_agg order by proname)
    'bootstrap_me','cancel_build_order','command_main_ship_space_move','command_main_ship_space_move_to_location',
    'command_main_ship_space_stop','get_combat_reports','get_my_expedition_preview','get_world_map',
    'move_main_ship_to_location','repair_main_ship','request_leave_location','request_main_ship_return',
    'request_retreat','send_fleet_to_location','send_main_ship_expedition','train_units'];
begin
  -- array_agg WITHOUT distinct: a duplicate proname (an overloaded authenticated callable) appears twice.
  select array_agg(p.proname order by p.proname), count(*), count(distinct p.proname)
    into actual, n_total, n_distinct
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f' and has_function_privilege('authenticated', p.oid, 'EXECUTE');

  -- missing canonical RPC → hard fail
  if not (actual @> expected) then
    raise exception 'PERM FAIL: canonical authenticated RPC(s) MISSING: %',
      (select array_agg(x) from unnest(expected) x where not (x = any(actual)));
  end if;
  -- any unexpected authenticated-executable function → hard fail (NOT a notice)
  if not (expected @> actual) then
    raise exception 'PERM FAIL: UNEXPECTED authenticated-executable public function(s) — a new client-writable RPC appeared: %',
      (select array_agg(distinct x) from unnest(actual) x where not (x = any(expected)));
  end if;
  -- exact count = 16, and no overloaded/duplicate public callable shape (total grants = distinct names = 16)
  if n_total <> 16 then raise exception 'PERM FAIL: authenticated surface count = % (expected exactly 16): %', n_total, actual; end if;
  if n_distinct <> 16 then raise exception 'PERM FAIL: an overloaded/duplicate authenticated callable exists (% grants across % distinct names): %', n_total, n_distinct, actual; end if;
  -- exact ordered array equality (belt-and-suspenders over the set checks above)
  if actual is distinct from expected then raise exception 'PERM FAIL: authenticated surface != canonical 16. actual=%', actual; end if;

  raise notice 'PERM ok: authenticated surface is EXACTLY the canonical 16 (15 + command_main_ship_space_move_to_location); no extras, none missing, no overloads, count=16';
end $$;

select 'OSN-HUB-1A REAL-CHAIN PERM/BOUNDARY: ALL PASSED' as result;
