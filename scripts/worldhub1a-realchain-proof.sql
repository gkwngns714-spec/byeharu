-- WORLD-HUB-1A — REAL-CHAIN proof for the additive city/port + home-port domain foundation (migration 0065).
-- Runs via psql against a DISPOSABLE local Supabase stack whose schema is the ACTUAL migration chain
-- 0001..0065 (NOT a stub, NEVER the shared/live DB). Proves:
--   1  locations.physical_role exists (text, NOT NULL, default 'unclassified', closed CHECK) and EVERY existing
--      location is 'unclassified' (no forced reclassification, no seed).
--   2  invalid physical_role rejected; a valid role accepted then reverted (no durable reclassification).
--   3  location_services shape: FK→locations (ON DELETE CASCADE), closed service/status CHECKs, one-per-kind
--      unique, index present; a location may hold multiple distinct services; duplicate kind rejected;
--      cascade removes service rows when the owning location is deleted.
--   4  player_home_port shape: PK(player_id) (one per player), FK player→auth.users CASCADE, FK
--      location→locations RESTRICT; player cascade removes the row; a location cannot be deleted while
--      referenced.
--   5  ACL: anon/authenticated have NO access to location_services; authenticated may SELECT only
--      player_home_port (owner-read) and has NO insert/update/delete on it; locations remains client
--      SELECT-only (authenticated CANNOT UPDATE → cannot write physical_role); service_role has full access.
--   6  no consumer/seed: both new tables are EMPTY at the end; physical_role still 'unclassified' everywhere.
--   7  compatibility: get_world_map() still returns the seeded world; OSN resolver/space_anchors/profiles are
--      untouched (S1..S6A / DOCK-0 / ANCHOR / OSN-4 non-regression is proven by the sibling real-chain proofs
--      that boot the SAME chain).
-- Fixtures use the 'worldhub1a.' email prefix and are removed at the end. Touches NO flags. NEVER the live DB.

\set ON_ERROR_STOP on

\echo ''
\echo '================= WORLD-HUB-1A: schema shape ================='
do $$
declare n int;
begin
  -- locations.physical_role
  if (select data_type from information_schema.columns
        where table_schema='public' and table_name='locations' and column_name='physical_role') <> 'text'
    then raise exception 'physical_role missing/!text'; end if;
  if (select is_nullable from information_schema.columns
        where table_schema='public' and table_name='locations' and column_name='physical_role') <> 'NO'
    then raise exception 'physical_role must be NOT NULL'; end if;
  if (select column_default from information_schema.columns
        where table_schema='public' and table_name='locations' and column_name='physical_role') not like '%unclassified%'
    then raise exception 'physical_role default must be unclassified'; end if;

  -- location_services
  if to_regclass('public.location_services') is null then raise exception 'location_services missing'; end if;
  if not (select relrowsecurity from pg_class where oid='public.location_services'::regclass) then raise exception 'location_services RLS off'; end if;
  if to_regclass('public.location_services_location_id_idx') is null then raise exception 'location_services index missing'; end if;

  -- player_home_port
  if to_regclass('public.player_home_port') is null then raise exception 'player_home_port missing'; end if;
  if not (select relrowsecurity from pg_class where oid='public.player_home_port'::regclass) then raise exception 'player_home_port RLS off'; end if;
  if (select count(*) from information_schema.table_constraints
        where table_schema='public' and table_name='player_home_port' and constraint_type='PRIMARY KEY') <> 1
    then raise exception 'player_home_port needs a PK(player_id)'; end if;

  raise notice 'schema shape ok';
end $$;

\echo ''
\echo '================= physical_role: defaults, CHECK, no reclassification ================='
do $$
declare n int; v_loc uuid;
begin
  select count(*) into n from public.locations where physical_role <> 'unclassified';
  if n <> 0 then raise exception 'expected ALL existing locations unclassified, found % roled', n; end if;

  select id into v_loc from public.locations limit 1;
  -- invalid role rejected
  begin update public.locations set physical_role='metropolis' where id=v_loc; raise exception 'invalid physical_role accepted'; exception when check_violation then null; end;
  -- valid role accepted, then reverted (no durable reclassification of seed data)
  update public.locations set physical_role='city' where id=v_loc;
  if (select physical_role from public.locations where id=v_loc) <> 'city' then raise exception 'valid role not applied'; end if;
  update public.locations set physical_role='unclassified' where id=v_loc;
  raise notice 'physical_role ok: all unclassified; CHECK closed; valid role applies then reverts';
end $$;

\echo ''
\echo '================= location_services: FK/cascade, multi-service, unique, CHECK ================='
do $$
declare v_zone uuid; v_loc uuid; n int;
begin
  select id into v_zone from public.zones limit 1;
  insert into public.locations (zone_id, name, location_type, x, y)
    values (v_zone, 'worldhub1a-fixture-'||replace(gen_random_uuid()::text,'-',''), 'trade_outpost', 1.0, 1.0)
    returning id into v_loc;

  -- multiple distinct services allowed
  insert into public.location_services (location_id, service) values (v_loc,'docking'),(v_loc,'market'),(v_loc,'repair');
  select count(*) into n from public.location_services where location_id=v_loc;
  if n <> 3 then raise exception 'expected 3 services, got %', n; end if;
  -- duplicate (location, service) rejected
  begin insert into public.location_services (location_id, service) values (v_loc,'docking'); raise exception 'duplicate service accepted'; exception when unique_violation then null; end;
  -- invalid service / status rejected
  begin insert into public.location_services (location_id, service) values (v_loc,'casino'); raise exception 'invalid service accepted'; exception when check_violation then null; end;
  begin insert into public.location_services (location_id, service, status) values (v_loc,'refit','paused'); raise exception 'invalid status accepted'; exception when check_violation then null; end;
  -- FK cascade: deleting the owning location removes its services
  delete from public.locations where id=v_loc;
  select count(*) into n from public.location_services where location_id=v_loc;
  if n <> 0 then raise exception 'service rows survived location delete (cascade failed)'; end if;
  raise notice 'location_services ok: multi-service, unique-per-kind, closed CHECKs, ON DELETE CASCADE';
end $$;

\echo ''
\echo '================= player_home_port: PK, FK restrict/cascade ================='
do $$
declare v_u uuid; v_zone uuid; v_loc uuid; n int;
begin
  select id into v_zone from public.zones limit 1;
  insert into public.locations (zone_id, name, location_type, x, y)
    values (v_zone, 'worldhub1a-port-'||replace(gen_random_uuid()::text,'-',''), 'trade_outpost', 2.0, 2.0)
    returning id into v_loc;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','worldhub1a.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into v_u;

  insert into public.player_home_port (player_id, location_id) values (v_u, v_loc);
  -- one per player (PK)
  begin insert into public.player_home_port (player_id, location_id) values (v_u, v_loc); raise exception 'second home port accepted'; exception when unique_violation then null; end;
  -- location RESTRICT: cannot delete a location while it is a home port
  begin delete from public.locations where id=v_loc; raise exception 'location deleted while referenced as home port'; exception when foreign_key_violation then null; end;
  -- player CASCADE: deleting the user removes the affiliation
  delete from auth.users where id=v_u;
  select count(*) into n from public.player_home_port where player_id=v_u; if n<>0 then raise exception 'home port survived user delete'; end if;
  delete from public.locations where id=v_loc; -- now unreferenced
  raise notice 'player_home_port ok: PK one-per-player, FK location RESTRICT, FK player CASCADE';
end $$;

\echo ''
\echo '================= ACL: server-only config; no player writes; locations stays SELECT-only ================='
do $$
begin
  -- location_services: fully private
  if has_table_privilege('anon','public.location_services','SELECT')          then raise exception 'anon SELECT location_services'; end if;
  if has_table_privilege('authenticated','public.location_services','SELECT') then raise exception 'authenticated SELECT location_services'; end if;
  if has_table_privilege('authenticated','public.location_services','INSERT') then raise exception 'authenticated INSERT location_services'; end if;
  if has_table_privilege('authenticated','public.location_services','UPDATE') then raise exception 'authenticated UPDATE location_services'; end if;
  if has_table_privilege('authenticated','public.location_services','DELETE') then raise exception 'authenticated DELETE location_services'; end if;
  if not has_table_privilege('service_role','public.location_services','INSERT') then raise exception 'service_role lacks location_services INSERT'; end if;

  -- player_home_port: owner-read only; no player write
  if has_table_privilege('anon','public.player_home_port','SELECT')           then raise exception 'anon SELECT player_home_port'; end if;
  if not has_table_privilege('authenticated','public.player_home_port','SELECT') then raise exception 'authenticated should owner-read player_home_port'; end if;
  if has_table_privilege('authenticated','public.player_home_port','INSERT')  then raise exception 'authenticated INSERT player_home_port'; end if;
  if has_table_privilege('authenticated','public.player_home_port','UPDATE')  then raise exception 'authenticated UPDATE player_home_port'; end if;
  if has_table_privilege('authenticated','public.player_home_port','DELETE')  then raise exception 'authenticated DELETE player_home_port'; end if;
  if not has_table_privilege('service_role','public.player_home_port','INSERT') then raise exception 'service_role lacks player_home_port INSERT'; end if;

  -- locations: client SELECT-only → cannot write physical_role
  if not has_table_privilege('authenticated','public.locations','SELECT') then raise exception 'authenticated lost locations SELECT (regression)'; end if;
  if has_table_privilege('authenticated','public.locations','UPDATE')     then raise exception 'authenticated can UPDATE locations (physical_role writable!)'; end if;
  raise notice 'acl ok: services private; home-port owner-read/no-write; locations SELECT-only';
end $$;

\echo ''
\echo '================= no seed + compatibility ================='
do $$
declare n int; v_sectors int;
begin
  select count(*) into n from public.location_services; if n<>0 then raise exception 'location_services not empty (%)', n; end if;
  select count(*) into n from public.player_home_port;  if n<>0 then raise exception 'player_home_port not empty (%)', n; end if;
  select count(*) into n from public.locations where physical_role<>'unclassified'; if n<>0 then raise exception 'a location was left reclassified'; end if;
  -- map read still works and returns the seeded world
  v_sectors := jsonb_array_length((public.get_world_map())->'sectors');
  if v_sectors < 1 then raise exception 'get_world_map regression (% sectors)', v_sectors; end if;
  raise notice 'no seed + compatibility ok: new tables empty, all unclassified, get_world_map intact (% sectors)', v_sectors;
end $$;

\echo ''
\echo 'WORLD-HUB-1A REAL-CHAIN PROOF: ALL PASSED'
