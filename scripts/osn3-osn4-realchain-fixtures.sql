-- OSN-4 — REAL-CHAIN fixture matrix for the Stop-mid-travel writer mainship_space_stop() and the shared
-- arrival primitive, built on the ACTUAL migration chain (through 0064). Proves, with all rows real:
--   V1  stop STRICTLY BEFORE arrive_at → outcome 'stopped' at the interpolated point; movement 'stopped'/
--       'player_stop'; fleet pointers cleared; ship in_space at the interpolated coord; receipt success.
--   V6  stop AT/AFTER arrive_at → outcome 'arrived' (NEVER destination 'stopped'); movement 'arrived'/
--       'auto_arrival'; ship in_space at the TARGET (settled via the shared primitive).
--   V2  idempotent replay (same request_id) → identical result, no second mutation.
--   V3  flag DISABLED + active in_transit → stop SUCCEEDS (in-flight safety; Constraint 1).
--   V5  not in transit (in_space) → flag false ⇒ feature_disabled; flag true ⇒ not_in_transit.
--   V8  active in_transit but target_kind='location' → not_space_movement, no mutation (Constraint C).
-- Fixtures marked by the 'osn4fix.' email prefix and removed at the end (cascade via auth.users). The
-- arrival cron is asserted then UNSCHEDULED for determinism. NEVER touches the shared/live DB.

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

-- ── V8: active in_transit but target_kind='location' → not_space_movement, no mutation (Constraint C) ─
do $$
declare p uuid; s uuid; f uuid; m uuid; r jsonb; v_mvst text;
begin
  select o_player,o_ship,o_fleet,o_mv into p,s,f,m from osn4fix_transit(interval '1 hour','location');
  r := public.mainship_space_stop(p, s, gen_random_uuid());
  if r->>'reason' <> 'not_space_movement' then raise exception 'V8 FAIL: expected not_space_movement, got %', r; end if;
  select status into v_mvst from main_ship_space_movements where id=m;
  if v_mvst <> 'moving' then raise exception 'V8 FAIL: location movement mutated to %', v_mvst; end if;
  raise notice 'V8 ok: location-target stop rejected, no mutation';
end $$;

-- ── cleanup ──────────────────────────────────────────────────────────────────────────────────────────
delete from auth.users where email like 'osn4fix.%@example.com';
drop function if exists osn4fix_transit(interval, text);
drop function if exists osn4fix_in_space();
drop function if exists osn4fix_user();
update game_config set value='false' where key='mainship_space_movement_enabled';  -- leave dark

select 'OSN-4 fixture matrix PASSED' as result;
