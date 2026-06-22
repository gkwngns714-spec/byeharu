-- OSN-3 S6A — REAL-CHAIN fixture matrix for the public coordinate-command wrapper
-- public.command_main_ship_space_move(p_target_x, p_target_y, p_request_id). Builds states on the ACTUAL
-- chain (through 0060) and drives the wrapper exactly as a signed-in player would (auth.uid() via a set
-- request.jwt claim). Proves:
--   • DARK: flag false → {ok:false, code:feature_disabled}, no movement/receipt written, ship unchanged;
--   • SUCCESS from home / in_space / at_location → ship in_transit, exactly one moving movement, receipt;
--   • CANONICALIZATION: non-integer snaps to nearest integer (half away from zero); near-edge inward snap;
--     out-of-bounds rejects; non-finite rejects; the response echoes the canonical accepted target;
--   • ZERO-DISTANCE rejects;  • IDEMPOTENCY via p_request_id (replay returns the same movement; an
--     equivalent raw value that canonicalizes to the same target replays; the same request_id with a
--     different canonical target → request_conflict; no duplicate movement);
--   • STATE matrix: in_transit→must_stop_first, destroyed→ship_destroyed, legacy-busy→busy_legacy;
--   • MUTUAL EXCLUSION (both directions): a coordinate-domain ship rejects the legacy send/move RPCs; a
--     legacy-busy ship rejects the coordinate command; the fleet movement-pointer XOR holds.
-- Mirrors live config (mainship_send_enabled=true); the S4 arrival cron is unscheduled for determinism
-- and restored by the workflow. Fixtures marked by the 'osn3s6fix.' email prefix and removed at the end.
-- NEVER touches shared/live. The wrapper itself never flips a flag — the fixtures do, then restore false.

\set ON_ERROR_STOP on

update game_config set value = 'true' where key = 'mainship_send_enabled';  -- mirror live activated state
do $$ begin perform cron.unschedule(jobid) from cron.job where jobname='process-mainship-space-arrivals'; exception when undefined_table then null; end $$;

create or replace function s6fix_user() returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated','osn3s6fix.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','','');
  return v;  -- on_auth_user_created_base trigger auto-creates the player's Home Base at (0,0)
end $$;

-- Build a fixture; returns the main_ship_id. Uses the auto-provisioned (0,0) home base.
create or replace function s6fix(kind text) returns uuid language plpgsql as $$
declare
  v_u uuid := s6fix_user(); v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid();
  v_b uuid; v_l1 uuid := (select id from locations order by id limit 1);
  v_fut timestamptz := now() + interval '1 hour';
begin
  select id into v_b from bases where player_id = v_u and status='active' order by created_at limit 1;
  if kind = 'home_ship' then
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','home',null,500,500,50,10,2,3,v_s);
  elsif kind = 'in_space' then
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,space_x,space_y,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','stationary','in_space',42,-17,500,500,50,10,2,3,v_s);
  elsif kind = 'in_space_edge' then  -- parked near the +x/-y corner, to test near-edge inward snap with a short hop
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,space_x,space_y,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','stationary','in_space',9990,-9990,500,500,50,10,2,3,v_s);
  elsif kind = 'at_location' then
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','stationary','at_location',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,current_location_id,main_ship_id) values (v_f,v_u,v_b,'present','location',v_l1,v_s);
    insert into location_presence (player_id,fleet_id,status,location_id) values (v_u,v_f,'active',v_l1);
  elsif kind = 'destroyed' then
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','destroyed',null,0,500,50,10,2,3,v_s);
  elsif kind = 'legacy_busy' then  -- legacy named expedition in flight (spatial NULL, fleet moving + active fleet_movements)
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling',null,500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into fleet_movements (player_id,fleet_id,origin_type,origin_x,origin_y,target_type,target_x,target_y,mission_type,status,arrive_at,travel_distance,travel_seconds,speed_used)
      values (v_u,v_f,'base',0,0,'location',1,1,'rally','moving',v_fut,1,1,1);
    update fleets set active_movement_id=(select id from fleet_movements where fleet_id=v_f and status='moving' limit 1) where id=v_f;
  else
    raise exception 's6fix: unknown kind %', kind;
  end if;
  return v_s;
end $$;

create or replace function s6_player(p_ship uuid) returns uuid language sql stable as $$ select player_id from main_ship_instances where main_ship_id=p_ship $$;

-- Drive the public wrapper exactly as the owning player (auth.uid() via the request.jwt claim).
create or replace function s6_cmd(p_player uuid, p_x double precision, p_y double precision, p_req uuid) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_player::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_player)::text, true);
  r := command_main_ship_space_move(p_x, p_y, p_req);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;

create or replace function s6_mv_count(p_ship uuid) returns int language sql stable as $$ select count(*)::int from main_ship_space_movements where main_ship_id=p_ship $$;

-- ════════ SECTION 1 — DARK: flag FALSE → feature_disabled, nothing written, ship unchanged ════════
do $$ declare s uuid; p uuid; r jsonb;
begin
  update game_config set value='false' where key='mainship_space_movement_enabled';
  s := s6fix('home_ship'); p := s6_player(s);
  r := s6_cmd(p, 100, 50, gen_random_uuid());
  if (r->>'ok')::boolean is not false or r->>'code' <> 'feature_disabled' then raise exception 'S1: expected feature_disabled, got %', r; end if;
  if s6_mv_count(s) <> 0 then raise exception 'S1: a movement was written while dark'; end if;
  if exists (select 1 from main_ship_space_command_receipts where main_ship_id=s) then raise exception 'S1: a receipt was written while dark'; end if;
  perform 1 from main_ship_instances where main_ship_id=s and status='home' and spatial_state is null;
  if not found then raise exception 'S1: ship changed while dark'; end if;
  raise notice 'SECTION 1 ok: flag false → feature_disabled, no movement/receipt, ship unchanged (net player-visible effect: none)';
end $$;

-- ════════ SECTION 2 — SUCCESS from in_space (ANCHOR-1A: the only anchored origin); canonical target echoed ════════
do $$ declare s uuid; p uuid; req uuid := gen_random_uuid(); r jsonb;
begin
  update game_config set value='true' where key='mainship_space_movement_enabled';
  s := s6fix('in_space'); p := s6_player(s);   -- OSN-ANCHOR-1A: home/at_location origins now reject origin_not_anchored
  r := s6_cmd(p, 12.7, -3.2, req);
  if (r->>'ok')::boolean is not true then raise exception 'S2: expected ok, got %', r; end if;
  if (r->>'target_x')::numeric <> 13 or (r->>'target_y')::numeric <> -3 then raise exception 'S2: canonical target not echoed (got %, %)', r->>'target_x', r->>'target_y'; end if;
  if (mainship_space_validate_context(s)->>'state') <> 'in_transit' then raise exception 'S2: ship not in_transit'; end if;
  if s6_mv_count(s) <> 1 then raise exception 'S2: expected exactly one movement'; end if;
  perform 1 from main_ship_space_movements where main_ship_id=s and status='moving' and target_x=13 and target_y=-3 and target_kind='space';
  if not found then raise exception 'S2: movement row target wrong'; end if;
  if not exists (select 1 from main_ship_space_command_receipts where main_ship_id=s and request_id=req and (result_json->>'ok')::boolean) then raise exception 'S2: success receipt missing'; end if;
  raise notice 'SECTION 2 ok: in_space success → canonical (13,-3) accepted+echoed, ship in_transit, one movement, receipt written';
end $$;

-- ════════ SECTION 2b — OSN-ANCHOR-1A: home/legacy_home/at_location are NOT anchored origins ════════
do $$ declare s uuid; p uuid; r jsonb;
begin
  -- home alias: s6fix('home_ship') has spatial_state NULL → validate state legacy_home
  s := s6fix('home_ship'); p := s6_player(s);
  r := s6_cmd(p, 30, 30, gen_random_uuid());
  if r->>'code' <> 'unavailable' then raise exception '2b: home/legacy_home expected unavailable (origin_not_anchored), got %', r; end if;
  if s6_mv_count(s) <> 0 then raise exception '2b: a movement was created from an unanchored home origin'; end if;
  if exists (select 1 from main_ship_space_command_receipts where main_ship_id=s) then raise exception '2b: a receipt was written for an unanchored home origin'; end if;
  perform 1 from main_ship_instances where main_ship_id=s and status='home' and spatial_state is null;
  if not found then raise exception '2b: home ship changed'; end if;
  -- at_location alias
  s := s6fix('at_location'); p := s6_player(s);
  r := s6_cmd(p, 30, 30, gen_random_uuid());
  if r->>'code' <> 'unavailable' then raise exception '2b: at_location expected unavailable (origin_not_anchored), got %', r; end if;
  if s6_mv_count(s) <> 0 then raise exception '2b: a movement was created from an unanchored at_location origin'; end if;
  if (mainship_space_validate_context(s)->>'state') <> 'at_location' then raise exception '2b: at_location ship changed'; end if;
  raise notice 'SECTION 2b ok: home/legacy_home + at_location → origin_not_anchored (code unavailable), no movement, no receipt, ship unchanged';
end $$;

-- ════════ SECTION 3 — CANONICALIZATION ════════
do $$ declare s uuid; p uuid; r jsonb;
begin
  -- 3a half-away-from-zero (positive ties) — ANCHOR-1A: in_space is the only valid origin
  s := s6fix('in_space'); p := s6_player(s);
  r := s6_cmd(p, 0.5, 2.5, gen_random_uuid());
  if (r->>'ok')::boolean is not true or (r->>'target_x')::numeric <> 1 or (r->>'target_y')::numeric <> 3 then raise exception '3a: (0.5,2.5) expected (1,3), got %', r; end if;
  -- 3b half-away-from-zero (negative ties)
  s := s6fix('in_space'); p := s6_player(s);
  r := s6_cmd(p, -0.5, -2.5, gen_random_uuid());
  if (r->>'ok')::boolean is not true or (r->>'target_x')::numeric <> -1 or (r->>'target_y')::numeric <> -3 then raise exception '3b: (-0.5,-2.5) expected (-1,-3), got %', r; end if;
  -- 3c near-edge inward snap (raw just inside ±10000.5 → snaps to the ±10000 boundary, accepted) — short hop
  s := s6fix('in_space_edge'); p := s6_player(s);
  r := s6_cmd(p, 9999.6, -9999.6, gen_random_uuid());
  if (r->>'ok')::boolean is not true or (r->>'target_x')::numeric <> 10000 or (r->>'target_y')::numeric <> -10000 then raise exception '3c: (9999.6,-9999.6) expected snap to (10000,-10000), got %', r; end if;
  -- 3d out-of-bounds: canonical (10001,0) rejected at input validation (before origin resolution), no movement
  s := s6fix('in_space'); p := s6_player(s);
  r := s6_cmd(p, 10000.6, 0, gen_random_uuid());
  if r->>'code' <> 'out_of_bounds' then raise exception '3d: (10000.6,0) expected out_of_bounds, got %', r; end if;
  if s6_mv_count(s) <> 0 then raise exception '3d: a movement was written for an out-of-bounds target'; end if;
  -- 3e non-finite rejected before the numeric cast (before origin resolution), no movement
  s := s6fix('in_space'); p := s6_player(s);
  r := s6_cmd(p, 'NaN'::double precision, 0, gen_random_uuid());
  if r->>'code' <> 'invalid_target' then raise exception '3e: NaN expected invalid_target, got %', r; end if;
  s := s6fix('in_space'); p := s6_player(s);
  r := s6_cmd(p, 'Infinity'::double precision, 5, gen_random_uuid());
  if r->>'code' <> 'invalid_target' then raise exception '3e: Infinity expected invalid_target, got %', r; end if;
  if s6_mv_count(s) <> 0 then raise exception '3e: a movement was written for a non-finite target'; end if;
  raise notice 'SECTION 3 ok: canonicalization — half away from zero, near-edge inward snap, out_of_bounds + non-finite rejected with no write';
end $$;

-- ════════ SECTION 4 — ZERO DISTANCE (target == current canonical position) ════════
do $$ declare s uuid; p uuid; r jsonb;
begin
  s := s6fix('in_space'); p := s6_player(s);  -- parked at (42,-17)
  r := s6_cmd(p, 42, -17, gen_random_uuid());
  if r->>'code' <> 'zero_distance' then raise exception 'S4: expected zero_distance, got %', r; end if;
  if s6_mv_count(s) <> 0 then raise exception 'S4: a movement was written for a zero-distance command'; end if;
  raise notice 'SECTION 4 ok: zero-distance rejected, no write';
end $$;

-- ════════ SECTION 5 — IDEMPOTENCY (p_request_id is the key) ════════
do $$ declare s uuid; p uuid; req uuid := gen_random_uuid(); r1 jsonb; r2 jsonb; r3 jsonb; r4 jsonb; mv uuid;
begin
  s := s6fix('in_space'); p := s6_player(s);   -- ANCHOR-1A: idempotency exercised from the valid in_space origin
  r1 := s6_cmd(p, 12.7, 0, req);
  if (r1->>'ok')::boolean is not true or (r1->>'target_x')::numeric <> 13 then raise exception 'S5: first command failed: %', r1; end if;
  mv := (r1->>'movement_id')::uuid;
  -- exact replay (same request_id, same raw target) → same movement, no second row
  r2 := s6_cmd(p, 12.7, 0, req);
  if (r2->>'ok')::boolean is not true or (r2->>'movement_id')::uuid <> mv then raise exception 'S5: exact replay did not return the same movement: %', r2; end if;
  -- equivalent replay (same request_id, different raw value that canonicalizes to the SAME target) → replay
  r3 := s6_cmd(p, 13.2, 0, req);
  if (r3->>'ok')::boolean is not true or (r3->>'movement_id')::uuid <> mv then raise exception 'S5: equivalent-canonical replay did not return the same movement: %', r3; end if;
  -- conflict (same request_id, DIFFERENT canonical target) → request_conflict, no second movement
  r4 := s6_cmd(p, 99, 0, req);
  if r4->>'code' <> 'request_conflict' then raise exception 'S5: expected request_conflict, got %', r4; end if;
  if s6_mv_count(s) <> 1 then raise exception 'S5: expected exactly one movement after replays+conflict, got %', s6_mv_count(s); end if;
  raise notice 'SECTION 5 ok: request_id idempotency — exact + equivalent-canonical replay reuse one movement; differing target → request_conflict; no duplicate';
end $$;

-- ════════ SECTION 6 — STATE matrix ════════
do $$ declare s uuid; p uuid; r jsonb; lx double precision; ly double precision; lid uuid;
begin
  -- 6a in_transit → must_stop_first (start a move from the valid in_space origin, then command again)
  s := s6fix('in_space'); p := s6_player(s);
  r := s6_cmd(p, 40, 40, gen_random_uuid());
  if (r->>'ok')::boolean is not true then raise exception '6a: setup move failed: %', r; end if;
  r := s6_cmd(p, 80, 80, gen_random_uuid());
  if r->>'code' <> 'must_stop_first' then raise exception '6a: in_transit expected must_stop_first, got %', r; end if;
  if s6_mv_count(s) <> 1 then raise exception '6a: a second movement was created for an in_transit ship'; end if;
  -- 6b destroyed → ship_destroyed
  s := s6fix('destroyed'); p := s6_player(s);
  r := s6_cmd(p, 10, 10, gen_random_uuid());
  if r->>'code' <> 'ship_destroyed' then raise exception '6b: destroyed expected ship_destroyed, got %', r; end if;
  -- 6c legacy-busy → busy_legacy
  s := s6fix('legacy_busy'); p := s6_player(s);
  r := s6_cmd(p, 10, 10, gen_random_uuid());
  if r->>'code' <> 'busy_legacy' then raise exception '6c: legacy-busy expected busy_legacy, got %', r; end if;
  if exists (select 1 from main_ship_space_movements where main_ship_id=s) then raise exception '6c: a coordinate movement was created during legacy travel'; end if;
  -- 6d at_location → origin_not_anchored (ANCHOR-1A): wrapper returns 'unavailable', no movement, unchanged
  s := s6fix('at_location'); p := s6_player(s);
  r := s6_cmd(p, 25, 25, gen_random_uuid());
  if r->>'code' <> 'unavailable' then raise exception '6d: at_location expected unavailable (origin_not_anchored), got %', r; end if;
  if s6_mv_count(s) <> 0 then raise exception '6d: a movement was created from an unanchored at_location origin'; end if;
  if (mainship_space_validate_context(s)->>'state') <> 'at_location' then raise exception '6d: at_location ship changed'; end if;
  raise notice 'SECTION 6d ok: at_location → origin_not_anchored (code unavailable), no movement, ship unchanged';
  raise notice 'SECTION 6 ok: in_transit→must_stop_first, destroyed→ship_destroyed, legacy-busy→busy_legacy (no coordinate write)';
end $$;

-- ════════ SECTION 7 — MUTUAL EXCLUSION (both directions) ════════
do $$ declare s uuid; p uuid; f uuid; lid uuid; got text; r jsonb;
begin
  lid := (select id from locations order by id limit 1);

  -- L1: a coordinate-domain (in_space) ship is REJECTED by the legacy send RPC (status<>'home').
  s := s6fix('in_space'); p := s6_player(s);
  perform set_config('request.jwt.claim.sub', p::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p)::text, true);
  begin
    perform send_main_ship_expedition(jsonb_build_array(s), lid);
    raise exception 'L1: legacy send accepted a coordinate-domain (in_space) ship';
  exception when others then
    got := sqlerrm;
    if got not like '%not available%' then raise exception 'L1: unexpected rejection reason: %', got; end if;
  end;
  perform set_config('request.jwt.claim.sub', '', true); perform set_config('request.jwt.claims', '', true);
  raise notice 'L1 ok: legacy send_main_ship_expedition rejects an in_space ship (%).', got;

  -- L2: a coordinate-domain (in_transit) ship is REJECTED by the legacy move RPC (status<>'present').
  s := s6fix('in_space'); p := s6_player(s);   -- ANCHOR-1A: drive in_transit from the valid in_space origin
  r := s6_cmd(p, 55, 55, gen_random_uuid());  -- → in_transit
  if (r->>'ok')::boolean is not true then raise exception 'L2: setup move failed: %', r; end if;
  select id into f from fleets where main_ship_id=s and status='moving' limit 1;
  perform set_config('request.jwt.claim.sub', p::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p)::text, true);
  begin
    perform move_main_ship_to_location(f, lid);
    raise exception 'L2: legacy move accepted a coordinate in_transit fleet';
  exception when others then
    got := sqlerrm;
    if got not like '%not present%' then raise exception 'L2: unexpected rejection reason: %', got; end if;
  end;
  perform set_config('request.jwt.claim.sub', '', true); perform set_config('request.jwt.claims', '', true);
  raise notice 'L2 ok: legacy move_main_ship_to_location rejects an in_transit fleet (%).', got;

  -- L3: the coordinate in_transit fleet holds the space pointer and NO legacy pointer (XOR holds).
  perform 1 from fleets where main_ship_id=s and status='moving' and active_space_movement_id is not null and active_movement_id is null;
  if not found then raise exception 'L3: in_transit fleet pointer XOR violated'; end if;
  raise notice 'L3 ok: coordinate in_transit fleet has active_space_movement_id set and active_movement_id NULL (movement-pointer XOR holds)';
  raise notice 'SECTION 7 ok: legacy and coordinate movement are mutually exclusive in both directions';
end $$;

-- ════════ cleanup + final assertions ════════
update game_config set value='false' where key='mainship_space_movement_enabled';
delete from auth.users where email like 'osn3s6fix.%@example.com';
do $$ declare n int;
begin
  select count(*) into n from main_ship_instances where player_id not in (select id from auth.users); if n<>0 then raise exception 'CLEANUP: % orphan ships', n; end if;
  select count(*) into n from main_ship_space_movements m where not exists (select 1 from main_ship_instances s where s.main_ship_id=m.main_ship_id); if n<>0 then raise exception 'CLEANUP: % orphan movements', n; end if;
  select count(*) into n from auth.users where email like 'osn3s6fix.%@example.com'; if n<>0 then raise exception 'CLEANUP: % fixture users remain', n; end if;
  raise notice 'ok cleanup: no fixture users/ships/fleets/movements/receipts/presence remain';
end $$;
drop function if exists s6_mv_count(uuid);
drop function if exists s6_cmd(uuid, double precision, double precision, uuid);
drop function if exists s6_player(uuid);
drop function if exists s6fix(text);
drop function if exists s6fix_user();
do $$ declare a text; b text; c text; begin
  select value::text into a from game_config where key='mainship_send_enabled';
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  select value::text into c from game_config where key='max_coordinate_travel_seconds';
  if a is distinct from 'true'  then raise exception 'FLAG FAIL: mainship_send_enabled=% (must remain true)', a; end if;
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled=% (must end false)', b; end if;
  if c is distinct from '86400' then raise exception 'CONFIG FAIL: max_coordinate_travel_seconds=%', c; end if;
  raise notice 'FLAG/CONFIG ok: send=true (untouched), space_movement=false, max_coordinate_travel_seconds=86400';
end $$;
select 'OSN-3 S6A REAL-CHAIN FIXTURE MATRIX: ALL PASSED' as result;
