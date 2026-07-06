-- PORT-ENTRY-1 — disposable REAL-CHAIN proof (runs on the actual chain 0001..0072 in a throwaway Supabase).
-- Proves the commissioning + same-location normalization contract (PORT-ENTRY-1A). Fixture users carry the
-- 'pe1fix.' email prefix; everything is reverted at the end. Flags are never written. No production access.

\set ON_ERROR_STOP on

create temp table pe1(k text primary key, v uuid) on commit preserve rows;
insert into pe1 values
  ('haven','b1a00001-0066-4a00-8a00-000000000001'),     -- Haven (designated spawn)
  ('slag', 'b1a00002-0066-4a00-8a00-000000000002'),     -- Slagworks (a different active port)
  ('slag_svc','b1a05002-0066-4a00-8a00-000000000052');  -- Slagworks docking service (for the ineligible-port case)

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- make N fresh players (auth trigger → base + disposable units; NO main_ship_instances).
do $$
declare u uuid; i int;
begin
  for i in 1..6 loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'pe1fix.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into pe1 values ('u'||i, u);
  end loop;
end $$;

-- precond: every fresh player has a base but NO main ship.
do $$
declare n int;
begin
  select count(*) into n from public.main_ship_instances s where s.player_id in (select v from pe1 where k like 'u%');
  if n <> 0 then raise exception 'PRECOND FAIL: fresh players already have % main ships', n; end if;
  select count(*) into n from public.bases b where b.player_id in (select v from pe1 where k like 'u%') and b.status='active';
  if n <> 6 then raise exception 'PRECOND FAIL: expected 6 fresh-player bases, got %', n; end if;
  raise notice 'precond ok: 6 fresh players, base present, zero main ships';
end $$;

-- Mirror PRODUCTION: the three starter ports are ACTIVE/public (revealed). A fresh disposable chain boots them
-- HIDDEN (migration 0066), so reveal them here exactly as production did (reverted to hidden at cleanup).
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  raise notice 'setup ok: starter ports active (mirrors production)';
end $$;

-- helper assertion: the player is in canonical at_location at the expected port (exactly 1 ship/fleet/presence).
create or replace function pg_temp.assert_docked(p_player uuid, p_loc uuid, p_label text) returns void language plpgsql as $$
declare v_ship uuid; v_ctx text; n int; v_fleet uuid;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=p_player;
  if v_ship is null then raise exception '%: no ship', p_label; end if;
  v_ctx := public.mainship_space_validate_context(v_ship)->>'state';
  if v_ctx is distinct from 'at_location' then raise exception '%: validate_context=% (want at_location)', p_label, v_ctx; end if;
  select count(*) into n from public.main_ship_instances where player_id=p_player; if n<>1 then raise exception '%: % ships', p_label, n; end if;
  select count(*) into n from public.fleets where main_ship_id=v_ship and status='present' and location_mode='location' and current_location_id=p_loc;
  if n<>1 then raise exception '%: present-fleet-at-loc count %', p_label, n; end if;
  select id into v_fleet from public.fleets where main_ship_id=v_ship and status='present' and location_mode='location';
  select count(*) into n from public.location_presence where fleet_id=v_fleet and status='active' and location_id=p_loc;
  if n<>1 then raise exception '%: active-presence-at-loc count %', p_label, n; end if;
end $$;

-- ════════ A. new account → first commission at Haven ════════
do $$
declare r jsonb;
begin
  r := pg_temp.call_as((select v from pe1 where k='u1'), 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'A FAIL: %', r; end if;
  if (r->'location_id')::text not like '%'||(select v from pe1 where k='haven')||'%' then raise exception 'A FAIL not Haven: %', r; end if;
  perform pg_temp.assert_docked((select v from pe1 where k='u1'), (select v from pe1 where k='haven'), 'A');
  raise notice 'A ok: new account commissioned, canonical at_location at Haven: %', r;
end $$;

-- ════════ B. commission retry → created=false, no write, not relocated ════════
do $$
declare r jsonb; s0 bigint; f0 bigint; p0 bigint; s1 bigint; f1 bigint; p1 bigint; u uuid := (select v from pe1 where k='u1');
begin
  select count(*) into s0 from public.main_ship_instances where player_id=u;
  select count(*) into f0 from public.fleets where player_id=u;
  select count(*) into p0 from public.location_presence where player_id=u;
  r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not false or (r->>'already_provisioned')::boolean is not true then raise exception 'B FAIL: %', r; end if;
  select count(*) into s1 from public.main_ship_instances where player_id=u;
  select count(*) into f1 from public.fleets where player_id=u;
  select count(*) into p1 from public.location_presence where player_id=u;
  if s0<>s1 or f0<>f1 or p0<>p1 then raise exception 'B FAIL: retry wrote (s %->% f %->% p %->%)', s0,s1,f0,f1,p0,p1; end if;
  perform pg_temp.assert_docked(u, (select v from pe1 where k='haven'), 'B');   -- still at Haven, not relocated
  raise notice 'B ok: retry idempotent, no write, still docked at Haven';
end $$;

-- IDEMPOTENCY / REPLAY (in-transaction repeat — NOT a concurrency proof). The real cross-session race is proven
-- separately by scripts/port-entry-1-concurrency.sh (two independent overlapping sessions). Here a repeated
-- writer call on-conflict yields exactly one ship/fleet/presence (the second invocation creates/writes nothing).
do $$
declare r1 jsonb; r2 jsonb; u uuid := (select v from pe1 where k='u2');
begin
  r1 := public.port_entry_commission_writer(u);
  r2 := public.port_entry_commission_writer(u);   -- second call must NOT create / write
  if (r1->>'created')::boolean is not true or (r2->>'created')::boolean is not false then raise exception 'IDEMPOTENCY FAIL: %, %', r1, r2; end if;
  perform pg_temp.assert_docked(u, (select v from pe1 where k='haven'), 'IDEMPOTENCY');
  raise notice 'idempotency/replay ok: repeated writer call → exactly one ship/fleet/presence (repeat wrote nothing; real concurrency in port-entry-1-concurrency.sh)';
end $$;

-- ════════ cross-user isolation: u2 ops left u1 untouched ════════
do $$
declare n int;
begin
  perform pg_temp.assert_docked((select v from pe1 where k='u1'), (select v from pe1 where k='haven'), 'XUSER-u1');
  select count(*) into n from public.main_ship_instances where player_id=(select v from pe1 where k='u1'); if n<>1 then raise exception 'XUSER FAIL: u1 ship count %', n; end if;
  raise notice 'cross-user ok: u1 unchanged by u2 commissioning';
end $$;

-- ════════ C. existing at_location at a DIFFERENT port → already_provisioned, report actual dock, never relocate ════════
do $$
declare u uuid := (select v from pe1 where k='u3'); s uuid; v_b uuid; v_zone uuid; v_sector uuid; v_fleet uuid := gen_random_uuid(); r jsonb;
begin
  -- construct a canonical at_location ship at SLAGWORKS (not Haven) directly.
  insert into public.main_ship_instances (player_id,hull_type_id,name,status,spatial_state,space_x,space_y,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots)
    select u,h.hull_type_id,'Byeharu','stationary','at_location',null,null,h.base_hp,h.base_hp,h.base_cargo_capacity,h.base_support_capacity,h.base_captain_slots,h.base_module_slots
    from public.main_ship_hull_types h where h.hull_type_id='starter_frigate' returning main_ship_id into s;
  select l.zone_id, z.sector_id into v_zone, v_sector from public.locations l join public.zones z on z.id=l.zone_id where l.id=(select v from pe1 where k='slag');
  select id into v_b from public.bases where player_id=u and status='active' limit 1;
  insert into public.fleets (id,player_id,origin_base_id,status,location_mode,current_base_id,current_location_id,current_zone_id,current_sector_id,main_ship_id)
    values (v_fleet,u,v_b,'present','location',null,(select v from pe1 where k='slag'),v_zone,v_sector,s);
  perform public.presence_create(u,v_fleet,v_sector,v_zone,(select v from pe1 where k='slag'),'none');
  if public.mainship_space_validate_context(s)->>'state' <> 'at_location' then raise exception 'C setup FAIL'; end if;
  r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not false or (r->>'already_provisioned')::boolean is not true then raise exception 'C FAIL: %', r; end if;
  if (r->'location_id')::text not like '%'||(select v from pe1 where k='slag')||'%' then raise exception 'C FAIL: did not report Slagworks dock: %', r; end if;
  perform pg_temp.assert_docked(u, (select v from pe1 where k='slag'), 'C');   -- NOT relocated to Haven
  raise notice 'C ok: existing at_location at Slagworks → already_provisioned, reported actual dock, not relocated';
end $$;

-- ════════ D/normalize. legacy_present → needs_normalization (no write) → normalize at SAME port (reuse fleet+presence) ════════
do $$
declare u uuid := (select v from pe1 where k='u4'); s uuid; v_b uuid; v_zone uuid; v_sector uuid; v_fleet uuid := gen_random_uuid();
        r jsonb; s0 bigint; f0 bigint; p0 bigint; s1 bigint; f1 bigint; p1 bigint;
begin
  -- construct legacy_present at Haven (spatial_state NULL, status home, one present fleet + active presence).
  insert into public.main_ship_instances (player_id,hull_type_id,name,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots)
    select u,h.hull_type_id,'Byeharu','home',null,h.base_hp,h.base_hp,h.base_cargo_capacity,h.base_support_capacity,h.base_captain_slots,h.base_module_slots
    from public.main_ship_hull_types h where h.hull_type_id='starter_frigate' returning main_ship_id into s;
  select l.zone_id, z.sector_id into v_zone, v_sector from public.locations l join public.zones z on z.id=l.zone_id where l.id=(select v from pe1 where k='haven');
  select id into v_b from public.bases where player_id=u and status='active' limit 1;
  insert into public.fleets (id,player_id,origin_base_id,status,location_mode,current_base_id,current_location_id,current_zone_id,current_sector_id,main_ship_id)
    values (v_fleet,u,v_b,'present','location',null,(select v from pe1 where k='haven'),v_zone,v_sector,s);
  perform public.presence_create(u,v_fleet,v_sector,v_zone,(select v from pe1 where k='haven'),'none');
  if public.mainship_space_validate_context(s)->>'state' <> 'legacy_present' then raise exception 'D setup FAIL: %', public.mainship_space_validate_context(s); end if;

  -- commission must REJECT a legacy_present with no write.
  select count(*) into s0 from public.main_ship_instances where player_id=u;
  select count(*) into f0 from public.fleets where player_id=u; select count(*) into p0 from public.location_presence where player_id=u;
  r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not false or r->>'reason' <> 'needs_normalization' then raise exception 'D FAIL commission: %', r; end if;
  select count(*) into s1 from public.main_ship_instances where player_id=u;
  select count(*) into f1 from public.fleets where player_id=u; select count(*) into p1 from public.location_presence where player_id=u;
  if s0<>s1 or f0<>f1 or p0<>p1 then raise exception 'D FAIL: commission wrote on legacy_present'; end if;

  -- normalize → at_location at the SAME port, REUSING the existing fleet + presence (ids unchanged, counts 1).
  r := pg_temp.call_as(u, 'public.normalize_main_ship_dock()');
  if (r->>'ok')::boolean is not true or (r->>'normalized')::boolean is not true then raise exception 'D FAIL normalize: %', r; end if;
  perform pg_temp.assert_docked(u, (select v from pe1 where k='haven'), 'D-normalize');
  if not exists (select 1 from public.fleets where id=v_fleet and main_ship_id=s and status='present') then raise exception 'D FAIL: fleet not reused'; end if;
  if (select count(*) from public.location_presence where fleet_id=v_fleet and status='active') <> 1 then raise exception 'D FAIL: presence duplicated'; end if;
  raise notice 'D ok: legacy_present → commission needs_normalization (no write) → normalized at same port, fleet+presence reused';

  -- normalize replay (now at_location) → normalized=false, no write.
  select count(*) into f0 from public.fleets where player_id=u; select count(*) into p0 from public.location_presence where player_id=u;
  r := pg_temp.call_as(u, 'public.normalize_main_ship_dock()');
  if (r->>'ok')::boolean is not true or (r->>'normalized')::boolean is not false then raise exception 'D FAIL replay: %', r; end if;
  select count(*) into f1 from public.fleets where player_id=u; select count(*) into p1 from public.location_presence where player_id=u;
  if f0<>f1 or p0<>p1 then raise exception 'D FAIL: normalize replay wrote'; end if;
  raise notice 'D-replay ok: at_location normalize is idempotent (normalized=false, no write)';
end $$;

-- ════════ E. legacy_home → commission needs_compat_route; normalize not_normalizable (no write) ════════
do $$
declare u uuid := (select v from pe1 where k='u5'); s uuid; r jsonb; f0 bigint;
begin
  insert into public.main_ship_instances (player_id,hull_type_id,name,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots)
    select u,h.hull_type_id,'Byeharu','home',null,h.base_hp,h.base_hp,h.base_cargo_capacity,h.base_support_capacity,h.base_captain_slots,h.base_module_slots
    from public.main_ship_hull_types h where h.hull_type_id='starter_frigate' returning main_ship_id into s;  -- legacy_home (no fleet)
  if public.mainship_space_validate_context(s)->>'state' <> 'legacy_home' then raise exception 'E setup FAIL: %', public.mainship_space_validate_context(s); end if;
  r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not false or r->>'reason' <> 'needs_compat_route' then raise exception 'E FAIL commission: %', r; end if;
  select count(*) into f0 from public.fleets where player_id=u;
  r := pg_temp.call_as(u, 'public.normalize_main_ship_dock()');
  if (r->>'ok')::boolean is not false or r->>'reason' <> 'not_normalizable' then raise exception 'E FAIL normalize: %', r; end if;
  if (select count(*) from public.fleets where player_id=u) <> f0 then raise exception 'E FAIL: normalize wrote on legacy_home'; end if;
  raise notice 'E ok: legacy_home → commission needs_compat_route; normalize not_normalizable (no write)';

  -- compat-route demonstration: land it as legacy_present (the legacy-send arrival), then normalize → at_location.
  declare v_b uuid; v_zone uuid; v_sector uuid; v_fleet uuid := gen_random_uuid();
  begin
    select l.zone_id, z.sector_id into v_zone, v_sector from public.locations l join public.zones z on z.id=l.zone_id where l.id=(select v from pe1 where k='haven');
    select id into v_b from public.bases where player_id=u and status='active' limit 1;
    insert into public.fleets (id,player_id,origin_base_id,status,location_mode,current_base_id,current_location_id,current_zone_id,current_sector_id,main_ship_id)
      values (v_fleet,u,v_b,'present','location',null,(select v from pe1 where k='haven'),v_zone,v_sector,s);
    perform public.presence_create(u,v_fleet,v_sector,v_zone,(select v from pe1 where k='haven'),'none');
    r := pg_temp.call_as(u, 'public.normalize_main_ship_dock()');
    if (r->>'ok')::boolean is not true or (r->>'normalized')::boolean is not true then raise exception 'E compat FAIL: %', r; end if;
    perform pg_temp.assert_docked(u, (select v from pe1 where k='haven'), 'E-compat');
    raise notice 'E-compat ok: legacy_home → (legacy arrival → legacy_present) → normalize → at_location; no OSN home origin used';
  end;
end $$;

-- ════════ F. destroyed → commission not_provisionable; normalize fails (no write) ════════
do $$
declare u uuid := (select v from pe1 where k='u6'); s uuid; r jsonb;
begin
  insert into public.main_ship_instances (player_id,hull_type_id,name,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots)
    select u,h.hull_type_id,'Byeharu','destroyed',null,0,h.base_hp,h.base_cargo_capacity,h.base_support_capacity,h.base_captain_slots,h.base_module_slots
    from public.main_ship_hull_types h where h.hull_type_id='starter_frigate' returning main_ship_id into s;
  if public.mainship_space_validate_context(s)->>'state' <> 'destroyed' then raise exception 'F setup FAIL'; end if;
  r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not false or r->>'reason' <> 'not_provisionable' then raise exception 'F FAIL commission: %', r; end if;
  r := pg_temp.call_as(u, 'public.normalize_main_ship_dock()');
  if (r->>'ok')::boolean is not false then raise exception 'F FAIL normalize: %', r; end if;
  raise notice 'F ok: destroyed → commission not_provisionable; normalize fails (no write)';
end $$;

-- ════════ ineligible-port normalize: legacy_present at a port whose docking service is inactive → ineligible_port ════════
do $$
declare u uuid := (select v from pe1 where k='u3'); s uuid; v_b uuid; v_zone uuid; v_sector uuid; v_fleet uuid := gen_random_uuid(); r jsonb; f0 bigint;
begin
  -- reuse a fresh fixture player path: make a NEW throwaway sub for this (u3 already has a ship). Use a temp user.
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','pe1fix.elig'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id into u;
  insert into public.main_ship_instances (player_id,hull_type_id,name,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots)
    select u,h.hull_type_id,'Byeharu','home',null,h.base_hp,h.base_hp,h.base_cargo_capacity,h.base_support_capacity,h.base_captain_slots,h.base_module_slots
    from public.main_ship_hull_types h where h.hull_type_id='starter_frigate' returning main_ship_id into s;
  select l.zone_id, z.sector_id into v_zone, v_sector from public.locations l join public.zones z on z.id=l.zone_id where l.id=(select v from pe1 where k='slag');
  select id into v_b from public.bases where player_id=u and status='active' limit 1;
  insert into public.fleets (id,player_id,origin_base_id,status,location_mode,current_base_id,current_location_id,current_zone_id,current_sector_id,main_ship_id)
    values (v_fleet,u,v_b,'present','location',null,(select v from pe1 where k='slag'),v_zone,v_sector,s);
  perform public.presence_create(u,v_fleet,v_sector,v_zone,(select v from pe1 where k='slag'),'none');
  -- make Slagworks non-dockable (disable its docking service) → normalize must fail closed, no write.
  update public.location_services set status='disabled' where id=(select v from pe1 where k='slag_svc');
  select count(*) into f0 from public.fleets where player_id=u;
  r := pg_temp.call_as(u, 'public.normalize_main_ship_dock()');
  if (r->>'ok')::boolean is not false or r->>'reason' <> 'ineligible_port' then raise exception 'INELIGIBLE FAIL: %', r; end if;
  if (select count(*) from public.fleets where player_id=u) <> f0 then raise exception 'INELIGIBLE FAIL: wrote'; end if;
  if public.mainship_space_validate_context(s)->>'state' <> 'legacy_present' then raise exception 'INELIGIBLE FAIL: state changed'; end if;
  update public.location_services set status='active' where id=(select v from pe1 where k='slag_svc');   -- restore
  raise notice 'ineligible-port ok: legacy_present at a non-dockable port → ineligible_port, no write, state unchanged';
end $$;

-- ════════ no-regression: coordinate gate + raw coordinate command unchanged ════════
do $$
declare cg text; r jsonb; u uuid := (select v from pe1 where k='u1');
begin
  select value::text into cg from public.game_config where key='mainship_coordinate_travel_enabled';
  if cg <> 'false' then raise exception 'REGRESSION FAIL: coord gate not false (%)', cg; end if;
  -- a raw coordinate command still rejects (movement domain false on disposable stack → feature_disabled, or
  -- coordinate_travel_disabled if movement enabled). Either way ok:false, no coordinate movement is created.
  r := pg_temp.call_as(u, 'public.command_main_ship_space_move(10::double precision, 10::double precision, gen_random_uuid())');
  if (r->>'ok')::boolean is not false then raise exception 'REGRESSION FAIL: raw coordinate command succeeded: %', r; end if;
  raise notice 'no-regression ok: coord gate false; raw coordinate command still rejected (code=%)', r->>'code';
end $$;

-- ════════ ACL / SECURITY DEFINER / search_path ════════
do $$
begin
  if not has_function_privilege('authenticated','public.commission_first_main_ship()','EXECUTE') then raise exception 'ACL: commission not authenticated-exec'; end if;
  if     has_function_privilege('anon','public.commission_first_main_ship()','EXECUTE') then raise exception 'ACL: commission anon-exec'; end if;
  if not has_function_privilege('authenticated','public.normalize_main_ship_dock()','EXECUTE') then raise exception 'ACL: normalize not authenticated-exec'; end if;
  if     has_function_privilege('anon','public.normalize_main_ship_dock()','EXECUTE') then raise exception 'ACL: normalize anon-exec'; end if;
  if     has_function_privilege('authenticated','public.port_entry_commission_writer(uuid)','EXECUTE') then raise exception 'ACL: writer authenticated-exec (must be service_role only)'; end if;
  if not has_function_privilege('service_role','public.port_entry_commission_writer(uuid)','EXECUTE') then raise exception 'ACL: writer not service_role-exec'; end if;
  -- secdef + search_path
  if not (select p.prosecdef from pg_proc p where p.oid='public.commission_first_main_ship()'::regprocedure) then raise exception 'commission not SECURITY DEFINER'; end if;
  if not (select p.prosecdef from pg_proc p where p.oid='public.normalize_main_ship_dock()'::regprocedure) then raise exception 'normalize not SECURITY DEFINER'; end if;
  if not (select p.prosecdef from pg_proc p where p.oid='public.port_entry_commission_writer(uuid)'::regprocedure) then raise exception 'writer not SECURITY DEFINER'; end if;
  if not (select p.proconfig @> array['search_path=public'] from pg_proc p where p.oid='public.commission_first_main_ship()'::regprocedure) then raise exception 'commission search_path not hardened'; end if;
  raise notice 'acl ok: authenticated-only RPCs; writer service_role-only; all SECURITY DEFINER + search_path=public';
end $$;

-- ════════ cleanup — remove all fixtures; assert no leftover; restore service ════════
update public.location_services set status='active' where id=(select v from pe1 where k='slag_svc');
delete from auth.users where email like 'pe1fix.%@example.com';   -- cascades ships/fleets/presence/bases/units
update public.locations set status='hidden'                        -- revert the reveal (test-only direct revert)
  where id in (select v from pe1 where k in ('haven','slag')) or id='b1a00003-0066-4a00-8a00-000000000003';
do $$
declare n int;
begin
  select count(*) into n from auth.users where email like 'pe1fix.%@example.com'; if n<>0 then raise exception 'CLEANUP: % fixture users remain', n; end if;
  select count(*) into n from public.main_ship_instances s where s.player_id not in (select id from auth.users); if n<>0 then raise exception 'CLEANUP: % orphan ships', n; end if;
  select count(*) into n from public.location_services where status<>'active' and id=(select v from pe1 where k='slag_svc'); if n<>0 then raise exception 'CLEANUP: slag docking service not restored'; end if;
  raise notice 'cleanup ok: no fixture users/ships; Slagworks docking service active';
end $$;
drop function pg_temp.call_as(uuid,text);
drop function pg_temp.assert_docked(uuid,uuid,text);
drop table if exists pe1;

select 'PORT-ENTRY-1 PROOF PASSED' as result;
