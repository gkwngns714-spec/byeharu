-- OSN-DOCK-0 — REAL-CHAIN fixture matrix for public.mainship_space_dock_at_location() via
-- public.process_mainship_space_arrivals(). Builds states on the ACTUAL migration chain (through 0067) and
-- proves, with mainship_space_movement_enabled = FALSE (production-dark) throughout:
--   • a due, coherent in_transit movement that EXPLICITLY targets an active 'none'-activity PORT location with
--     one active docking service and one active canonical anchor, whose target_x/y match that anchor, DOCKS
--     exactly once → ship stationary/at_location/(NULL,NULL); one active presence; no activity; no
--     fleet_movements; S2 validate = at_location; idempotent on replay;
--   • an inactive (status<>'active') location target → terminal failure 'undockable_inactive_location';
--   • a location target whose movement coordinate != its active canonical anchor → terminal failure 'target_anchor_changed';
--   • an unsupported-activity ('hunt_pirates') location target → terminal failure
--     'undockable_unsupported_activity' (NO presence, NO activity_start raise, processor returns normally);
--     every terminal failure: movement failed/<reason>/resolved_at; ship stationary/in_space/(target_x,y);
--     no presence; no half-docked pointers; replay is a no-op (no loop);
--   • a free-space (target_kind='space') arrival still settles to in_space, byte-for-byte unchanged;
--   • NO DOCK-0 path ever creates/reads a fleet_movements row.
-- Fixtures marked by the 'osn3dock0.' email prefix + 'dock0-test-' location names, removed at the end. Mirrors
-- the live activated legacy-send flag (mainship_send_enabled=true) and asserts DOCK-0 never disturbs it. The
-- pg_cron arrival job is asserted present then UNSCHEDULED for deterministic functional tests. Disposable only.

\set ON_ERROR_STOP on

update game_config set value = 'true'  where key = 'mainship_send_enabled';            -- mirror live (untouched)
update game_config set value = 'false' where key = 'mainship_space_movement_enabled';  -- production-dark settle

do $$
declare n int; sched text; cmd text;
begin
  select count(*), max(schedule), max(command) into n, sched, cmd from cron.job where jobname = 'process-mainship-space-arrivals';
  if n <> 1 then raise exception 'CRON FAIL: expected 1 process-mainship-space-arrivals job, found %', n; end if;
  if sched <> '30 seconds' then raise exception 'CRON FAIL: schedule=% (expected 30 seconds)', sched; end if;
  if position('process_mainship_space_arrivals' in cmd) = 0 then raise exception 'CRON FAIL: command=%', cmd; end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'process-mainship-space-arrivals';  -- determinism
  raise notice 'CRON ok: process-mainship-space-arrivals @ "30 seconds" → unscheduled for deterministic tests';
end $$;

create or replace function dock0_user() returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated','osn3dock0.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','','');
  return v;  -- on_auth_user_created trigger auto-creates this player's Home Base at (0,0)
end $$;

-- Insert a dedicated DOCK-0 test location (never disturbs seeded locations); returns its id.
create or replace function dock0_loc(p_x double precision, p_y double precision, p_status text, p_activity text)
returns uuid language plpgsql as $$
declare v_id uuid;
        v_zone uuid := (select z.id from zones z join sectors se on se.id = z.sector_id
                          where z.status = 'active' and se.status = 'active' order by z.id limit 1);
begin
  -- Post-0067 Dock-0 resolves the target through its canonical space_anchors location anchor (NOT locations.x/y)
  -- and revalidates the full legality rule (active sector/zone/location + role city|port + activity 'none' +
  -- exactly one active docking service + exactly one active location anchor). Build a PORT location with those
  -- preconditions so an ACTIVE 'none' target is genuinely dockable; the negative sections then violate exactly
  -- ONE term (inactive status / unsupported activity / coordinate divergence). The active anchor is seeded at
  -- the location's own (p_x,p_y): a coordinate-matched movement docks, a divergent one fails 'target_anchor_changed'.
  insert into locations (zone_id, name, location_type, x, y, activity_type, status, physical_role)
    values (v_zone, 'dock0-test-'||replace(gen_random_uuid()::text,'-',''),
            case when p_activity = 'none' then 'safe_zone' else 'pirate_hunt' end,
            p_x, p_y, p_activity, p_status, 'port')
    returning id into v_id;
  insert into location_services (location_id, service, status) values (v_id, 'docking', 'active');
  insert into space_anchors (kind, location_id, space_x, space_y, status) values ('location', v_id, p_x, p_y, 'active');
  return v_id;
end $$;

-- Build a coherent in_transit ship whose single due 'moving' movement EXPLICITLY targets p_loc at (p_tx,p_ty).
create or replace function dock0_fix(p_loc uuid, p_tx double precision, p_ty double precision)
returns uuid language plpgsql as $$
declare
  v_u uuid := dock0_user(); v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid(); v_m uuid := gen_random_uuid();
  v_b uuid; v_due timestamptz := now() - interval '1 hour';
begin
  select id into v_b from bases where player_id = v_u and status = 'active' order by created_at limit 1;
  insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
  insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id)
    values (v_f,v_u,v_b,'moving','movement',v_s);
  insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,target_location_id,speed_used,depart_at,arrive_at)
    values (v_m,v_s,v_f,v_u,'base',0,0,'location',p_tx,p_ty,p_loc,1.0, now()-interval '2 hour', v_due);
  update fleets set active_space_movement_id = v_m where id = v_f;
  return v_s;
end $$;

-- Build a coherent in_transit ship whose single due 'moving' movement targets free SPACE (regression).
create or replace function dock0_fix_space(p_tx double precision, p_ty double precision)
returns uuid language plpgsql as $$
declare
  v_u uuid := dock0_user(); v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid(); v_m uuid := gen_random_uuid();
  v_b uuid; v_due timestamptz := now() - interval '1 hour';
begin
  select id into v_b from bases where player_id = v_u and status = 'active' order by created_at limit 1;
  insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values (v_u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
  insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id)
    values (v_f,v_u,v_b,'moving','movement',v_s);
  insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
    values (v_m,v_s,v_f,v_u,'base',0,0,'space',p_tx,p_ty,1.0, now()-interval '2 hour', v_due);
  update fleets set active_space_movement_id = v_m where id = v_f;
  return v_s;
end $$;

create or replace function dock0_ship_hash(p_ship uuid) returns text language sql stable as $$
  select md5(coalesce(string_agg(t,''),'')) from (
    select md5(s::text) t from main_ship_instances s where s.main_ship_id = p_ship
    union all select md5(f::text) from fleets f where f.main_ship_id = p_ship
    union all select md5(m::text) from main_ship_space_movements m where m.main_ship_id = p_ship
    union all select md5(lp::text) from location_presence lp join fleets f on f.id = lp.fleet_id where f.main_ship_id = p_ship
    union all select md5(fm::text) from fleet_movements fm join fleets f on f.id = fm.fleet_id where f.main_ship_id = p_ship
  ) z;
$$;

-- Assert the full docked (at_location) state for a ship docked at p_loc.
create or replace function dock0_assert_docked(p_ship uuid, p_loc uuid, p_tx double precision, p_ty double precision) returns void language plpgsql as $$
declare v_mv uuid; v_fleet uuid; v_zone uuid; v_sector uuid;
begin
  if (select count(*) from main_ship_space_movements where main_ship_id=p_ship and status='moving') <> 0 then raise exception 'docked: a moving movement remains'; end if;
  select id, fleet_id into v_mv, v_fleet from main_ship_space_movements where main_ship_id=p_ship and status='arrived' order by resolved_at desc limit 1;
  if v_mv is null then raise exception 'docked: no arrived movement'; end if;
  perform 1 from main_ship_space_movements m where m.id=v_mv and m.status='arrived' and m.resolved_at is not null and m.terminal_reason='auto_arrival' and m.target_kind='location' and m.target_location_id=p_loc and m.target_x=p_tx and m.target_y=p_ty;
  if not found then raise exception 'docked: movement terminal fields wrong: %', (select to_jsonb(m) from main_ship_space_movements m where m.id=v_mv); end if;
  perform 1 from main_ship_instances s where s.main_ship_id=p_ship and s.status='stationary' and s.spatial_state='at_location' and s.space_x is null and s.space_y is null;
  if not found then raise exception 'docked: ship not stationary/at_location/(NULL,NULL): %', (select to_jsonb(s) from main_ship_instances s where s.main_ship_id=p_ship); end if;
  select z.id, z.sector_id into v_zone, v_sector from locations l join zones z on z.id=l.zone_id where l.id=p_loc;
  perform 1 from fleets f where f.id=v_fleet and f.status='present' and f.location_mode='location'
     and f.active_space_movement_id is null and f.active_movement_id is null and f.current_base_id is null
     and f.current_location_id=p_loc and f.current_zone_id=v_zone and f.current_sector_id=v_sector;
  if not found then raise exception 'docked: fleet state wrong: %', (select to_jsonb(f) from fleets f where f.id=v_fleet); end if;
  if (select count(*) from location_presence lp where lp.fleet_id=v_fleet and lp.status='active') <> 1 then raise exception 'docked: expected exactly one active presence'; end if;
  perform 1 from location_presence lp where lp.fleet_id=v_fleet and lp.status='active' and lp.location_id=p_loc and lp.activity_type='none';
  if not found then raise exception 'docked: presence not active/at-loc/activity=none: %', (select to_jsonb(lp) from location_presence lp where lp.fleet_id=v_fleet and lp.status='active'); end if;
  if exists (select 1 from fleet_movements fm where fm.fleet_id=v_fleet) then raise exception 'docked: a fleet_movements row exists (legacy dependency leaked)'; end if;
  if (mainship_space_validate_context(p_ship)->>'state') is distinct from 'at_location' then raise exception 'docked: S2 validate not at_location: %', mainship_space_validate_context(p_ship); end if;
  raise notice 'ok docked: ship % at location % (%, %); movement arrived/auto_arrival; ship at_location/(NULL,NULL); one presence; no activity; no fleet_movements; S2=at_location', p_ship, p_loc, p_tx, p_ty;
end $$;

-- Assert the deterministic terminal-failure state (ship floats in_space; no presence; explicit reason).
create or replace function dock0_assert_failed(p_ship uuid, p_reason text, p_tx double precision, p_ty double precision) returns void language plpgsql as $$
declare v_mv uuid; v_fleet uuid;
begin
  if (select count(*) from main_ship_space_movements where main_ship_id=p_ship and status='moving') <> 0 then raise exception 'failed: a moving movement remains (would loop)'; end if;
  select id, fleet_id into v_mv, v_fleet from main_ship_space_movements where main_ship_id=p_ship and status='failed' order by resolved_at desc limit 1;
  if v_mv is null then raise exception 'failed: no failed movement'; end if;
  perform 1 from main_ship_space_movements m where m.id=v_mv and m.status='failed' and m.resolved_at is not null and m.terminal_reason=p_reason;
  if not found then raise exception 'failed: terminal fields wrong (expected reason=%): %', p_reason, (select to_jsonb(m) from main_ship_space_movements m where m.id=v_mv); end if;
  perform 1 from main_ship_instances s where s.main_ship_id=p_ship and s.status='stationary' and s.spatial_state='in_space' and s.space_x=p_tx and s.space_y=p_ty;
  if not found then raise exception 'failed: ship not stationary/in_space at (%, %): %', p_tx, p_ty, (select to_jsonb(s) from main_ship_instances s where s.main_ship_id=p_ship); end if;
  perform 1 from fleets f where f.id=v_fleet and f.status='completed' and f.location_mode='movement'
     and f.active_space_movement_id is null and f.active_movement_id is null
     and f.current_base_id is null and f.current_location_id is null and f.current_zone_id is null and f.current_sector_id is null;
  if not found then raise exception 'failed: fleet not coherently cleared (half-docked pointer?): %', (select to_jsonb(f) from fleets f where f.id=v_fleet); end if;
  if exists (select 1 from location_presence lp where lp.fleet_id=v_fleet) then raise exception 'failed: a presence exists (must be none)'; end if;
  if exists (select 1 from fleet_movements fm where fm.fleet_id=v_fleet) then raise exception 'failed: a fleet_movements row exists (legacy dependency leaked)'; end if;
  if (mainship_space_validate_context(p_ship)->>'state') is distinct from 'in_space' then raise exception 'failed: S2 validate not in_space: %', mainship_space_validate_context(p_ship); end if;
  raise notice 'ok terminal-failure (%): ship % → in_space at (%, %); movement failed/resolved; fleet cleared; no presence; no fleet_movements; S2=in_space', p_reason, p_ship, p_tx, p_ty;
end $$;

-- ════════ SECTION A — valid explicit location target docks exactly once (active + 'none' + coords match) ══
do $$ declare l uuid; s uuid; h1 text; h2 text; n int;
begin
  l := dock0_loc(120, -60, 'active', 'none');
  s := dock0_fix(l, 120, -60);
  if (mainship_space_validate_context(s)->>'state') is distinct from 'in_transit' then raise exception 'A precond: fixture not in_transit'; end if;
  n := process_mainship_space_arrivals();
  if n < 1 then raise exception 'A: processor settled 0 (expected >=1)'; end if;
  perform dock0_assert_docked(s, l, 120, -60);
  h1 := dock0_ship_hash(s); perform process_mainship_space_arrivals(); h2 := dock0_ship_hash(s);  -- idempotent
  if h1 is distinct from h2 then raise exception 'A: replay re-settled / created a second presence on a docked ship'; end if;
  raise notice 'SECTION A ok: explicit location target docks once; replay is a no-op (exactly-once)';
end $$;

-- ════════ SECTION B — inactive location → deterministic terminal failure (no loop) ══════════════════════
do $$ declare l uuid; s uuid; h1 text; h2 text;
begin
  l := dock0_loc(200, 200, 'locked', 'none');   -- status<>'active'
  s := dock0_fix(l, 200, 200);
  perform process_mainship_space_arrivals();
  perform dock0_assert_failed(s, 'undockable_inactive_location', 200, 200);
  h1 := dock0_ship_hash(s); perform process_mainship_space_arrivals(); h2 := dock0_ship_hash(s);  -- no retry/loop
  if h1 is distinct from h2 then raise exception 'B: cron replay retried a failed movement (loop)'; end if;
  raise notice 'SECTION B ok: inactive-location target → terminal failure; replay cannot loop';
end $$;

-- ════════ SECTION C — coordinate-mismatched location target → deterministic terminal failure ════════════
do $$ declare l uuid; s uuid; h1 text; h2 text;
begin
  l := dock0_loc(300, 300, 'active', 'none');   -- eligible; canonical anchor seeded at (300,300)
  s := dock0_fix(l, 301, 300);   -- movement target_x (301) != the active canonical anchor (300) → no redirect
  perform process_mainship_space_arrivals();
  perform dock0_assert_failed(s, 'target_anchor_changed', 301, 300);
  h1 := dock0_ship_hash(s); perform process_mainship_space_arrivals(); h2 := dock0_ship_hash(s);
  if h1 is distinct from h2 then raise exception 'C: cron replay retried a failed movement (loop)'; end if;
  raise notice 'SECTION C ok: movement target != canonical active anchor → terminal failure (never docks on a moved anchor)';
end $$;

-- ════════ SECTION D — unsupported activity ('hunt_pirates') → terminal failure; NO presence/activity ════
do $$ declare l uuid; s uuid; h1 text; h2 text;
begin
  l := dock0_loc(400, -400, 'active', 'hunt_pirates');   -- active + coords will match, but activity unsupported
  s := dock0_fix(l, 400, -400);
  perform process_mainship_space_arrivals();   -- must NOT raise (activity_start never reached)
  perform dock0_assert_failed(s, 'undockable_unsupported_activity', 400, -400);
  if exists (select 1 from location_presence lp join fleets f on f.id=lp.fleet_id where f.main_ship_id=s) then raise exception 'D: a presence was created for an unsupported-activity target'; end if;
  h1 := dock0_ship_hash(s); perform process_mainship_space_arrivals(); h2 := dock0_ship_hash(s);
  if h1 is distinct from h2 then raise exception 'D: cron replay retried a failed movement (loop)'; end if;
  raise notice 'SECTION D ok: unsupported-activity target → terminal failure; activity_start never reached; no presence; no loop';
end $$;

-- ════════ SECTION E — free-space arrival unchanged (regression: still settles to in_space) ══════════════
do $$ declare s uuid; v_fleet uuid;
begin
  s := dock0_fix_space(500, 250);
  perform process_mainship_space_arrivals();
  perform 1 from main_ship_space_movements m where m.main_ship_id=s and m.status='arrived' and m.terminal_reason='auto_arrival' and m.target_kind='space' and m.target_x=500 and m.target_y=250;
  if not found then raise exception 'E: space movement did not settle to arrived/auto_arrival'; end if;
  perform 1 from main_ship_instances s2 where s2.main_ship_id=s and s2.status='stationary' and s2.spatial_state='in_space' and s2.space_x=500 and s2.space_y=250;
  if not found then raise exception 'E: ship not stationary/in_space at the space target'; end if;
  select id into v_fleet from fleets where main_ship_id=s;
  if exists (select 1 from location_presence lp where lp.fleet_id=v_fleet) then raise exception 'E: space arrival created a presence'; end if;
  if (mainship_space_validate_context(s)->>'state') is distinct from 'in_space' then raise exception 'E: S2 validate not in_space'; end if;
  raise notice 'SECTION E ok: free-space (target_kind=space) arrival settles to in_space, unchanged; no presence';
end $$;

-- ════════ SECTION F — global no-fleet_movements guarantee across every DOCK-0 fixture ═══════════════════
do $$ declare n int;
begin
  select count(*) into n from fleet_movements fm
    join fleets f on f.id = fm.fleet_id
    join main_ship_instances s on s.main_ship_id = f.main_ship_id
    where s.player_id in (select id from auth.users where email like 'osn3dock0.%@example.com');
  if n <> 0 then raise exception 'F: % fleet_movements row(s) exist for DOCK-0 fixtures (legacy dependency)', n; end if;
  raise notice 'SECTION F ok: DOCK-0 created/used ZERO fleet_movements rows';
end $$;

-- ════════ cleanup (delete users first → cascades ships/fleets/movements/presence, freeing the loc FK) ════
delete from auth.users where email like 'osn3dock0.%@example.com';
-- space_anchors.location_id is ON DELETE RESTRICT → drop the fixture's location anchors BEFORE their locations
-- (location_services is ON DELETE CASCADE and goes with the location). If any dock0 anchor leaked, the
-- locations delete below would raise under ON_ERROR_STOP — so a clean completion also proves no anchor remained.
delete from space_anchors a using locations l where a.location_id = l.id and l.name like 'dock0-test-%';
delete from locations where name like 'dock0-test-%';
do $$ declare n int;
begin
  select count(*) into n from main_ship_instances where player_id not in (select id from auth.users); if n<>0 then raise exception 'CLEANUP: % orphan ships', n; end if;
  select count(*) into n from locations where name like 'dock0-test-%'; if n<>0 then raise exception 'CLEANUP: % dock0 test locations remain', n; end if;
  select count(*) into n from auth.users where email like 'osn3dock0.%@example.com'; if n<>0 then raise exception 'CLEANUP: % fixture users remain', n; end if;
  raise notice 'ok cleanup: no DOCK-0 fixture users/ships/fleets/movements/presence/locations remain';
end $$;
drop function if exists dock0_assert_docked(uuid, uuid, double precision, double precision);
drop function if exists dock0_assert_failed(uuid, text, double precision, double precision);
drop function if exists dock0_ship_hash(uuid);
drop function if exists dock0_fix(uuid, double precision, double precision);
drop function if exists dock0_fix_space(double precision, double precision);
drop function if exists dock0_loc(double precision, double precision, text, text);
drop function if exists dock0_user();

do $$ declare a text; b text; begin
  select value::text into a from game_config where key='mainship_send_enabled';
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  if a is distinct from 'true'  then raise exception 'FLAG FAIL: mainship_send_enabled=% (must remain true / untouched by DOCK-0)', a; end if;
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled=% (must remain false)', b; end if;
  raise notice 'FLAG ok: mainship_send_enabled=true (untouched), mainship_space_movement_enabled=false (dark)';
end $$;
select 'OSN-DOCK-0 REAL-CHAIN FIXTURE MATRIX: ALL PASSED' as result;
