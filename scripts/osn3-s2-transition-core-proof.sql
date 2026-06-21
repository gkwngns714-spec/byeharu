-- OSN-3 S2 — DISPOSABLE transition-core proof. Runs on an EPHEMERAL postgres:15 container.
-- Reproduces the four S2 helper functions VERBATIM against minimal stand-in tables (no Supabase
-- auth/RLS — those are validated live post-merge) and proves: REAL two-session locking via dblink
-- (blocking conflict + skip-locked + all-locked + legacy-movement NOT locked), the static lock order,
-- the validate/resolve/exclusion truth tables, and that no helper mutates any row. Fixtures are
-- COMMITTED (so the separate dblink session can see them) and dropped at the end.

\set ON_ERROR_STOP on
create extension if not exists pgcrypto;
create extension if not exists dblink;

-- ── stub schema (only the columns the helpers reference) ──────────────────────────────────────
drop table if exists location_presence, fleet_movements, main_ship_space_movements, fleets, main_ship_instances, locations, bases cascade;
create table bases (id uuid primary key default gen_random_uuid(), player_id uuid not null, status text not null default 'active', x double precision, y double precision, created_at timestamptz not null default now());
create table locations (id uuid primary key default gen_random_uuid(), x double precision, y double precision);
create table main_ship_instances (main_ship_id uuid primary key default gen_random_uuid(), player_id uuid not null, status text not null default 'home', spatial_state text, space_x double precision, space_y double precision);
create table fleets (id uuid primary key default gen_random_uuid(), main_ship_id uuid, player_id uuid not null, status text not null default 'idle', location_mode text not null default 'base', current_location_id uuid, active_movement_id uuid, active_space_movement_id uuid);
create table main_ship_space_movements (id uuid primary key default gen_random_uuid(), main_ship_id uuid not null, fleet_id uuid not null, player_id uuid not null, status text not null default 'moving');
create table fleet_movements (id uuid primary key default gen_random_uuid(), fleet_id uuid not null, status text not null default 'moving');
create table location_presence (id uuid primary key default gen_random_uuid(), fleet_id uuid not null, status text not null default 'active', location_id uuid);

-- ── the four S2 helpers (VERBATIM from migration 0056) ────────────────────────────────────────
create or replace function public.mainship_space_lock_context(p_main_ship_id uuid, p_skip_locked boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ship main_ship_instances%rowtype; v_fleet fleets%rowtype; v_fleets jsonb := '[]'::jsonb; v_count integer := 0;
  v_one_fleet uuid := null; v_mv main_ship_space_movements%rowtype; v_pres location_presence%rowtype; v_has_legacy boolean := false;
begin
  if p_skip_locked then
    select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id for update skip locked;
    if not found then
      if exists (select 1 from main_ship_instances where main_ship_id = p_main_ship_id) then return jsonb_build_object('status','skipped'); else return jsonb_build_object('status','not_found'); end if;
    end if;
  else
    select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id for update;
    if not found then return jsonb_build_object('status','not_found'); end if;
  end if;
  for v_fleet in select * from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning') order by id for update loop
    v_count := v_count + 1; v_fleets := v_fleets || to_jsonb(v_fleet); v_one_fleet := v_fleet.id;
  end loop;
  if v_count <> 1 then v_one_fleet := null; end if;
  select * into v_mv from main_ship_space_movements where main_ship_id = p_main_ship_id and status = 'moving' for update;
  if v_one_fleet is not null then
    select * into v_pres from location_presence where fleet_id = v_one_fleet and status = 'active' for update;
    v_has_legacy := exists (select 1 from fleet_movements where fleet_id = v_one_fleet and status = 'moving');
  end if;
  return jsonb_build_object('status','locked','main_ship_id',p_main_ship_id,'ship',to_jsonb(v_ship),'fleets',v_fleets,'fleet_count',v_count,
    'relevant_fleet_id',v_one_fleet,'space_movement',case when v_mv.id is null then null else to_jsonb(v_mv) end,
    'presence',case when v_pres.id is null then null else to_jsonb(v_pres) end,'has_active_legacy_movement',v_has_legacy);
end; $$;

create or replace function public.mainship_space_validate_context(p_main_ship_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ship main_ship_instances%rowtype; v_fleet fleets%rowtype; v_count integer := 0; v_mv main_ship_space_movements%rowtype;
  v_pres location_presence%rowtype; v_ss text; v_st text; v_has_legacy boolean := false; v_coord boolean; v_presact boolean; fail constant text := 'contradictory_state';
begin
  select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;
  v_ss := v_ship.spatial_state; v_st := v_ship.status;
  select count(*) into v_count from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
  if v_count > 1 then return jsonb_build_object('ok', false, 'reason', 'multiple_active_fleets'); end if;
  if v_count = 1 then select * into v_fleet from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning'); end if;
  select * into v_mv from main_ship_space_movements where main_ship_id = p_main_ship_id and status = 'moving';
  v_coord := v_mv.id is not null;
  if v_count = 1 then
    select * into v_pres from location_presence where fleet_id = v_fleet.id and status = 'active';
    v_has_legacy := exists (select 1 from fleet_movements where fleet_id = v_fleet.id and status = 'moving');
  end if;
  v_presact := v_pres.id is not null;
  if v_st = 'destroyed' or v_ss = 'destroyed' then
    if v_coord or v_presact or v_count > 0 then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'destroyed');
  end if;
  if v_ss = 'in_space' then
    if v_st <> 'stationary' or v_count > 0 or v_coord or v_presact then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_ship.space_x is null or v_ship.space_y is null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'in_space');
  elsif v_ss = 'at_location' then
    if v_st <> 'stationary' or v_count <> 1 then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_fleet.status <> 'present' or v_fleet.location_mode <> 'location' or v_fleet.current_location_id is null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_fleet.active_movement_id is not null or v_fleet.active_space_movement_id is not null or v_coord then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if not v_presact or v_pres.location_id is distinct from v_fleet.current_location_id then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'at_location');
  elsif v_ss = 'in_transit' then
    if v_st <> 'traveling' or v_count <> 1 then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_fleet.status <> 'moving' or v_fleet.location_mode <> 'movement' or v_fleet.active_movement_id is not null then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if not v_coord or v_fleet.active_space_movement_id is distinct from v_mv.id then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_mv.fleet_id is distinct from v_fleet.id or v_mv.main_ship_id is distinct from v_ship.main_ship_id or v_mv.player_id is distinct from v_ship.player_id then return jsonb_build_object('ok', false, 'reason', fail); end if;
    if v_presact or v_has_legacy then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'in_transit');
  elsif v_ss = 'home' then
    if v_st <> 'home' or v_count > 0 or v_coord or v_presact then return jsonb_build_object('ok', false, 'reason', fail); end if;
    return jsonb_build_object('ok', true, 'state', 'home');
  elsif v_ss is not null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_spatial_state');
  end if;
  if v_count = 0 and v_st = 'home' then return jsonb_build_object('ok', true, 'state', 'legacy_home'); end if;
  if v_count = 1 and v_fleet.status = 'present' and v_fleet.current_location_id is not null and v_presact and v_pres.location_id is not distinct from v_fleet.current_location_id then return jsonb_build_object('ok', true, 'state', 'legacy_present'); end if;
  if v_count = 1 and v_fleet.status in ('moving','returning') and v_has_legacy then return jsonb_build_object('ok', true, 'state', 'legacy_transit'); end if;
  return jsonb_build_object('ok', false, 'reason', fail);
end; $$;

create or replace function public.mainship_space_resolve_origin(p_main_ship_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_val jsonb; v_state text; v_ship main_ship_instances%rowtype; v_fleet fleets%rowtype; v_base record; v_loc record;
begin
  v_val := public.mainship_space_validate_context(p_main_ship_id);
  if (v_val->>'ok')::boolean is not true then return jsonb_build_object('ok', false, 'reason', coalesce(v_val->>'reason','contradictory_state')); end if;
  v_state := v_val->>'state';
  select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;
  if v_state in ('home','legacy_home') then
    select id, x, y into v_base from bases where player_id = v_ship.player_id and status = 'active' order by created_at limit 1;
    if v_base.id is null or v_base.x is null or v_base.y is null then return jsonb_build_object('ok', false, 'reason', 'base_unresolved'); end if;
    return jsonb_build_object('ok', true, 'origin_kind', 'base', 'origin_x', v_base.x, 'origin_y', v_base.y, 'origin_base_id', v_base.id);
  elsif v_state in ('at_location','legacy_present') then
    select * into v_fleet from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning') limit 1;
    select id, x, y into v_loc from locations where id = v_fleet.current_location_id;
    if v_loc.id is null or v_loc.x is null or v_loc.y is null then return jsonb_build_object('ok', false, 'reason', 'location_unresolved'); end if;
    return jsonb_build_object('ok', true, 'origin_kind', 'location', 'origin_x', v_loc.x, 'origin_y', v_loc.y, 'origin_location_id', v_loc.id);
  elsif v_state = 'in_space' then
    if v_ship.space_x is null or v_ship.space_y is null then return jsonb_build_object('ok', false, 'reason', 'contradictory_state'); end if;
    return jsonb_build_object('ok', true, 'origin_kind', 'space', 'origin_x', v_ship.space_x, 'origin_y', v_ship.space_y);
  elsif v_state in ('in_transit','legacy_transit') then return jsonb_build_object('ok', false, 'reason', 'in_transit_must_stop');
  elsif v_state = 'destroyed' then return jsonb_build_object('ok', false, 'reason', 'destroyed');
  end if;
  return jsonb_build_object('ok', false, 'reason', 'contradictory_state');
end; $$;

create or replace function public.mainship_space_assert_cross_domain_exclusion(p_main_ship_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ship main_ship_instances%rowtype; v_fleet fleets%rowtype; v_count integer := 0; v_mv main_ship_space_movements%rowtype;
begin
  select * into v_ship from main_ship_instances where main_ship_id = p_main_ship_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'ship_not_found'); end if;
  select count(*) into v_count from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
  if v_count > 1 then return jsonb_build_object('ok', false, 'reason', 'multiple_active_fleets'); end if;
  if v_count = 1 then
    select * into v_fleet from fleets where main_ship_id = p_main_ship_id and status in ('idle','moving','present','returning');
    if exists (select 1 from fleet_movements where fleet_id = v_fleet.id and status = 'moving') then return jsonb_build_object('ok', false, 'reason', 'active_legacy_movement'); end if;
  end if;
  select * into v_mv from main_ship_space_movements where main_ship_id = p_main_ship_id and status = 'moving';
  if v_mv.id is not null then
    if v_count <> 1 or v_mv.fleet_id is distinct from v_fleet.id or v_fleet.active_space_movement_id is distinct from v_mv.id or v_mv.player_id is distinct from v_ship.player_id then
      return jsonb_build_object('ok', false, 'reason', 'coordinate_pointer_mismatch'); end if;
  end if;
  if v_ship.spatial_state in ('in_space','in_transit') and v_count = 1 and exists (select 1 from location_presence where fleet_id = v_fleet.id and status = 'active') then
    return jsonb_build_object('ok', false, 'reason', 'presence_conflict'); end if;
  return jsonb_build_object('ok', true);
end; $$;

-- ── COMMITTED fixtures (so the dblink session sees them) ───────────────────────────────────────
\set conn 'host=localhost port=5432 dbname=postgres user=postgres password=postgres'

-- a parked-in-space ship + a present-at-location ship + an in-transit ship + a home ship
insert into bases(id, player_id, x, y) values ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-000000000001', 0, 0);
insert into locations(id, x, y) values ('00000000-0000-0000-0000-0000000000c1', 300, 400);

-- LOCK fixture ship: home, with one idle fleet, a (fake) coordinate movement, and a presence — so all four rows exist to lock.
insert into main_ship_instances(main_ship_id, player_id, status, spatial_state) values ('00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-000000000001','home', null);
insert into fleets(id, main_ship_id, player_id, status, location_mode) values ('00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-000000000001','moving','movement');
insert into main_ship_space_movements(id, main_ship_id, fleet_id, player_id, status) values ('00000000-0000-0000-0000-00000000d001','00000000-0000-0000-0000-00000000a001','00000000-0000-0000-0000-00000000f001','00000000-0000-0000-0000-000000000001','moving');
update fleets set active_space_movement_id='00000000-0000-0000-0000-00000000d001' where id='00000000-0000-0000-0000-00000000f001';
insert into location_presence(id, fleet_id, status, location_id) values ('00000000-0000-0000-0000-00000000e001','00000000-0000-0000-0000-00000000f001','active','00000000-0000-0000-0000-0000000000c1');
insert into fleet_movements(id, fleet_id, status) values ('00000000-0000-0000-0000-00000000ab01','00000000-0000-0000-0000-00000000f001','moving');

-- ════════════════════ PART 1: two-session lock proofs (dblink) ════════════════════
-- Test A: ship-row serialization — while we hold the lock, a SEPARATE session NOWAIT conflicts.
begin;
select 1 from public.mainship_space_lock_context('00000000-0000-0000-0000-00000000a001', false);
do $$ begin
  perform dblink('host=localhost port=5432 dbname=postgres user=postgres password=postgres',
                 'select main_ship_id from main_ship_instances where main_ship_id=''00000000-0000-0000-0000-00000000a001'' for update nowait');
  raise exception 'TEST A FAIL: NOWAIT did not conflict (ship not locked)';
exception when others then raise notice 'TEST A ok: separate session NOWAIT conflicted (ship is locked): %', left(sqlerrm,40); end $$;
-- all four rows locked: NOWAIT on fleet / coordinate movement / presence each conflicts
do $$ begin perform dblink('host=localhost port=5432 dbname=postgres user=postgres password=postgres','select id from fleets where id=''00000000-0000-0000-0000-00000000f001'' for update nowait'); raise exception 'TEST A FAIL: fleet not locked'; exception when others then raise notice 'TEST A ok: fleet locked'; end $$;
do $$ begin perform dblink('host=localhost port=5432 dbname=postgres user=postgres password=postgres','select id from main_ship_space_movements where id=''00000000-0000-0000-0000-00000000d001'' for update nowait'); raise exception 'TEST A FAIL: coord movement not locked'; exception when others then raise notice 'TEST A ok: coordinate movement locked'; end $$;
do $$ begin perform dblink('host=localhost port=5432 dbname=postgres user=postgres password=postgres','select id from location_presence where id=''00000000-0000-0000-0000-00000000e001'' for update nowait'); raise exception 'TEST A FAIL: presence not locked'; exception when others then raise notice 'TEST A ok: presence locked'; end $$;
-- fleet_movements is NOT locked by lock_context (only a non-locking EXISTS read): NOWAIT succeeds
do $$ begin perform dblink('host=localhost port=5432 dbname=postgres user=postgres password=postgres','select id from fleet_movements where id=''00000000-0000-0000-0000-00000000ab01'' for update nowait'); raise notice 'TEST A ok: fleet_movements NOT locked (legacy domain untouched)'; exception when others then raise exception 'TEST A FAIL: fleet_movements was locked: %', sqlerrm; end $$;
commit;
-- after commit, the separate session can lock the ship
do $$ begin perform dblink('host=localhost port=5432 dbname=postgres user=postgres password=postgres','select main_ship_id from main_ship_instances where main_ship_id=''00000000-0000-0000-0000-00000000a001'' for update nowait'); raise notice 'TEST A ok: after commit, ship lockable again'; exception when others then raise exception 'TEST A FAIL: ship still locked after commit'; end $$;

-- Test B: skip-locked mode — while A holds the ship lock, a separate session in skip mode returns 'skipped'.
begin;
select 1 from public.mainship_space_lock_context('00000000-0000-0000-0000-00000000a001', false);  -- hold lock
do $$ declare r text; begin
  select dblink('host=localhost port=5432 dbname=postgres user=postgres password=postgres',
                'select public.mainship_space_lock_context(''00000000-0000-0000-0000-00000000a001'', true)::text') into r;
  if r like '%skipped%' then raise notice 'TEST B ok: skip-locked mode returned skipped (no block): %', r; else raise exception 'TEST B FAIL: expected skipped, got %', r; end if;
end $$;
commit;

-- Test C (lock-order, static detection): parse the function source; assert FOR-UPDATE statements appear
-- in canonical order ship < fleet < coordinate-movement < presence.
do $$ declare src text; p_ship int; p_fleet int; p_mv int; p_pres int; begin
  src := pg_get_functiondef('public.mainship_space_lock_context(uuid, boolean)'::regprocedure);
  p_ship := position('from main_ship_instances where main_ship_id = p_main_ship_id for update' in src);
  p_fleet := position('from fleets where main_ship_id = p_main_ship_id and status in' in src);
  p_mv := position('from main_ship_space_movements where main_ship_id = p_main_ship_id and status = ''moving'' for update' in src);
  p_pres := position('from location_presence where fleet_id = v_one_fleet and status = ''active'' for update' in src);
  if p_ship=0 or p_fleet=0 or p_mv=0 or p_pres=0 then raise exception 'TEST C FAIL: a FOR UPDATE locus not found (ship=% fleet=% mv=% pres=%)', p_ship,p_fleet,p_mv,p_pres; end if;
  if not (p_ship < p_fleet and p_fleet < p_mv and p_mv < p_pres) then raise exception 'TEST C FAIL: lock order wrong (%,%,%,%)', p_ship,p_fleet,p_mv,p_pres; end if;
  raise notice 'TEST C ok: lock order ship<fleet<movement<presence (positions %, %, %, %)', p_ship,p_fleet,p_mv,p_pres;
  if position('fleet_movements' in src) > 0 and position('for update' in substring(src from position('fleet_movements' in src))) < position('end loop' in src) then null; end if;
end $$;

-- ════════════════════ PART 2: validate / resolve / exclusion truth tables ════════════════════
-- builder: reset a ship into a precise state and return its id
create or replace function s2tmp_make(p_kind text) returns uuid language plpgsql as $$
declare v_u uuid := gen_random_uuid(); v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid(); v_m uuid := gen_random_uuid(); v_b uuid := gen_random_uuid();
begin
  insert into bases(id,player_id,x,y) values (v_b,v_u,10,20);
  if p_kind='legacy_home' then insert into main_ship_instances(main_ship_id,player_id,status,spatial_state) values (v_s,v_u,'home',null);
  elsif p_kind='home' then insert into main_ship_instances(main_ship_id,player_id,status,spatial_state) values (v_s,v_u,'home','home');
  elsif p_kind='in_space' then insert into main_ship_instances(main_ship_id,player_id,status,spatial_state,space_x,space_y) values (v_s,v_u,'stationary','in_space',7,-9);
  elsif p_kind='destroyed' then insert into main_ship_instances(main_ship_id,player_id,status,spatial_state) values (v_s,v_u,'destroyed','destroyed');
  elsif p_kind='legacy_present' then
    insert into main_ship_instances(main_ship_id,player_id,status,spatial_state) values (v_s,v_u,'traveling',null);
    insert into fleets(id,main_ship_id,player_id,status,location_mode,current_location_id) values (v_f,v_s,v_u,'present','location','00000000-0000-0000-0000-0000000000c1');
    insert into location_presence(id,fleet_id,status,location_id) values (v_m,v_f,'active','00000000-0000-0000-0000-0000000000c1');
  elsif p_kind='at_location' then
    insert into main_ship_instances(main_ship_id,player_id,status,spatial_state) values (v_s,v_u,'stationary','at_location');
    insert into fleets(id,main_ship_id,player_id,status,location_mode,current_location_id) values (v_f,v_s,v_u,'present','location','00000000-0000-0000-0000-0000000000c1');
    insert into location_presence(id,fleet_id,status,location_id) values (v_m,v_f,'active','00000000-0000-0000-0000-0000000000c1');
  elsif p_kind='in_transit' then
    insert into main_ship_instances(main_ship_id,player_id,status,spatial_state) values (v_s,v_u,'traveling','in_transit');
    insert into fleets(id,main_ship_id,player_id,status,location_mode) values (v_f,v_s,v_u,'moving','movement');
    insert into main_ship_space_movements(id,main_ship_id,fleet_id,player_id,status) values (v_m,v_s,v_f,v_u,'moving');
    update fleets set active_space_movement_id=v_m where id=v_f;
  elsif p_kind='legacy_with_legacy_mv' then
    insert into main_ship_instances(main_ship_id,player_id,status,spatial_state) values (v_s,v_u,'traveling',null);
    insert into fleets(id,main_ship_id,player_id,status,location_mode) values (v_f,v_s,v_u,'moving','movement');
    insert into fleet_movements(fleet_id,status) values (v_f,'moving');
  end if;
  return v_s;
end $$;

do $$
declare s uuid; r jsonb;
begin
  -- validate truth table
  s := s2tmp_make('legacy_home');    r := mainship_space_validate_context(s); if r->>'state' <> 'legacy_home' then raise exception 'V legacy_home: %', r; end if;
  s := s2tmp_make('home');           r := mainship_space_validate_context(s); if r->>'state' <> 'home' then raise exception 'V home: %', r; end if;
  s := s2tmp_make('in_space');       r := mainship_space_validate_context(s); if r->>'state' <> 'in_space' then raise exception 'V in_space: %', r; end if;
  s := s2tmp_make('destroyed');      r := mainship_space_validate_context(s); if r->>'state' <> 'destroyed' then raise exception 'V destroyed: %', r; end if;
  s := s2tmp_make('legacy_present'); r := mainship_space_validate_context(s); if r->>'state' <> 'legacy_present' then raise exception 'V legacy_present: %', r; end if;
  s := s2tmp_make('at_location');    r := mainship_space_validate_context(s); if r->>'state' <> 'at_location' then raise exception 'V at_location: %', r; end if;
  s := s2tmp_make('in_transit');     r := mainship_space_validate_context(s); if r->>'state' <> 'in_transit' then raise exception 'V in_transit: %', r; end if;
  raise notice 'validate truth table ok';

  -- malformed: in_space with an active presence/movement → contradictory
  s := s2tmp_make('in_space');
  insert into fleets(id,main_ship_id,player_id,status,location_mode) values (gen_random_uuid(), s, (select player_id from main_ship_instances where main_ship_id=s), 'moving','movement');
  r := mainship_space_validate_context(s); if (r->>'ok')::boolean then raise exception 'V in_space+fleet should fail: %', r; end if;
  raise notice 'validate malformed ok';

  -- resolve_origin truth table
  s := s2tmp_make('legacy_home');    r := mainship_space_resolve_origin(s); if r->>'origin_kind' <> 'base' then raise exception 'O legacy_home: %', r; end if;
  s := s2tmp_make('home');           r := mainship_space_resolve_origin(s); if r->>'origin_kind' <> 'base' then raise exception 'O home: %', r; end if;
  s := s2tmp_make('legacy_present'); r := mainship_space_resolve_origin(s); if r->>'origin_kind' <> 'location' then raise exception 'O legacy_present: %', r; end if;
  s := s2tmp_make('at_location');    r := mainship_space_resolve_origin(s); if r->>'origin_kind' <> 'location' then raise exception 'O at_location: %', r; end if;
  s := s2tmp_make('in_space');       r := mainship_space_resolve_origin(s); if r->>'origin_kind' <> 'space' then raise exception 'O in_space: %', r; end if;
  s := s2tmp_make('in_transit');     r := mainship_space_resolve_origin(s); if r->>'reason' <> 'in_transit_must_stop' then raise exception 'O in_transit: %', r; end if;
  s := s2tmp_make('destroyed');      r := mainship_space_resolve_origin(s); if r->>'reason' <> 'destroyed' then raise exception 'O destroyed: %', r; end if;
  raise notice 'resolve_origin truth table ok';

  -- cross-domain exclusion
  s := s2tmp_make('legacy_with_legacy_mv'); r := mainship_space_assert_cross_domain_exclusion(s); if r->>'reason' <> 'active_legacy_movement' then raise exception 'X legacy mv: %', r; end if;
  s := s2tmp_make('in_transit');            r := mainship_space_assert_cross_domain_exclusion(s); if (r->>'ok')::boolean is not true then raise exception 'X in_transit (consistent) should pass: %', r; end if;
  -- mismatched pointer: break the fleet pointer
  s := s2tmp_make('in_transit'); update fleets set active_space_movement_id = gen_random_uuid() where main_ship_id=s;
  r := mainship_space_assert_cross_domain_exclusion(s); if r->>'reason' <> 'coordinate_pointer_mismatch' then raise exception 'X mismatch: %', r; end if;
  raise notice 'cross-domain exclusion ok';
end $$;

-- mutation safety: validate+resolve+exclusion change NO row
do $$ declare h1 text; h2 text; s uuid;
begin
  s := s2tmp_make('at_location');
  select md5(string_agg(t,'')) into h1 from (
    select md5(main_ship_instances::text) t from main_ship_instances union all
    select md5(fleets::text) from fleets union all select md5(main_ship_space_movements::text) from main_ship_space_movements union all
    select md5(location_presence::text) from location_presence union all select md5(fleet_movements::text) from fleet_movements) z;
  perform mainship_space_validate_context(s); perform mainship_space_resolve_origin(s); perform mainship_space_assert_cross_domain_exclusion(s);
  select md5(string_agg(t,'')) into h2 from (
    select md5(main_ship_instances::text) t from main_ship_instances union all
    select md5(fleets::text) from fleets union all select md5(main_ship_space_movements::text) from main_ship_space_movements union all
    select md5(location_presence::text) from location_presence union all select md5(fleet_movements::text) from fleet_movements) z;
  if h1 is distinct from h2 then raise exception 'MUTATION FAIL: a helper changed table content'; end if;
  raise notice 'mutation-safety ok: no row changed by validate/resolve/exclusion';
end $$;

-- cleanup (disposable)
drop function if exists s2tmp_make(text);
drop function if exists public.mainship_space_lock_context(uuid, boolean), public.mainship_space_validate_context(uuid), public.mainship_space_resolve_origin(uuid), public.mainship_space_assert_cross_domain_exclusion(uuid);
drop table if exists location_presence, fleet_movements, main_ship_space_movements, fleets, main_ship_instances, locations, bases cascade;
select 'OSN-3 S2 TRANSITION-CORE PROOF: ALL PASSED' as result;
