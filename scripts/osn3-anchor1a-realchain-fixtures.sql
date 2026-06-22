-- OSN-ANCHOR-1A — REAL-CHAIN proof for the truthful-origin guard (migration 0062). Runs via psql against a
-- DISPOSABLE local Supabase stack whose schema is the ACTUAL migration chain 0001..0062 (NOT a stub, NOT
-- the shared/live DB). Proves:
--   1. home / legacy_home → origin_not_anchored; no movement; no receipt; no base-origin movement created.
--   2. at_location / legacy_present → origin_not_anchored; no movement; no receipt; no location-origin movement.
--   3. in_space → success; movement origin_x/y == ship space_x/y (canonical); travel time derives from that
--      origin; target_kind='space'.
--   4. Rejected-request idempotency: an origin_not_anchored attempt writes NO receipt; after the SAME ship is
--      truthfully placed in_space, the SAME request_id creates exactly one movement + one receipt; a replay
--      after success is idempotent.
--   5. No legacy leakage through the WRITER: every begin_move-created movement has origin_kind='space'; the
--      resolver source no longer reads bases/locations as an origin (asserted in the PARITY block). NOTE: a
--      direct trusted INSERT may hold arbitrary coordinates — that is not claimed otherwise; the guard
--      constrains the writer's resolved origin only.
--   6. Non-regression: cross-domain exclusion unchanged (legacy-busy → active_legacy_movement BEFORE the
--      resolver); destruction + repair compatible; DOCK-0 unchanged + unreachable from the public route;
--      resolver ACL/security/signature parity (service_role-only, SECDEF, search_path=public); flags unchanged.
-- Toggles mainship_space_movement_enabled ONLY in this disposable stack and restores false at the end.
-- Fixtures marked by the 'osn3anchor1a.' email prefix and removed at the end. NEVER touches shared/live.

\set ON_ERROR_STOP on

update game_config set value='true' where key='mainship_send_enabled';  -- mirror live activated state
do $$ begin perform cron.unschedule(jobid) from cron.job where jobname='process-mainship-space-arrivals'; exception when undefined_table then null; end $$;

-- ════════ ACL / SECURITY / SIGNATURE PARITY (resolver must match the pre-0062 invariant) ════════
\echo ''
\echo '================= ANCHOR-1A RESOLVER DESCRIPTOR ================='
select p.proname,
       pg_get_function_identity_arguments(p.oid) as identity_args,
       p.prosecdef as security_definer, p.proconfig as function_config,
       pg_get_userbyid(p.proowner) as owner,
       has_function_privilege('anon', p.oid, 'EXECUTE')          as anon_x,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_x,
       has_function_privilege('service_role', p.oid, 'EXECUTE')  as srv_x,
       p.proacl::text as acl
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'mainship_space_resolve_origin';

do $$
declare r record;
begin
  select p.oid, p.prosecdef, p.proconfig, p.proacl,
         pg_get_function_identity_arguments(p.oid) as args,
         pg_get_userbyid(p.proowner) as owner,
         pg_get_functiondef(p.oid) as def
    into r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'mainship_space_resolve_origin';
  if r.oid is null then raise exception 'PARITY FAIL: resolver not installed'; end if;
  -- signature unchanged (pre-0062 invariant)
  if r.args is distinct from 'p_main_ship_id uuid' then raise exception 'PARITY FAIL: resolver signature changed: %', r.args; end if;
  -- security model unchanged
  if not r.prosecdef then raise exception 'PARITY FAIL: resolver not SECURITY DEFINER'; end if;
  if r.proconfig is null or not ('search_path=public' = any(r.proconfig)) then raise exception 'PARITY FAIL: resolver search_path not pinned to public (%)', r.proconfig; end if;
  if r.owner <> 'postgres' then raise exception 'PARITY FAIL: resolver owner=% (expected postgres)', r.owner; end if;
  -- grants unchanged: service_role only; anon/authenticated/PUBLIC denied
  if has_function_privilege('anon', r.oid, 'EXECUTE') then raise exception 'PARITY FAIL: anon can EXECUTE the resolver'; end if;
  if has_function_privilege('authenticated', r.oid, 'EXECUTE') then raise exception 'PARITY FAIL: authenticated can EXECUTE the resolver'; end if;
  if not has_function_privilege('service_role', r.oid, 'EXECUTE') then raise exception 'PARITY FAIL: service_role cannot EXECUTE the resolver'; end if;
  if r.proacl is null then raise exception 'PARITY FAIL: resolver has null proacl (defaults to PUBLIC EXECUTE)'; end if;
  if exists (select 1 from unnest(r.proacl) a where a::text like '=%') then raise exception 'PARITY FAIL: resolver grants EXECUTE to PUBLIC'; end if;
  -- no dynamic SQL; no legacy-coordinate ORIGIN source (no SELECT ... FROM bases / FROM locations)
  if r.def ~* 'execute format' or strpos(lower(r.def), 'execute ''') > 0 then raise exception 'PARITY FAIL: resolver uses dynamic SQL'; end if;
  if r.def ~* 'from\s+bases\M' then raise exception 'LEAK FAIL: resolver still reads FROM bases as an origin source'; end if;
  if r.def ~* 'from\s+locations\M' then raise exception 'LEAK FAIL: resolver still reads FROM locations as an origin source'; end if;
  raise notice 'PARITY ok: resolver SECDEF, search_path=public, owner=postgres, service_role-only (anon/auth/PUBLIC denied), signature (p_main_ship_id uuid), no dynamic SQL, no bases/locations origin read';
end $$;

-- ════════ fixtures ════════
create or replace function anchor1a_user() returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated','osn3anchor1a.'||replace(v::text,'-','')||'@example.com','',now(),now(),now(),'','','','');
  return v;  -- on_auth_user_created_base trigger auto-creates the player's Home Base at (0,0)
end $$;

create or replace function anchor1a_fix(kind text) returns uuid language plpgsql as $$
declare
  v_u uuid := anchor1a_user(); v_s uuid := gen_random_uuid(); v_f uuid := gen_random_uuid(); v_b uuid;
  v_l1 uuid := (select id from locations order by id limit 1);
  v_fut timestamptz := now() + interval '1 hour';
begin
  select id into v_b from bases where player_id = v_u and status='active' order by created_at limit 1;
  if kind = 'home' then               -- spatial_state='home'
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','home','home',500,500,50,10,2,3,v_s);
  elsif kind = 'legacy_home' then     -- spatial_state NULL, status home
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','home',null,500,500,50,10,2,3,v_s);
  elsif kind = 'in_space' then        -- canonical origin (42,-17)
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,space_x,space_y,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','stationary','in_space',42,-17,500,500,50,10,2,3,v_s);
  elsif kind = 'at_location' then     -- spatial_state='at_location' + present fleet + active presence
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','stationary','at_location',500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,current_location_id,main_ship_id) values (v_f,v_u,v_b,'present','location',v_l1,v_s);
    insert into location_presence (player_id,fleet_id,status,location_id) values (v_u,v_f,'active',v_l1);
  elsif kind = 'legacy_present' then  -- spatial_state NULL + present fleet + active presence
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling',null,500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,current_location_id,main_ship_id) values (v_f,v_u,v_b,'present','location',v_l1,v_s);
    insert into location_presence (player_id,fleet_id,status,location_id) values (v_u,v_f,'active',v_l1);
  elsif kind = 'legacy_busy' then     -- legacy (spatial NULL) in-flight with an active legacy fleet_movement
    insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
      values (v_u,'starter_frigate','traveling',null,500,500,50,10,2,3,v_s);
    insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (v_f,v_u,v_b,'moving','movement',v_s);
    insert into fleet_movements (player_id,fleet_id,origin_type,origin_x,origin_y,target_type,target_x,target_y,mission_type,status,arrive_at,travel_distance,travel_seconds,speed_used)
      values (v_u,v_f,'base',0,0,'location',1,1,'rally','moving',v_fut,1,1,1);
    update fleets set active_movement_id=(select id from fleet_movements where fleet_id=v_f and status='moving' limit 1) where id=v_f;
  else
    raise exception 'anchor1a_fix: unknown kind %', kind;
  end if;
  return v_s;
end $$;

create or replace function anchor1a_player(p_ship uuid) returns uuid language sql stable as $$ select player_id from main_ship_instances where main_ship_id=p_ship $$;
create or replace function anchor1a_mv_count(p_ship uuid) returns int language sql stable as $$ select count(*)::int from main_ship_space_movements where main_ship_id=p_ship $$;
create or replace function anchor1a_rcpt_count(p_ship uuid) returns int language sql stable as $$ select count(*)::int from main_ship_space_command_receipts where main_ship_id=p_ship $$;

-- admit new moves ONLY in this disposable stack
update game_config set value='true' where key='mainship_space_movement_enabled';

-- ════════ SECTION 1 — home / legacy_home → origin_not_anchored (no movement, no receipt) ════════
do $$ declare s uuid; p uuid; r jsonb;
begin
  s := anchor1a_fix('legacy_home'); p := anchor1a_player(s);
  if (mainship_space_resolve_origin(s)->>'reason') <> 'origin_not_anchored' then raise exception '1: legacy_home resolver = %', mainship_space_resolve_origin(s); end if;
  r := mainship_space_begin_move(p, s, 70, 30, gen_random_uuid());
  if (r->>'ok')::boolean is distinct from false or (r->>'reason') <> 'origin_not_anchored' then raise exception '1: legacy_home begin_move expected origin_not_anchored, got %', r; end if;
  if anchor1a_mv_count(s) <> 0 then raise exception '1: legacy_home created a movement'; end if;
  if anchor1a_rcpt_count(s) <> 0 then raise exception '1: legacy_home created a receipt'; end if;

  s := anchor1a_fix('home'); p := anchor1a_player(s);
  if (mainship_space_resolve_origin(s)->>'reason') <> 'origin_not_anchored' then raise exception '1: home resolver = %', mainship_space_resolve_origin(s); end if;
  r := mainship_space_begin_move(p, s, -80, 40, gen_random_uuid());
  if (r->>'ok')::boolean is distinct from false or (r->>'reason') <> 'origin_not_anchored' then raise exception '1: home begin_move expected origin_not_anchored, got %', r; end if;
  if anchor1a_mv_count(s) <> 0 or anchor1a_rcpt_count(s) <> 0 then raise exception '1: home created movement/receipt'; end if;

  if exists (select 1 from main_ship_space_movements where origin_kind='base') then raise exception '1: a base-origin movement exists (legacy bases.x/y leak through the writer)'; end if;
  raise notice 'SECTION 1 ok: home/legacy_home → origin_not_anchored, no movement, no receipt, no base-origin movement';
end $$;

-- ════════ SECTION 2 — at_location / legacy_present → origin_not_anchored (no movement, no receipt) ════════
do $$ declare s uuid; p uuid; r jsonb;
begin
  s := anchor1a_fix('legacy_present'); p := anchor1a_player(s);
  if (mainship_space_validate_context(s)->>'state') <> 'legacy_present' then raise exception '2: legacy_present precond: %', mainship_space_validate_context(s); end if;
  if (mainship_space_resolve_origin(s)->>'reason') <> 'origin_not_anchored' then raise exception '2: legacy_present resolver = %', mainship_space_resolve_origin(s); end if;
  r := mainship_space_begin_move(p, s, 60, -30, gen_random_uuid());
  if (r->>'reason') <> 'origin_not_anchored' then raise exception '2: legacy_present begin_move expected origin_not_anchored, got %', r; end if;
  if anchor1a_mv_count(s) <> 0 or anchor1a_rcpt_count(s) <> 0 then raise exception '2: legacy_present created movement/receipt'; end if;

  s := anchor1a_fix('at_location'); p := anchor1a_player(s);
  if (mainship_space_validate_context(s)->>'state') <> 'at_location' then raise exception '2: at_location precond: %', mainship_space_validate_context(s); end if;
  if (mainship_space_resolve_origin(s)->>'reason') <> 'origin_not_anchored' then raise exception '2: at_location resolver = %', mainship_space_resolve_origin(s); end if;
  r := mainship_space_begin_move(p, s, -55, -25, gen_random_uuid());
  if (r->>'reason') <> 'origin_not_anchored' then raise exception '2: at_location begin_move expected origin_not_anchored, got %', r; end if;
  if anchor1a_mv_count(s) <> 0 or anchor1a_rcpt_count(s) <> 0 then raise exception '2: at_location created movement/receipt'; end if;

  if exists (select 1 from main_ship_space_movements where origin_kind='location') then raise exception '2: a location-origin movement exists (legacy locations.x/y leak through the writer)'; end if;
  raise notice 'SECTION 2 ok: at_location/legacy_present → origin_not_anchored, no movement, no receipt, no location-origin movement';
end $$;

-- ════════ SECTION 3 — in_space success: origin == canonical ship space_x/y; duration from that origin ════════
do $$ declare s uuid; p uuid; req uuid := gen_random_uuid(); r jsonb; m record; v_speed double precision; v_scale double precision; v_min double precision; v_dist double precision; v_secs double precision; v_actual double precision;
begin
  s := anchor1a_fix('in_space'); p := anchor1a_player(s);  -- canonical (42,-17)
  r := mainship_space_begin_move(p, s, 120, -60, req);
  if (r->>'ok')::boolean is not true then raise exception '3: in_space begin_move failed: %', r; end if;
  select * into m from main_ship_space_movements where main_ship_id=s and status='moving';
  if m.origin_kind <> 'space' then raise exception '3: origin_kind=% (expected space)', m.origin_kind; end if;
  if m.origin_x <> 42 or m.origin_y <> -17 then raise exception '3: origin (%, %) != ship space_x/y (42,-17)', m.origin_x, m.origin_y; end if;
  if m.target_kind <> 'space' or m.target_x <> 120 or m.target_y <> -60 or m.target_location_id is not null or m.target_base_id is not null then raise exception '3: target not a clean space target: %', to_jsonb(m); end if;
  if not (m.depart_at < m.arrive_at) then raise exception '3: non-positive duration'; end if;
  -- the travel time is computed from the movement''s OWN (canonical) origin — recompute the writer formula
  -- from m.origin_x/y and assert equality (same inputs ⇒ exact match).
  select h.base_speed into v_speed from main_ship_instances si join main_ship_hull_types h on h.hull_type_id=si.hull_type_id where si.main_ship_id=s;
  v_scale := coalesce(cfg_num('travel_scale'), 1.0);
  v_min   := coalesce(cfg_num('min_travel_seconds'), 1.0);
  v_dist  := sqrt(power(m.target_x - m.origin_x, 2) + power(m.target_y - m.origin_y, 2));
  v_secs  := greatest(v_min, v_dist / v_speed * v_scale);
  v_actual := extract(epoch from (m.arrive_at - m.depart_at));
  if abs(v_actual - v_secs) > 0.01 then raise exception '3: duration % != % computed from canonical origin', v_actual, v_secs; end if;
  if anchor1a_rcpt_count(s) <> 1 then raise exception '3: expected exactly one success receipt'; end if;
  raise notice 'SECTION 3 ok: in_space success → origin==ship space_x/y (42,-17), target_kind=space (120,-60), duration % s from canonical origin, one receipt', v_actual;
end $$;

-- ════════ SECTION 4 — rejected-request idempotency: reject writes no receipt; same request_id later valid ════════
do $$ declare s uuid; p uuid; req uuid := gen_random_uuid(); r jsonb; mv uuid;
begin
  -- start unanchored (legacy_home) → reject, NO receipt
  s := anchor1a_fix('legacy_home'); p := anchor1a_player(s);
  r := mainship_space_begin_move(p, s, 55, 25, req);
  if (r->>'reason') <> 'origin_not_anchored' then raise exception '4: expected origin_not_anchored, got %', r; end if;
  if anchor1a_rcpt_count(s) <> 0 then raise exception '4: a receipt was written for a rejected (unanchored) request'; end if;
  -- truthfully place the SAME ship into a valid in_space state (canonical coords; no anchor, no legacy fallback)
  update main_ship_instances set status='stationary', spatial_state='in_space', space_x=10, space_y=10 where main_ship_id=s;
  if (mainship_space_validate_context(s)->>'state') <> 'in_space' then raise exception '4: not in_space after truthful placement: %', mainship_space_validate_context(s); end if;
  -- SAME request_id now succeeds exactly once (the earlier reject wrote no blocking receipt)
  r := mainship_space_begin_move(p, s, 55, 25, req);
  if (r->>'ok')::boolean is not true then raise exception '4: same request_id in valid in_space state expected success, got %', r; end if;
  mv := (r->>'movement_id')::uuid;
  if anchor1a_mv_count(s) <> 1 then raise exception '4: expected exactly one movement, got %', anchor1a_mv_count(s); end if;
  if anchor1a_rcpt_count(s) <> 1 then raise exception '4: expected exactly one receipt, got %', anchor1a_rcpt_count(s); end if;
  -- replay after success is idempotent (existing behavior)
  r := mainship_space_begin_move(p, s, 55, 25, req);
  if (r->>'movement_id')::uuid <> mv then raise exception '4: replay returned a different movement'; end if;
  if anchor1a_mv_count(s) <> 1 or anchor1a_rcpt_count(s) <> 1 then raise exception '4: replay created a duplicate'; end if;
  raise notice 'SECTION 4 ok: rejected origin_not_anchored wrote no receipt; SAME request_id succeeds once after truthful in_space placement; replay idempotent';
end $$;

-- ════════ SECTION 5 — no legacy leakage through the writer (behavioral) ════════
do $$ declare n int; tot int;
begin
  select count(*) into n from main_ship_space_movements where origin_kind <> 'space';
  if n <> 0 then raise exception '5: % movement(s) have a non-space origin (legacy base/location leak through the writer)', n; end if;
  select count(*) into tot from main_ship_space_movements;
  if tot < 1 then raise exception '5: precond — expected at least one begin_move-created movement to inspect'; end if;
  raise notice 'SECTION 5 ok: all % begin_move-created movement(s) have origin_kind=space (no bases.x/y or locations.x/y reached a movement origin). Resolver source carries no FROM bases / FROM locations origin read (see PARITY). NOTE: a direct trusted INSERT may hold arbitrary coords — not claimed otherwise.', tot;
end $$;

-- ════════ SECTION 6 — non-regression (exclusion / destruction / repair / DOCK-0 / grants) ════════
do $$ declare s uuid; p uuid; r jsonb; d jsonb;
begin
  -- 6a cross-domain exclusion UNCHANGED: a legacy-busy ship is rejected active_legacy_movement at the
  --    exclusion step (8), which runs BEFORE the resolver (9) → unaffected by ANCHOR-1A.
  s := anchor1a_fix('legacy_busy'); p := anchor1a_player(s);
  if not exists (select 1 from fleet_movements fm join fleets f on f.id=fm.fleet_id where f.main_ship_id=s and fm.status='moving') then raise exception '6a precond: no active legacy movement'; end if;
  r := mainship_space_begin_move(p, s, 80, 80, gen_random_uuid());
  if (r->>'reason') <> 'active_legacy_movement' then raise exception '6a: expected active_legacy_movement (exclusion unchanged), got %', r; end if;
  if anchor1a_mv_count(s) <> 0 then raise exception '6a: a coordinate movement was created for a legacy-busy ship'; end if;

  -- 6b destruction + repair compatibility: destroy an in_space ship, then repair → clean legacy_home.
  s := anchor1a_fix('in_space'); p := anchor1a_player(s);
  d := dev_set_main_ship_destroyed(p);
  perform 1 from main_ship_instances where main_ship_id=s and status='destroyed' and hp=0 and spatial_state is null and space_x is null and space_y is null;
  if not found then raise exception '6b: destruction did not coordinate-complete the ship: %', d; end if;
  perform set_config('request.jwt.claim.sub', p::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p)::text, true);
  r := repair_main_ship();
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  if (mainship_space_validate_context(s)->>'state') <> 'legacy_home' then raise exception '6b: repaired ship not legacy_home: %', mainship_space_validate_context(s); end if;

  raise notice '6a/6b ok: exclusion unchanged (active_legacy_movement); destruction + repair compatible';
end $$;

-- 6c DOCK-0 unchanged + unreachable: the docking primitive stays service_role-only (no client grant), and
--    no movement created by the public/writer route in this proof is a location target.
do $$
declare r record; n int;
begin
  select p.oid into r from pg_proc p join pg_namespace nsp on nsp.oid=p.pronamespace where nsp.nspname='public' and p.proname='mainship_space_dock_at_location';
  if r.oid is null then raise exception '6c: dock primitive missing'; end if;
  if has_function_privilege('anon', r.oid, 'EXECUTE') or has_function_privilege('authenticated', r.oid, 'EXECUTE') then raise exception '6c: DOCK-0 primitive became client-executable'; end if;
  if not has_function_privilege('service_role', r.oid, 'EXECUTE') then raise exception '6c: DOCK-0 primitive lost service_role execute'; end if;
  select count(*) into n from main_ship_space_movements where target_kind='location';
  if n <> 0 then raise exception '6c: a location-target movement exists (% rows) — public route must never create one', n; end if;
  raise notice '6c ok: DOCK-0 primitive service_role-only + unreachable; zero location-target movements created by the public route';
end $$;

-- ════════ cleanup + final assertions ════════
update game_config set value='false' where key='mainship_space_movement_enabled';
delete from auth.users where email like 'osn3anchor1a.%@example.com';
do $$ declare n int;
begin
  select count(*) into n from main_ship_instances where player_id not in (select id from auth.users); if n<>0 then raise exception 'CLEANUP: % orphan ships', n; end if;
  select count(*) into n from main_ship_space_movements m where not exists (select 1 from main_ship_instances s where s.main_ship_id=m.main_ship_id); if n<>0 then raise exception 'CLEANUP: % orphan movements', n; end if;
  select count(*) into n from main_ship_space_command_receipts c where not exists (select 1 from main_ship_instances s where s.main_ship_id=c.main_ship_id); if n<>0 then raise exception 'CLEANUP: % orphan receipts', n; end if;
  select count(*) into n from auth.users where email like 'osn3anchor1a.%@example.com'; if n<>0 then raise exception 'CLEANUP: % fixture users remain', n; end if;
  raise notice 'ok cleanup: no fixture users/ships/fleets/movements/receipts/presence remain';
end $$;
drop function if exists anchor1a_rcpt_count(uuid);
drop function if exists anchor1a_mv_count(uuid);
drop function if exists anchor1a_player(uuid);
drop function if exists anchor1a_fix(text);
drop function if exists anchor1a_user();
do $$ declare a text; b text; c text; begin
  select value::text into a from game_config where key='mainship_send_enabled';
  select value::text into b from game_config where key='mainship_space_movement_enabled';
  select value::text into c from game_config where key='max_coordinate_travel_seconds';
  if a is distinct from 'true'  then raise exception 'FLAG FAIL: mainship_send_enabled=% (must remain true / untouched)', a; end if;
  if b is distinct from 'false' then raise exception 'FLAG FAIL: mainship_space_movement_enabled=% (must end false)', b; end if;
  if c is distinct from '86400' then raise exception 'CONFIG FAIL: max_coordinate_travel_seconds=%', c; end if;
  raise notice 'FLAG/CONFIG ok: send=true (untouched), space_movement=false, max_coordinate_travel_seconds=86400';
end $$;
select 'OSN-ANCHOR-1A REAL-CHAIN PROOF: ALL PASSED' as result;
