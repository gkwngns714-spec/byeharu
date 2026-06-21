-- OSN-3 S3 — REAL-CHAIN writer fixture matrix for public.mainship_space_begin_move(...).
-- Builds each state from REAL rows (auth.users → bases → main_ship_instances → fleets →
-- movements/presence) satisfying the actual 0054/0055/0057 CHECKs, then exercises the writer:
--   • positive begin-move from every supported stationary origin (legacy_home / home /
--     legacy_present / at_location / in_space) with full ship/fleet/movement/pointer/receipt/presence
--     assertions;
--   • the full rejection matrix, each proven to mutate NO row (state hash before == after);
--   • idempotency replay (same request_id+payload → identical result, one movement) and conflict
--     (same request_id, changed payload → request_id_payload_conflict, no second movement).
-- Fixtures are marked by the 'osn3s3fix.' email prefix and removed at the end (cascade via auth.users).
-- The flag mainship_space_movement_enabled and the cap max_coordinate_travel_seconds are toggled ONLY
-- in this disposable stack and restored + asserted false/86400 at the end (the workflow nets a
-- best-effort restore too). NEVER touches the shared/live DB; NEVER touches mainship_send_enabled.

\set ON_ERROR_STOP on

create or replace function s3fix_user() returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated', 'authenticated',
          'osn3s3fix.'||replace(v::text,'-','')||'@example.com', '', now(), now(), now(), '', '', '', '');
  return v;
end $$;

-- Build a fixture of the given kind; returns the main_ship_id. Mirrors the S2 builder.
create or replace function s3fix(kind text) returns uuid language plpgsql as $$
declare
  v_u uuid := s3fix_user(); v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid();
  v_f2 uuid := gen_random_uuid(); v_m uuid := gen_random_uuid(); v_m_term uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_sec uuid := (select id from sectors order by sector_index limit 1);
  v_l1 uuid := (select id from locations order by id limit 1);
  v_l2 uuid := (select id from locations order by id offset 1 limit 1);
begin
  insert into bases (id, player_id, name, sector_id, x, y) values (v_b, v_u, 'fixbase', v_sec, 1, 2);

  if kind = 'legacy_home' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'home', null, 500, 500, 50, 10, 2, 3, v_s);
  elsif kind = 'home' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'home', 'home', 500, 500, 50, 10, 2, 3, v_s);
  elsif kind = 'in_space' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, space_x, space_y, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'stationary', 'in_space', 7, -9, 500, 500, 50, 10, 2, 3, v_s);
  elsif kind = 'in_space_oob' then  -- in_space, resolved origin OUTSIDE the movement envelope
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

  elsif kind = 'legacy_with_legacy_mv' then
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

-- Positive: run the writer and assert the full coherent post-state.
create or replace function s3_run_ok(p_ship uuid, p_tx double precision, p_ty double precision, p_req uuid, p_expect_okind text) returns void language plpgsql as $$
declare v_player uuid; r jsonb; v_mv uuid; v_fleet uuid;
begin
  select player_id into v_player from main_ship_instances where main_ship_id = p_ship;
  r := mainship_space_begin_move(v_player, p_ship, p_tx, p_ty, p_req);
  if (r->>'ok')::boolean is not true then raise exception '% expected ok, got %', p_expect_okind, r; end if;

  if (select count(*) from main_ship_space_movements where main_ship_id = p_ship and status = 'moving') <> 1 then
    raise exception '% expected exactly one moving movement', p_expect_okind; end if;
  select id, fleet_id into v_mv, v_fleet from main_ship_space_movements where main_ship_id = p_ship and status = 'moving';

  perform 1 from main_ship_space_movements m where m.id = v_mv
     and m.player_id = v_player and m.origin_kind = p_expect_okind and m.target_kind = 'space'
     and m.target_x = p_tx and m.target_y = p_ty and m.target_location_id is null and m.target_base_id is null
     and m.speed_used > 0 and m.depart_at < m.arrive_at;
  if not found then raise exception '% movement fields wrong: %', p_expect_okind, (select to_jsonb(m) from main_ship_space_movements m where m.id = v_mv); end if;

  perform 1 from fleets f where f.id = v_fleet and f.main_ship_id = p_ship and f.status = 'moving'
     and f.location_mode = 'movement' and f.active_space_movement_id = v_mv and f.active_movement_id is null
     and f.current_location_id is null and f.current_zone_id is null and f.current_sector_id is null;
  if not found then raise exception '% fleet pointer wrong: %', p_expect_okind, (select to_jsonb(f) from fleets f where f.id = v_fleet); end if;

  perform 1 from main_ship_instances s where s.main_ship_id = p_ship and s.status = 'traveling'
     and s.spatial_state = 'in_transit' and s.space_x is null and s.space_y is null;
  if not found then raise exception '% ship state wrong', p_expect_okind; end if;

  perform 1 from main_ship_space_command_receipts c where c.main_ship_id = p_ship and c.request_id = p_req
     and c.command_type = 'space_begin_move' and c.movement_id = v_mv and c.outcome_status = 'success'
     and (c.result_json->>'ok')::boolean is true and c.completed_at is not null;
  if not found then raise exception '% receipt wrong', p_expect_okind; end if;

  if p_expect_okind = 'location' and exists (select 1 from location_presence where fleet_id = v_fleet and status = 'active') then
    raise exception '% presence not closed', p_expect_okind; end if;
  if exists (select 1 from fleet_movements where fleet_id = v_fleet) then
    raise exception '% unexpected legacy fleet_movement created', p_expect_okind; end if;

  raise notice 'ok positive %: one moving move, coherent fleet/ship/receipt%', p_expect_okind,
    case when p_expect_okind = 'location' then ', presence closed' else '' end;
end $$;

-- Rejection: assert ok=false (+ optional exact reason) AND no row mutated.
create or replace function s3_reject(p_player uuid, p_ship uuid, p_tx double precision, p_ty double precision, p_req uuid, p_expect_reason text) returns void language plpgsql as $$
declare h1 text; h2 text; r jsonb;
begin
  h1 := s3_state_hash();
  r := mainship_space_begin_move(p_player, p_ship, p_tx, p_ty, p_req);
  if (r->>'ok')::boolean is distinct from false then raise exception 'expected reject, got %', r; end if;
  if p_expect_reason is not null and (r->>'reason') is distinct from p_expect_reason then
    raise exception 'expected reason %, got %', p_expect_reason, r; end if;
  h2 := s3_state_hash();
  if h1 is distinct from h2 then raise exception 'MUTATION on reject (reason %): state hash changed', coalesce(p_expect_reason, r->>'reason'); end if;
  raise notice 'ok reject %: no mutation', coalesce(p_expect_reason, r->>'reason');
end $$;

-- ════════ SECTION 1 — flag OFF: feature_disabled (and proves no write while disabled) ════════
do $$ declare s uuid; p uuid;
begin
  s := s3fix('legacy_home'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'feature_disabled');
  raise notice 'SECTION 1 ok: flag-off rejection';
end $$;

-- ════════ enable the writer ONLY in this disposable stack ════════
update game_config set value = 'true' where key = 'mainship_space_movement_enabled';

-- ════════ SECTION 2 — positive moves from every supported stationary origin ════════
do $$ declare s uuid;
begin
  s := s3fix('legacy_home');    perform s3_run_ok(s, 100,  50, gen_random_uuid(), 'base');
  s := s3fix('home');           perform s3_run_ok(s, -80,  40, gen_random_uuid(), 'base');
  s := s3fix('legacy_present'); perform s3_run_ok(s,  60, -30, gen_random_uuid(), 'location');
  s := s3fix('at_location');    perform s3_run_ok(s, -55, -25, gen_random_uuid(), 'location');
  s := s3fix('in_space');       perform s3_run_ok(s,  12,  34, gen_random_uuid(), 'space');
  raise notice 'SECTION 2 ok: positive moves from all five origins';
end $$;

-- ════════ SECTION 3 — rejection matrix (flag ON; each proven non-mutating) ════════
do $$ declare s uuid; p uuid; other uuid;
begin
  -- not owned
  s := s3fix('legacy_home'); other := s3fix_user();
  perform s3_reject(other, s, 100, 50, gen_random_uuid(), 'not_owned');
  -- missing ship
  perform s3_reject(s3fix_user(), gen_random_uuid(), 100, 50, gen_random_uuid(), 'missing_ship');
  -- destroyed
  s := s3fix('destroyed'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'destroyed');
  -- new-domain in_transit → in_transit_must_stop
  s := s3fix('in_transit'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'in_transit_must_stop');
  -- legacy transit / active legacy movement → active_legacy_movement
  s := s3fix('legacy_with_legacy_mv'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'active_legacy_movement');
  -- inconsistent coordinate pointer: validate (step 7) catches it as contradictory_state BEFORE the
  -- exclusion's coordinate_pointer_mismatch (step 8) could fire — i.e. the writer surfaces it as
  -- contradictory_state (defence-in-depth: no state passes validate yet fails the pointer exclusion).
  s := s3fix('in_transit_misptr'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'contradictory_state');
  -- in_space + active movement → contradictory_state (validate)
  s := s3fix('in_space_with_movement'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'contradictory_state');
  -- in_space + active presence → contradictory_state (validate)
  s := s3fix('in_space_with_presence'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'contradictory_state');
  -- multiple active fleets
  s := s3fix('multi_fleet'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'multiple_active_fleets');
  -- target out of bounds
  s := s3fix('legacy_home'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 20000, 0, gen_random_uuid(), 'target_out_of_bounds');
  -- resolved origin out of bounds (in_space at 15000,0)
  s := s3fix('in_space_oob'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'origin_out_of_bounds');
  -- non-finite input
  s := s3fix('legacy_home'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 'NaN'::double precision, 0, gen_random_uuid(), 'invalid_coordinate');
  -- exact zero-distance (home base is at (1,2))
  s := s3fix('legacy_home'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 1, 2, gen_random_uuid(), 'zero_distance');
  raise notice 'SECTION 3 ok: rejection matrix (all non-mutating)';
end $$;

-- ════════ SECTION 4 — travel-time cap (disposable cap toggle, restored after) ════════
do $$ declare s uuid; p uuid;
begin
  update game_config set value = '1' where key = 'max_coordinate_travel_seconds';   -- force the cap
  s := s3fix('legacy_home'); select player_id into p from main_ship_instances where main_ship_id = s;
  perform s3_reject(p, s, 100, 50, gen_random_uuid(), 'travel_time_exceeds_limit'); -- min_travel_seconds(5) > 1
  update game_config set value = '86400' where key = 'max_coordinate_travel_seconds'; -- restore
  raise notice 'SECTION 4 ok: travel_time_exceeds_limit (cap restored to 86400)';
end $$;

-- ════════ SECTION 5 — idempotency replay + payload conflict ════════
do $$ declare s uuid; p uuid; req uuid := gen_random_uuid(); r1 jsonb; r2 jsonb; n int;
begin
  s := s3fix('legacy_home'); select player_id into p from main_ship_instances where main_ship_id = s;
  r1 := mainship_space_begin_move(p, s, 70, 70, req);
  if (r1->>'ok')::boolean is not true then raise exception 'replay setup failed: %', r1; end if;
  -- replay: same request_id + same payload → identical result, no second movement/receipt
  r2 := mainship_space_begin_move(p, s, 70, 70, req);
  if r2 is distinct from r1 then raise exception 'replay returned a different result: % vs %', r2, r1; end if;
  select count(*) into n from main_ship_space_movements where main_ship_id = s; if n <> 1 then raise exception 'replay created extra movement (n=%)', n; end if;
  select count(*) into n from main_ship_space_command_receipts where main_ship_id = s and request_id = req; if n <> 1 then raise exception 'replay created extra receipt (n=%)', n; end if;
  -- conflict: same request_id, CHANGED payload → request_id_payload_conflict, still one movement
  r2 := mainship_space_begin_move(p, s, 71, 71, req);
  if (r2->>'ok')::boolean is distinct from false or (r2->>'reason') <> 'request_id_payload_conflict' then raise exception 'expected payload conflict, got %', r2; end if;
  select count(*) into n from main_ship_space_movements where main_ship_id = s; if n <> 1 then raise exception 'conflict created extra movement (n=%)', n; end if;
  raise notice 'SECTION 5 ok: idempotent replay + payload conflict';
end $$;

-- ════════ disable the writer again ════════
update game_config set value = 'false' where key = 'mainship_space_movement_enabled';

-- ════════ cleanup + final assertions ════════
delete from auth.users where email like 'osn3s3fix.%@example.com';
do $$ declare n int;
begin
  select count(*) into n from main_ship_instances where player_id not in (select id from auth.users); if n <> 0 then raise exception 'CLEANUP FAIL: % orphan ships', n; end if;
  select count(*) into n from main_ship_space_movements m where not exists (select 1 from main_ship_instances s where s.main_ship_id = m.main_ship_id); if n <> 0 then raise exception 'CLEANUP FAIL: % orphan movements', n; end if;
  select count(*) into n from main_ship_space_command_receipts c where not exists (select 1 from main_ship_instances s where s.main_ship_id = c.main_ship_id); if n <> 0 then raise exception 'CLEANUP FAIL: % orphan receipts', n; end if;
  select count(*) into n from main_ship_space_movements; raise notice 'ok cleanup: no fixture rows remain (coordinate-movement rows now = %)', n;
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
