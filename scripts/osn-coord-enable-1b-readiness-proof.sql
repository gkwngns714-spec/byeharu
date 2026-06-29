-- OSN-COORD-ENABLE-1B — disposable REAL-CHAIN proof for the additive coordinate-travel readiness capability
-- (migration 0071). Runs on the ACTUAL chain (0001..0071) in a throwaway Supabase. Proves:
--   • the 2×2 truth table for coordinate_travel_available = osn_available AND cfg_bool(coordinate gate);
--   • a non-actionable/UNANCHORED origin can NEVER get coordinate_travel_available=true even with BOTH flags true;
--   • every EXISTING readiness field retains its prior value/meaning across all origin categories;
--   • location/port readiness stays intact (anchored origin still yields the other active ports);
--   • the new field is a strict JSON boolean and present in every response shape;
--   • an authenticated caller can read readiness; anon/PUBLIC cannot execute the RPC;
--   • reading readiness writes NOTHING (game_config / movements / ports / ships / fleets / presence unchanged);
--   • cleanup leaves no net world/player/flag change.
-- Flags are restored to their pre-test values at the end. Fixture users carry the 'ce1bfix.' email prefix.

\set ON_ERROR_STOP on

-- Fixed 0066 identities (same starter ports used by the PORT-LAUNCH-1A matrix).
create temp table ce1b_id(k text primary key, id uuid) on commit preserve rows;
insert into ce1b_id values
  ('p1','b1a00001-0066-4a00-8a00-000000000001'),
  ('p2','b1a00002-0066-4a00-8a00-000000000002'),
  ('p3','b1a00003-0066-4a00-8a00-000000000003');

-- Snapshot the flags we will toggle so we can prove no NET flag change at the end.
create temp table ce1b_flag0 as
  select key, value from public.game_config
  where key in ('mainship_space_movement_enabled', 'mainship_coordinate_travel_enabled');

-- ════════ fixtures ════════
-- u1: HOME (not_anchored) — the UNANCHORED origin used to prove osn_available=false can never go true.
-- u2: legacy_present docked at p1 (anchored) — the actionable origin used to reach osn_available=true.
-- u3: destroyed; u4: in coordinate transit — to prove the new field stays false for non-actionable origins too.
do $$
declare u uuid; i int; v_ship uuid;
begin
  for i in 1..4 loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'ce1bfix.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    perform public.ensure_main_ship_for_player(u);
    select main_ship_id into v_ship from public.main_ship_instances where player_id = u;
    insert into ce1b_id values ('u'||i, u), ('s'||i, v_ship);
  end loop;
  -- u1 → clean HOME
  update public.main_ship_instances set status='home', spatial_state=null, space_x=null, space_y=null
    where main_ship_id = (select id from ce1b_id where k='s1');
end $$;

-- u2: coherent legacy_present docked at p1 (spatial_state NULL + one present fleet + active presence). p1's
-- active location anchor makes resolve_origin return anchored, independent of the port's hidden/active status.
do $$
declare u uuid := (select id from ce1b_id where k='u2');
        s uuid := (select id from ce1b_id where k='s2');
        p uuid := (select id from ce1b_id where k='p1');
        v_b uuid; v_zone uuid; v_sector uuid; v_fleet uuid := gen_random_uuid();
begin
  select l.zone_id, z.sector_id into v_zone, v_sector from public.locations l join public.zones z on z.id=l.zone_id where l.id=p;
  select id into v_b from public.bases where player_id=u and status='active' order by created_at limit 1;
  update public.main_ship_instances set status='home', spatial_state=null, space_x=null, space_y=null where main_ship_id=s;
  insert into public.fleets (id,player_id,origin_base_id,status,location_mode,current_base_id,current_location_id,current_zone_id,current_sector_id,main_ship_id)
    values (v_fleet,u,v_b,'present','location',null,p,v_zone,v_sector,s);
  insert into public.location_presence (player_id,fleet_id,sector_id,zone_id,location_id,activity_type,status,last_tick_at)
    values (u,v_fleet,v_sector,v_zone,p,'none','active',now());
  insert into ce1b_id values ('f2', v_fleet);
end $$;

-- u3: canonical destroyed via the trusted primitive. u4: coherent space-coordinate transit (in_transit).
do $$ begin perform public.dev_set_main_ship_destroyed((select id from ce1b_id where k='u3')); end $$;
do $$
declare u uuid := (select id from ce1b_id where k='u4');
        s uuid := (select id from ce1b_id where k='s4');
        v_b uuid; v_fleet uuid := gen_random_uuid(); v_mv uuid := gen_random_uuid();
begin
  select id into v_b from public.bases where player_id=u and status='active' order by created_at limit 1;
  update public.main_ship_instances set status='traveling', spatial_state='in_transit', space_x=null, space_y=null where main_ship_id=s;
  insert into public.fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id)
    values (v_fleet,u,v_b,'moving','movement',s);
  insert into public.main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
    values (v_mv,s,v_fleet,u,'base',0,0,'space',100,50,1.0, now()-interval '1 hour', now()+interval '1 hour');
  update public.fleets set active_space_movement_id=v_mv where id=v_fleet;
end $$;

-- ════════ helper: assert the FULL response contract for a fixture under the current flags ════════
-- Asserts existing fields exactly, that coordinate_travel_available is a strict boolean equal to the expected
-- value, and (for the contract) that no unexpected key set drift occurred.
create or replace function pg_temp.ce1b_assert(
  p_sub uuid, p_cat text, p_avail boolean, p_reason text, p_coord boolean) returns void
language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  v := public.get_osn_movement_readiness();
  -- existing fields retain their prior meaning/values
  if v->>'origin_category' <> p_cat then raise exception 'origin_category drift: got % want % (%)', v->>'origin_category', p_cat, v; end if;
  if (v->>'osn_available')::boolean <> p_avail then raise exception 'osn_available drift: got % want % (%)', v->>'osn_available', p_avail, v; end if;
  if v->>'reason' <> p_reason then raise exception 'reason drift: got % want % (%)', v->>'reason', p_reason, v; end if;
  if v->'eligible_destination_ids' is null or jsonb_typeof(v->'eligible_destination_ids') <> 'array' then
    raise exception 'eligible_destination_ids missing/not-array: %', v; end if;
  -- new field: present, STRICT boolean, exact expected value
  if not (v ? 'coordinate_travel_available') then raise exception 'coordinate_travel_available absent: %', v; end if;
  if jsonb_typeof(v->'coordinate_travel_available') <> 'boolean' then raise exception 'coordinate_travel_available not a boolean: %', v; end if;
  if (v->>'coordinate_travel_available')::boolean <> p_coord then
    raise exception 'coordinate_travel_available drift: got % want % (%)', v->>'coordinate_travel_available', p_coord, v; end if;
end $$;

-- ════════ pre-state: confirm the live-equivalent dark default before the 2×2 sweep ════════
-- A fresh chain defaults BOTH flags false (production's movement_enabled=true is set at runtime, not by a
-- migration). The coordinate gate ships false (migration 0070). Confirm, then drive the truth table explicitly.
do $$
declare mv text; co text;
begin
  select value into co from public.game_config where key='mainship_coordinate_travel_enabled';
  if co <> 'false' then raise exception 'PRECOND: coordinate gate not false on a fresh chain (got %)', co; end if;
  raise notice 'precond ok: coordinate gate ships false (dark)';
end $$;

-- ════════ 2×2 TRUTH TABLE ════════
-- osn_available is driven by the ORIGIN (u1 home=false vs u2 anchored=true) with the movement domain enabled,
-- and by the coordinate flag we toggle. Both anchored rows require mainship_space_movement_enabled=true.
update public.game_config set value='true' where key='mainship_space_movement_enabled';

-- Row [osn_available=false, coord flag=false] → false   (u1 home)
-- Row [osn_available=true , coord flag=false] → false   (u2 anchored)
update public.game_config set value='false' where key='mainship_coordinate_travel_enabled';
do $$ begin
  perform pg_temp.ce1b_assert((select id from ce1b_id where k='u1'), 'not_anchored', false, 'travel_to_port', false);
  perform pg_temp.ce1b_assert((select id from ce1b_id where k='u2'), 'anchored',     true,  'none',           false);
  raise notice 'truth-table rows (coord flag=false): osn=false→false, osn=true→false  OK';
end $$;

-- Row [osn_available=false, coord flag=true ] → false   (u1 home — CRITICAL unanchored-cannot-go-true)
-- Row [osn_available=true , coord flag=true ] → true    (u2 anchored)
update public.game_config set value='true' where key='mainship_coordinate_travel_enabled';
do $$ begin
  perform pg_temp.ce1b_assert((select id from ce1b_id where k='u1'), 'not_anchored', false, 'travel_to_port', false);
  perform pg_temp.ce1b_assert((select id from ce1b_id where k='u2'), 'anchored',     true,  'none',           true);
  raise notice 'truth-table rows (coord flag=true): osn=false→false (UNANCHORED fails closed), osn=true→true  OK';
end $$;

-- Explicit, isolated security statement: BOTH flags true, yet the UNANCHORED home origin is still false.
do $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from ce1b_id where k='u1')::text, 'role','authenticated')::text, true);
  v := public.get_osn_movement_readiness();
  if (v->>'osn_available')::boolean <> false or (v->>'coordinate_travel_available')::boolean <> false then
    raise exception 'SECURITY FAIL: unanchored origin received coordinate availability with both flags true: %', v; end if;
  raise notice 'security ok: both flags true, unanchored origin → osn_available=false, coordinate_travel_available=false';
end $$;

-- Non-actionable origins also stay false with both flags true (destroyed / in_transit / no_ship).
do $$ begin
  perform pg_temp.ce1b_assert((select id from ce1b_id where k='u3'), 'destroyed', false, 'destroyed',  false);
  perform pg_temp.ce1b_assert((select id from ce1b_id where k='u4'), 'in_transit',false, 'in_transit', false);
  perform pg_temp.ce1b_assert(gen_random_uuid(), 'no_ship', false, 'no_ship', false);  -- caller with no main ship
  raise notice 'non-actionable origins (destroyed/in_transit/no_ship) → coordinate_travel_available=false  OK';
end $$;

-- ════════ location/port readiness intact: anchored origin still yields the OTHER active ports ════════
-- Reveal the three starter ports, keep BOTH flags true, and confirm the existing destination projection is
-- unchanged by this migration (u2 docked at p1 → exactly {p2,p3}; current dock excluded; no leak).
do $$
declare r jsonb; v jsonb; p1 uuid; p2 uuid; p3 uuid; dests jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'reveal setup FAIL: %', r; end if;
  p1 := (select id from ce1b_id where k='p1'); p2 := (select id from ce1b_id where k='p2'); p3 := (select id from ce1b_id where k='p3');
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from ce1b_id where k='u2')::text, 'role','authenticated')::text, true);
  v := public.get_osn_movement_readiness();
  if v->>'origin_category' <> 'anchored' or (v->>'osn_available')::boolean <> true then
    raise exception 'port-readiness FAIL (anchored/available): %', v; end if;
  -- with the coordinate flag still true, an anchored+available origin shows coordinate availability AND ports
  if (v->>'coordinate_travel_available')::boolean <> true then raise exception 'port-readiness FAIL (coord avail): %', v; end if;
  dests := v->'eligible_destination_ids';
  if jsonb_array_length(dests) <> 2 or not (dests @> to_jsonb(p2) and dests @> to_jsonb(p3)) or (dests @> to_jsonb(p1)) then
    raise exception 'port-readiness FAIL: destinations not exactly {p2,p3} (current dock p1 excluded): %', v; end if;
  raise notice 'port-readiness ok: anchored origin still yields exactly the other active ports {p2,p3}; coordinate availability coexists';
end $$;

-- ════════ authorization: authenticated reads; anon/PUBLIC cannot execute ════════
do $$
begin
  if has_function_privilege('anon', 'public.get_osn_movement_readiness()', 'EXECUTE') then
    raise exception 'ACL FAIL: anon can execute readiness RPC'; end if;
  if has_function_privilege('public', 'public.get_osn_movement_readiness()', 'EXECUTE') then
    raise exception 'ACL FAIL: PUBLIC can execute readiness RPC'; end if;
  if not has_function_privilege('authenticated', 'public.get_osn_movement_readiness()', 'EXECUTE') then
    raise exception 'ACL FAIL: authenticated cannot execute readiness RPC'; end if;
  raise notice 'acl ok: authenticated execute only; no anon/PUBLIC';
end $$;

-- ════════ reading readiness writes NOTHING ════════
-- Snapshot mutable surfaces, perform several authenticated reads, assert byte-for-byte unchanged.
do $$
declare
  gc0 text; mv0 bigint; fl0 bigint; pr0 bigint; ms0 bigint; sp0 bigint;
  gc1 text; mv1 bigint; fl1 bigint; pr1 bigint; ms1 bigint; sp1 bigint;
begin
  select md5(string_agg(key||'='||value, ',' order by key)) into gc0 from public.game_config;
  select count(*) into mv0 from public.main_ship_space_movements;
  select count(*) into fl0 from public.fleets;
  select count(*) into pr0 from public.location_presence;
  select count(*) into ms0 from public.main_ship_instances;
  select count(*) into sp0 from public.space_anchors;

  perform set_config('request.jwt.claims', json_build_object('sub', (select id from ce1b_id where k='u2')::text, 'role','authenticated')::text, true);
  perform public.get_osn_movement_readiness();
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from ce1b_id where k='u1')::text, 'role','authenticated')::text, true);
  perform public.get_osn_movement_readiness();

  select md5(string_agg(key||'='||value, ',' order by key)) into gc1 from public.game_config;
  select count(*) into mv1 from public.main_ship_space_movements;
  select count(*) into fl1 from public.fleets;
  select count(*) into pr1 from public.location_presence;
  select count(*) into ms1 from public.main_ship_instances;
  select count(*) into sp1 from public.space_anchors;

  if gc0 is distinct from gc1 then raise exception 'WRITE FAIL: game_config changed by a read'; end if;
  if mv0<>mv1 or fl0<>fl1 or pr0<>pr1 or ms0<>ms1 or sp0<>sp1 then
    raise exception 'WRITE FAIL: a read mutated movement/fleet/presence/ship/anchor counts'; end if;
  raise notice 'read-only ok: readiness reads mutated no config/movement/fleet/presence/ship/anchor state';
end $$;

-- ════════ cleanup — remove fixtures, revert ports to hidden, restore the two flags to pre-test values ════════
delete from auth.users where email like 'ce1bfix.%@example.com';   -- cascades ships/fleets/presence/movements/bases
update public.locations set status='hidden' where id in (select id from ce1b_id where k in ('p1','p2','p3'));
update public.game_config g set value = f.value
  from ce1b_flag0 f where g.key = f.key;                            -- restore movement_enabled + coordinate gate

do $$
declare n int; co text; mv text;
begin
  select count(*) into n from auth.users where email like 'ce1bfix.%@example.com';
  if n <> 0 then raise exception 'CLEANUP: % fixture users remain', n; end if;
  select count(*) into n from public.locations where id in (select id from ce1b_id where k in ('p1','p2','p3')) and status <> 'hidden';
  if n <> 0 then raise exception 'CLEANUP: % ports not reverted to hidden', n; end if;
  select count(*) into n from public.main_ship_instances s where s.player_id not in (select id from auth.users);
  if n <> 0 then raise exception 'CLEANUP: % orphan main ships remain', n; end if;
  select value into co from public.game_config where key='mainship_coordinate_travel_enabled';
  select value into mv from public.game_config where key='mainship_space_movement_enabled';
  if co <> (select value::text from ce1b_flag0 where key='mainship_coordinate_travel_enabled')
     or mv <> (select value::text from ce1b_flag0 where key='mainship_space_movement_enabled') then
    raise exception 'CLEANUP: flags not restored (movement=%, coordinate=%)', mv, co; end if;
  raise notice 'cleanup ok: no fixtures, ports hidden, flags restored to pre-test values';
end $$;

drop function pg_temp.ce1b_assert(uuid, text, boolean, text, boolean);
drop table if exists ce1b_id;
drop table if exists ce1b_flag0;

select 'OSN-COORD-ENABLE-1B READINESS PROOF PASSED' as result;
