-- OSN-3 S4 — REAL-CHAIN fixture matrix for public.process_mainship_space_arrivals(). Builds states on
-- the ACTUAL migration chain (through 0058). Proves: a due, coherent S3 movement settles exactly once to
-- the frozen arrival state; a not-yet-due movement stays moving; the processor is idempotent; the S3
-- creation receipt is immutable; settlement proceeds with mainship_space_movement_enabled=FALSE; and
-- EVERY contradiction/malformed/destroyed/conflict/ownership/pointer/legacy/presence case leaves all
-- affected rows UNTOUCHED (per-ship state hash before == after). Fixtures marked by the 'osn3s4fix.'
-- email prefix and removed at the end (cascade via auth.users). Mirrors the live activated config in the
-- disposable stack (mainship_send_enabled=true) and asserts S4 never disturbs it. The pg_cron arrival
-- job is asserted present then UNSCHEDULED so the functional tests are deterministic (disposable only).
-- NEVER touches the shared/live DB.

\set ON_ERROR_STOP on

-- mirror the live activated legacy-send flag in this disposable stack (S4 must leave it untouched).
update game_config set value = 'true' where key = 'mainship_send_enabled';
-- assert the arrival cron job exists exactly once, then unschedule it for deterministic functional tests.
do $$
declare n int; sched text; cmd text;
begin
  select count(*), max(schedule), max(command) into n, sched, cmd from cron.job where jobname = 'process-mainship-space-arrivals';
  if n <> 1 then raise exception 'CRON FAIL: expected 1 process-mainship-space-arrivals job, found %', n; end if;
  if sched <> '30 seconds' then raise exception 'CRON FAIL: schedule=% (expected 30 seconds)', sched; end if;
  if position('process_mainship_space_arrivals' in cmd) = 0 then raise exception 'CRON FAIL: command=%', cmd; end if;
  raise notice 'CRON ok: job process-mainship-space-arrivals @ "30 seconds" → %', cmd;
  perform cron.unschedule(jobid) from cron.job where jobname = 'process-mainship-space-arrivals';  -- determinism (disposable)
end $$;

create or replace function s4fix_user() returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated','osn3s4fix.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','','');
  return v;  -- on_auth_user_created_base trigger auto-creates this player's Home Base at (0,0)
end $$;

-- Build a fixture; returns the main_ship_id. Uses the auto-provisioned (0,0) home base.
create or replace function s4fix(kind text) returns uuid language plpgsql as $$
declare
  v_u uuid := s4fix_user(); v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid();
  v_m uuid := gen_random_uuid(); v_m_term uuid := gen_random_uuid(); v_other uuid; v_b uuid;
  v_l1 uuid := (select id from locations order by id limit 1);
  v_due timestamptz := now() - interval '1 second';
begin
  select id into v_b from bases where player_id = v_u and status = 'active' order by created_at limit 1;

  if kind = 'home_ship' then  -- a plain home ship to drive the real S3 writer
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','home',null,500,500,50,10,2,3,v_s);

  elsif kind in ('in_transit_due','in_transit_future') then
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0, now()-interval '1 hour',
              case when kind='in_transit_due' then v_due else now()+interval '1 hour' end);
    update fleets set active_space_movement_id = v_m where id = v_f;

  elsif kind = 'destroyed_due' then  -- destroyed ship + due moving movement (contradiction)
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','destroyed','destroyed',0,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0, now()-interval '1 hour', v_due);
    update fleets set active_space_movement_id = v_m where id = v_f;

  elsif kind = 'legacy_conflict_due' then  -- in_transit + due coord movement + active LEGACY movement
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0, now()-interval '1 hour', v_due);
    update fleets set active_space_movement_id = v_m where id = v_f;
    insert into fleet_movements (player_id,fleet_id,origin_type,origin_x,origin_y,target_type,target_x,target_y,mission_type,status,arrive_at,travel_distance,travel_seconds,speed_used)
      values (v_u,v_f,'base',0,0,'location',1,1,'rally','moving', now()+interval '1 hour',1,1,1);

  elsif kind = 'presence_conflict_due' then  -- in_transit + due movement + unexpected active presence
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0, now()-interval '1 hour', v_due);
    update fleets set active_space_movement_id = v_m where id = v_f;
    insert into location_presence (player_id,fleet_id,status,location_id) values (v_u,v_f,'active',v_l1);

  elsif kind = 'pointer_mismatch_due' then  -- fleet pointer → a TERMINAL movement, not the active due one
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0, now()-interval '1 hour', v_due);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at,status,resolved_at)
      values (v_m_term,v_s,v_f,v_u,'base',0,0,'space',1,1,1.0, now()-interval '2 hour', now()-interval '1 hour','arrived',now());
    update fleets set active_space_movement_id = v_m_term where id = v_f;

  elsif kind = 'ownership_mismatch_due' then  -- movement.player_id ≠ ship.player_id
    v_other := s4fix_user();
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_other,'base',0,0,'space',100,50,1.0, now()-interval '1 hour', v_due);
    update fleets set active_space_movement_id = v_m where id = v_f;

  elsif kind = 'malformed_due' then  -- in_transit ship + due movement but fleet pointer NOT set
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0, now()-interval '1 hour', v_due);
    -- deliberately DO NOT set fleets.active_space_movement_id (pointer NULL → not a coherent in_transit)

  elsif kind = 'already_arrived' then  -- fully settled ship (movement not 'moving' → never scanned)
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,space_x,space_y,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','stationary','in_space',100,50,500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'completed','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at,status,resolved_at,terminal_reason)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0, now()-interval '2 hour', now()-interval '1 hour','arrived',now(),'auto_arrival');
  else
    raise exception 's4fix: unknown kind %', kind;
  end if;
  return v_s;
end $$;

-- Per-ship state hash over every table the processor could touch (proves no-mutation on contradiction).
create or replace function s4_ship_hash(p_ship uuid) returns text language sql stable as $$
  select md5(coalesce(string_agg(t,''),'')) from (
    select md5(s::text) t from main_ship_instances s where s.main_ship_id = p_ship
    union all select md5(f::text) from fleets f where f.main_ship_id = p_ship
    union all select md5(m::text) from main_ship_space_movements m where m.main_ship_id = p_ship
    union all select md5(lp::text) from location_presence lp join fleets f on f.id = lp.fleet_id where f.main_ship_id = p_ship
    union all select md5(fm::text) from fleet_movements fm join fleets f on f.id = fm.fleet_id where f.main_ship_id = p_ship
    union all select md5(r::text) from main_ship_space_command_receipts r where r.main_ship_id = p_ship
  ) z;
$$;

-- Assert the full frozen arrival state for a settled ship.
create or replace function s4_assert_arrived(p_ship uuid, p_tx double precision, p_ty double precision) returns void language plpgsql as $$
declare v_mv uuid; v_fleet uuid;
begin
  if (select count(*) from main_ship_space_movements where main_ship_id = p_ship and status='moving') <> 0 then raise exception 'arrived: a moving movement remains'; end if;
  select id, fleet_id into v_mv, v_fleet from main_ship_space_movements where main_ship_id = p_ship and status='arrived' order by resolved_at desc limit 1;
  if v_mv is null then raise exception 'arrived: no arrived movement'; end if;
  perform 1 from main_ship_space_movements m where m.id=v_mv and m.status='arrived' and m.resolved_at is not null and m.terminal_reason='auto_arrival' and m.target_x=p_tx and m.target_y=p_ty;
  if not found then raise exception 'arrived: movement terminal fields wrong: %', (select to_jsonb(m) from main_ship_space_movements m where m.id=v_mv); end if;
  perform 1 from main_ship_instances s where s.main_ship_id=p_ship and s.status='stationary' and s.spatial_state='in_space' and s.space_x=p_tx and s.space_y=p_ty;
  if not found then raise exception 'arrived: ship not stationary/in_space at (%, %)', p_tx, p_ty; end if;
  perform 1 from fleets f where f.id=v_fleet and f.status='completed' and f.location_mode='movement'
     and f.active_space_movement_id is null and f.active_movement_id is null
     and f.current_base_id is null and f.current_location_id is null and f.current_zone_id is null and f.current_sector_id is null;
  if not found then raise exception 'arrived: fleet terminal state wrong: %', (select to_jsonb(f) from fleets f where f.id=v_fleet); end if;
  if exists (select 1 from location_presence lp join fleets f on f.id=lp.fleet_id where f.main_ship_id=p_ship and lp.status='active') then raise exception 'arrived: active presence exists'; end if;
  if exists (select 1 from fleet_movements fm join fleets f on f.id=fm.fleet_id where f.main_ship_id=p_ship) then raise exception 'arrived: legacy fleet_movement exists'; end if;
  if (mainship_space_validate_context(p_ship)->>'state') is distinct from 'in_space' then raise exception 'arrived: S2 validate not in_space: %', mainship_space_validate_context(p_ship); end if;
  raise notice 'ok arrived: ship % → in_space at (%, %); movement arrived/auto_arrival/resolved; fleet completed/movement, pointers+base cleared; no presence; no legacy mv; S2=in_space', p_ship, p_tx, p_ty;
end $$;

-- Contradiction: processor leaves every row for this ship untouched.
create or replace function s4_assert_noop(p_ship uuid, p_label text) returns void language plpgsql as $$
declare h1 text; h2 text;
begin
  h1 := s4_ship_hash(p_ship);
  perform process_mainship_space_arrivals();
  h2 := s4_ship_hash(p_ship);
  if h1 is distinct from h2 then raise exception 'CONTRADICTION "%": processor mutated ship %', p_label, p_ship; end if;
  raise notice 'ok no-op (%): all rows untouched', p_label;
end $$;

-- ════════ SECTION A — real S3-writer movement settles with the FLAG OFF; receipt immutable ════════
do $$ declare s uuid; p uuid; req uuid := gen_random_uuid(); r jsonb; mv uuid; rcpt_before jsonb; n int;
begin
  update game_config set value='true' where key='mainship_space_movement_enabled';   -- admit the new move
  s := s4fix('home_ship'); select player_id into p from main_ship_instances where main_ship_id=s;
  r := mainship_space_begin_move(p, s, 120, -60, req);
  if (r->>'ok')::boolean is not true then raise exception 'A: begin_move failed: %', r; end if;
  mv := (r->>'movement_id')::uuid;
  select result_json into rcpt_before from main_ship_space_command_receipts where main_ship_id=s and request_id=req;
  update main_ship_space_movements set arrive_at = now() - interval '1 second' where id = mv;  -- simulate elapsed travel
  update game_config set value='false' where key='mainship_space_movement_enabled';  -- FLAG OFF before settlement
  perform process_mainship_space_arrivals();
  perform s4_assert_arrived(s, 120, -60);
  select count(*) into n from main_ship_space_command_receipts where main_ship_id=s and request_id=req and result_json = rcpt_before and movement_id = mv;
  if n <> 1 then raise exception 'A: S3 creation receipt was changed'; end if;
  raise notice 'SECTION A ok: writer-created movement settled with mainship_space_movement_enabled=FALSE; S3 receipt immutable; terminal history present';
end $$;

-- ════════ SECTION B — due settles once + idempotent; not-yet-due stays moving ════════
do $$ declare s uuid; h1 text; h2 text;
begin
  s := s4fix('in_transit_due');
  if (mainship_space_validate_context(s)->>'state') is distinct from 'in_transit' then raise exception 'B precond: fixture not in_transit'; end if;
  perform process_mainship_space_arrivals();
  perform s4_assert_arrived(s, 100, 50);
  h1 := s4_ship_hash(s); perform process_mainship_space_arrivals(); h2 := s4_ship_hash(s);  -- idempotent
  if h1 is distinct from h2 then raise exception 'B: second processor call re-settled / mutated an arrived ship'; end if;
  raise notice 'SECTION B ok: due coherent movement settles once; second processor call idempotent';
end $$;
do $$ declare s uuid; h1 text; h2 text;
begin
  s := s4fix('in_transit_future');
  if (mainship_space_validate_context(s)->>'state') is distinct from 'in_transit' then raise exception 'future precond'; end if;
  h1 := s4_ship_hash(s); perform process_mainship_space_arrivals(); h2 := s4_ship_hash(s);
  if h1 is distinct from h2 then raise exception 'not-yet-due movement was mutated'; end if;
  if (select status from main_ship_space_movements where main_ship_id=s) <> 'moving' then raise exception 'future: movement not still moving'; end if;
  raise notice 'SECTION B2 ok: not-yet-due movement remains moving, untouched';
end $$;

-- ════════ SECTION C — contradiction / no-op matrix (each leaves all affected rows untouched) ════════
do $$ declare s uuid;
begin
  s := s4fix('destroyed_due');         perform s4_assert_noop(s, 'destroyed ship + due movement');
  s := s4fix('legacy_conflict_due');   perform s4_assert_noop(s, 'active legacy movement + due coordinate movement');
  s := s4fix('presence_conflict_due'); perform s4_assert_noop(s, 'unexpected active presence + due movement');
  s := s4fix('pointer_mismatch_due');  perform s4_assert_noop(s, 'fleet pointer ≠ active moving movement');
  s := s4fix('ownership_mismatch_due');perform s4_assert_noop(s, 'movement.player_id ≠ ship.player_id');
  s := s4fix('malformed_due');         perform s4_assert_noop(s, 'in_transit ship + due movement but fleet pointer NULL');
  s := s4fix('already_arrived');       perform s4_assert_noop(s, 'already-arrived movement (never scanned)');
  raise notice 'SECTION C ok: every contradiction left all affected rows untouched (no settle/fail/repair/delete)';
end $$;

-- ════════ cleanup + final assertions ════════
delete from auth.users where email like 'osn3s4fix.%@example.com';
do $$ declare n int;
begin
  select count(*) into n from main_ship_instances where player_id not in (select id from auth.users); if n<>0 then raise exception 'CLEANUP: % orphan ships', n; end if;
  select count(*) into n from fleets where player_id not in (select id from auth.users); if n<>0 then raise exception 'CLEANUP: % orphan fleets', n; end if;
  select count(*) into n from main_ship_space_movements m where not exists (select 1 from main_ship_instances s where s.main_ship_id=m.main_ship_id); if n<>0 then raise exception 'CLEANUP: % orphan movements', n; end if;
  select count(*) into n from main_ship_space_command_receipts r where not exists (select 1 from main_ship_instances s where s.main_ship_id=r.main_ship_id); if n<>0 then raise exception 'CLEANUP: % orphan receipts', n; end if;
  select count(*) into n from auth.users where email like 'osn3s4fix.%@example.com'; if n<>0 then raise exception 'CLEANUP: % fixture users remain', n; end if;
  raise notice 'ok cleanup: no fixture users/ships/fleets/movements/receipts/presence remain';
end $$;
drop function if exists s4_assert_arrived(uuid, double precision, double precision);
drop function if exists s4_assert_noop(uuid, text);
drop function if exists s4_ship_hash(uuid);
drop function if exists s4fix(text);
drop function if exists s4fix_user();
do $$ declare a text; b text; c text; begin
  select value::text into a from game_config where key='mainship_send_enabled';
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  select value::text into c from game_config where key='max_coordinate_travel_seconds';
  if a is distinct from 'true'  then raise exception 'FLAG FAIL: mainship_send_enabled=% (must remain true / untouched by S4)', a; end if;
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled=% (must end false)', b; end if;
  if c is distinct from '86400' then raise exception 'CONFIG FAIL: max_coordinate_travel_seconds=% (must end 86400)', c; end if;
  raise notice 'FLAG/CONFIG ok: mainship_send_enabled=true (untouched), mainship_space_movement_enabled=false, max_coordinate_travel_seconds=86400';
end $$;
select 'OSN-3 S4 REAL-CHAIN FIXTURE MATRIX: ALL PASSED' as result;
