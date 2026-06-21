-- OSN-3 S2 — REAL-CHAIN fixture matrix. Builds each state from REAL rows that satisfy the actual
-- 0054/0055 CHECKs (auth.users → bases → main_ship_instances → fleets → movements/presence), invokes
-- the helpers, and asserts validate/resolve/exclusion + no-mutation. Uses SEEDED sectors/zones/
-- locations from the world_map migration. Fixtures are marked by the 'osn3s2fix.' email prefix and
-- removed at the end (cascade via auth.users); the workflow also nets a best-effort cleanup. NEVER
-- touches the shared/live DB; NEVER updates a flag.

\set ON_ERROR_STOP on

create or replace function s2fix_user() returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated', 'authenticated',
          'osn3s2fix.'||replace(v::text,'-','')||'@example.com', '', now(), now(), now(), '', '', '', '');
  return v;
end $$;

create or replace function s2fix(kind text) returns uuid language plpgsql as $$
declare
  v_u uuid := s2fix_user(); v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid();
  v_m uuid := gen_random_uuid(); v_m_term uuid := gen_random_uuid(); v_b uuid := gen_random_uuid();
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
  elsif kind = 'at_location_nopres' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'stationary', 'at_location', 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, current_location_id, main_ship_id) values (v_f, v_u, v_b, 'present', 'location', v_l1, v_s);
  elsif kind = 'at_location_mispres' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'stationary', 'at_location', 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, current_location_id, main_ship_id) values (v_f, v_u, v_b, 'present', 'location', v_l1, v_s);
    insert into location_presence (player_id, fleet_id, status, location_id) values (v_u, v_f, 'active', v_l2);  -- presence at a DIFFERENT location

  elsif kind = 'in_transit' then
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'traveling', 'in_transit', 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, main_ship_id) values (v_f, v_u, v_b, 'moving', 'movement', v_s);
    insert into main_ship_space_movements (id, main_ship_id, fleet_id, player_id, origin_kind, origin_x, origin_y, target_kind, target_x, target_y, speed_used, depart_at, arrive_at)
      values (v_m, v_s, v_f, v_u, 'base', 0, 0, 'space', 100, 50, 1.0, now(), now() + interval '1 hour');
    update fleets set active_space_movement_id = v_m where id = v_f;
  elsif kind = 'in_transit_misptr' then  -- fleet pointer → a TERMINAL movement of the same ship, not the active one
    insert into main_ship_instances (player_id, hull_type_id, status, spatial_state, hp, max_hp, cargo_capacity, support_capacity, captain_slots, module_slots, main_ship_id)
      values (v_u, 'starter_frigate', 'traveling', 'in_transit', 500, 500, 50, 10, 2, 3, v_s);
    insert into fleets (id, player_id, origin_base_id, status, location_mode, main_ship_id) values (v_f, v_u, v_b, 'moving', 'movement', v_s);
    insert into main_ship_space_movements (id, main_ship_id, fleet_id, player_id, origin_kind, origin_x, origin_y, target_kind, target_x, target_y, speed_used, depart_at, arrive_at)
      values (v_m, v_s, v_f, v_u, 'base', 0, 0, 'space', 100, 50, 1.0, now(), now() + interval '1 hour');  -- the ACTIVE (moving) movement
    insert into main_ship_space_movements (id, main_ship_id, fleet_id, player_id, origin_kind, origin_x, origin_y, target_kind, target_x, target_y, speed_used, depart_at, arrive_at, status, resolved_at)
      values (v_m_term, v_s, v_f, v_u, 'base', 0, 0, 'space', 1, 1, 1.0, now() - interval '2 hour', now() - interval '1 hour', 'arrived', now());  -- a terminal movement
    update fleets set active_space_movement_id = v_m_term where id = v_f;  -- pointer ≠ the active moving movement

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

-- ── matrix ──────────────────────────────────────────────────────────────────────────────────────
do $$
declare s uuid; r jsonb;
begin
  s := s2fix('legacy_home');    r := mainship_space_validate_context(s); if r->>'state'<>'legacy_home' then raise exception 'legacy_home validate: %', r; end if;
                                r := mainship_space_resolve_origin(s);   if r->>'origin_kind'<>'base' then raise exception 'legacy_home resolve: %', r; end if; raise notice 'ok legacy_home → validate legacy_home / resolve base';
  s := s2fix('home');           r := mainship_space_validate_context(s); if r->>'state'<>'home' then raise exception 'home validate: %', r; end if;
                                r := mainship_space_resolve_origin(s);   if r->>'origin_kind'<>'base' then raise exception 'home resolve: %', r; end if; raise notice 'ok home → validate home / resolve base';
  s := s2fix('legacy_present'); r := mainship_space_validate_context(s); if r->>'state'<>'legacy_present' then raise exception 'legacy_present validate: %', r; end if;
                                r := mainship_space_resolve_origin(s);   if r->>'origin_kind'<>'location' then raise exception 'legacy_present resolve: %', r; end if; raise notice 'ok legacy_present → validate legacy_present / resolve location';
  s := s2fix('at_location');    r := mainship_space_validate_context(s); if r->>'state'<>'at_location' then raise exception 'at_location validate: %', r; end if;
                                r := mainship_space_resolve_origin(s);   if r->>'origin_kind'<>'location' then raise exception 'at_location resolve: %', r; end if; raise notice 'ok at_location → validate at_location / resolve location';
  s := s2fix('in_space');       r := mainship_space_validate_context(s); if r->>'state'<>'in_space' then raise exception 'in_space validate: %', r; end if;
                                r := mainship_space_resolve_origin(s);   if r->>'origin_kind'<>'space' then raise exception 'in_space resolve: %', r; end if; raise notice 'ok in_space → validate in_space / resolve space';
  s := s2fix('in_transit');     r := mainship_space_validate_context(s); if r->>'state'<>'in_transit' then raise exception 'in_transit validate: %', r; end if;
                                r := mainship_space_resolve_origin(s);   if r->>'reason'<>'in_transit_must_stop' then raise exception 'in_transit resolve: %', r; end if; raise notice 'ok in_transit → validate in_transit / resolve in_transit_must_stop';
  s := s2fix('destroyed');      r := mainship_space_validate_context(s); if r->>'state'<>'destroyed' then raise exception 'destroyed validate: %', r; end if;
                                r := mainship_space_resolve_origin(s);   if r->>'reason'<>'destroyed' then raise exception 'destroyed resolve: %', r; end if; raise notice 'ok destroyed → validate destroyed / resolve destroyed';

  s := s2fix('at_location_nopres');     r := mainship_space_validate_context(s); if (r->>'ok')::boolean then raise exception 'at_location_nopres should reject: %', r; end if; raise notice 'ok reject: missing active presence';
  s := s2fix('at_location_mispres');    r := mainship_space_validate_context(s); if (r->>'ok')::boolean then raise exception 'at_location_mispres should reject: %', r; end if; raise notice 'ok reject: mismatched active presence';
  s := s2fix('in_transit_misptr');      r := mainship_space_validate_context(s); if (r->>'ok')::boolean then raise exception 'in_transit_misptr should reject: %', r; end if; raise notice 'ok reject: mismatched fleet/movement pointer';
  s := s2fix('in_space_with_movement'); r := mainship_space_validate_context(s); if (r->>'ok')::boolean then raise exception 'in_space_with_movement should reject: %', r; end if; raise notice 'ok reject: in_space + active coordinate movement';
  s := s2fix('in_space_with_presence'); r := mainship_space_validate_context(s); if (r->>'ok')::boolean then raise exception 'in_space_with_presence should reject: %', r; end if; raise notice 'ok reject: in_space + active presence';

  -- mismatched player/ship/fleet ownership: in_transit movement whose player_id ≠ ship's player
  s := s2fix('in_transit'); update main_ship_space_movements set player_id = gen_random_uuid() where main_ship_id = s and status='moving';
  r := mainship_space_validate_context(s); if (r->>'ok')::boolean then raise exception 'mismatched player should reject: %', r; end if; raise notice 'ok reject: mismatched player/ship/fleet ownership';

  -- exclusion
  s := s2fix('legacy_with_legacy_mv'); r := mainship_space_assert_cross_domain_exclusion(s); if r->>'reason'<>'active_legacy_movement' then raise exception 'exclusion legacy mv: %', r; end if; raise notice 'ok exclusion: active legacy movement rejected';
  s := s2fix('in_transit');            r := mainship_space_assert_cross_domain_exclusion(s); if (r->>'ok')::boolean is not true then raise exception 'exclusion consistent in_transit should pass: %', r; end if; raise notice 'ok exclusion: consistent coordinate transit passes';
  s := s2fix('in_transit_misptr');     r := mainship_space_assert_cross_domain_exclusion(s); if r->>'reason'<>'coordinate_pointer_mismatch' then raise exception 'exclusion mismatch: %', r; end if; raise notice 'ok exclusion: pointer mismatch rejected';
  raise notice 'MATRIX ok';
end $$;

-- NO MUTATION
do $$ declare s uuid; h1 text; h2 text;
begin
  s := s2fix('at_location');
  select md5(coalesce(string_agg(t,''),'')) into h1 from (
    select md5(main_ship_instances::text) t from main_ship_instances union all select md5(fleets::text) from fleets union all
    select md5(main_ship_space_movements::text) from main_ship_space_movements union all select md5(location_presence::text) from location_presence union all
    select md5(fleet_movements::text) from fleet_movements union all select md5(main_ship_space_command_receipts::text) from main_ship_space_command_receipts) z;
  perform mainship_space_lock_context(s, false);
  perform mainship_space_validate_context(s);
  perform mainship_space_resolve_origin(s);
  perform mainship_space_assert_cross_domain_exclusion(s);
  select md5(coalesce(string_agg(t,''),'')) into h2 from (
    select md5(main_ship_instances::text) t from main_ship_instances union all select md5(fleets::text) from fleets union all
    select md5(main_ship_space_movements::text) from main_ship_space_movements union all select md5(location_presence::text) from location_presence union all
    select md5(fleet_movements::text) from fleet_movements union all select md5(main_ship_space_command_receipts::text) from main_ship_space_command_receipts) z;
  if h1 is distinct from h2 then raise exception 'MUTATION FAIL: a helper changed a row'; end if;
  raise notice 'ok no-mutation: lock/validate/resolve/exclusion changed no row';
end $$;

-- ── cleanup + assertions ──────────────────────────────────────────────────────────────────────
delete from auth.users where email like 'osn3s2fix.%@example.com';
do $$ declare n int;
begin
  select count(*) into n from main_ship_instances where player_id not in (select id from auth.users); if n<>0 then raise exception 'CLEANUP FAIL: % orphan ships', n; end if;
  select count(*) into n from main_ship_space_movements m where not exists (select 1 from main_ship_instances s where s.main_ship_id = m.main_ship_id); if n<>0 then raise exception 'CLEANUP FAIL: % orphan movements', n; end if;
  select count(*) into n from main_ship_space_movements; raise notice 'ok cleanup: no fixture ships/movements remain (total coordinate-movement rows now = %)', n;
end $$;
drop function if exists s2fix(text); drop function if exists s2fix_user();
do $$ declare a text; b text; begin
  select value::text into a from game_config where key='mainship_send_enabled';
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  if a is distinct from 'false' or b is distinct from 'false' then raise exception 'FLAG FAIL post-fixtures: send=% space=%', a, b; end if;
  raise notice 'FLAG ok post-fixtures: both false';
end $$;
select 'OSN-3 S2 REAL-CHAIN FIXTURE MATRIX: ALL PASSED' as result;
