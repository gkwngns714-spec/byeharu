-- OSN-3 S5 — REAL-CHAIN fixture matrix for the coordinate-complete trusted destruction primitive
-- public.dev_set_main_ship_destroyed(p_player). Builds states on the ACTUAL chain (through 0059). Proves:
--   • coherent destruction of in_transit / in_space / at_location / legacy states (coordinate movement
--     cancelled + pointer + spatial state cleared; legacy cleanup preserved; receipt immutable; history
--     preserved);  • idempotent repeated destruction;  • real repair_main_ship after destruction returns
--     a valid legacy_home with no coordinate residue;  • every generic contradiction ABORTS atomically,
--     leaving all rows unchanged (per-ship state hash before == after).
-- Mirrors the live config in the disposable stack (mainship_send_enabled=true) and asserts S5 never
-- disturbs it. The S4 arrival cron is unscheduled for determinism and restored by the workflow.
-- Fixtures marked by the 'osn3s5fix.' email prefix and removed at the end. NEVER touches shared/live.

\set ON_ERROR_STOP on

update game_config set value = 'true' where key = 'mainship_send_enabled';  -- mirror live activated state
do $$ begin perform cron.unschedule(jobid) from cron.job where jobname='process-mainship-space-arrivals'; exception when undefined_table then null; end $$;

create or replace function s5fix_user() returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated','osn3s5fix.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','','');
  return v;  -- on_auth_user_created_base trigger auto-creates the player's Home Base at (0,0)
end $$;

-- Build a fixture; returns the main_ship_id. Uses the auto-provisioned (0,0) home base.
create or replace function s5fix(kind text) returns uuid language plpgsql as $$
declare
  v_u uuid := s5fix_user(); v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid(); v_f2 uuid := gen_random_uuid();
  v_m uuid := gen_random_uuid(); v_m_term uuid := gen_random_uuid(); v_other uuid; v_b uuid;
  v_l1 uuid := (select id from locations order by id limit 1);
  v_fut timestamptz := now() + interval '1 hour';
begin
  select id into v_b from bases where player_id = v_u and status='active' order by created_at limit 1;

  if kind = 'home_ship' then  -- a home ship to drive the real S3 writer
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','home',null,500,500,50,10,2,3,v_s);
  elsif kind = 'in_space' then
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,space_x,space_y,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','stationary','in_space',42,-17,500,500,50,10,2,3,v_s);
  elsif kind = 'at_location' then
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','stationary','at_location',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,current_location_id,main_ship_id) values (v_f,v_u,v_b,'present','location',v_l1,v_s);
    insert into location_presence (player_id,fleet_id,status,location_id) values (v_u,v_f,'active',v_l1);
  elsif kind = 'legacy_present' then  -- legacy (spatial_state NULL) present-at-location ship
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling',null,500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,current_location_id,main_ship_id) values (v_f,v_u,v_b,'present','location',v_l1,v_s);
    insert into location_presence (player_id,fleet_id,status,location_id) values (v_u,v_f,'active',v_l1);

  -- ── contradiction fixtures (validate_context not ok → destruction must ABORT) ─────────────────────
  elsif kind = 'legacy_conflict' then  -- in_transit + active legacy fleet_movement
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0,now(),v_fut);
    update fleets set active_space_movement_id=v_m where id=v_f;
    insert into fleet_movements (player_id,fleet_id,origin_type,origin_x,origin_y,target_type,target_x,target_y,mission_type,status,arrive_at,travel_distance,travel_seconds,speed_used)
      values (v_u,v_f,'base',0,0,'location',1,1,'rally','moving',v_fut,1,1,1);
  elsif kind = 'presence_conflict' then  -- in_transit + unexpected active presence
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0,now(),v_fut);
    update fleets set active_space_movement_id=v_m where id=v_f;
    insert into location_presence (player_id,fleet_id,status,location_id) values (v_u,v_f,'active',v_l1);
  elsif kind = 'pointer_mismatch' then  -- fleet pointer → a terminal movement, not the active one
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0,now(),v_fut);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at,status,resolved_at)
      values (v_m_term,v_s,v_f,v_u,'base',0,0,'space',1,1,1.0,now()-interval '2 hour',now()-interval '1 hour','arrived',now());
    update fleets set active_space_movement_id=v_m_term where id=v_f;
  elsif kind = 'ownership_mismatch' then  -- movement.player_id ≠ ship.player_id
    v_other := s5fix_user();
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_other,'base',0,0,'space',100,50,1.0,now(),v_fut);
    update fleets set active_space_movement_id=v_m where id=v_f;
  elsif kind = 'multi_fleet' then  -- two active fleets for one ship
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','home',null,500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,current_location_id,main_ship_id) values (v_f, v_u,v_b,'present','location',v_l1,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,current_location_id,main_ship_id) values (v_f2,v_u,v_b,'present','location',v_l1,v_s);
  elsif kind = 'in_transit_no_mv' then  -- spatial in_transit but NO active coordinate movement
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
  elsif kind = 'destroyed_corrupt' then  -- destroyed ship + a stray moving coordinate movement
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','destroyed',null,0,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (v_m,v_s,v_f,v_u,'base',0,0,'space',100,50,1.0,now(),v_fut);
    update fleets set active_space_movement_id=v_m where id=v_f;
  else
    raise exception 's5fix: unknown kind %', kind;
  end if;
  return v_s;
end $$;

create or replace function s5_player(p_ship uuid) returns uuid language sql stable as $$ select player_id from main_ship_instances where main_ship_id=p_ship $$;

create or replace function s5_ship_hash(p_ship uuid) returns text language sql stable as $$
  select md5(coalesce(string_agg(t,''),'')) from (
    select md5(s::text) t from main_ship_instances s where s.main_ship_id=p_ship
    union all select md5(f::text) from fleets f where f.main_ship_id=p_ship
    union all select md5(m::text) from main_ship_space_movements m where m.main_ship_id=p_ship
    union all select md5(lp::text) from location_presence lp join fleets f on f.id=lp.fleet_id where f.main_ship_id=p_ship
    union all select md5(fm::text) from fleet_movements fm join fleets f on f.id=fm.fleet_id where f.main_ship_id=p_ship
    union all select md5(r::text) from main_ship_space_command_receipts r where r.main_ship_id=p_ship
  ) z;
$$;

-- Assert a fully-coordinate-complete destroyed ship. p_expect_cancelled = number of coordinate movements
-- that should now be 'cancelled'/'ship_destroyed' (1 for in_transit, 0 otherwise).
create or replace function s5_assert_destroyed(p_ship uuid, p_expect_cancelled integer) returns void language plpgsql as $$
declare n int;
begin
  perform 1 from main_ship_instances s where s.main_ship_id=p_ship and s.status='destroyed' and s.hp=0 and s.spatial_state is null and s.space_x is null and s.space_y is null;
  if not found then raise exception 'destroyed: ship state wrong: %', (select to_jsonb(s) from main_ship_instances s where s.main_ship_id=p_ship); end if;
  select count(*) into n from fleets where main_ship_id=p_ship and status in ('idle','moving','present','returning'); if n<>0 then raise exception 'destroyed: % active fleet(s) remain', n; end if;
  select count(*) into n from fleets where main_ship_id=p_ship and (active_space_movement_id is not null or active_movement_id is not null); if n<>0 then raise exception 'destroyed: % fleet(s) retain a movement pointer', n; end if;
  select count(*) into n from location_presence lp join fleets f on f.id=lp.fleet_id where f.main_ship_id=p_ship and lp.status='active'; if n<>0 then raise exception 'destroyed: % active presence remain', n; end if;
  select count(*) into n from main_ship_space_movements where main_ship_id=p_ship and status='cancelled' and terminal_reason='ship_destroyed' and resolved_at is not null;
  if n <> p_expect_cancelled then raise exception 'destroyed: expected % cancelled coordinate movement(s), found %', p_expect_cancelled, n; end if;
  select count(*) into n from main_ship_space_movements where main_ship_id=p_ship and status='moving'; if n<>0 then raise exception 'destroyed: a moving coordinate movement remains'; end if;
  if (mainship_space_validate_context(p_ship)->>'state') is distinct from 'destroyed' then raise exception 'destroyed: S2 validate not destroyed: %', mainship_space_validate_context(p_ship); end if;
end $$;

-- Contradiction: destruction must ABORT (raise) and leave all rows unchanged.
create or replace function s5_assert_abort(p_ship uuid, p_label text) returns void language plpgsql as $$
declare h1 text; h2 text; v_p uuid := s5_player(p_ship);
begin
  h1 := s5_ship_hash(p_ship);
  begin
    perform dev_set_main_ship_destroyed(v_p);
    raise exception 'CONTRADICTION "%": destruction succeeded but should have aborted', p_label;
  exception
    when others then
      if sqlerrm not like '%refusing to destroy a contradictory%' then raise; end if;  -- only the intended abort
  end;
  h2 := s5_ship_hash(p_ship);
  if h1 is distinct from h2 then raise exception 'CONTRADICTION "%": rows changed despite abort', p_label; end if;
  raise notice 'ok abort (%): destruction refused; all rows untouched', p_label;
end $$;

-- ════════ SECTION 1 — coherent in_transit destruction (via real S3 writer; flag OFF at destroy; receipt immutable) ════════
do $$ declare s uuid; p uuid; req uuid := gen_random_uuid(); r jsonb; mv uuid; rcpt_before jsonb; n int; d jsonb;
begin
  update game_config set value='true' where key='mainship_space_movement_enabled';
  s := s5fix('home_ship'); p := s5_player(s);
  r := mainship_space_begin_move(p, s, 70, 30, req);
  if (r->>'ok')::boolean is not true then raise exception 'S1: begin_move failed: %', r; end if;
  mv := (r->>'movement_id')::uuid;
  select result_json into rcpt_before from main_ship_space_command_receipts where main_ship_id=s and request_id=req;
  if (mainship_space_validate_context(s)->>'state') <> 'in_transit' then raise exception 'S1 precond: not in_transit'; end if;
  update game_config set value='false' where key='mainship_space_movement_enabled';  -- destruction must not depend on the flag
  d := dev_set_main_ship_destroyed(p);
  if (d->>'coordinate_movements_cancelled')::int <> 1 then raise exception 'S1: expected 1 coordinate movement cancelled, got %', d; end if;
  perform s5_assert_destroyed(s, 1);
  perform 1 from main_ship_space_movements where id=mv and status='cancelled' and terminal_reason='ship_destroyed' and resolved_at is not null and target_x=70 and target_y=30;
  if not found then raise exception 'S1: cancelled movement fields wrong'; end if;
  select count(*) into n from main_ship_space_command_receipts where main_ship_id=s and request_id=req and result_json = rcpt_before and movement_id = mv; if n<>1 then raise exception 'S1: S3 receipt changed'; end if;
  raise notice 'SECTION 1 ok: in_transit destruction → movement cancelled/ship_destroyed, fleet+ship coordinate-complete, receipt immutable, history preserved';
end $$;

-- ════════ SECTION 2 — coherent in_space destruction (no movement invented) ════════
do $$ declare s uuid; p uuid; before int; d jsonb;
begin
  s := s5fix('in_space'); p := s5_player(s);
  if (mainship_space_validate_context(s)->>'state') <> 'in_space' then raise exception 'S2 precond'; end if;
  select count(*) into before from main_ship_space_movements where main_ship_id=s;  -- 0
  d := dev_set_main_ship_destroyed(p);
  perform s5_assert_destroyed(s, 0);
  if (select count(*) from main_ship_space_movements where main_ship_id=s) <> before then raise exception 'S2: a movement was invented'; end if;
  raise notice 'SECTION 2 ok: in_space destruction → ship destroyed/hp0/spatial NULL/coords NULL; no movement invented';
end $$;

-- ════════ SECTION 3 — coherent at_location destruction (legacy fleet/presence cleanup + spatial clear) ════════
do $$ declare s uuid; p uuid; d jsonb;
begin
  s := s5fix('at_location'); p := s5_player(s);
  if (mainship_space_validate_context(s)->>'state') <> 'at_location' then raise exception 'S3 precond'; end if;
  d := dev_set_main_ship_destroyed(p);
  perform s5_assert_destroyed(s, 0);
  if exists (select 1 from main_ship_space_movements where main_ship_id=s) then raise exception 'S3: a coordinate movement was invented'; end if;
  raise notice 'SECTION 3 ok: at_location destruction → fleet destroyed, presence closed, ship destroyed/spatial NULL; no movement invented';
end $$;

-- ════════ SECTION 4 — legacy_present destruction (PRESERVED legacy behavior) ════════
do $$ declare s uuid; p uuid; d jsonb;
begin
  s := s5fix('legacy_present'); p := s5_player(s);
  if (mainship_space_validate_context(s)->>'state') <> 'legacy_present' then raise exception 'S4 precond'; end if;
  d := dev_set_main_ship_destroyed(p);
  perform s5_assert_destroyed(s, 0);
  raise notice 'SECTION 4 ok: legacy_present destruction preserved (fleet destroyed, presence closed, ship destroyed, spatial stays NULL)';
end $$;

-- ════════ SECTION 5 — repeated destruction is idempotent ════════
do $$ declare s uuid; p uuid; h1 text; h2 text;
begin
  s := s5fix('in_space'); p := s5_player(s);
  perform dev_set_main_ship_destroyed(p);  -- first
  perform s5_assert_destroyed(s, 0);
  h1 := s5_ship_hash(s); perform dev_set_main_ship_destroyed(p); h2 := s5_ship_hash(s);  -- second (idempotent)
  if h1 is distinct from h2 then raise exception 'S5: repeated destruction mutated the already-destroyed ship'; end if;
  perform s5_assert_destroyed(s, 0);
  raise notice 'SECTION 5 ok: repeated destruction is idempotent (no duplicate terminalization)';
end $$;

-- ════════ SECTION 6 — real repair_main_ship after destruction → valid legacy_home, no coordinate residue ════════
do $$ declare s uuid; p uuid; r jsonb;
begin
  s := s5fix('in_space'); p := s5_player(s);
  perform dev_set_main_ship_destroyed(p);
  perform s5_assert_destroyed(s, 0);
  -- call the UNCHANGED repair_main_ship as the owning player (auth.uid() via jwt claim); repair is owner-executable here
  perform set_config('request.jwt.claim.sub', p::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p)::text, true);
  r := repair_main_ship();
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  if (r->>'status') <> 'home' then raise exception 'S6: repair did not return home: %', r; end if;
  perform 1 from main_ship_instances where main_ship_id=s and status='home' and spatial_state is null and space_x is null and space_y is null and hp = max_hp;
  if not found then raise exception 'S6: repaired ship not a clean legacy_home'; end if;
  if exists (select 1 from fleets where main_ship_id=s and status in ('idle','moving','present','returning')) then raise exception 'S6: repair created an active fleet'; end if;
  if exists (select 1 from main_ship_space_movements where main_ship_id=s and status='moving') then raise exception 'S6: repair created a coordinate movement'; end if;
  if exists (select 1 from location_presence lp join fleets f on f.id=lp.fleet_id where f.main_ship_id=s and lp.status='active') then raise exception 'S6: repair created presence'; end if;
  if (mainship_space_validate_context(s)->>'state') <> 'legacy_home' then raise exception 'S6: repaired ship not validate=legacy_home: %', mainship_space_validate_context(s); end if;
  raise notice 'SECTION 6 ok: repair_main_ship (unchanged) after destruction → clean legacy_home, no coordinate residue';
end $$;

-- ════════ SECTION 7 — generic contradictions: destruction ABORTS, all rows untouched ════════
do $$ declare s uuid;
begin
  s := s5fix('legacy_conflict');    perform s5_assert_abort(s, 'active legacy movement during coordinate transit');
  s := s5fix('presence_conflict');  perform s5_assert_abort(s, 'unexpected active presence during coordinate transit');
  s := s5fix('pointer_mismatch');   perform s5_assert_abort(s, 'fleet pointer ≠ active moving movement');
  s := s5fix('ownership_mismatch'); perform s5_assert_abort(s, 'movement.player_id ≠ ship.player_id');
  s := s5fix('multi_fleet');        perform s5_assert_abort(s, 'multiple active fleets');
  s := s5fix('in_transit_no_mv');   perform s5_assert_abort(s, 'ship in_transit with no active coordinate movement');
  s := s5fix('destroyed_corrupt');  perform s5_assert_abort(s, 'pre-existing destroyed-plus-moving corruption');
  raise notice 'SECTION 7 ok: every generic contradiction aborts destruction atomically with all rows untouched';
end $$;

-- ════════ cleanup + final assertions ════════
update game_config set value='false' where key='mainship_space_movement_enabled';
delete from auth.users where email like 'osn3s5fix.%@example.com';
do $$ declare n int;
begin
  select count(*) into n from main_ship_instances where player_id not in (select id from auth.users); if n<>0 then raise exception 'CLEANUP: % orphan ships', n; end if;
  select count(*) into n from main_ship_space_movements m where not exists (select 1 from main_ship_instances s where s.main_ship_id=m.main_ship_id); if n<>0 then raise exception 'CLEANUP: % orphan movements', n; end if;
  select count(*) into n from auth.users where email like 'osn3s5fix.%@example.com'; if n<>0 then raise exception 'CLEANUP: % fixture users remain', n; end if;
  raise notice 'ok cleanup: no fixture users/ships/fleets/movements/receipts/presence remain';
end $$;
drop function if exists s5_assert_destroyed(uuid, integer);
drop function if exists s5_assert_abort(uuid, text);
drop function if exists s5_ship_hash(uuid);
drop function if exists s5_player(uuid);
drop function if exists s5fix(text);
drop function if exists s5fix_user();
do $$ declare a text; b text; c text; begin
  select value::text into a from game_config where key='mainship_send_enabled';
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  select value::text into c from game_config where key='max_coordinate_travel_seconds';
  if a is distinct from 'true'  then raise exception 'FLAG FAIL: mainship_send_enabled=% (must remain true)', a; end if;
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled=% (must end false)', b; end if;
  if c is distinct from '86400' then raise exception 'CONFIG FAIL: max_coordinate_travel_seconds=%', c; end if;
  raise notice 'FLAG/CONFIG ok: send=true (untouched), space_movement=false, max_coordinate_travel_seconds=86400';
end $$;
select 'OSN-3 S5 REAL-CHAIN FIXTURE MATRIX: ALL PASSED' as result;
