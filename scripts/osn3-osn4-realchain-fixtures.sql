-- OSN-4 — REAL-CHAIN fixture matrix for the Stop-mid-travel writer mainship_space_stop() and the shared
-- arrival primitive, built on the ACTUAL migration chain (through 0067). Proves, with all rows real:
--   V1  SPACE route, stop STRICTLY BEFORE arrive_at → outcome 'stopped' at the interpolated point; movement
--       'stopped'/'player_stop'; fleet pointers cleared; ship in_space at the interpolated coord; receipt success.
--   V6  SPACE route, stop AT/AFTER arrive_at → outcome 'arrived' (NEVER destination 'stopped'); movement
--       'arrived'/'auto_arrival'; ship in_space at the TARGET (settled via the strict space-only primitive).
--   V2  idempotent replay (same request_id) → identical result, no second mutation.
--   V3  flag DISABLED + active in_transit → stop SUCCEEDS (in-flight safety; Constraint 1).
--   V5  not in transit (in_space) → flag false ⇒ feature_disabled; flag true ⇒ not_in_transit.
--   V8  LOCATION route, stop STRICTLY BEFORE arrive_at → outcome 'stopped' at the interpolated point (IDENTICAL
--       to the space branch); movement 'stopped'/'player_stop'; location identity preserved; no dock, no
--       presence (migration-0067 OSN-4 Stop location-compatibility, mid-flight branch).
--   V9  LOCATION route, stop AT/AFTER arrive_at → settles through the SAME canonical Dock-0 decision (not an
--       arbitrary park): an eligible anchored port DOCKS → outcome 'arrived'/docked; movement 'arrived'/
--       'auto_arrival'; ship at_location; exactly one active presence (migration-0067 Stop ↔ Dock-0 settlement).
-- Fixtures marked by the 'osn4fix.' email prefix (users; removed first, cascading ships/fleets/movements/
-- presence) plus the 'osn4fix-port-' location-name prefix (the V8/V9 eligible ports + their anchors/services,
-- removed at the end). The arrival cron is asserted then UNSCHEDULED for determinism. NEVER touches the shared/live DB.

\set ON_ERROR_STOP on

update game_config set value = 'true' where key = 'mainship_send_enabled';

-- determinism: assert + unschedule the arrival cron (disposable only) so it can't settle a move under us.
do $$
declare n int;
begin
  select count(*) into n from cron.job where jobname = 'process-mainship-space-arrivals';
  if n <> 1 then raise exception 'CRON FAIL: expected 1 arrival job, found %', n; end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'process-mainship-space-arrivals';
end $$;

create or replace function osn4fix_user() returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated','osn4fix.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','','');
  return v;  -- on_auth_user_created_base trigger auto-creates this player's Home Base at (0,0)
end $$;

-- Build an in_transit coordinate fixture; returns (player, ship, fleet, movement). arrive offset + target
-- kind parameterized. origin (0,0) → target (100,50); depart 1h ago.
create or replace function osn4fix_transit(p_arrive interval, p_kind text, out o_player uuid, out o_ship uuid, out o_fleet uuid, out o_mv uuid)
language plpgsql as $$
declare v_b uuid; v_l uuid := (select id from locations where activity_type='none' and status='active' order by id limit 1);
        v_lx double precision; v_ly double precision;
begin
  o_player := osn4fix_user();
  o_ship := gen_random_uuid(); o_fleet := gen_random_uuid(); o_mv := gen_random_uuid();
  select id into v_b from bases where player_id = o_player and status = 'active' order by created_at limit 1;
  insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values (o_player,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,o_ship);
  insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id)
    values (o_fleet,o_player,v_b,'moving','movement',o_ship);
  if p_kind = 'location' then
    select x,y into v_lx,v_ly from locations where id = v_l;
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,target_location_id,speed_used,depart_at,arrive_at)
      values (o_mv,o_ship,o_fleet,o_player,'base',0,0,'location',v_lx,v_ly,v_l,1.0, now()-interval '1 hour', now()+p_arrive);
  else
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (o_mv,o_ship,o_fleet,o_player,'base',0,0,'space',100,50,1.0, now()-interval '1 hour', now()+p_arrive);
  end if;
  update fleets set active_space_movement_id = o_mv where id = o_fleet;
end $$;

-- An in_space (not in transit) fixture; returns (player, ship).
create or replace function osn4fix_in_space(out o_player uuid, out o_ship uuid)
language plpgsql as $$
begin
  o_player := osn4fix_user(); o_ship := gen_random_uuid();
  insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,space_x,space_y,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values (o_player,'starter_frigate','stationary','in_space',10,10,500,500,50,10,2,3,o_ship);
end $$;

-- An ELIGIBLE port location for the LOCATION-route Stop tests: active sector/zone/location + physical_role
-- 'port' + activity 'none' + exactly one active docking service + exactly one active canonical anchor at
-- (p_x,p_y). Returns the location id. Fixture-owned via the 'osn4fix-port-' name prefix.
create or replace function osn4fix_eligible_loc(p_x double precision, p_y double precision) returns uuid
language plpgsql as $$
declare v_zone uuid := (select z.id from zones z join sectors se on se.id = z.sector_id
                          where z.status = 'active' and se.status = 'active' order by z.id limit 1);
        v_loc uuid;
begin
  insert into locations (zone_id, name, location_type, x, y, activity_type, status, physical_role)
    values (v_zone, 'osn4fix-port-'||replace(gen_random_uuid()::text,'-',''), 'safe_zone', p_x, p_y, 'none', 'active', 'port')
    returning id into v_loc;
  insert into location_services (location_id, service, status) values (v_loc, 'docking', 'active');
  insert into space_anchors (kind, location_id, space_x, space_y, status) values ('location', v_loc, p_x, p_y, 'active');
  return v_loc;
end $$;

-- Build an in_transit fixture whose single due 'moving' LOCATION movement targets p_loc at its anchor
-- coordinate (p_tx,p_ty); arrive offset parameterized. Returns (player, ship, fleet, movement).
create or replace function osn4fix_transit_loc(p_loc uuid, p_tx double precision, p_ty double precision, p_arrive interval,
                                               out o_player uuid, out o_ship uuid, out o_fleet uuid, out o_mv uuid)
language plpgsql as $$
declare v_b uuid;
begin
  o_player := osn4fix_user();
  o_ship := gen_random_uuid(); o_fleet := gen_random_uuid(); o_mv := gen_random_uuid();
  select id into v_b from bases where player_id = o_player and status = 'active' order by created_at limit 1;
  insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values (o_player,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,o_ship);
  insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id)
    values (o_fleet,o_player,v_b,'moving','movement',o_ship);
  insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,target_location_id,speed_used,depart_at,arrive_at)
    values (o_mv,o_ship,o_fleet,o_player,'base',0,0,'location',p_tx,p_ty,p_loc,1.0, now()-interval '1 hour', now()+p_arrive);
  update fleets set active_space_movement_id = o_mv where id = o_fleet;
end $$;

-- ── V1: stop STRICTLY BEFORE arrive_at → 'stopped' at the interpolated point ─────────────────────────
do $$
declare p uuid; s uuid; f uuid; m uuid; r jsonb; rid uuid := gen_random_uuid();
        v_ss text; v_sx double precision; v_sy double precision; v_mvst text; v_mvr text; v_fl fleets%rowtype;
begin
  select o_player,o_ship,o_fleet,o_mv into p,s,f,m from osn4fix_transit(interval '1 hour','space');  -- arrive in +1h (t≈0.5)
  r := public.mainship_space_stop(p, s, rid);
  if (r->>'ok')::boolean is not true or r->>'outcome' <> 'stopped' then raise exception 'V1 FAIL: outcome=% r=%', r->>'outcome', r; end if;
  select spatial_state,space_x,space_y into v_ss,v_sx,v_sy from main_ship_instances where main_ship_id=s;
  if v_ss <> 'in_space' then raise exception 'V1 FAIL: spatial_state=%', v_ss; end if;
  if v_sx < 49 or v_sx > 51 or v_sy < 24 or v_sy > 26 then raise exception 'V1 FAIL: interp (%,%) not ~ (50,25)', v_sx, v_sy; end if;
  select status,terminal_reason into v_mvst,v_mvr from main_ship_space_movements where id=m;
  if v_mvst <> 'stopped' or v_mvr <> 'player_stop' then raise exception 'V1 FAIL: movement %/%', v_mvst, v_mvr; end if;
  select * into v_fl from fleets where id=f;
  if v_fl.active_space_movement_id is not null or v_fl.status <> 'completed' then raise exception 'V1 FAIL: fleet not cleared (% / %)', v_fl.status, v_fl.active_space_movement_id; end if;
  if not exists (select 1 from main_ship_space_command_receipts where main_ship_id=s and request_id=rid and command_type='space_stop' and outcome_status='success') then raise exception 'V1 FAIL: receipt missing'; end if;
  raise notice 'V1 ok: stopped at (%,%)', v_sx, v_sy;

  -- V2: idempotent replay → identical result, no second mutation (movement stays 'stopped').
  if public.mainship_space_stop(p, s, rid) is distinct from r then raise exception 'V2 FAIL: replay not identical'; end if;
  select status into v_mvst from main_ship_space_movements where id=m;
  if v_mvst <> 'stopped' then raise exception 'V2 FAIL: replay mutated movement to %', v_mvst; end if;
  raise notice 'V2 ok: idempotent replay';
end $$;

-- ── V6: stop AT/AFTER arrive_at → 'arrived' at the TARGET (never destination 'stopped') ──────────────
do $$
declare p uuid; s uuid; f uuid; m uuid; r jsonb; v_ss text; v_sx double precision; v_sy double precision; v_mvst text; v_mvr text;
begin
  select o_player,o_ship,o_fleet,o_mv into p,s,f,m from osn4fix_transit(-interval '1 second','space');  -- already due
  r := public.mainship_space_stop(p, s, gen_random_uuid());
  if (r->>'ok')::boolean is not true or r->>'outcome' <> 'arrived' then raise exception 'V6 FAIL: outcome=% r=%', r->>'outcome', r; end if;
  select spatial_state,space_x,space_y into v_ss,v_sx,v_sy from main_ship_instances where main_ship_id=s;
  if v_ss <> 'in_space' or v_sx <> 100 or v_sy <> 50 then raise exception 'V6 FAIL: ship (%,%,%) not in_space@target', v_ss,v_sx,v_sy; end if;
  select status,terminal_reason into v_mvst,v_mvr from main_ship_space_movements where id=m;
  if v_mvst <> 'arrived' or v_mvr <> 'auto_arrival' then raise exception 'V6 FAIL: movement %/% (expected arrived/auto_arrival)', v_mvst, v_mvr; end if;
  raise notice 'V6 ok: due-at-stop settled as arrived at target';
end $$;

-- ── V3: flag DISABLED + active in_transit → stop SUCCEEDS (in-flight safety) ──────────────────────────
do $$
declare p uuid; s uuid; r jsonb;
begin
  update game_config set value='false' where key='mainship_space_movement_enabled';
  select o_player,o_ship into p,s from osn4fix_transit(interval '1 hour','space');
  r := public.mainship_space_stop(p, s, gen_random_uuid());
  if (r->>'ok')::boolean is not true or r->>'outcome' <> 'stopped' then raise exception 'V3 FAIL: in-flight stop blocked by flag: %', r; end if;
  raise notice 'V3 ok: in-flight stop succeeds with flag OFF';
end $$;

-- ── V5: not in transit → flag false ⇒ feature_disabled; flag true ⇒ not_in_transit ──────────────────
do $$
declare p uuid; s uuid; r jsonb; v_ss text;
begin
  update game_config set value='false' where key='mainship_space_movement_enabled';
  select o_player,o_ship into p,s from osn4fix_in_space();
  r := public.mainship_space_stop(p, s, gen_random_uuid());
  if r->>'reason' <> 'feature_disabled' then raise exception 'V5 FAIL: expected feature_disabled, got %', r; end if;
  select spatial_state into v_ss from main_ship_instances where main_ship_id=s;
  if v_ss <> 'in_space' then raise exception 'V5 FAIL: in_space ship mutated to %', v_ss; end if;

  update game_config set value='true' where key='mainship_space_movement_enabled';
  r := public.mainship_space_stop(p, s, gen_random_uuid());
  if r->>'reason' <> 'not_in_transit' then raise exception 'V5 FAIL: expected not_in_transit, got %', r; end if;
  update game_config set value='false' where key='mainship_space_movement_enabled';  -- restore dark
  raise notice 'V5 ok: feature_disabled (flag off) / not_in_transit (flag on), no mutation';
end $$;

-- ── V8: LOCATION route, stop STRICTLY BEFORE arrive_at → parks 'stopped' at the interpolated point (IDENTICAL
--    to the space branch); target/location identity preserved; never docks, never creates presence ──────────
do $$
declare p uuid; s uuid; f uuid; m uuid; r jsonb; rid uuid := gen_random_uuid();
        l uuid; v_ss text; v_sx double precision; v_sy double precision;
        v_mvst text; v_mvr text; v_tloc uuid; v_fl fleets%rowtype;
begin
  l := osn4fix_eligible_loc(100, 50);
  select o_player,o_ship,o_fleet,o_mv into p,s,f,m from osn4fix_transit_loc(l, 100, 50, interval '1 hour');  -- +1h (t≈0.5)
  r := public.mainship_space_stop(p, s, rid);
  if (r->>'ok')::boolean is not true or r->>'outcome' <> 'stopped' then raise exception 'V8 FAIL: outcome=% r=%', r->>'outcome', r; end if;
  select spatial_state,space_x,space_y into v_ss,v_sx,v_sy from main_ship_instances where main_ship_id=s;
  if v_ss <> 'in_space' then raise exception 'V8 FAIL: ship not in_space (%)', v_ss; end if;
  if v_sx < 49 or v_sx > 51 or v_sy < 24 or v_sy > 26 then raise exception 'V8 FAIL: interp (%,%) not ~ (50,25)', v_sx, v_sy; end if;
  select status,terminal_reason,target_location_id into v_mvst,v_mvr,v_tloc from main_ship_space_movements where id=m;
  if v_mvst <> 'stopped' or v_mvr <> 'player_stop' then raise exception 'V8 FAIL: movement %/% (expected stopped/player_stop)', v_mvst, v_mvr; end if;
  if v_tloc is distinct from l then raise exception 'V8 FAIL: location identity not preserved (% expected %)', v_tloc, l; end if;
  select * into v_fl from fleets where id=f;
  if v_fl.active_space_movement_id is not null or v_fl.status <> 'completed' then raise exception 'V8 FAIL: fleet not cleared (%/%)', v_fl.status, v_fl.active_space_movement_id; end if;
  if exists (select 1 from location_presence lp where lp.fleet_id=f and lp.status='active') then raise exception 'V8 FAIL: a presence was created by a mid-flight stop'; end if;
  if exists (select 1 from fleet_movements fm where fm.fleet_id=f) then raise exception 'V8 FAIL: legacy fleet_movements row leaked'; end if;
  if not exists (select 1 from main_ship_space_command_receipts where main_ship_id=s and request_id=rid and command_type='space_stop' and outcome_status='success') then raise exception 'V8 FAIL: receipt missing'; end if;
  raise notice 'V8 ok: before-arrival LOCATION stop parks at interpolated (%,%); location identity preserved; no dock/presence', v_sx, v_sy;
end $$;

-- ── V9: LOCATION route, stop AT/AFTER arrive_at → settles through the SAME canonical Dock-0 decision (never an
--    arbitrary park). An eligible anchored port DOCKS: outcome 'arrived'/docked; movement 'arrived'/'auto_arrival';
--    ship at_location; exactly one active presence ─────────────────────────────────────────────────────────
do $$
declare p uuid; s uuid; f uuid; m uuid; r jsonb; rid uuid := gen_random_uuid();
        l uuid; v_ss text; v_mvst text; v_mvr text; v_fl fleets%rowtype;
begin
  l := osn4fix_eligible_loc(120, -80);
  select o_player,o_ship,o_fleet,o_mv into p,s,f,m from osn4fix_transit_loc(l, 120, -80, -interval '1 second');  -- already due
  r := public.mainship_space_stop(p, s, rid);
  if (r->>'ok')::boolean is not true or r->>'outcome' <> 'arrived' then raise exception 'V9 FAIL: outcome=% r=%', r->>'outcome', r; end if;
  if (r->>'docked')::boolean is not true then raise exception 'V9 FAIL: due location stop did not dock via Dock-0: %', r; end if;
  select status,terminal_reason into v_mvst,v_mvr from main_ship_space_movements where id=m;
  if v_mvst <> 'arrived' or v_mvr <> 'auto_arrival' then raise exception 'V9 FAIL: movement %/% (expected arrived/auto_arrival)', v_mvst, v_mvr; end if;
  select spatial_state into v_ss from main_ship_instances where main_ship_id=s;
  if v_ss <> 'at_location' then raise exception 'V9 FAIL: ship not at_location (%)', v_ss; end if;
  select * into v_fl from fleets where id=f;
  if v_fl.status <> 'present' or v_fl.current_location_id is distinct from l or v_fl.active_space_movement_id is not null then
    raise exception 'V9 FAIL: fleet not docked-present (status=%, loc=%, ptr=%)', v_fl.status, v_fl.current_location_id, v_fl.active_space_movement_id; end if;
  if (select count(*) from location_presence lp where lp.fleet_id=f and lp.status='active') <> 1 then raise exception 'V9 FAIL: expected exactly one active presence'; end if;
  if exists (select 1 from fleet_movements fm where fm.fleet_id=f) then raise exception 'V9 FAIL: legacy fleet_movements row leaked'; end if;
  if not exists (select 1 from main_ship_space_command_receipts where main_ship_id=s and request_id=rid and command_type='space_stop' and outcome_status='success') then raise exception 'V9 FAIL: receipt missing'; end if;
  raise notice 'V9 ok: at/after-arrival LOCATION stop settles via Dock-0 → docked/arrived; ship at_location; one presence';
end $$;

-- ── cleanup ──────────────────────────────────────────────────────────────────────────────────────────
delete from auth.users where email like 'osn4fix.%@example.com';
-- the V8/V9 eligible-port locations are NOT user-owned: drop their anchors first (space_anchors.location_id is
-- ON DELETE RESTRICT), then the locations themselves (location_services is ON DELETE CASCADE and goes with them).
delete from space_anchors a using locations l where a.location_id = l.id and l.name like 'osn4fix-port-%';
delete from locations where name like 'osn4fix-port-%';
drop function if exists osn4fix_transit_loc(uuid, double precision, double precision, interval);
drop function if exists osn4fix_eligible_loc(double precision, double precision);
drop function if exists osn4fix_transit(interval, text);
drop function if exists osn4fix_in_space();
drop function if exists osn4fix_user();
update game_config set value='false' where key='mainship_space_movement_enabled';  -- leave dark

select 'OSN-4 fixture matrix PASSED' as result;
