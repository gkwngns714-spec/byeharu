-- OSN-3 S3 — REAL-CHAIN writer fixture matrix for public.mainship_space_begin_move(...).
-- Builds each state from REAL rows on the ACTUAL migration chain. CRITICAL: every fixture derives its
-- preconditions from AUTHORITATIVE database state, never from assumed inserts. In particular, the real
-- chain auto-provisions a 'Home Base' at (0,0) via the on_auth_user_created_base trigger
-- (initialize_new_player), so this harness does NOT insert its own base — it reads the auto-base and
-- uses mainship_space_resolve_origin(ship) as the single source of truth for every origin/zero-distance
-- coordinate. Positives assert movement.origin == the S2-resolved origin and speed_used ==
-- resolve_fleet_movement_speed(fleet). Every rejection is standalone, asserts its own starting state,
-- and is proven to mutate NO row (global state hash before == after). Fixtures are marked by the
-- 'osn3s3fix.' email prefix and removed at the end (cascade via auth.users). The flag
-- mainship_space_movement_enabled and the cap max_coordinate_travel_seconds are toggled ONLY in this
-- disposable stack and restored + asserted at the end (the workflow nets a best-effort restore too).
-- NEVER touches the shared/live DB; NEVER touches mainship_send_enabled.

\set ON_ERROR_STOP on

create or replace function s3fix_user() returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated', 'authenticated',
          'osn3s3fix.'||replace(v::text,'-','')||'@example.com', '', now(), now(), now(), '', '', '', '');
  return v;  -- the on_auth_user_created_base trigger auto-creates this player's 'Home Base' at (0,0)
end $$;

-- Build a fixture of the given kind; returns the main_ship_id. Uses the AUTO-provisioned home base
-- (no second base is inserted) so resolve_origin's "oldest active base" is unambiguous.
create or replace function s3fix(kind text) returns uuid language plpgsql as $$
declare
  v_u uuid := s3fix_user(); v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid();
  v_f2 uuid := gen_random_uuid(); v_m uuid := gen_random_uuid(); v_m_term uuid := gen_random_uuid();
  v_b uuid;
  v_l1 uuid := (select id from locations order by id limit 1);
  v_l2 uuid := (select id from locations order by id offset 1 limit 1);
begin
  select id into v_b from bases where player_id = v_u and status = 'active' order by created_at limit 1;  -- the (0,0) auto-base
  if v_b is null then raise exception 's3fix: expected an auto-provisioned base for the fixture user'; end if;

  if kind = 'legacy_home' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'home', null, 500, 500, 50, 10, 2, 3, v_s);
  elsif kind = 'home' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'home', 'home', 500, 500, 50, 10, 2, 3, v_s);
  elsif kind = 'in_space' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, space_x, space_y, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'stationary', 'in_space', 7, -9, 500, 500, 50, 10, 2, 3, v_s);
  elsif kind = 'in_space_oob' then  -- in_space whose resolved origin is OUTSIDE the movement envelope
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, space_x, space_y, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'stationary', 'in_space', 15000, 0, 500, 500, 50, 10, 2, 3, v_s);
  elsif kind = 'destroyed' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'destroyed', 'destroyed', 0, 500, 50, 10, 2, 3, v_s);

  elsif kind = 'legacy_present' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'traveling', null, 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, current_location_id, main_ship_id) values (v_f, v_u, v_b, 'present', 'location', v_l1, v_s);
    insert into location_presence (player_id, fleet_id, status, location_id) values (v_u, v_f, 'active', v_l1);
  elsif kind = 'at_location' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'stationary', 'at_location', 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, current_location_id, main_ship_id) values (v_f, v_u, v_b, 'present', 'location', v_l1, v_s);
    insert into location_presence (player_id, fleet_id, status, location_id) values (v_u, v_f, 'active', v_l1);
  elsif kind = 'at_location_nopres' then  -- at_location but NO active presence (missing required presence)
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'stationary', 'at_location', 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, current_location_id, main_ship_id) values (v_f, v_u, v_b, 'present', 'location', v_l1, v_s);
  elsif kind = 'at_location_mispres' then  -- presence at a DIFFERENT location than the fleet (mismatched)
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'stationary', 'at_location', 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, current_location_id, main_ship_id) values (v_f, v_u, v_b, 'present', 'location', v_l1, v_s);
    insert into location_presence (player_id, fleet_id, status, location_id) values (v_u, v_f, 'active', v_l2);

  elsif kind = 'multi_fleet' then  -- two active fleets for one ship → multiple_active_fleets
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'home', null, 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, current_location_id, main_ship_id) values (v_f,  v_u, v_b, 'present', 'location', v_l1, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, current_location_id, main_ship_id) values (v_f2, v_u, v_b, 'present', 'location', v_l2, v_s);

  elsif kind = 'in_transit' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'traveling', 'in_transit', 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, main_ship_id) values (v_f, v_u, v_b, 'moving', 'movement', v_s);
    insert into main_ship_space_movements (id, main_ship_id, fleet_id, player_id, origin_kind, origin_x, origin_y, target_kind, target_x, target_y, speed_used, depart_at, arrive_at)
      values (v_m, v_s, v_f, v_u, 'base', 0, 0, 'space', 100, 50, 1.0, now(), now() + interval '1 hour');
    update fleets set active_space_movement_id = v_m where id = v_f;
  elsif kind = 'in_transit_misptr' then  -- fleet pointer → a TERMINAL movement, not the active one
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'traveling', 'in_transit', 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, main_ship_id) values (v_f, v_u, v_b, 'moving', 'movement', v_s);
    insert into main_ship_space_movements (id, main_ship_id, fleet_id, player_id, origin_kind, origin_x, origin_y, target_kind, target_x, target_y, speed_used, depart_at, arrive_at)
      values (v_m, v_s, v_f, v_u, 'base', 0, 0, 'space', 100, 50, 1.0, now(), now() + interval '1 hour');
    insert into main_ship_space_movements (id, main_ship_id, fleet_id, player_id, origin_kind, origin_x, origin_y, target_kind, target_x, target_y, speed_used, depart_at, arrive_at, status, resolved_at)
      values (v_m_term, v_s, v_f, v_u, 'base', 0, 0, 'space', 1, 1, 1.0, now() - interval '2 hour', now() - interval '1 hour', 'arrived', now());
    update fleets set active_space_movement_id = v_m_term where id = v_f;

  elsif kind = 'legacy_transit' then  -- legacy moving fleet WITH an active legacy fleet_movement
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'traveling', null, 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, main_ship_id) values (v_f, v_u, v_b, 'moving', 'movement', v_s);
    insert into fleet_movements (player_id, fleet_id, origin_type, origin_x, origin_y, target_type, target_x, target_y, mission_type, status, arrive_at, travel_distance, travel_seconds, speed_used)
      values (v_u, v_f, 'base', 0, 0, 'location', 1, 1, 'rally', 'moving', now() + interval '1 hour', 1, 1, 1);

  elsif kind = 'in_space_with_movement' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, space_x, space_y, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'stationary', 'in_space', 5, 6, 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, main_ship_id) values (v_f, v_u, v_b, 'moving', 'movement', v_s);
    insert into main_ship_space_movements (id, main_ship_id, fleet_id, player_id, origin_kind, origin_x, origin_y, target_kind, target_x, target_y, speed_used, depart_at, arrive_at)
      values (v_m, v_s, v_f, v_u, 'base', 0, 0, 'space', 1, 1, 1.0, now(), now() + interval '1 hour');
    update fleets set active_space_movement_id = v_m where id = v_f;
  elsif kind = 'in_space_with_presence' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, space_x, space_y, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'stationary', 'in_space', 5, 6, 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, current_location_id, main_ship_id) values (v_f, v_u, v_b, 'present', 'location', v_l1, v_s);
    insert into location_presence (player_id, fleet_id, status, location_id) values (v_u, v_f, 'active', v_l1);
  else
    raise exception 's3fix: unknown kind %', kind;
  end if;
  return v_s;
end $$;

-- Global state hash over every table the writer could touch (proves "no mutation" on rejection).
create or replace function s3_state_hash() returns text language sql stable as $$
  select md5(coalesce(string_agg(t, ''), '')) from (
    select md5(main_ship_instances::text) t from main_ship_instances
    union all select md5(fleets::text) from fleets
    union all select md5(main_ship_space_movements::text) from main_ship_space_movements
    union all select md5(location_presence::text) from location_presence
    union all select md5(fleet_movements::text) from fleet_movements
    union all select md5(main_ship_space_command_receipts::text) from main_ship_space_command_receipts
  ) z;
$$;

-- Positive: derive the authoritative origin, run the writer, assert the full coherent post-state
-- INCLUDING movement.origin == resolved origin and speed_used == resolve_fleet_movement_speed(fleet).
create or replace function s3_run_ok(p_ship uuid, p_tx double precision, p_ty double precision, p_req uuid, p_expect_okind text) returns void language plpgsql as $$
declare v_player uuid; v_o jsonb; v_ox double precision; v_oy double precision; r jsonb; v_mv uuid; v_fleet uuid; v_speed double precision;
begin
  select player_id into v_player from main_ship_instances where main_ship_id = p_ship;
  -- precondition: authoritative resolved origin is ok, finite, and the expected kind
  v_o := mainship_space_resolve_origin(p_ship);
  if (v_o->>'ok')::boolean is not true then raise exception '% precond: resolve_origin not ok: %', p_expect_okind, v_o; end if;
  if (v_o->>'origin_kind') <> p_expect_okind then raise exception '% precond: origin_kind=% (expected %)', p_expect_okind, v_o->>'origin_kind', p_expect_okind; end if;
  v_ox := (v_o->>'origin_x')::double precision; v_oy := (v_o->>'origin_y')::double precision;
  if v_ox is null or v_oy is null or v_ox = 'NaN'::double precision or v_oy = 'NaN'::double precision then raise exception '% precond: origin not finite: %', p_expect_okind, v_o; end if;
  if v_ox = p_tx and v_oy = p_ty then raise exception '% precond: chosen target equals origin (would be zero-distance)', p_expect_okind; end if;

  r := mainship_space_begin_move(v_player, p_ship, p_tx, p_ty, p_req);
  if (r->>'ok')::boolean is not true then raise exception '% expected ok, got %', p_expect_okind, r; end if;

  if (select count(*) from main_ship_space_movements where main_ship_id = p_ship and status = 'moving') <> 1 then
    raise exception '% expected exactly one moving movement', p_expect_okind; end if;
  select id, fleet_id into v_mv, v_fleet from main_ship_space_movements where main_ship_id = p_ship and status = 'moving';
  v_speed := resolve_fleet_movement_speed(v_fleet);

  perform 1 from main_ship_space_movements m where m.id = v_mv
     and m.player_id = v_player and m.origin_kind = p_expect_okind
     and m.origin_x = v_ox and m.origin_y = v_oy                         -- origin == authoritative resolved origin
     and m.target_kind = 'space' and m.target_x = p_tx and m.target_y = p_ty
     and m.target_location_id is null and m.target_base_id is null
     and m.speed_used = v_speed and m.speed_used > 0                     -- speed_used == resolve_fleet_movement_speed
     and m.depart_at < m.arrive_at;
  if not found then raise exception '% movement fields wrong: % (resolved origin %, % ; speed %)', p_expect_okind, (select to_jsonb(m) from main_ship_space_movements m where m.id = v_mv), v_ox, v_oy, v_speed; end if;

  perform 1 from fleets f where f.id = v_fleet and f.main_ship_id = p_ship and f.status = 'moving'
     and f.location_mode = 'movement' and f.active_space_movement_id = v_mv and f.active_movement_id is null
     and f.current_location_id is null and f.current_zone_id is null and f.current_sector_id is null;
  if not found then raise exception '% fleet pointer wrong: %', p_expect_okind, (select to_jsonb(f) from fleets f where f.id = v_fleet); end if;

  perform 1 from main_ship_instances s where s.main_ship_id = p_ship and s.status = 'traveling'
     and s.spatial_state = 'in_transit' and s.space_x is null and s.space_y is null;
  if not found then raise exception '% ship state wrong', p_expect_okind; end if;

  if r->>'movement_id' <> v_mv::text or r->>'fleet_id' <> v_fleet::text or (r->>'speed_used')::double precision <> v_speed then
    raise exception '% returned result not coherent with rows: %', p_expect_okind, r; end if;
  perform 1 from main_ship_space_command_receipts c where c.main_ship_id = p_ship and c.request_id = p_req
     and c.command_type = 'space_begin_move' and c.movement_id = v_mv and c.outcome_status = 'success'
     and (c.result_json->>'ok')::boolean is true and c.completed_at is not null and c.result_json = r;
  if not found then raise exception '% receipt wrong/not linked/not equal to returned result', p_expect_okind; end if;

  if p_expect_okind = 'location' then
    if (select count(*) from location_presence where fleet_id = v_fleet and status = 'completed') <> 1 then raise exception '% presence not closed exactly once', p_expect_okind; end if;
    if exists (select 1 from location_presence where fleet_id = v_fleet and status = 'active') then raise exception '% active presence remains', p_expect_okind; end if;
  end if;
  if exists (select 1 from fleet_movements where fleet_id = v_fleet) then raise exception '% unexpected legacy fleet_movement', p_expect_okind; end if;

  raise notice 'ok positive %: one move, origin==resolved(%, %), speed==resolver(%), coherent fleet/ship/receipt%',
    p_expect_okind, v_ox, v_oy, v_speed, case when p_expect_okind = 'location' then ', presence closed once' else '' end;
end $$;

-- Rejection: assert ok=false (+ exact reason) AND no row mutated.
create or replace function s3_reject(p_player uuid, p_ship uuid, p_tx double precision, p_ty double precision, p_req uuid, p_expect_reason text) returns void language plpgsql as $$
declare h1 text; h2 text; r jsonb;
begin
  h1 := s3_state_hash();
  r := mainship_space_begin_move(p_player, p_ship, p_tx, p_ty, p_req);
  if (r->>'ok')::boolean is distinct from false then raise exception 'expected reject (%), got %', p_expect_reason, r; end if;
  if p_expect_reason is not null and (r->>'reason') is distinct from p_expect_reason then
    raise exception 'expected reason %, got %', p_expect_reason, r; end if;
  h2 := s3_state_hash();
  if h1 is distinct from h2 then raise exception 'MUTATION on reject (reason %): state hash changed', coalesce(p_expect_reason, r->>'reason'); end if;
  raise notice 'ok reject %: no mutation', coalesce(p_expect_reason, r->>'reason');
end $$;

-- ════════ SECTION 1 — flag OFF: feature_disabled (proves no write while disabled) ════════
do $$ declare s uuid; p uuid;
begin
  if (select value::text from game_config where key = 'mainship_space_movement_enabled') <> 'false' then raise exception 'precond: flag must start false'; end if;
  s := s3fix('legacy_home'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'feature_disabled');
  raise notice 'SECTION 1 ok: flag-off rejection';
end $$;

-- ════════ enable the writer ONLY in this disposable stack ════════
update game_config set value = 'true' where key = 'mainship_space_movement_enabled';

-- ════════ SECTION 2 — ANCHOR-1A: in_space is the ONLY anchored origin; home/location origins reject ════════
do $$ declare s uuid; p uuid;
begin
  -- legacy base/location coordinates are NOT canonical OSN positions → origin_not_anchored, no mutation.
  -- s3_reject proves the global state hash is unchanged → NO movement/fleet/receipt/presence written.
  s := s3fix('legacy_home');    select player_id into p from main_ship_instances where main_ship_id=s; perform s3_reject(p, s, 100,  50, gen_random_uuid(), 'origin_not_anchored');
  s := s3fix('home');           select player_id into p from main_ship_instances where main_ship_id=s; perform s3_reject(p, s, -80,  40, gen_random_uuid(), 'origin_not_anchored');
  s := s3fix('legacy_present'); select player_id into p from main_ship_instances where main_ship_id=s; perform s3_reject(p, s,  60, -30, gen_random_uuid(), 'origin_not_anchored');
  s := s3fix('at_location');    select player_id into p from main_ship_instances where main_ship_id=s; perform s3_reject(p, s, -55, -25, gen_random_uuid(), 'origin_not_anchored');
  -- in_space remains a real positive: movement.origin == authoritative ship space_x/y; speed==resolver.
  s := s3fix('in_space');       perform s3_run_ok(s,  12,  34, gen_random_uuid(), 'space');
  raise notice 'SECTION 2 ok: home/legacy_home/at_location/legacy_present → origin_not_anchored (no mutation); in_space positive (origin==resolved space coords)';
end $$;

-- ════════ SECTION 3 — rejection matrix (flag ON; each standalone + non-mutating + precondition-asserted) ════════
do $$ declare s uuid; p uuid; other uuid; o jsonb; ox double precision; oy double precision;
begin
  -- invalid_request_id (null request id)
  s := s3fix('legacy_home'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, null, 'invalid_request_id');
  -- invalid_coordinate (non-finite target)
  s := s3fix('legacy_home'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 'NaN'::double precision, 0, gen_random_uuid(), 'invalid_coordinate');
  -- target_out_of_bounds
  s := s3fix('legacy_home'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 20000, 0, gen_random_uuid(), 'target_out_of_bounds');
  -- origin_out_of_bounds (in_space resolved at 15000,0); assert the precondition first
  s := s3fix('in_space_oob'); select player_id into p from main_ship_instances where main_ship_id = s;
  o := mainship_space_resolve_origin(s);
  if (o->>'ok')::boolean is not true or abs((o->>'origin_x')::double precision) <= 10000 then raise exception 'origin_oob precond not met: %', o; end if;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'origin_out_of_bounds');
  -- zero_distance: derive the EXACT authoritative origin and use it as the target. ANCHOR-1A: in_space is
  -- the only origin resolve_origin still resolves, so the zero-distance path is reachable only from it.
  s := s3fix('in_space'); select player_id into p from main_ship_instances where main_ship_id = s;
  o := mainship_space_resolve_origin(s);
  if (o->>'ok')::boolean is not true then raise exception 'zero_distance precond: resolve not ok: %', o; end if;
  ox := (o->>'origin_x')::double precision; oy := (o->>'origin_y')::double precision;
  if ox is null or oy is null or ox = 'NaN'::double precision or oy = 'NaN'::double precision then raise exception 'zero_distance precond: origin not finite: %', o; end if;
  perform s3_reject(p, s, ox, oy, gen_random_uuid(), 'zero_distance');
  raise notice '  (zero_distance target == authoritative resolved origin %, %)', ox, oy;
  -- missing_ship
  perform s3_reject(s3fix_user(), gen_random_uuid(), 100, 50, gen_random_uuid(), 'missing_ship');
  -- not_owned
  s := s3fix('legacy_home'); other := s3fix_user();
  perform s3_reject(other, s, 100, 50, gen_random_uuid(), 'not_owned');
  -- destroyed (assert starting status first)
  s := s3fix('destroyed'); select player_id into p from main_ship_instances where main_ship_id = s;
  if (select status from main_ship_instances where main_ship_id = s) <> 'destroyed' then raise exception 'destroyed precond'; end if;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'destroyed');
  -- in_transit (new-domain) → in_transit_must_stop
  s := s3fix('in_transit'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'in_transit_must_stop');
  -- legacy_transit / active legacy fleet movement → active_legacy_movement (exclusion fires before resolve)
  s := s3fix('legacy_transit'); select player_id into p from main_ship_instances where main_ship_id = s;
  if not exists (select 1 from fleet_movements fm join fleets f on f.id = fm.fleet_id where f.main_ship_id = s and fm.status = 'moving') then raise exception 'legacy_transit precond: no active legacy movement'; end if;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'active_legacy_movement');
  -- malformed linkage: at_location with NO active presence → contradictory_state
  s := s3fix('at_location_nopres'); select player_id into p from main_ship_instances where main_ship_id = s;
  if exists (select 1 from location_presence lp join fleets f on f.id = lp.fleet_id where f.main_ship_id = s and lp.status = 'active') then raise exception 'nopres precond: an active presence exists'; end if;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'contradictory_state');
  -- mismatched required presence → contradictory_state
  s := s3fix('at_location_mispres'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'contradictory_state');
  -- active/inconsistent coordinate movement (in_space + active movement) → contradictory_state
  s := s3fix('in_space_with_movement'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'contradictory_state');
  -- pointer mismatch (fleet → terminal movement): validate catches it first as contradictory_state
  -- (the exclusion's coordinate_pointer_mismatch is defence-in-depth, unreachable through the writer).
  s := s3fix('in_transit_misptr'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'contradictory_state');
  -- active conflicting presence (in_space + active presence) → contradictory_state
  -- (the exclusion's presence_conflict is defence-in-depth, unreachable through the writer).
  s := s3fix('in_space_with_presence'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'contradictory_state');
  -- multiple active fleets
  s := s3fix('multi_fleet'); select player_id into p from main_ship_instances where main_ship_id = s;
  if (select count(*) from fleets where main_ship_id = s and status in ('idle','moving','present','returning')) <> 2 then raise exception 'multi_fleet precond'; end if;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'multiple_active_fleets');
  raise notice 'SECTION 3 ok: rejection matrix (all standalone, precondition-asserted, non-mutating)';
end $$;

-- ════════ SECTION 4 — unknown_spatial_state is schema-unreachable (writer branch is defensive-only) ════════
do $$ declare s uuid;
begin
  s := s3fix('legacy_home');
  begin
    update main_ship_instances set spatial_state = 'bogus_state' where main_ship_id = s;
    raise exception 'unknown_spatial_state: the 0054 domain CHECK failed to reject an invalid spatial_state';
  exception when check_violation then
    raise notice 'SECTION 4 ok: spatial_state domain CHECK rejects unknown values → writer unknown_spatial_state branch is unreachable by construction';
  end;
end $$;

-- ════════ SECTION 5 — travel-time cap (disposable cap toggle; explicit no-mutation) ════════
do $$ declare s uuid; p uuid; h1 text; h2 text; r jsonb; nf int; nm int; nr int;
begin
  update game_config set value = '1' where key = 'max_coordinate_travel_seconds';   -- force the cap (min_travel_seconds=5 > 1)
  s := s3fix('in_space'); select player_id into p from main_ship_instances where main_ship_id = s;  -- ANCHOR-1A: cap exercised from the valid in_space origin
  h1 := s3_state_hash();
  r := mainship_space_begin_move(p, s, 100, 50, gen_random_uuid());
  if (r->>'ok')::boolean is distinct from false or (r->>'reason') <> 'travel_time_exceeds_limit' then raise exception 'expected travel_time_exceeds_limit, got %', r; end if;
  h2 := s3_state_hash();
  if h1 is distinct from h2 then raise exception 'travel-time reject mutated state'; end if;
  -- explicit per-table no-effect assertions for this ship
  select count(*) into nf from fleets where main_ship_id = s;                          if nf <> 0 then raise exception 'travel-time: a fleet was materialised (%)', nf; end if;
  select count(*) into nm from main_ship_space_movements where main_ship_id = s;       if nm <> 0 then raise exception 'travel-time: a movement was created (%)', nm; end if;
  select count(*) into nr from main_ship_space_command_receipts where main_ship_id = s; if nr <> 0 then raise exception 'travel-time: a receipt was created (%)', nr; end if;
  perform 1 from main_ship_instances where main_ship_id = s and status = 'stationary' and spatial_state = 'in_space';
  if not found then raise exception 'travel-time: ship was mutated'; end if;
  update game_config set value = '86400' where key = 'max_coordinate_travel_seconds'; -- restore
  raise notice 'SECTION 5 ok: travel_time_exceeds_limit → no fleet/movement/receipt/ship/pointer/presence change (cap restored to 86400)';
end $$;

-- ════════ SECTION 6 — idempotency replay + payload conflict ════════
do $$ declare s uuid; p uuid; req uuid := gen_random_uuid(); r1 jsonb; r2 jsonb; stored jsonb; n int;
begin
  s := s3fix('in_space'); select player_id into p from main_ship_instances where main_ship_id = s;  -- ANCHOR-1A: replay exercised from the valid in_space origin
  r1 := mainship_space_begin_move(p, s, 70, 70, req);
  if (r1->>'ok')::boolean is not true then raise exception 'replay setup failed: %', r1; end if;
  select result_json into stored from main_ship_space_command_receipts where main_ship_id = s and request_id = req;
  -- replay: same request_id + same payload → identical result, no second movement/receipt
  r2 := mainship_space_begin_move(p, s, 70, 70, req);
  if r2 is distinct from r1 then raise exception 'replay returned a different result: % vs %', r2, r1; end if;
  if r2 is distinct from stored then raise exception 'replay result != committed receipt result_json'; end if;
  select count(*) into n from main_ship_space_movements where main_ship_id = s; if n <> 1 then raise exception 'replay created extra movement (n=%)', n; end if;
  select count(*) into n from main_ship_space_command_receipts where main_ship_id = s and request_id = req; if n <> 1 then raise exception 'replay created extra receipt (n=%)', n; end if;
  -- conflict: same request_id, CHANGED payload → request_id_payload_conflict, still one movement
  r2 := mainship_space_begin_move(p, s, 71, 71, req);
  if (r2->>'ok')::boolean is distinct from false or (r2->>'reason') <> 'request_id_payload_conflict' then raise exception 'expected payload conflict, got %', r2; end if;
  select count(*) into n from main_ship_space_movements where main_ship_id = s; if n <> 1 then raise exception 'conflict created extra movement (n=%)', n; end if;
  raise notice 'SECTION 6 ok: idempotent replay returns the committed receipt; changed payload → request_id_payload_conflict';
end $$;

-- ════════ disable the writer again ════════
update game_config set value = 'false' where key = 'mainship_space_movement_enabled';

-- ════════ cleanup + final assertions ════════
delete from auth.users where email like 'osn3s3fix.%@example.com';
do $$ declare n int;
begin
  select count(*) into n from main_ship_instances where player_id not in (select id from auth.users); if n <> 0 then raise exception 'CLEANUP FAIL: % orphan ships', n; end if;
  select count(*) into n from fleets where player_id not in (select id from auth.users); if n <> 0 then raise exception 'CLEANUP FAIL: % orphan fleets', n; end if;
  select count(*) into n from main_ship_space_movements m where not exists (select 1 from main_ship_instances s where s.main_ship_id = m.main_ship_id); if n <> 0 then raise exception 'CLEANUP FAIL: % orphan movements', n; end if;
  select count(*) into n from main_ship_space_command_receipts c where not exists (select 1 from main_ship_instances s where s.main_ship_id = c.main_ship_id); if n <> 0 then raise exception 'CLEANUP FAIL: % orphan receipts', n; end if;
  select count(*) into n from location_presence lp where lp.player_id not in (select id from auth.users); if n <> 0 then raise exception 'CLEANUP FAIL: % orphan presence', n; end if;
  select count(*) into n from auth.users where email like 'osn3s3fix.%@example.com'; if n <> 0 then raise exception 'CLEANUP FAIL: % fixture users remain', n; end if;
  raise notice 'ok cleanup: no fixture users/ships/fleets/movements/receipts/presence remain';
end $$;
drop function if exists s3_run_ok(uuid, double precision, double precision, uuid, text);
drop function if exists s3_reject(uuid, uuid, double precision, double precision, uuid, text);
drop function if exists s3_state_hash();
drop function if exists s3fix(text);
drop function if exists s3fix_user();
do $$ declare a text; b text; c text; begin
  select value::text into a from game_config where key = 'mainship_send_enabled';
  select value::text into b from game_config where key = 'mainship_space_movement_enabled';
  select value::text into c from game_config where key = 'max_coordinate_travel_seconds';
  if a is distinct from 'false' then raise exception 'FLAG FAIL: mainship_send_enabled=% (must be false/untouched)', a; end if;
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled=% (must be restored false)', b; end if;
  if c is distinct from '86400' then raise exception 'CONFIG FAIL: max_coordinate_travel_seconds=% (must be restored 86400)', c; end if;
  raise notice 'FLAG/CONFIG ok post-fixtures: send=false, space_movement=false, max_coordinate_travel_seconds=86400';
end $$;
select 'OSN-3 S3 REAL-CHAIN FIXTURE MATRIX: ALL PASSED' as result;
