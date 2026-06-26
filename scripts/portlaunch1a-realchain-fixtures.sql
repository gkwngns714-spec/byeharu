-- PORT-LAUNCH-1A — REAL-CHAIN functional fixture matrix on the ACTUAL chain (through 0068). Disposable only.
-- Proves reveal_starter_ports atomicity/idempotency/fail-closed rejection and get_osn_movement_readiness
-- categories + no-leak, then REVERTS the world to fully hidden (no net world/player change; no fixtures left).
-- Fixture users carry the 'pl1afix.' email prefix. Flags are NEVER written here; the dark flag stays false.

\set ON_ERROR_STOP on

-- Fixed 0066 identities.
create temp table pl1a_id(k text primary key, id uuid) on commit preserve rows;
insert into pl1a_id values
  ('p1','b1a00001-0066-4a00-8a00-000000000001'),
  ('p2','b1a00002-0066-4a00-8a00-000000000002'),
  ('p3','b1a00003-0066-4a00-8a00-000000000003'),
  ('a1','b1a0a001-0066-4a00-8a00-0000000000a1');

-- ── precondition: the three starter ports are HIDDEN on a fresh chain ──────────────────────────────────────
do $$
declare n int;
begin
  select count(*) into n from public.locations
    where id in ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003')
      and status = 'hidden';
  if n <> 3 then raise exception 'PRECOND FAIL: expected 3 hidden starter ports, got %', n; end if;
  raise notice 'precond ok: 3 starter ports hidden';
end $$;

-- snapshot the ORIGINAL (non-port) locations to prove reveal never touches them
create temp table pl1a_orig as
  select id, status from public.locations
  where id not in ('b1a00001-0066-4a00-8a00-000000000001','b1a00002-0066-4a00-8a00-000000000002','b1a00003-0066-4a00-8a00-000000000003');

-- ── fixture players (HOME ship auto-provisioned by the auth trigger; ship via ensure_main_ship_for_player) ──
do $$
declare u uuid; i int; v_ship uuid;
begin
  for i in 1..4 loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'pl1afix.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    perform public.ensure_main_ship_for_player(u);
    select main_ship_id into v_ship from public.main_ship_instances where player_id = u;
    insert into pl1a_id values ('u'||i, u), ('s'||i, v_ship);
  end loop;
  -- u1 stays HOME (legacy_home). Normalize to a clean home.
  update public.main_ship_instances set status='home', spatial_state=null, space_x=null, space_y=null
    where main_ship_id = (select id from pl1a_id where k='s1');
end $$;

-- u2: coherent legacy_present at port p1 (spatial_state NULL + one fleet present + active presence at p1).
do $$
declare u uuid := (select id from pl1a_id where k='u2');
        s uuid := (select id from pl1a_id where k='s2');
        p uuid := (select id from pl1a_id where k='p1');
        v_b uuid; v_zone uuid; v_sector uuid; v_fleet uuid := gen_random_uuid();
begin
  select l.zone_id, z.sector_id into v_zone, v_sector from public.locations l join public.zones z on z.id=l.zone_id where l.id=p;
  select id into v_b from public.bases where player_id=u and status='active' order by created_at limit 1;
  -- legacy_present = spatial_state NULL + one PRESENT fleet + active presence; ship status stays a legacy
  -- value ('stationary' is reserved for the new in_space/at_location domain by a CHECK constraint).
  update public.main_ship_instances set status='home', spatial_state=null, space_x=null, space_y=null where main_ship_id=s;
  insert into public.fleets (id,player_id,origin_base_id,status,location_mode,current_base_id,current_location_id,current_zone_id,current_sector_id,main_ship_id)
    values (v_fleet,u,v_b,'present','location',null,p,v_zone,v_sector,s);
  insert into public.location_presence (player_id,fleet_id,sector_id,zone_id,location_id,activity_type,status,last_tick_at)
    values (u,v_fleet,v_sector,v_zone,p,'none','active',now());
  insert into pl1a_id values ('f2', v_fleet);
end $$;

-- u3: canonical destroyed state via the existing trusted primitive.
do $$ begin perform public.dev_set_main_ship_destroyed((select id from pl1a_id where k='u3')); end $$;

-- u4: coherent space coordinate transit (in_transit).
do $$
declare u uuid := (select id from pl1a_id where k='u4');
        s uuid := (select id from pl1a_id where k='s4');
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

-- ════════ readiness WHILE PORTS HIDDEN (no hidden-port id may ever leak) ════════
-- helper assertion blocks set request.jwt.claims (so auth.uid() resolves the fixture player) then call the RPC.
do $$
declare v jsonb;
begin
  -- no_ship: a sub with no main ship
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text)::text, true);
  v := public.get_osn_movement_readiness();
  if v->>'origin_category' <> 'no_ship' or (v->>'osn_available')::boolean <> false or v->>'reason' <> 'no_ship'
     or jsonb_array_length(v->'eligible_destination_ids') <> 0 then raise exception 'no_ship FAIL: %', v; end if;
  raise notice 'no_ship ok: %', v;
end $$;

do $$
declare v jsonb;
begin
  -- u1 HOME → not_anchored / travel_to_port; osn_available false; NO destinations
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from pl1a_id where k='u1')::text)::text, true);
  v := public.get_osn_movement_readiness();
  if v->>'origin_category' <> 'not_anchored' or (v->>'osn_available')::boolean <> false or v->>'reason' <> 'travel_to_port'
     or jsonb_array_length(v->'eligible_destination_ids') <> 0 then raise exception 'home FAIL: %', v; end if;
  raise notice 'home ok: %', v;
end $$;

do $$
declare v jsonb;
begin
  -- u2 docked at HIDDEN port p1 → anchored (anchor active), but NO destination ids (other ports hidden → none eligible)
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from pl1a_id where k='u2')::text)::text, true);
  v := public.get_osn_movement_readiness();
  if v->>'origin_category' <> 'anchored' or (v->>'osn_available')::boolean <> false or v->>'reason' <> 'feature_disabled'
     or jsonb_array_length(v->'eligible_destination_ids') <> 0 then raise exception 'hidden-dock leak FAIL (must expose NO hidden port): %', v; end if;
  raise notice 'hidden-dock no-leak ok: %', v;
end $$;

do $$
declare v jsonb;
begin
  -- u3 destroyed
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from pl1a_id where k='u3')::text)::text, true);
  v := public.get_osn_movement_readiness();
  if v->>'origin_category' <> 'destroyed' or (v->>'osn_available')::boolean <> false or v->>'reason' <> 'destroyed'
     or jsonb_array_length(v->'eligible_destination_ids') <> 0 then raise exception 'destroyed FAIL: %', v; end if;
  raise notice 'destroyed ok: %', v;
end $$;

do $$
declare v jsonb;
begin
  -- u4 in coordinate transit
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from pl1a_id where k='u4')::text)::text, true);
  v := public.get_osn_movement_readiness();
  if v->>'origin_category' <> 'in_transit' or (v->>'osn_available')::boolean <> false or v->>'reason' <> 'in_transit'
     or jsonb_array_length(v->'eligible_destination_ids') <> 0 then raise exception 'in_transit FAIL: %', v; end if;
  raise notice 'in_transit ok: %', v;
end $$;

-- ════════ reveal_starter_ports — atomicity / idempotency / fail-closed rejection ════════
-- R1: coherent hidden set → reveal exactly the 3 ports; originals untouched.
do $$
declare r jsonb; n int;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true or (r->>'revealed')::int <> 3 or (r->>'already_active')::boolean <> false then raise exception 'R1 FAIL: %', r; end if;
  select count(*) into n from public.locations where id in (select id from pl1a_id where k in ('p1','p2','p3')) and status='active';
  if n <> 3 then raise exception 'R1 FAIL: ports active count %', n; end if;
  if exists (select 1 from public.locations l join pl1a_orig o on o.id=l.id where l.status is distinct from o.status) then
    raise exception 'R1 FAIL: an original location status changed'; end if;
  raise notice 'R1 ok: 3 ports revealed; originals unchanged';
end $$;

-- R2: idempotent on a coherent all-active set → no-op success.
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true or (r->>'revealed')::int <> 0 or (r->>'already_active')::boolean <> true then raise exception 'R2 FAIL: %', r; end if;
  raise notice 'R2 ok: idempotent no-op when already active';
end $$;

-- R3: mixed state → abort with NO write.
do $$
declare ok boolean := false;
begin
  update public.locations set status='hidden' where id=(select id from pl1a_id where k='p1');  -- p1 hidden, p2/p3 active = mixed
  begin perform public.reveal_starter_ports(); exception when others then ok := true; end;
  if not ok then raise exception 'R3 FAIL: mixed state did not abort'; end if;
  if (select status from public.locations where id=(select id from pl1a_id where k='p1')) <> 'hidden' then raise exception 'R3 FAIL: p1 mutated on a rejected reveal'; end if;
  if (select count(*) from public.locations where id in (select id from pl1a_id where k in ('p2','p3')) and status='active') <> 2 then raise exception 'R3 FAIL: p2/p3 changed on a rejected reveal'; end if;
  raise notice 'R3 ok: mixed state rejected, no write';
  -- restore to a coherent ALL-HIDDEN set for the invariant test
  update public.locations set status='hidden' where id in (select id from pl1a_id where k in ('p2','p3'));
end $$;

-- R4: broken invariant (anchor de-activated) on a coherent hidden set → abort with NO status write.
do $$
declare ok boolean := false;
begin
  update public.space_anchors set status='retired' where id=(select id from pl1a_id where k='a1');  -- break p1's anchor
  begin perform public.reveal_starter_ports(); exception when others then ok := true; end;
  if not ok then raise exception 'R4 FAIL: broken-anchor invariant did not abort'; end if;
  if (select count(*) from public.locations where id in (select id from pl1a_id where k in ('p1','p2','p3')) and status='hidden') <> 3 then
    raise exception 'R4 FAIL: a port status changed despite the invariant abort'; end if;
  raise notice 'R4 ok: broken-anchor invariant rejected, no status write';
  update public.space_anchors set status='active' where id=(select id from pl1a_id where k='a1');  -- restore
end $$;

-- ════════ readiness with ports REVEALED — anchored origin yields the OTHER ports as destinations ════════
do $$
declare r jsonb; v jsonb; p1 uuid; p2 uuid; p3 uuid; dests jsonb;
begin
  r := public.reveal_starter_ports();  -- now coherent-hidden → reveal all 3
  if (r->>'revealed')::int <> 3 then raise exception 'A-setup FAIL: re-reveal %', r; end if;
  p1 := (select id from pl1a_id where k='p1'); p2 := (select id from pl1a_id where k='p2'); p3 := (select id from pl1a_id where k='p3');
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from pl1a_id where k='u2')::text)::text, true);
  v := public.get_osn_movement_readiness();
  if v->>'origin_category' <> 'anchored' or (v->>'osn_available')::boolean <> false or v->>'reason' <> 'feature_disabled' then raise exception 'A-anchored FAIL: %', v; end if;
  dests := v->'eligible_destination_ids';
  -- exactly the two OTHER revealed ports (p1 excluded = current dock); no originals, no p1
  if jsonb_array_length(dests) <> 2 or not (dests @> to_jsonb(p2) and dests @> to_jsonb(p3)) or (dests @> to_jsonb(p1)) then
    raise exception 'A-anchored FAIL: destinations not exactly {p2,p3}: %', v; end if;
  raise notice 'A-anchored ok (flag still false → osn_available=false): %', v;
end $$;

-- ════════ cleanup — REVERT the world to fully hidden + remove all fixtures (no net change) ════════
delete from auth.users where email like 'pl1afix.%@example.com';   -- cascades ships/fleets/presence/movements/bases
update public.locations set status='hidden'                        -- one-way reveal has no unreveal fn; direct test-only revert
  where id in (select id from pl1a_id where k in ('p1','p2','p3'));
do $$
declare n int;
begin
  select count(*) into n from auth.users where email like 'pl1afix.%@example.com';
  if n <> 0 then raise exception 'CLEANUP: % fixture users remain', n; end if;
  select count(*) into n from public.locations where id in (select id from pl1a_id where k in ('p1','p2','p3')) and status <> 'hidden';
  if n <> 0 then raise exception 'CLEANUP: % ports not reverted to hidden', n; end if;
  if exists (select 1 from public.locations l join pl1a_orig o on o.id = l.id where l.status is distinct from o.status) then
    raise exception 'CLEANUP: an original location status changed'; end if;
  select count(*) into n from public.main_ship_instances s where s.player_id not in (select id from auth.users);
  if n <> 0 then raise exception 'CLEANUP: % orphan main ships remain', n; end if;
  select count(*) into n from public.space_anchors where status <> 'active';
  if n <> 0 then raise exception 'CLEANUP: % anchor(s) not active (fixture leaked anchor state)', n; end if;
  raise notice 'cleanup ok: 3 ports hidden again, originals unchanged, no fixture users/ships, anchors active';
end $$;
drop table if exists pl1a_id;
drop table if exists pl1a_orig;

select 'PORT-LAUNCH-1A FIXTURE MATRIX PASSED' as result;
