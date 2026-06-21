-- OSN-3 S1 — DISPOSABLE schema/constraint proof. Runs on an EPHEMERAL postgres:15 container.
-- Reuses the EXACT CHECK/constraint/index expressions from migration 0055 against minimal stand-in
-- tables (no Supabase auth/RLS — those are validated live post-merge). Proves every §5.1 case:
-- accept the valid, reject the invalid. One transaction, rolled back → disposable.

\set ON_ERROR_STOP on
begin;
create extension if not exists pgcrypto;

-- ── stubs (only the columns/constraints the proof needs) ──────────────────────────────────────
create table users_stub (id uuid primary key default gen_random_uuid());
create table locations (id uuid primary key default gen_random_uuid());
create table bases (id uuid primary key default gen_random_uuid());

create table main_ship_instances (
  main_ship_id uuid primary key default gen_random_uuid(),
  player_id    uuid not null references users_stub(id) on delete cascade,
  status       text not null default 'home',
  spatial_state text,
  space_x      double precision,
  space_y      double precision,
  -- 0054 checks (pre-existing; must keep working — included to prove they still hold)
  constraint mss_domain check (spatial_state is null or spatial_state in ('home','at_location','in_transit','in_space','destroyed')),
  constraint mss_coords check (
        (space_x is null) = (space_y is null)
    and (space_x is null or spatial_state is not distinct from 'in_space')
    and (spatial_state is distinct from 'in_space' or space_x is not null)
    and (space_x is null or (space_x <> 'NaN'::double precision and space_x <> 'Infinity'::double precision and space_x <> '-Infinity'::double precision))
    and (space_y is null or (space_y <> 'NaN'::double precision and space_y <> 'Infinity'::double precision and space_y <> '-Infinity'::double precision))
  ),
  -- 0055 status domain (+stationary) + six lifecycle checks (verbatim)
  constraint main_ship_instances_status_check check (status in ('home','traveling','hunting','trading','exploring','mining','retreating','returning','repairing','destroyed','stationary')),
  constraint ss_in_space_status   check (spatial_state is distinct from 'in_space'    or status = 'stationary'),
  constraint ss_at_location_status check (spatial_state is distinct from 'at_location' or status = 'stationary'),
  constraint ss_in_transit_status check (spatial_state is distinct from 'in_transit'  or status = 'traveling'),
  constraint ss_home_status       check (spatial_state is distinct from 'home'        or status = 'home'),
  constraint ss_destroyed_status  check (spatial_state is distinct from 'destroyed'   or status = 'destroyed'),
  constraint stationary_spatial_state check (status <> 'stationary' or (spatial_state in ('in_space','at_location')) is true)
);

create table fleets (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references users_stub(id) on delete cascade,
  status text not null default 'idle',
  location_mode text not null default 'base',
  active_movement_id uuid,
  active_space_movement_id uuid,
  main_ship_id uuid references main_ship_instances(main_ship_id) on delete set null
);

create table main_ship_space_movements (
  id uuid primary key default gen_random_uuid(),
  main_ship_id uuid not null references main_ship_instances(main_ship_id) on delete cascade,
  fleet_id uuid not null references fleets(id) on delete cascade,
  player_id uuid not null references users_stub(id) on delete cascade,
  origin_kind text not null check (origin_kind in ('base','location','space')),
  origin_x double precision not null, origin_y double precision not null,
  target_kind text not null check (target_kind in ('space','location','base')),
  target_x double precision not null, target_y double precision not null,
  target_location_id uuid references locations(id),
  target_base_id uuid references bases(id),
  status text not null default 'moving' check (status in ('moving','arrived','stopped','cancelled','failed')),
  terminal_reason text,
  speed_used double precision not null,
  depart_at timestamptz not null, arrive_at timestamptz not null,
  created_at timestamptz not null default now(), resolved_at timestamptz,
  check (arrive_at > depart_at),
  check (speed_used > 0 and speed_used <> 'NaN'::double precision and speed_used <> 'Infinity'::double precision and speed_used <> '-Infinity'::double precision),
  check (origin_x <> 'NaN'::double precision and origin_x <> 'Infinity'::double precision and origin_x <> '-Infinity'::double precision and origin_x >= -10000 and origin_x <= 10000),
  check (origin_y <> 'NaN'::double precision and origin_y <> 'Infinity'::double precision and origin_y <> '-Infinity'::double precision and origin_y >= -10000 and origin_y <= 10000),
  check (target_x <> 'NaN'::double precision and target_x <> 'Infinity'::double precision and target_x <> '-Infinity'::double precision and target_x >= -10000 and target_x <= 10000),
  check (target_y <> 'NaN'::double precision and target_y <> 'Infinity'::double precision and target_y <> '-Infinity'::double precision and target_y >= -10000 and target_y <= 10000),
  check ((target_kind='space' and target_location_id is null and target_base_id is null)
      or (target_kind='location' and target_location_id is not null and target_base_id is null)
      or (target_kind='base' and target_base_id is not null and target_location_id is null)),
  check ((status='moving' and resolved_at is null) or (status in ('arrived','stopped','cancelled','failed') and resolved_at is not null))
);
create unique index msm_one_active_per_ship on main_ship_space_movements (main_ship_id) where status='moving';
create unique index msm_one_active_per_fleet on main_ship_space_movements (fleet_id) where status='moving';

alter table fleets add constraint fleets_active_space_movement_fk
  foreign key (active_space_movement_id) references main_ship_space_movements(id) on delete set null deferrable initially deferred;
alter table fleets add constraint fleets_movement_pointers_exclusive
  check (active_movement_id is null or active_space_movement_id is null);
alter table fleets add constraint fleets_active_space_movement_requires_moving
  check (active_space_movement_id is null or (active_movement_id is null and status='moving' and location_mode='movement'));
create unique index fleets_one_per_active_space_movement on fleets (active_space_movement_id) where active_space_movement_id is not null;

-- helper: assert that a statement RAISES (proof fails if it does NOT)
create function expect_reject(sql text, label text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then raise notice '  reject ok: %', label; return; end;
  raise exception 'PROOF FAIL: % was ACCEPTED but should be rejected', label;
end $$;

do $p$
declare v_u uuid; v_a uuid; v_f uuid; v_m uuid; v_loc uuid; v_base uuid; v_dep timestamptz := now(); v_arr timestamptz := now()+interval '1 hour';
begin
  insert into users_stub default values returning id into v_u;
  insert into locations default values returning id into v_loc;
  insert into bases default values returning id into v_base;
  insert into main_ship_instances(player_id, status, spatial_state) values (v_u, 'home', null) returning main_ship_id into v_a; -- legacy NULL accepted
  raise notice 'T1 ok: legacy spatial_state=NULL row accepted';
  insert into fleets(player_id, status, location_mode, main_ship_id) values (v_u, 'moving', 'movement', v_a) returning id into v_f;

  -- T2: stationary + in_space / at_location accepted; stationary + NULL rejected
  update main_ship_instances set status='stationary', spatial_state='in_space', space_x=5, space_y=6 where main_ship_id=v_a;
  update main_ship_instances set status='stationary', spatial_state='at_location', space_x=null, space_y=null where main_ship_id=v_a;
  raise notice 'T2 ok: stationary+in_space and stationary+at_location accepted';
  perform expect_reject(format('update main_ship_instances set status=%L, spatial_state=null, space_x=null, space_y=null where main_ship_id=%L','stationary',v_a), 'stationary + NULL spatial_state');

  -- T3: each non-null spatial state with incompatible status rejected
  perform expect_reject(format('update main_ship_instances set status=%L, spatial_state=%L, space_x=1, space_y=1 where main_ship_id=%L','home','in_space',v_a), 'in_space with status=home');
  perform expect_reject(format('update main_ship_instances set status=%L, spatial_state=%L where main_ship_id=%L','home','at_location',v_a), 'at_location with status=home');
  perform expect_reject(format('update main_ship_instances set status=%L, spatial_state=%L where main_ship_id=%L','home','in_transit',v_a), 'in_transit with status=home');
  perform expect_reject(format('update main_ship_instances set status=%L, spatial_state=%L where main_ship_id=%L','traveling','home',v_a), 'home with status=traveling');
  perform expect_reject(format('update main_ship_instances set status=%L, spatial_state=%L where main_ship_id=%L','home','destroyed',v_a), 'destroyed with status=home');
  raise notice 'T3 ok: incompatible spatial_state/status combos rejected';

  -- reset ship to a clean home so further fleet tests are unconstrained by ship state
  update main_ship_instances set status='home', spatial_state=null, space_x=null, space_y=null where main_ship_id=v_a;

  -- T4 (0054): in_space coord pairing/finite still enforced
  perform expect_reject(format('update main_ship_instances set status=%L, spatial_state=%L, space_x=1, space_y=null where main_ship_id=%L','stationary','in_space',v_a), '0054 half-pair coords');
  perform expect_reject(format($q$update main_ship_instances set status='stationary', spatial_state='in_space', space_x='NaN'::double precision, space_y=2 where main_ship_id='%s'$q$, v_a), '0054 NaN coord');
  raise notice 'T4 ok: 0054 in_space pairing/finite checks still enforced';
  update main_ship_instances set status='home', spatial_state=null, space_x=null, space_y=null where main_ship_id=v_a;

  -- valid coordinate movement (space target)
  insert into main_ship_space_movements(main_ship_id, fleet_id, player_id, origin_kind, origin_x, origin_y, target_kind, target_x, target_y, speed_used, depart_at, arrive_at)
    values (v_a, v_f, v_u, 'base', 0, 0, 'space', 100, 50, 1.0, v_dep, v_arr) returning id into v_m;
  raise notice 'valid space-target movement inserted';

  -- T5: pointer mutual exclusion + T6: requires moving/movement
  update fleets set active_space_movement_id = v_m where id = v_f;  -- fleet already moving/movement → ok
  perform expect_reject(format('update fleets set active_movement_id=%L where id=%L', gen_random_uuid(), v_f), 'both movement pointers non-null');
  raise notice 'T5 ok: movement pointers mutually exclusive';
  -- requires moving/movement: a non-moving fleet cannot hold a coordinate pointer
  declare v_f2 uuid; begin
    insert into fleets(player_id, status, location_mode) values (v_u, 'idle', 'base') returning id into v_f2;
    perform expect_reject(format('update fleets set active_space_movement_id=%L where id=%L', v_m, v_f2), 'active_space_movement_id on idle fleet');
  end;
  raise notice 'T6 ok: active_space_movement_id requires moving/movement fleet';

  -- T7: two fleets cannot share the same active coordinate movement
  declare v_f3 uuid; begin
    insert into fleets(player_id, status, location_mode) values (v_u, 'moving', 'movement') returning id into v_f3;
    perform expect_reject(format('update fleets set active_space_movement_id=%L where id=%L', v_m, v_f3), 'two fleets share one coordinate movement');
  end;
  raise notice 'T7 ok: one fleet per active coordinate movement';

  -- T8: one active coordinate movement per ship / per fleet
  perform expect_reject(format($q$insert into main_ship_space_movements(main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at) values ('%s','%s','%s','space',1,1,'space',2,2,1,'%s','%s')$q$, v_a, v_f, v_u, v_dep, v_arr), 'second active movement same ship+fleet');
  raise notice 'T8 ok: one active coordinate movement per ship/fleet';

  -- T9: finite/bounds reject invalid origin/target
  perform expect_reject(format($q$insert into main_ship_space_movements(main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at) values ('%s','%s','%s','space',0,0,'space',20000,0,1,'%s','%s')$q$, v_a, v_f, v_u, v_dep, v_arr), 'target_x out of bounds (20000)');
  perform expect_reject(format($q$insert into main_ship_space_movements(main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at) values ('%s','%s','%s','space',0,0,'space','Infinity'::double precision,0,1,'%s','%s')$q$, v_a, v_f, v_u, v_dep, v_arr), 'target_x Infinity');
  raise notice 'T9 ok: finite/bounds reject invalid coords';

  -- T10: invalid target-kind/id combos
  perform expect_reject(format($q$insert into main_ship_space_movements(main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,target_location_id,speed_used,depart_at,arrive_at) values ('%s','%s','%s','space',0,0,'space',1,1,'%s',1,'%s','%s')$q$, v_a, v_f, v_u, v_loc, v_dep, v_arr), 'space target with target_location_id set');
  perform expect_reject(format($q$insert into main_ship_space_movements(main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at) values ('%s','%s','%s','space',0,0,'location',1,1,1,'%s','%s')$q$, v_a, v_f, v_u, v_dep, v_arr), 'location target without target_location_id');
  raise notice 'T10 ok: target-kind/id invariant enforced';

  -- T11: arrive <= depart rejected
  perform expect_reject(format($q$insert into main_ship_space_movements(main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at) values ('%s','%s','%s','space',0,0,'space',1,1,1,'%s','%s')$q$, v_a, v_f, v_u, v_arr, v_dep), 'arrive_at <= depart_at');
  raise notice 'T11 ok: arrive_at>depart_at enforced';

  -- T12: non-finite / non-positive speed rejected
  perform expect_reject(format($q$insert into main_ship_space_movements(main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at) values ('%s','%s','%s','space',0,0,'space',1,1,0,'%s','%s')$q$, v_a, v_f, v_u, v_dep, v_arr), 'speed_used = 0');
  perform expect_reject(format($q$insert into main_ship_space_movements(main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at) values ('%s','%s','%s','space',0,0,'space',1,1,'Infinity'::double precision,'%s','%s')$q$, v_a, v_f, v_u, v_dep, v_arr), 'speed_used = Infinity');
  raise notice 'T12 ok: speed finite/positive enforced';

  -- T13: terminal-status requires resolved_at
  perform expect_reject(format($q$update main_ship_space_movements set status='arrived', resolved_at=null where id='%s'$q$, v_m), 'arrived without resolved_at');
  raise notice 'T13 ok: status/resolved_at integrity enforced';

  raise notice 'OSN-3 S1 SCHEMA PROOF: ALL PASSED';
end
$p$;
rollback;
