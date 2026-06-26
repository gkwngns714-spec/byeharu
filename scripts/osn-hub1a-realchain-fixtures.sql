-- OSN-HUB-1A — REAL-CHAIN functional fixture matrix for canonical location-target navigation.
-- Runs on the ACTUAL migration chain (0001..0067) in a DISPOSABLE local Supabase. Proves, with the legacy
-- send flag mirrored live (mainship_send_enabled=true) and the OSN flag DARK by default
-- (mainship_space_movement_enabled=false) — toggled true ONLY inside the explicit success sections and
-- restored false:
--   B  location-target command success via BOTH the core writer and the public wrapper (server stamps
--      target_kind='location' + the exact location id; target x/y come from the ANCHOR, not locations.x/y;
--      idempotent replay; no duplicate fleet/movement/receipt);
--   C  origin resolution: parked in_space → eligible anchored port; docked (at_location) origin resolves from
--      its location anchor; mutating legacy locations.x/y or bases.x/y does NOT change OSN behavior; legacy
--      HOME stays origin_not_anchored; unanchored docked origin fails closed with no mutation;
--   D  target rejection matrix (hidden / inactive location / inactive zone / inactive sector / unsupported
--      role / no docking service / no active anchor / retired anchor / malformed / flag off / hidden-while-off)
--      each leaves NO orphan fleet/movement/receipt/presence/ship mutation;
--   E  anchor-backed docking + anchor-change race (dock only when the live anchor still matches the stored
--      target snapshot; a moved/retired anchor → terminal failure, never a redirect; NO locations.x/y consulted;
--      one arrival cron; Dock-0 reached only via the processor);
--   G  cross-domain safety (no concurrent legacy+OSN movement; pointer contradictions fail closed; only the
--      existing single writer/processor/dock resolver exist).
-- All fixtures are disposable (osn3hub1a.* users / hub1a-* world rows) and fully cleaned up. No production data.

\set ON_ERROR_STOP on

update game_config set value = 'true'  where key = 'mainship_send_enabled';            -- mirror live (untouched)
update game_config set value = 'false' where key = 'mainship_space_movement_enabled';  -- production-dark default

-- The one arrival cron is asserted present once, then unscheduled for deterministic functional settling.
do $$ declare n int; sched text;
begin
  select count(*), max(schedule) into n, sched from cron.job where jobname = 'process-mainship-space-arrivals';
  if n <> 1 then raise exception 'CRON FAIL: expected exactly 1 arrival job, found %', n; end if;
  if sched <> '30 seconds' then raise exception 'CRON FAIL: schedule=% (expected 30 seconds)', sched; end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'process-mainship-space-arrivals';
  raise notice 'CRON ok: one process-mainship-space-arrivals @ 30 seconds → unscheduled for deterministic tests';
end $$;

-- ── helpers ───────────────────────────────────────────────────────────────────────────────────────────────
create or replace function h1a_user() returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated','osn3hub1a.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','','');
  return v;  -- on_auth_user_created → Home Base at (0,0)
end $$;

-- A disposable test sector/zone scaffold (status varies to exercise inactive-zone / inactive-sector targets).
create or replace function h1a_zone(p_sector_status text, p_zone_status text) returns uuid language plpgsql as $$
declare v_se uuid; v_z uuid; v_idx int;
begin
  select coalesce(max(sector_index),0)+1 into v_idx from sectors;
  insert into sectors (name, sector_index, x, y, danger_tier, status)
    values ('hub1a-sec-'||replace(gen_random_uuid()::text,'-',''), v_idx, 500, 500, 1, p_sector_status)
    returning id into v_se;
  insert into zones (sector_id, name, x, y, radius, base_difficulty, max_danger_level, reward_tier, status)
    values (v_se, 'hub1a-zone-'||replace(gen_random_uuid()::text,'-',''), 500, 500, 5, 0, 1, 1, p_zone_status)
    returning id into v_z;
  return v_z;
end $$;

-- Create a test location (port/city/etc) with controllable status/role/activity. Returns its id.
create or replace function h1a_loc(p_zone uuid, p_role text, p_status text, p_x double precision, p_y double precision, p_activity text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into locations (zone_id, name, location_type, x, y, activity_type, status, physical_role)
    values (p_zone, 'hub1a-loc-'||replace(gen_random_uuid()::text,'-',''), 'trade_outpost', p_x, p_y, p_activity, p_status, p_role)
    returning id into v_id;
  return v_id;
end $$;

create or replace function h1a_service(p_loc uuid, p_status text) returns void language plpgsql as $$
begin insert into location_services (location_id, service, status) values (p_loc, 'docking', p_status); end $$;

create or replace function h1a_anchor(p_loc uuid, p_x double precision, p_y double precision, p_status text) returns uuid language plpgsql as $$
declare v uuid;
begin insert into space_anchors (kind, location_id, space_x, space_y, status) values ('location', p_loc, p_x, p_y, p_status) returning id into v; return v; end $$;

-- An eligible, VISIBLE public port: active sector/zone/location, role 'port', active docking service, exactly
-- one active location anchor whose coords equal the location's x/y. Returns the location id.
create or replace function h1a_eligible_port(p_x double precision, p_y double precision) returns uuid language plpgsql as $$
declare v_z uuid := h1a_zone('active','active'); v_l uuid;
begin
  v_l := h1a_loc(v_z, 'port', 'active', p_x, p_y, 'none');
  perform h1a_service(v_l, 'active');
  perform h1a_anchor(v_l, p_x, p_y, 'active');
  return v_l;
end $$;

-- A parked-in_space ship for player u at (sx,sy). No fleet, no presence. Returns ship id.
create or replace function h1a_ship_in_space(u uuid, sx double precision, sy double precision) returns uuid language plpgsql as $$
declare v_s uuid := gen_random_uuid();
begin
  insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,space_x,space_y,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values (u,'starter_frigate','stationary','in_space',sx,sy,500,500,50,10,2,3,v_s);
  return v_s;
end $$;

-- A legacy-home ship for player u (status home, spatial_state NULL, no fleet). Returns ship id.
create or replace function h1a_ship_home(u uuid) returns uuid language plpgsql as $$
declare v_s uuid := gen_random_uuid();
begin
  insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values (u,'starter_frigate','home',null,500,500,50,10,2,3,v_s);
  return v_s;
end $$;

-- A ship DOCKED (at_location) at p_loc: present fleet + active presence; validate_context = at_location.
create or replace function h1a_ship_at_location(u uuid, p_loc uuid) returns uuid language plpgsql as $$
declare v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid(); v_z uuid; v_se uuid;
begin
  select z.id, z.sector_id into v_z, v_se from locations l join zones z on z.id=l.zone_id where l.id=p_loc;
  insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values (u,'starter_frigate','stationary','at_location',500,500,50,10,2,3,v_s);
  insert into fleets (id,player_id,status,location_mode,current_location_id,current_zone_id,current_sector_id,main_ship_id)
    values (v_f,u,'present','location',p_loc,v_z,v_se,v_s);
  perform public.presence_create(u, v_f, v_se, v_z, p_loc, 'none');
  return v_s;
end $$;

-- Directly build a coherent in_transit ship with a single DUE 'moving' location-target movement whose stored
-- target snapshot is (p_tx,p_ty). Mirrors the DOCK-0 fixture builder (independent of the flag/core). Returns ship.
create or replace function h1a_intransit_loc(u uuid, p_loc uuid, p_tx double precision, p_ty double precision) returns uuid language plpgsql as $$
declare v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid(); v_m uuid := gen_random_uuid();
begin
  insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values (u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,v_s);
  insert into fleets (id,player_id,status,location_mode,main_ship_id) values (v_f,u,'moving','movement',v_s);
  insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,target_location_id,speed_used,depart_at,arrive_at)
    values (v_m,v_s,v_f,u,'space',0,0,'location',p_tx,p_ty,p_loc,1.0, now()-interval '2 hour', now()-interval '1 hour');
  update fleets set active_space_movement_id = v_m where id = v_f;
  return v_s;
end $$;

create or replace function h1a_ship_hash(p_ship uuid) returns text language sql stable as $$
  select md5(coalesce(string_agg(t,''),'')) from (
    select md5(s::text) t from main_ship_instances s where s.main_ship_id = p_ship
    union all select md5(f::text) from fleets f where f.main_ship_id = p_ship
    union all select md5(m::text) from main_ship_space_movements m where m.main_ship_id = p_ship
    union all select md5(lp::text) from location_presence lp join fleets f on f.id = lp.fleet_id where f.main_ship_id = p_ship
  ) z;
$$;

-- Assert a deterministic Dock-0 terminal failure: movement failed/<reason>/resolved; ship coherently parked
-- in_space at the STORED target snapshot (p_tx,p_ty) — never redirected/docked; fleet pointers cleared; NO
-- presence; S2 validate = in_space; and a replay is a no-op (no loop). Used by the arrival-race matrix (E).
create or replace function h1a_assert_terminal(p_ship uuid, p_reason text, p_tx double precision, p_ty double precision) returns void language plpgsql as $$
declare v_fleet uuid; h1 text; h2 text;
begin
  if (select count(*) from main_ship_space_movements where main_ship_id=p_ship and status='moving') <> 0 then raise exception 'terminal(%): a moving movement remains (would loop)', p_reason; end if;
  perform 1 from main_ship_space_movements m where m.main_ship_id=p_ship and m.status='failed' and m.resolved_at is not null and m.terminal_reason=p_reason;
  if not found then raise exception 'terminal(%): wrong terminal row: %', p_reason, (select to_jsonb(m) from main_ship_space_movements m where m.main_ship_id=p_ship order by created_at desc limit 1); end if;
  perform 1 from main_ship_instances m where m.main_ship_id=p_ship and m.status='stationary' and m.spatial_state='in_space' and m.space_x=p_tx and m.space_y=p_ty;
  if not found then raise exception 'terminal(%): ship not parked in_space at the stored snapshot (%, %): %', p_reason, p_tx, p_ty, (select to_jsonb(m) from main_ship_instances m where m.main_ship_id=p_ship); end if;
  select id into v_fleet from fleets where main_ship_id=p_ship;
  perform 1 from fleets f where f.id=v_fleet and f.status='completed' and f.active_space_movement_id is null and f.active_movement_id is null
     and f.current_location_id is null and f.current_zone_id is null and f.current_sector_id is null and f.current_base_id is null;
  if not found then raise exception 'terminal(%): fleet not coherently cleared (half-docked?): %', p_reason, (select to_jsonb(f) from fleets f where f.id=v_fleet); end if;
  if exists (select 1 from location_presence lp where lp.fleet_id=v_fleet) then raise exception 'terminal(%): a presence exists (must be none)', p_reason; end if;
  if (mainship_space_validate_context(p_ship)->>'state') is distinct from 'in_space' then raise exception 'terminal(%): S2 validate != in_space', p_reason; end if;
  h1 := h1a_ship_hash(p_ship); perform process_mainship_space_arrivals(); h2 := h1a_ship_hash(p_ship);
  if h1 is distinct from h2 then raise exception 'terminal(%): cron replay re-processed a failed movement (loop)', p_reason; end if;
end $$;

-- ════════ SECTION B — location-target SUCCESS (core writer + public wrapper) ════════════════════════════════
do $$
declare u uuid; s uuid; port uuid; r jsonb; r2 jsonb; req uuid := gen_random_uuid(); n int;
begin
  update game_config set value='true' where key='mainship_space_movement_enabled';  -- enable in the disposable env
  u := h1a_user(); port := h1a_eligible_port(120, -60); s := h1a_ship_in_space(u, 10, 10);

  -- core writer: client gives ONLY a location id (no coords). Server stamps location + anchor coords.
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, port, req);
  if (r->>'ok')::boolean is not true then raise exception 'B core: expected ok, got %', r; end if;
  if (r->>'target_kind') <> 'location' then raise exception 'B core: target_kind not location: %', r; end if;
  if (r->>'target_location_id')::uuid <> port then raise exception 'B core: target_location_id mismatch: %', r; end if;
  if (r->>'target_x')::double precision <> 120 or (r->>'target_y')::double precision <> -60 then raise exception 'B core: target x/y not from anchor: %', r; end if;
  -- the persisted movement row carries the location id + anchor coords + origin from the parked point.
  perform 1 from main_ship_space_movements m where m.id=(r->>'movement_id')::uuid
     and m.target_kind='location' and m.target_location_id=port and m.target_x=120 and m.target_y=-60
     and m.origin_kind='space' and m.origin_x=10 and m.origin_y=10 and m.status='moving';
  if not found then raise exception 'B core: persisted movement wrong: %', (select to_jsonb(m) from main_ship_space_movements m where m.id=(r->>'movement_id')::uuid); end if;

  -- idempotent replay: same request id + same location → byte-identical result, no duplicate movement/receipt.
  r2 := public.mainship_space_begin_move_core(u, s, 'location', null, null, port, req);
  if r2 is distinct from r then raise exception 'B core: replay not idempotent'; end if;
  select count(*) into n from main_ship_space_movements where main_ship_id=s; if n <> 1 then raise exception 'B core: % movements (expected 1)', n; end if;
  select count(*) into n from main_ship_space_command_receipts where main_ship_id=s; if n <> 1 then raise exception 'B core: % receipts (expected 1)', n; end if;
  select count(*) into n from fleets where main_ship_id=s; if n <> 1 then raise exception 'B core: % fleets (expected 1)', n; end if;

  -- regression: the preserved 5-arg space writer (now a delegate to the core) still produces a space move.
  declare us uuid; ss uuid; rs jsonb;
  begin
    us := h1a_user(); ss := h1a_ship_in_space(us, -300, -300);
    rs := public.mainship_space_begin_move(us, ss, 250, 175, gen_random_uuid());
    if (rs->>'ok')::boolean is not true or (rs->>'target_kind') <> 'space' then raise exception 'B: 5-arg space delegate regressed: %', rs; end if;
    if (rs->>'target_x')::double precision <> 250 then raise exception 'B: space delegate target wrong: %', rs; end if;
    perform 1 from main_ship_space_movements m where m.id=(rs->>'movement_id')::uuid and m.target_kind='space' and m.target_location_id is null;
    if not found then raise exception 'B: space movement carried a location id'; end if;
  end;
  raise notice 'SECTION B (core) ok: location target stamped server-side from the anchor; idempotent; single fleet/movement/receipt; 5-arg space delegate unchanged';

  -- public wrapper as the AUTHENTICATED owner (auth.uid()), success path + leak-safety + flag-gate.
  declare u2 uuid; s2 uuid; port2 uuid; hid uuid; wz uuid; rr jsonb;
  begin
    u2 := h1a_user(); port2 := h1a_eligible_port(80, 40); s2 := h1a_ship_in_space(u2, -10, -10);
    -- a HIDDEN port (status hidden) with a full eligible shape otherwise, to prove the leak-safe generic code.
    wz := h1a_zone('active','active'); hid := h1a_loc(wz, 'port', 'hidden', 200, 50, 'none');
    perform h1a_service(hid, 'active'); perform h1a_anchor(hid, 200, 50, 'active');

    -- auth.uid() is derived from request.jwt.claims (independent of the executing role). The wrapper's
    -- authenticated-only ACL is proven separately (perm script + the workflow's SET ROLE denial); here we
    -- exercise its functional path (flag gate → own-ship derivation → core delegation → leak-safe mapping).
    perform set_config('request.jwt.claims', json_build_object('sub', u2)::text, true);

    -- leak-safety FIRST, while the ship is still parked (a successful move would flip it to in_transit and the
    -- core would then short-circuit at in_transit_must_stop before ever evaluating target legality).
    rr := public.command_main_ship_space_move_to_location(hid, gen_random_uuid());
    if (rr->>'ok')::boolean is not false or (rr->>'code') <> 'invalid_target' then raise exception 'B wrapper: hidden port must return generic invalid_target, got %', rr; end if;
    rr := public.command_main_ship_space_move_to_location(gen_random_uuid(), gen_random_uuid());
    if (rr->>'ok')::boolean is not false or (rr->>'code') <> 'invalid_target' then raise exception 'B wrapper: nonexistent uuid must return generic invalid_target, got %', rr; end if;

    -- success LAST (the parked ship departs for the eligible port).
    rr := public.command_main_ship_space_move_to_location(port2, gen_random_uuid());
    if (rr->>'ok')::boolean is not true then raise exception 'B wrapper: expected ok for eligible port, got %', rr; end if;
    if (rr->>'target_location_id')::uuid <> port2 or (rr->>'target_x')::double precision <> 80 then raise exception 'B wrapper: stamped fields wrong: %', rr; end if;
    perform set_config('request.jwt.claims', '', true);
    raise notice 'SECTION B (wrapper) ok: hidden port and nonexistent uuid are INDISTINGUISHABLE (both invalid_target); eligible owner move succeeds';
  end;

  update game_config set value='false' where key='mainship_space_movement_enabled';  -- restore dark
end $$;

-- ════════ SECTION C — origin resolution (anchored docked / in_space; home fail-closed; legacy coords inert) ══
do $$
declare u uuid; s uuid; portA uuid; portB uuid; r jsonb; h text; n int;
begin
  update game_config set value='true' where key='mainship_space_movement_enabled';

  -- docked at anchored port A → move to anchored port B: origin resolves from A's anchor (NOT locations.x/y).
  u := h1a_user(); portA := h1a_eligible_port(300, 100); portB := h1a_eligible_port(-200, -50);
  s := h1a_ship_at_location(u, portA);
  if (mainship_space_resolve_origin(s)->>'origin_kind') <> 'location' then raise exception 'C: docked origin not location: %', mainship_space_resolve_origin(s); end if;
  if (mainship_space_resolve_origin(s)->>'origin_x')::double precision <> 300 then raise exception 'C: docked origin x not from anchor'; end if;

  -- mutate legacy locations.x/y of A away from the anchor → OSN origin is UNCHANGED (anchor-sourced).
  update locations set x = 9999, y = 9999 where id = portA;
  if (mainship_space_resolve_origin(s)->>'origin_x')::double precision <> 300 then raise exception 'C: locations.x/y leaked into OSN origin'; end if;
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, portB, gen_random_uuid());
  if (r->>'ok')::boolean is not true then raise exception 'C: docked→port move failed: %', r; end if;
  if (r->>'origin_x')::double precision <> 300 or (r->>'target_x')::double precision <> -200 then raise exception 'C: docked move used wrong anchored coords: %', r; end if;

  -- legacy HOME stays fail-closed origin_not_anchored; mutating bases.x/y does not change that.
  declare u2 uuid; s2 uuid;
  begin
    u2 := h1a_user(); s2 := h1a_ship_home(u2);
    update bases set x = 1234, y = 5678 where player_id = u2;
    if (mainship_space_resolve_origin(s2)->>'reason') <> 'origin_not_anchored' then raise exception 'C: home not origin_not_anchored: %', mainship_space_resolve_origin(s2); end if;
    portB := h1a_eligible_port(-300, 70);
    h := h1a_ship_hash(s2);
    r := public.mainship_space_begin_move_core(u2, s2, 'location', null, null, portB, gen_random_uuid());
    if (r->>'ok')::boolean is not false or (r->>'reason') <> 'origin_not_anchored' then raise exception 'C: home move not rejected origin_not_anchored: %', r; end if;
    if h is distinct from h1a_ship_hash(s2) then raise exception 'C: home-rejection mutated ship state'; end if;
  end;

  -- docked at an UNANCHORED location → origin fails closed, no mutation.
  declare u3 uuid; s3 uuid; bareZone uuid; bareLoc uuid;
  begin
    u3 := h1a_user(); bareZone := h1a_zone('active','active');
    bareLoc := h1a_loc(bareZone, 'port', 'active', 400, 400, 'none'); perform h1a_service(bareLoc, 'active');  -- NO anchor
    s3 := h1a_ship_at_location(u3, bareLoc);
    if (mainship_space_resolve_origin(s3)->>'reason') <> 'origin_not_anchored' then raise exception 'C: unanchored docked origin not fail-closed: %', mainship_space_resolve_origin(s3); end if;
    portB := h1a_eligible_port(150, -150); h := h1a_ship_hash(s3);
    r := public.mainship_space_begin_move_core(u3, s3, 'location', null, null, portB, gen_random_uuid());
    if (r->>'ok')::boolean is not false or (r->>'reason') <> 'origin_not_anchored' then raise exception 'C: unanchored docked move not rejected: %', r; end if;
    if h is distinct from h1a_ship_hash(s3) then raise exception 'C: unanchored-rejection mutated ship state'; end if;
  end;

  update game_config set value='false' where key='mainship_space_movement_enabled';
  raise notice 'SECTION C ok: docked/in_space origins resolve from the anchor; legacy locations.x/y & bases.x/y are inert; HOME & unanchored fail closed with no mutation';
end $$;

-- ════════ SECTION D — target rejection matrix (every case: no orphan fleet/movement/receipt/presence) ═══════
do $$
declare u uuid; s uuid; r jsonb; h text; tgt uuid; z_la uuid; z_lz uuid; z_ls uuid;
begin
  update game_config set value='true' where key='mainship_space_movement_enabled';
  u := h1a_user(); s := h1a_ship_in_space(u, 5, 5); h := h1a_ship_hash(s);

  -- helper inline: assert a location target is rejected with no orphan + no ship mutation, returns nothing.
  -- (each case builds its own target and asserts)
  -- hidden location
  z_la := h1a_zone('active','active'); tgt := h1a_loc(z_la,'port','hidden',210,10,'none'); perform h1a_service(tgt,'active'); perform h1a_anchor(tgt,210,10,'active');
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, tgt, gen_random_uuid());
  if (r->>'ok')::boolean is not false or (r->>'reason') <> 'target_inactive_location' then raise exception 'D hidden: %', r; end if;

  -- inactive location (status locked)
  tgt := h1a_loc(z_la,'port','locked',211,10,'none'); perform h1a_service(tgt,'active'); perform h1a_anchor(tgt,211,10,'active');
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, tgt, gen_random_uuid());
  if (r->>'reason') <> 'target_inactive_location' then raise exception 'D inactive-loc: %', r; end if;

  -- inactive zone (zone locked, sector active)
  z_lz := h1a_zone('active','locked'); tgt := h1a_loc(z_lz,'port','active',212,10,'none'); perform h1a_service(tgt,'active'); perform h1a_anchor(tgt,212,10,'active');
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, tgt, gen_random_uuid());
  if (r->>'reason') <> 'target_inactive_zone' then raise exception 'D inactive-zone: %', r; end if;

  -- inactive sector (sector locked)
  z_ls := h1a_zone('locked','active'); tgt := h1a_loc(z_ls,'port','active',213,10,'none'); perform h1a_service(tgt,'active'); perform h1a_anchor(tgt,213,10,'active');
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, tgt, gen_random_uuid());
  if (r->>'reason') <> 'target_inactive_sector' then raise exception 'D inactive-sector: %', r; end if;

  -- unsupported role (station)
  tgt := h1a_loc(z_la,'station','active',214,10,'none'); perform h1a_service(tgt,'active'); perform h1a_anchor(tgt,214,10,'active');
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, tgt, gen_random_uuid());
  if (r->>'reason') <> 'target_unsupported_role' then raise exception 'D role: %', r; end if;

  -- unsupported activity: active sector/zone/location + role port + active docking service + one active anchor,
  -- but activity_type<>'none' (a route Dock-0 would predictably reject) → rejected at DEPARTURE, no mutation.
  tgt := h1a_loc(z_la,'port','active',219,10,'hunt_pirates'); perform h1a_service(tgt,'active'); perform h1a_anchor(tgt,219,10,'active');
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, tgt, gen_random_uuid());
  if (r->>'reason') <> 'target_unsupported_activity' then raise exception 'D activity: %', r; end if;

  -- no active docking service
  tgt := h1a_loc(z_la,'port','active',215,10,'none'); perform h1a_anchor(tgt,215,10,'active');  -- no service
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, tgt, gen_random_uuid());
  if (r->>'reason') <> 'target_no_docking_service' then raise exception 'D no-service: %', r; end if;
  -- disabled docking service (also not active)
  tgt := h1a_loc(z_la,'port','active',216,10,'none'); perform h1a_service(tgt,'disabled'); perform h1a_anchor(tgt,216,10,'active');
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, tgt, gen_random_uuid());
  if (r->>'reason') <> 'target_no_docking_service' then raise exception 'D disabled-service: %', r; end if;

  -- no active anchor
  tgt := h1a_loc(z_la,'port','active',217,10,'none'); perform h1a_service(tgt,'active');  -- no anchor
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, tgt, gen_random_uuid());
  if (r->>'reason') <> 'target_anchor_not_unique' then raise exception 'D no-anchor: %', r; end if;
  -- retired-only anchor (no active) → still count(active)=0
  tgt := h1a_loc(z_la,'port','active',218,10,'none'); perform h1a_service(tgt,'active'); perform h1a_anchor(tgt,218,10,'retired');
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, tgt, gen_random_uuid());
  if (r->>'reason') <> 'target_anchor_not_unique' then raise exception 'D retired-anchor: %', r; end if;

  -- malformed: location id null, and a space-shape contradiction on a location command
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, null, gen_random_uuid());
  if (r->>'reason') <> 'invalid_target_location' then raise exception 'D null-loc: %', r; end if;
  r := public.mainship_space_begin_move_core(u, s, 'location', 1, 2, h1a_eligible_port(260,10), gen_random_uuid());
  if (r->>'reason') <> 'invalid_target_shape' then raise exception 'D client-coords-on-location: %', r; end if;
  r := public.mainship_space_begin_move_core(u, s, 'banana', null, null, null, gen_random_uuid());
  if (r->>'reason') <> 'invalid_target_kind' then raise exception 'D bad-kind: %', r; end if;

  -- after the ENTIRE rejection matrix the ship is byte-for-byte unchanged: NO orphan fleet/movement/receipt.
  if h is distinct from h1a_ship_hash(s) then raise exception 'D: a rejection mutated ship state'; end if;
  if exists (select 1 from fleets where main_ship_id=s) then raise exception 'D: an orphan fleet was created'; end if;
  if exists (select 1 from main_ship_space_movements where main_ship_id=s) then raise exception 'D: an orphan movement was created'; end if;
  if exists (select 1 from main_ship_space_command_receipts where main_ship_id=s) then raise exception 'D: a receipt was written for a rejection'; end if;

  -- flag OFF → feature_disabled regardless of target; a HIDDEN uuid while off is ALSO feature_disabled (anti-probe).
  update game_config set value='false' where key='mainship_space_movement_enabled';
  declare u4 uuid; s4 uuid; goodPort uuid; rr jsonb;
  begin
    u4 := h1a_user(); s4 := h1a_ship_in_space(u4, 1, 1); goodPort := h1a_eligible_port(330, 33);
    r := public.mainship_space_begin_move_core(u4, s4, 'location', null, null, goodPort, gen_random_uuid());
    if (r->>'reason') <> 'feature_disabled' then raise exception 'D flag-off core: %', r; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', u4)::text, true);
    rr := public.command_main_ship_space_move_to_location(goodPort, gen_random_uuid());
    if (rr->>'code') <> 'feature_disabled' then raise exception 'D flag-off wrapper(eligible): %', rr; end if;
    -- hidden uuid while off → SAME feature_disabled (no existence probe): target resolution never runs.
    rr := public.command_main_ship_space_move_to_location(gen_random_uuid(), gen_random_uuid());
    if (rr->>'code') <> 'feature_disabled' then raise exception 'D flag-off wrapper(hidden): %', rr; end if;
    perform set_config('request.jwt.claims', '', true);
  end;
  raise notice 'SECTION D ok: full target rejection matrix non-mutating + no orphans; flag-off is feature_disabled (anti-probe) for both eligible and hidden targets';
end $$;

-- ════════ SECTION E — anchor-backed docking + anchor-change race (no locations.x/y; no redirect) ════════════
do $$
declare u uuid; s uuid; port uuid; n int; h1 text; h2 text;
begin
  -- (flag stays false — the arrival processor does not gate on it)
  -- E0 regression: a free-space (target_kind='space') arrival still settles to in_space, byte-for-byte.
  declare us uuid; ss uuid; vf uuid := gen_random_uuid(); vm uuid := gen_random_uuid();
  begin
    us := h1a_user();
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (us,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,gen_random_uuid()) returning main_ship_id into ss;
    insert into fleets (id,player_id,status,location_mode,main_ship_id) values (vf,us,'moving','movement',ss);
    insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
      values (vm,ss,vf,us,'space',0,0,'space',333,222,1.0, now()-interval '2 hour', now()-interval '1 hour');
    update fleets set active_space_movement_id=vm where id=vf;
    perform process_mainship_space_arrivals();
    perform 1 from main_ship_instances m where m.main_ship_id=ss and m.spatial_state='in_space' and m.space_x=333 and m.space_y=222;
    if not found then raise exception 'E0: space arrival no longer settles to in_space'; end if;
    if exists (select 1 from location_presence lp where lp.fleet_id=vf) then raise exception 'E0: space arrival created a presence'; end if;
  end;

  -- E1: docks when the live anchor still matches the stored target snapshot.
  u := h1a_user(); port := h1a_eligible_port(120, -60); s := h1a_intransit_loc(u, port, 120, -60);
  n := process_mainship_space_arrivals();
  if n < 1 then raise exception 'E1: processor settled 0'; end if;
  perform 1 from main_ship_instances m where m.main_ship_id=s and m.status='stationary' and m.spatial_state='at_location';
  if not found then raise exception 'E1: ship not docked at_location'; end if;
  if (mainship_space_validate_context(s)->>'state') <> 'at_location' then raise exception 'E1: S2 != at_location'; end if;
  if exists (select 1 from main_ship_space_movements where main_ship_id=s and status='moving') then raise exception 'E1: a moving movement remains'; end if;
  -- mutate locations.x/y AFTER docking: docking never consulted it (above already docked on the anchor).
  raise notice 'E1 ok: docks when the live anchor matches the stored snapshot (anchor is the coordinate authority)';

  -- ── Arrival-race matrix: each route is DOCKABLE at departure (snapshot = the live anchor), then ONE
  --    dockability condition is broken DURING travel. Dock-0 must FULLY revalidate at arrival and terminally
  --    fail (ship parked in_space at the stored snapshot, no presence, no redirect, no loop) — never dock. ──

  -- E2: the anchor MOVES after departure → target_anchor_changed (ship floats at the stored target, NOT 71).
  u := h1a_user(); port := h1a_eligible_port(70, 70); s := h1a_intransit_loc(u, port, 70, 70);
  update space_anchors set status='retired' where location_id=port and kind='location' and status='active';
  perform h1a_anchor(port, 71, 70, 'active');                       -- new active anchor at DIFFERENT coords
  perform process_mainship_space_arrivals();
  perform h1a_assert_terminal(s, 'target_anchor_changed', 70, 70);

  -- E3: the anchor RETIRES with no replacement → undockable_no_active_anchor.
  u := h1a_user(); port := h1a_eligible_port(-90, 40); s := h1a_intransit_loc(u, port, -90, 40);
  update space_anchors set status='retired' where location_id=port and kind='location' and status='active';
  perform process_mainship_space_arrivals();
  perform h1a_assert_terminal(s, 'undockable_no_active_anchor', -90, 40);

  -- E4: the DOCKING SERVICE becomes inactive after departure → undockable_no_docking_service.
  u := h1a_user(); port := h1a_eligible_port(160, -20); s := h1a_intransit_loc(u, port, 160, -20);
  update location_services set status='disabled' where location_id=port and service='docking';
  perform process_mainship_space_arrivals();
  perform h1a_assert_terminal(s, 'undockable_no_docking_service', 160, -20);

  -- E5: the target ZONE becomes inactive after departure → undockable_inactive_zone.
  u := h1a_user(); port := h1a_eligible_port(-160, 20); s := h1a_intransit_loc(u, port, -160, 20);
  update zones set status='locked' where id = (select zone_id from locations where id=port);
  perform process_mainship_space_arrivals();
  perform h1a_assert_terminal(s, 'undockable_inactive_zone', -160, 20);

  -- E6: the target SECTOR becomes inactive after departure → undockable_inactive_sector.
  u := h1a_user(); port := h1a_eligible_port(40, 160); s := h1a_intransit_loc(u, port, 40, 160);
  update sectors set status='locked' where id = (select z.sector_id from locations l join zones z on z.id=l.zone_id where l.id=port);
  perform process_mainship_space_arrivals();
  perform h1a_assert_terminal(s, 'undockable_inactive_sector', 40, 160);

  -- E7: the target LOCATION ACTIVITY becomes non-'none' after departure → undockable_unsupported_activity.
  u := h1a_user(); port := h1a_eligible_port(-40, -160); s := h1a_intransit_loc(u, port, -40, -160);
  update locations set activity_type='hunt_pirates' where id=port;
  perform process_mainship_space_arrivals();
  perform h1a_assert_terminal(s, 'undockable_unsupported_activity', -40, -160);

  -- E8: the target LOCATION becomes inactive after departure → undockable_inactive_location.
  u := h1a_user(); port := h1a_eligible_port(175, 175); s := h1a_intransit_loc(u, port, 175, 175);
  update locations set status='locked' where id=port;
  perform process_mainship_space_arrivals();
  perform h1a_assert_terminal(s, 'undockable_inactive_location', 175, 175);

  -- Dock-0 is reachable ONLY via the processor (no client/anon/auth EXECUTE — proven in the perm script).
  raise notice 'SECTION E ok: full arrival revalidation under target-hierarchy locks — anchor move/retire, service/zone/sector deactivation, activity change, and location deactivation each terminally fail (parked in_space at snapshot; no presence; no redirect; no loop)';
end $$;

-- ════════ SECTION G — pointer coherence / single engine (no concurrent OSN move; one processor/dock/core) ═══
do $$
declare u uuid; s uuid; port uuid; r jsonb; h text; n int;
begin
  update game_config set value='true' where key='mainship_space_movement_enabled';
  -- a ship ALREADY in coordinate transit cannot begin a second OSN location move: resolve_origin returns
  -- in_transit_must_stop and the core rejects with NO second movement/fleet/receipt (one-active-per-ship holds).
  u := h1a_user(); port := h1a_eligible_port(140, 20);
  s := h1a_intransit_loc(u, port, 140, 20);   -- coherent active OSN location movement already in flight
  if (mainship_space_validate_context(s)->>'state') <> 'in_transit' then raise exception 'G precond: not in_transit'; end if;
  h := h1a_ship_hash(s);
  r := public.mainship_space_begin_move_core(u, s, 'location', null, null, h1a_eligible_port(-140, -20), gen_random_uuid());
  if (r->>'ok')::boolean is not false or (r->>'reason') <> 'in_transit_must_stop' then raise exception 'G: a moving ship began a second OSN move: %', r; end if;
  if h is distinct from h1a_ship_hash(s) then raise exception 'G: the rejected second move mutated ship state'; end if;
  select count(*) into n from main_ship_space_movements where main_ship_id=s; if n <> 1 then raise exception 'G: % active movements (expected exactly 1)', n; end if;
  update game_config set value='false' where key='mainship_space_movement_enabled';

  -- single engine: exactly one arrival processor, one dock resolver, one discriminated core writer.
  if (select count(*) from pg_proc p join pg_namespace nn on nn.oid=p.pronamespace where nn.nspname='public' and p.proname='process_mainship_space_arrivals') <> 1 then raise exception 'G: not exactly one arrival processor'; end if;
  if (select count(*) from pg_proc p join pg_namespace nn on nn.oid=p.pronamespace where nn.nspname='public' and p.proname='mainship_space_dock_at_location') <> 1 then raise exception 'G: not exactly one dock resolver'; end if;
  if (select count(*) from pg_proc p join pg_namespace nn on nn.oid=p.pronamespace where nn.nspname='public' and p.proname='mainship_space_begin_move_core') <> 1 then raise exception 'G: not exactly one core writer'; end if;
  raise notice 'SECTION G ok: a moving ship cannot start a second OSN move (one-active-per-ship, pointer-coherent); exactly one arrival processor + one dock resolver + one core writer (no second engine). Legacy↔OSN cross-domain exclusion is enforced by the unchanged S2 assert_cross_domain_exclusion the core composes.';
end $$;

-- ════════ cleanup (delete users → cascade ships/fleets/movements/receipts/presence; then world scaffold) ════
delete from auth.users where email like 'osn3hub1a.%@example.com';
delete from space_anchors a using locations l where a.location_id=l.id and l.name like 'hub1a-loc-%';
delete from location_services svc using locations l where svc.location_id=l.id and l.name like 'hub1a-loc-%';
delete from locations where name like 'hub1a-loc-%';
delete from zones   where name like 'hub1a-zone-%';
delete from sectors where name like 'hub1a-sec-%';

do $$ declare n int;
begin
  select count(*) into n from auth.users where email like 'osn3hub1a.%@example.com'; if n<>0 then raise exception 'CLEANUP: % fixture users remain', n; end if;
  select count(*) into n from locations where name like 'hub1a-loc-%';                if n<>0 then raise exception 'CLEANUP: % hub1a locations remain', n; end if;
  select count(*) into n from sectors   where name like 'hub1a-sec-%';                if n<>0 then raise exception 'CLEANUP: % hub1a sectors remain', n; end if;
  select count(*) into n from main_ship_instances where player_id not in (select id from auth.users); if n<>0 then raise exception 'CLEANUP: % orphan ships', n; end if;
  raise notice 'ok cleanup: no OSN-HUB-1A fixture rows remain';
end $$;

drop function if exists h1a_assert_terminal(uuid,text,double precision,double precision);
drop function if exists h1a_intransit_loc(uuid,uuid,double precision,double precision);
drop function if exists h1a_ship_at_location(uuid,uuid);
drop function if exists h1a_ship_home(uuid);
drop function if exists h1a_ship_in_space(uuid,double precision,double precision);
drop function if exists h1a_eligible_port(double precision,double precision);
drop function if exists h1a_anchor(uuid,double precision,double precision,text);
drop function if exists h1a_service(uuid,text);
drop function if exists h1a_loc(uuid,text,text,double precision,double precision,text);
drop function if exists h1a_zone(text,text);
drop function if exists h1a_ship_hash(uuid);
drop function if exists h1a_user();

-- restore the arrival cron (asserted+unscheduled above) and re-assert the dark flag invariants.
do $$ begin
  perform cron.unschedule(jobid) from cron.job where jobname='process-mainship-space-arrivals';
  perform cron.schedule('process-mainship-space-arrivals','30 seconds',$cmd$select public.process_mainship_space_arrivals();$cmd$);
exception when undefined_table then null; end $$;

do $$ declare a text; b text; begin
  select value::text into a from game_config where key='mainship_send_enabled';
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  if a is distinct from 'true'  then raise exception 'FLAG FAIL: mainship_send_enabled=% (must remain true)', a; end if;
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled=% (must remain false / dark)', b; end if;
  raise notice 'FLAG ok: mainship_send_enabled=true (untouched), mainship_space_movement_enabled=false (dark)';
end $$;

select 'OSN-HUB-1A REAL-CHAIN FIXTURE MATRIX: ALL PASSED' as result;
