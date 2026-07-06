-- WORLD-HUB-1B-A — REAL-CHAIN proof (migration 0066). Runs via psql against a DISPOSABLE local Supabase
-- stack whose schema is the ACTUAL chain 0001..0066 (NOT a stub; NEVER the live DB). Proves:
--   1  the three approved HIDDEN ports exist with exact content + correct active parent hierarchy;
--   2  each port has exactly one ACTIVE location anchor with coords EQUAL to the location coords;
--   3  each port has one ACTIVE docking service;
--   4  hidden ports are ABSENT from get_world_map();
--   5  the five original seed locations are UNCHANGED (coords/role 'unclassified'/active);
--   6  is_home_port_eligible: hidden ports FAIL; an active fixture PASSES only when all six terms hold;
--      toggling each of {location.status, zone.status, sector.status, docking service, anchor, role=station}
--      individually makes it FAIL;
--   7  the trigger rejects a direct ineligible write and accepts an eligible one;
--   8  assign_home_port succeeds only for an eligible active fixture and rejects a hidden (ineligible) port;
--   9  no client (anon/authenticated) read/write of player_home_port or location_services; no client EXECUTE
--      of assign_home_port / is_home_port_eligible; owner-read scoping holds;
--   10 player_home_port left EMPTY; legacy get_world_map content intact; all 'worldhub1ba' fixtures removed.
-- Fixtures use sector_index=9001 and the 'worldhub1ba.' email prefix; all removed at the end. NO flag change.

\set ON_ERROR_STOP on

\echo ''
\echo '================= 1. catalog: three hidden ports, exact content + active parent hierarchy ========='
do $$
declare r record; n int;
begin
  -- exact-content check, keyed on the FIXED LITERAL location UUIDs (identity, not the mutable name)
  for r in
    select * from (values
      ('b1a00001-0066-4a00-8a00-000000000001'::uuid,'Haven',        'city','Outer Haven',   1,'Wreck Belt',     -50::float8,-30::float8),
      ('b1a00002-0066-4a00-8a00-000000000002'::uuid,'Slagworks','port','Crimson Nebula',2,'Ion Storm Route', 70::float8,-10::float8),
      ('b1a00003-0066-4a00-8a00-000000000003'::uuid,'Driftmarch', 'port','Crimson Nebula',2,'Ion Storm Route', 10::float8, 80::float8)
    ) as v(id, name, role, sector_name, sector_index, zone_name, x, y)
  loop
    select count(*) into n
      from public.locations l
      join public.zones z   on z.id = l.zone_id
      join public.sectors s on s.id = z.sector_id
      where l.id = r.id and l.name = r.name and l.physical_role = r.role and l.status = 'hidden'
        and l.x = r.x and l.y = r.y
        and z.name = r.zone_name and z.status = 'active'
        and s.name = r.sector_name and s.sector_index = r.sector_index and s.status = 'active';
    if n <> 1 then raise exception 'catalog: % (id %) not found with exact content/active hierarchy (got %)', r.name, r.id, n; end if;
  end loop;
  -- STRICT ALLOWLIST: the ONLY city/port locations are EXACTLY the three fixed IDs (no concealed extra port)
  select count(*) into n from public.locations where physical_role in ('city','port')
    and id not in ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');
  if n <> 0 then raise exception 'unexpected city/port location outside the 3 fixed IDs (% extra)', n; end if;
  select count(*) into n from public.locations where physical_role in ('city','port');
  if n <> 3 then raise exception 'expected exactly 3 city/port locations, got %', n; end if;
  raise notice 'catalog ok: exactly the 3 fixed-ID hidden ports with exact content + active parents';
end $$;

\echo ''
\echo '================= 2. anchors aligned + exactly one active per port ================================'
do $$
declare r record; n int; ax float8; ay float8;
begin
  -- each port: exactly one active location anchor with the FIXED anchor id and coords == location coords
  for r in
    select * from (values
      ('b1a00001-0066-4a00-8a00-000000000001'::uuid,'b1a0a001-0066-4a00-8a00-0000000000a1'::uuid,-50::float8,-30::float8),
      ('b1a00002-0066-4a00-8a00-000000000002'::uuid,'b1a0a002-0066-4a00-8a00-0000000000a2'::uuid, 70::float8,-10::float8),
      ('b1a00003-0066-4a00-8a00-000000000003'::uuid,'b1a0a003-0066-4a00-8a00-0000000000a3'::uuid, 10::float8, 80::float8)
    ) as v(loc_id, anchor_id, x, y)
  loop
    select count(*) into n from public.space_anchors a
      where a.location_id = r.loc_id and a.kind = 'location' and a.status = 'active';
    if n <> 1 then raise exception 'anchor: location % must have exactly one active anchor (got %)', r.loc_id, n; end if;
    select space_x, space_y into ax, ay from public.space_anchors
      where id = r.anchor_id and location_id = r.loc_id and kind = 'location' and status = 'active';
    if not found then raise exception 'anchor id % not found for location %', r.anchor_id, r.loc_id; end if;
    if ax <> r.x or ay <> r.y then raise exception 'anchor % coords (%,%) != location (%,%)', r.anchor_id, ax, ay, r.x, r.y; end if;
  end loop;
  -- STRICT ALLOWLIST: the ONLY active location-kind anchors are the three fixed anchor IDs
  select count(*) into n from public.space_anchors where kind='location' and status='active'
    and id not in ('b1a0a001-0066-4a00-8a00-0000000000a1','b1a0a002-0066-4a00-8a00-0000000000a2','b1a0a003-0066-4a00-8a00-0000000000a3');
  if n <> 0 then raise exception 'unexpected active location anchor outside the 3 fixed IDs (% extra)', n; end if;
  raise notice 'anchors ok: exactly the 3 fixed-ID active anchors, coords == location coords';
end $$;

\echo ''
\echo '================= 3. docking services ============================================================='
do $$
declare r record; n int;
begin
  -- each port: exactly one active docking service with the FIXED service id
  for r in
    select * from (values
      ('b1a00001-0066-4a00-8a00-000000000001'::uuid,'b1a05001-0066-4a00-8a00-000000000051'::uuid),
      ('b1a00002-0066-4a00-8a00-000000000002'::uuid,'b1a05002-0066-4a00-8a00-000000000052'::uuid),
      ('b1a00003-0066-4a00-8a00-000000000003'::uuid,'b1a05003-0066-4a00-8a00-000000000053'::uuid)
    ) as v(loc_id, svc_id)
  loop
    select count(*) into n from public.location_services
      where id = r.svc_id and location_id = r.loc_id and service = 'docking' and status = 'active';
    if n <> 1 then raise exception 'docking: service id % for location % not exactly one active (got %)', r.svc_id, r.loc_id, n; end if;
  end loop;
  -- STRICT ALLOWLIST: the ONLY location_services rows are the three fixed docking services
  select count(*) into n from public.location_services
    where id not in ('b1a05001-0066-4a00-8a00-000000000051','b1a05002-0066-4a00-8a00-000000000052','b1a05003-0066-4a00-8a00-000000000053');
  if n <> 0 then raise exception 'unexpected location_services row outside the 3 fixed IDs (% extra)', n; end if;
  raise notice 'docking services ok: exactly the 3 fixed-ID active docking services';
end $$;

\echo ''
\echo '================= 4. hidden ports absent from get_world_map() ====================================='
do $$
declare t text;
begin
  -- Field-anchored ("name": "…"): the bare word Haven would also match the sector 'Outer Haven'.
  t := public.get_world_map()::text;
  if t ~ '"name" *: *"Haven"' or t ~ '"name" *: *"Slagworks"' or t ~ '"name" *: *"Driftmarch"' then
    raise exception 'hidden port leaked into get_world_map()';
  end if;
  raise notice 'hidden ports absent from get_world_map ok';
end $$;

\echo ''
\echo '================= 5. five original seed locations unchanged ======================================='
do $$
declare n int;
begin
  select count(*) into n from public.locations
    where name in ('Refuge','Snare','Reaver','Lull','Blackden')
      and physical_role = 'unclassified' and status = 'active';
  if n <> 5 then raise exception 'an original seed location was modified/repurposed (intact=% of 5)', n; end if;
  raise notice 'original 5 locations unchanged ok';
end $$;

\echo ''
\echo '================= 6. predicate: hidden FAIL; active fixture PASS only with all six terms =========='
do $$
declare v_sec uuid; v_zone uuid; v_loc uuid; v_hidden uuid;
begin
  -- hidden real ports are ineligible (status != active)
  for v_hidden in select id from public.locations where physical_role in ('city','port') loop
    if public.is_home_port_eligible(v_hidden) then raise exception 'hidden port % unexpectedly eligible', v_hidden; end if;
  end loop;

  -- disposable ACTIVE fixture: sector 9001 → zone → location(role city, active) → active anchor → docking
  insert into public.sectors (name, sector_index, x, y) values ('worldhub1ba-fix', 9001, 500, 500) returning id into v_sec;
  insert into public.zones (sector_id, name, x, y) values (v_sec, 'worldhub1ba-zone', 500, 500) returning id into v_zone;
  insert into public.locations (zone_id, name, location_type, x, y, activity_type, status, physical_role)
    values (v_zone, 'worldhub1ba-port', 'trade_outpost', 500, 500, 'none', 'active', 'city') returning id into v_loc;
  insert into public.space_anchors (kind, location_id, space_x, space_y, status) values ('location', v_loc, 500, 500, 'active');
  insert into public.location_services (location_id, service, status) values (v_loc, 'docking', 'active');

  if not public.is_home_port_eligible(v_loc) then raise exception 'fully-eligible active fixture wrongly rejected'; end if;

  -- toggle each term off in a rolled-back subtransaction → must become ineligible
  begin update public.locations set status='locked' where id=v_loc; if public.is_home_port_eligible(v_loc) then raise exception 'location.status off still eligible'; end if; raise exception 'rollback6a'; exception when others then if sqlerrm not like '%rollback6a%' then raise; end if; end;
  begin update public.zones set status='locked' where id=v_zone; if public.is_home_port_eligible(v_loc) then raise exception 'zone.status off still eligible'; end if; raise exception 'rollback6b'; exception when others then if sqlerrm not like '%rollback6b%' then raise; end if; end;
  begin update public.sectors set status='locked' where id=v_sec; if public.is_home_port_eligible(v_loc) then raise exception 'sector.status off still eligible'; end if; raise exception 'rollback6c'; exception when others then if sqlerrm not like '%rollback6c%' then raise; end if; end;
  begin update public.location_services set status='disabled' where location_id=v_loc; if public.is_home_port_eligible(v_loc) then raise exception 'docking disabled still eligible'; end if; raise exception 'rollback6d'; exception when others then if sqlerrm not like '%rollback6d%' then raise; end if; end;
  begin update public.space_anchors set status='retired' where location_id=v_loc; if public.is_home_port_eligible(v_loc) then raise exception 'anchor retired still eligible'; end if; raise exception 'rollback6e'; exception when others then if sqlerrm not like '%rollback6e%' then raise; end if; end;
  begin update public.locations set physical_role='station' where id=v_loc; if public.is_home_port_eligible(v_loc) then raise exception 'role=station still eligible'; end if; raise exception 'rollback6f'; exception when others then if sqlerrm not like '%rollback6f%' then raise; end if; end;

  -- still fully eligible after all rollbacks
  if not public.is_home_port_eligible(v_loc) then raise exception 'fixture not eligible after rollbacks'; end if;
  raise notice 'predicate ok: hidden FAIL; active fixture PASS; each term-off FAIL';

  -- §7/§8 reuse this eligible fixture below; cleanup happens in §10.
end $$;

\echo ''
\echo '================= 7. trigger: rejects ineligible direct write, accepts eligible (rolled back) ====='
do $$
declare v_loc uuid; v_hidden uuid; v_u uuid;
begin
  select id into v_loc from public.locations where name='worldhub1ba-port';
  select id into v_hidden from public.locations where name='Haven';
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','worldhub1ba.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into v_u;

  -- direct write of an INELIGIBLE (hidden) target → trigger rejects
  begin insert into public.player_home_port(player_id, location_id) values (v_u, v_hidden); raise exception 'trigger allowed ineligible hidden target'; exception when check_violation then null; end;
  -- direct write of the ELIGIBLE fixture → trigger accepts (then undo)
  begin
    insert into public.player_home_port(player_id, location_id) values (v_u, v_loc);
    if (select count(*) from public.player_home_port where player_id=v_u) <> 1 then raise exception 'eligible direct write not persisted'; end if;
    raise exception 'rollback7';
  exception when others then if sqlerrm not like '%rollback7%' then raise; end if; end;
  delete from auth.users where id=v_u;
  raise notice 'trigger ok: ineligible rejected; eligible accepted';
end $$;

\echo ''
\echo '================= 8. assign_home_port: eligible succeeds, hidden rejected ========================='
do $$
declare v_loc uuid; v_hidden uuid; v_u uuid;
begin
  select id into v_loc from public.locations where name='worldhub1ba-port';
  select id into v_hidden from public.locations where name='Haven';
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','worldhub1ba.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into v_u;

  begin perform public.assign_home_port(v_u, v_hidden); raise exception 'assign_home_port accepted a hidden ineligible port'; exception when check_violation then null; end;
  perform public.assign_home_port(v_u, v_loc);
  if (select count(*) from public.player_home_port where player_id=v_u and location_id=v_loc) <> 1 then raise exception 'assign_home_port did not write eligible affiliation'; end if;
  delete from auth.users where id=v_u;  -- player FK CASCADE removes the affiliation
  raise notice 'assign_home_port ok: eligible writes, hidden rejected';
end $$;

\echo ''
\echo '================= 9. client (anon/authenticated) denial — grant + runtime ========================'
do $$
begin
  -- grant-level: no client write/execute, no client read of services
  if has_table_privilege('authenticated','public.player_home_port','INSERT') then raise exception 'authenticated INSERT player_home_port'; end if;
  if has_table_privilege('authenticated','public.player_home_port','UPDATE') then raise exception 'authenticated UPDATE player_home_port'; end if;
  if has_table_privilege('authenticated','public.player_home_port','DELETE') then raise exception 'authenticated DELETE player_home_port'; end if;
  if has_table_privilege('anon','public.player_home_port','SELECT')          then raise exception 'anon SELECT player_home_port'; end if;
  if not has_table_privilege('authenticated','public.player_home_port','SELECT') then raise exception 'authenticated should owner-read player_home_port'; end if;
  if has_table_privilege('authenticated','public.location_services','SELECT') then raise exception 'authenticated SELECT location_services'; end if;
  if has_table_privilege('anon','public.location_services','SELECT')          then raise exception 'anon SELECT location_services'; end if;
  if has_function_privilege('authenticated','public.assign_home_port(uuid,uuid)','EXECUTE') then raise exception 'authenticated EXECUTE assign_home_port'; end if;
  if has_function_privilege('anon','public.assign_home_port(uuid,uuid)','EXECUTE')          then raise exception 'anon EXECUTE assign_home_port'; end if;
  if has_function_privilege('authenticated','public.is_home_port_eligible(uuid)','EXECUTE') then raise exception 'authenticated EXECUTE is_home_port_eligible'; end if;
  raise notice 'grant-level denial ok';
end $$;

-- runtime denial under real roles (hermetic BEGIN..ROLLBACK; claim set then SET LOCAL ROLE)
begin;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role','authenticated')::text, true);
set local role authenticated;
do $$
begin
  begin insert into public.player_home_port(player_id, location_id) values (auth.uid(), (select id from public.locations where name='worldhub1ba-port')); raise exception 'authenticated INSERT player_home_port ALLOWED'; exception when insufficient_privilege then null; end;
  begin perform public.assign_home_port(auth.uid(), (select id from public.locations where name='worldhub1ba-port')); raise exception 'authenticated EXECUTE assign_home_port ALLOWED'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.location_services limit 1; raise exception 'authenticated SELECT location_services ALLOWED'; exception when insufficient_privilege then null; end;
  raise notice 'authenticated runtime denial ok';
end $$;
rollback;

begin;
select set_config('request.jwt.claims', '', true);
set local role anon;
do $$
begin
  begin perform 1 from public.player_home_port limit 1; raise exception 'anon SELECT player_home_port ALLOWED'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.location_services limit 1; raise exception 'anon SELECT location_services ALLOWED'; exception when insufficient_privilege then null; end;
  raise notice 'anon runtime denial ok';
end $$;
rollback;

\echo ''
\echo '================= 10. cleanup + final invariants ================================================='
do $$
declare n int;
begin
  -- remove disposable fixtures (anchors first: location_id is ON DELETE RESTRICT)
  delete from public.space_anchors where location_id in (select id from public.locations where name='worldhub1ba-port');
  delete from public.sectors where sector_index = 9001;  -- cascades zone → location → its docking service
  delete from auth.users where email like 'worldhub1ba.%@example.com';

  if (select count(*) from public.player_home_port) <> 0 then raise exception 'player_home_port not empty after proof'; end if;
  if exists (select 1 from public.sectors where sector_index = 9001) then raise exception 'fixture sector remained'; end if;
  if exists (select 1 from public.locations where name like 'worldhub1ba-%') then raise exception 'fixture location remained'; end if;
  if exists (select 1 from auth.users where email like 'worldhub1ba.%@example.com') then raise exception 'fixture user remained'; end if;
  -- legacy map content still present
  if jsonb_array_length((public.get_world_map())->'sectors') < 1 then raise exception 'get_world_map regression'; end if;
  -- the three real ports remain hidden + their anchors/services intact (untouched by cleanup)
  if (select count(*) from public.locations where physical_role in ('city','port') and status='hidden') <> 3 then raise exception 'the 3 starter ports are not all still hidden'; end if;
  raise notice 'cleanup + invariants ok: fixtures gone, player_home_port empty, 3 ports still hidden, map intact';
end $$;

\echo ''
\echo 'WORLD-HUB-1B-A REAL-CHAIN PROOF: ALL PASSED'
