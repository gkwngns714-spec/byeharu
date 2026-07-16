-- FLEET-GO PROOF (charter §3 step 3a, migration 0207) — the ONE fleet-level mover.
--
-- Proves command_ship_group_go against a REAL disposable Postgres running the full migration chain.
-- Runs inside ONE transaction that ROLLBACKs — it persists NO player, ship, group, fleet, movement,
-- or flag flip. The dark flags are enabled ONLY inside this txn; the ROLLBACK reverts them, so every
-- committed flag is still false afterwards (the workflow re-checks).
--
-- THE CROWN-JEWEL PROPERTY IS FLEETGO_PASS_NOSHIPWRITE.
-- Charter §2 says "THE FLEET IS THE ONLY UNIT OF MOVEMENT. A SHIP DOES NOT MOVE." Every OTHER mover
-- in this codebase writes ship-level movement state (move_main_ship_to_location → 'traveling';
-- mainship_space_begin_move_core → 'in_transit'; send_ship_group_hunt → 'hunting'). The unified
-- mover must write NONE. That is not a nice-to-have — it IS the model. So this proof snapshots every
-- ship column that could carry movement (status, spatial_state, space_x, space_y, updated_at) into a
-- temp table BEFORE the command and diffs it AFTER, asserting byte-equality via a full EXCEPT both
-- ways. If a future edit adds an `update main_ship_instances` to the mover, this fails loudly.
-- It is asserted after the FIRST go, after a REDIRECT, and after the guards — a ship must never be
-- touched by any path through this function.
--
-- Fixture honesty:
--   • Provisioning is real-RPC (commission_first_main_ship / commission_additional_main_ship).
--     Commissioning docks ships canonically at Haven (stationary/at_location + a 'present' fleet),
--     which IS the bootstrap origin case — so no home-normalization surgery is needed for the main path.
--   • The ONE piece of fixture surgery is BACKDATING a movement's depart_at/arrive_at to test redirect
--     interpolation. now() is transaction-constant, so without it every in-txn redirect would compute
--     t=0 and the interpolated point would trivially equal the origin — proving nothing. Backdating to
--     (now()-30s, now()+30s) pins t=0.5 exactly, so the assertion is an exact midpoint, not an epsilon.
--     It is marked SURGERY below and touches no ship row.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table fg(k text primary key, v uuid) on commit preserve rows;
insert into fg values
  ('haven', 'b1a00001-0066-4a00-8a00-000000000001'),   -- starter port (commission dock)
  ('slag',  'b1a00002-0066-4a00-8a00-000000000002'),   -- active non-combat destination
  ('drift', 'b1a00003-0066-4a00-8a00-000000000003');   -- the redirect's second destination

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- the ship-state snapshot/diff helpers — the §2 assertion machinery.
create or replace function pg_temp.snap_ships(p_tag text) returns void language plpgsql as $$
begin
  insert into pg_temp.ship_snap
    select p_tag, main_ship_id, status, spatial_state, space_x, space_y, updated_at
      from public.main_ship_instances;
end $$;

create temp table ship_snap(
  tag text, main_ship_id uuid, status text, spatial_state text,
  space_x double precision, space_y double precision, updated_at timestamptz
) on commit preserve rows;

-- Asserts two snapshots are byte-identical in BOTH directions (EXCEPT is asymmetric alone).
create or replace function pg_temp.assert_ships_untouched(p_before text, p_after text, p_ctx text)
returns void language plpgsql as $$
declare n int;
begin
  select count(*) into n from (
    (select main_ship_id,status,spatial_state,space_x,space_y,updated_at from pg_temp.ship_snap where tag=p_before
     except
     select main_ship_id,status,spatial_state,space_x,space_y,updated_at from pg_temp.ship_snap where tag=p_after)
    union all
    (select main_ship_id,status,spatial_state,space_x,space_y,updated_at from pg_temp.ship_snap where tag=p_after
     except
     select main_ship_id,status,spatial_state,space_x,space_y,updated_at from pg_temp.ship_snap where tag=p_before)
  ) d;
  if n <> 0 then
    raise exception 'SHIP-WRITE FAIL (%): the unified mover touched % ship row(s) — charter §2 says a ship does not move', p_ctx, n;
  end if;
  -- guard the guard: the snapshots must be non-empty, or "identical" is vacuous.
  select count(*) into n from pg_temp.ship_snap where tag = p_before;
  if n = 0 then raise exception 'SHIP-WRITE FAIL (%): before-snapshot is EMPTY — the assertion would be vacuous', p_ctx; end if;
end $$;

-- ════════ SETUP: mirror production config a fresh disposable chain lacks (reverted by ROLLBACK) ════════
do $$
declare r jsonb; n int;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  select count(*) into n from public.locations
    where id in ((select v from fg where k='slag'), (select v from fg where k='drift'))
      and status = 'active';
  if n <> 2 then raise exception 'SETUP FAIL: expected Slagworks+Driftmarch active, got %', n; end if;
  raise notice 'setup ok: starter ports revealed + active (transient)';
end $$;

-- two fresh players: uA (the group under test), uB (the foreign-owner probe).
do $$
declare u uuid; k text;
begin
  foreach k in array array['uA','uB'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'fg.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into fg values (k, u);
  end loop;
end $$;

-- ════════ BLOCK DARK: the mover rejects BEFORE any read while fleet_movement_unified_enabled=false ════
-- Run BEFORE any flag flip, as a REAL authenticated sub, with a RANDOM NONEXISTENT group id AND a
-- random nonexistent location. If the gate read group/location state first, these would surface
-- group_not_found / invalid_location instead — so this proves reject-before-read with no existence oracle.
do $$
declare r jsonb; uA uuid := (select v from fg where k='uA'); slag uuid := (select v from fg where k='slag');
begin
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(gen_random_uuid(), %L::uuid)', slag));
  if (r->>'reason') is distinct from 'unified_movement_disabled' then
    raise exception 'DARK FAIL (nonexistent group): %', r; end if;
  r := pg_temp.call_as(uA, 'public.command_ship_group_go(gen_random_uuid(), gen_random_uuid())');
  if (r->>'reason') is distinct from 'unified_movement_disabled' then
    raise exception 'DARK FAIL (nonexistent group+location): %', r; end if;
  -- and it wrote nothing while dark.
  if exists (select 1 from public.fleets where group_id is not null and main_ship_id is null) then
    raise exception 'DARK FAIL: a unified fleet exists after a dark call';
  end if;
  raise notice 'FLEETGO_PASS_DARK: reject-before-read, no write, while dark';
end $$;

-- ════════ Enable the dark capabilities ONLY inside this txn (reverted by ROLLBACK) ════════
update public.game_config set value='true'::jsonb where key='team_command_enabled';
update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

-- Fund the fixture wallets BEFORE any additional commission. commission_first_main_ship is free, but
-- every ADDITIONAL commission DEBITS a price from player_wallet (0091) and fresh fixtures have zero
-- balance. Kept AFTER the DARK block (which must stay unfunded/unprovisioned) and inside the txn.
-- player_wallet is lazy, so on_conflict covers a row a signup/ensure path may already have created.
-- (The trade-market-1 / team-command proofs use this same direct-owner insert.)
insert into public.player_wallet (player_id, balance)
select v, 1000000 from fg where k in ('uA','uB')
on conflict (player_id) do update set balance = excluded.balance;

-- ════════ PROVISION via the REAL commission RPCs ════════
do $$
declare r jsonb;
  uA uuid := (select v from fg where k='uA'); uB uuid := (select v from fg where k='uB');
  a1 uuid; a2 uuid; b1 uuid; g uuid;
begin
  r := pg_temp.call_as(uA, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL uA first: %', r; end if;
  select main_ship_id into a1 from public.main_ship_instances where player_id = uA;
  r := pg_temp.call_as(uA, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL uA 2nd: %', r; end if;
  a2 := (r->>'main_ship_id')::uuid;

  r := pg_temp.call_as(uB, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL uB first: %', r; end if;
  select main_ship_id into b1 from public.main_ship_instances where player_id = uB;

  -- uA's group with BOTH ships (real RPCs).
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(1, ''Vanguard'')');
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL group: %', r; end if;
  g := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a1, g));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign a1: %', r; end if;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a2, g));
  if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL assign a2: %', r; end if;

  insert into fg values ('a1',a1),('a2',a2),('b1',b1),('g',g);
  raise notice 'provisioned: uA 2 ships in group Vanguard, uB 1 ship';
end $$;

-- ════════ BLOCK ONEFLEET + NOSHIPWRITE: one go → ONE fleet, ONE movement, ZERO ship writes ════════
do $$
declare r jsonb; n int; uA uuid := (select v from fg where k='uA');
  g uuid := (select v from fg where k='g'); slag uuid := (select v from fg where k='slag');
  haven uuid := (select v from fg where k='haven'); v_fleet uuid; v_mv uuid;
begin
  perform pg_temp.snap_ships('before_go');

  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, slag));
  if (r->>'ok')::boolean is not true then raise exception 'GO FAIL: %', r; end if;
  v_fleet := (r->>'fleet_id')::uuid;
  v_mv    := (r->>'movement_id')::uuid;

  perform pg_temp.snap_ships('after_go');
  -- ★ THE CHARTER §2 ASSERTION ★
  perform pg_temp.assert_ships_untouched('before_go', 'after_go', 'first go');

  -- exactly ONE unified fleet for the group (main_ship_id NULL — the hunt's proven shape).
  select count(*) into n from public.fleets
   where group_id = g and player_id = uA and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'ONEFLEET FAIL: expected 1 unified fleet, got %', n; end if;

  -- ONE movement, and it belongs to that fleet.
  select count(*) into n from public.fleet_movements where fleet_id = v_fleet and status = 'moving';
  if n <> 1 then raise exception 'ONEFLEET FAIL: expected 1 moving movement, got %', n; end if;

  -- the fleet is moving and points at it.
  select count(*) into n from public.fleets
   where id = v_fleet and status = 'moving' and active_movement_id = v_mv;
  if n <> 1 then raise exception 'ONEFLEET FAIL: fleet not moving/pointing at the movement'; end if;

  -- N members did NOT each get a fleet — the whole point vs the legacy per-member loop.
  select count(*) into n from public.fleets
   where player_id = uA and main_ship_id in ((select v from fg where k='a1'), (select v from fg where k='a2'))
     and status = 'moving';
  if n <> 0 then raise exception 'ONEFLEET FAIL: % per-member moving fleet(s) exist — that is the composed model §2 forbids', n; end if;

  -- bootstrap origin = the commission dock (Haven), NOT the base: "the fleet moves from wherever it is".
  if (r->>'origin_type') is distinct from 'location' then
    raise exception 'ONEFLEET FAIL: expected bootstrap origin_type=location (the dock), got %', r->>'origin_type'; end if;
  select count(*) into n from public.fleet_movements
   where id = v_mv and origin_type = 'location' and origin_location_id = haven and target_location_id = slag;
  if n <> 1 then raise exception 'ONEFLEET FAIL: movement did not depart Haven → Slagworks'; end if;

  if (r->>'redirected')::boolean is not false then raise exception 'ONEFLEET FAIL: first go reported redirected'; end if;

  insert into fg values ('fleet', v_fleet), ('mv1', v_mv);
  raise notice 'FLEETGO_PASS_ONEFLEET: 1 fleet, 1 movement, 0 per-member fleets, origin = the dock';
  raise notice 'FLEETGO_PASS_NOSHIPWRITE: ship rows byte-identical across the go (charter §2)';
end $$;

-- ════════ BLOCK SPEEDMIN: movement speed == an INDEPENDENT min over the members ════════
-- Recomputed here from the per-member adapter directly — not read back from the same helper the RPC
-- used — so a wrong fold (sum/max/first) cannot pass by agreeing with itself.
do $$
declare v_speed double precision; v_expect double precision := null; v_ms double precision;
  s uuid; uA uuid := (select v from fg where k='uA'); v_mv uuid := (select v from fg where k='mv1');
  v_stats jsonb;
begin
  select speed_used into v_speed from public.fleet_movements where id = v_mv;
  foreach s in array array[(select v from fg where k='a1'), (select v from fg where k='a2')] loop
    v_stats := public.calculate_expedition_stats(uA, s, '[]'::jsonb, 'none');
    v_ms := (v_stats->>'speed')::double precision;
    v_expect := least(coalesce(v_expect, v_ms), v_ms);
  end loop;
  if v_expect is null then raise exception 'SPEEDMIN FAIL: independent expectation is null'; end if;
  if v_speed is distinct from v_expect then
    raise exception 'SPEEDMIN FAIL: movement speed % <> independent member-min %', v_speed, v_expect; end if;
  raise notice 'FLEETGO_PASS_SPEEDMIN: fleet speed = min(members) = % (independently recomputed)', v_expect;
end $$;

-- ════════ BLOCK REDIRECT: re-issuing mid-flight is the SAME call — cancel at the interpolated point ════
do $$
declare r jsonb; n int; uA uuid := (select v from fg where k='uA');
  g uuid := (select v from fg where k='g'); drift uuid := (select v from fg where k='drift');
  v_fleet uuid := (select v from fg where k='fleet'); v_mv1 uuid := (select v from fg where k='mv1');
  v_mv2 uuid; v_ox double precision; v_oy double precision; v_mid_x double precision; v_mid_y double precision;
begin
  -- ── SURGERY (the only one; touches NO ship row): now() is txn-constant, so an in-txn redirect would
  --    compute t=0 and the "interpolated" point would trivially equal the origin. Backdate the leg to
  --    (now()-30s, now()+30s) → t is EXACTLY 0.5 → the assertion below is an exact midpoint.
  update public.fleet_movements
     set depart_at = now() - interval '30 seconds', arrive_at = now() + interval '30 seconds'
   where id = v_mv1;
  select (origin_x + target_x) / 2, (origin_y + target_y) / 2 into v_mid_x, v_mid_y
    from public.fleet_movements where id = v_mv1;

  perform pg_temp.snap_ships('before_redirect');

  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, drift));
  if (r->>'ok')::boolean is not true then raise exception 'REDIRECT FAIL: %', r; end if;
  if (r->>'redirected')::boolean is not true then raise exception 'REDIRECT FAIL: not reported as a redirect: %', r; end if;
  v_mv2 := (r->>'movement_id')::uuid;

  perform pg_temp.snap_ships('after_redirect');
  -- ★ THE CHARTER §2 ASSERTION, again — a redirect must not touch a ship either ★
  perform pg_temp.assert_ships_untouched('before_redirect', 'after_redirect', 'redirect');

  -- the SAME fleet — a redirect must never create a second mover.
  if (r->>'fleet_id')::uuid is distinct from v_fleet then
    raise exception 'REDIRECT FAIL: redirect created a different fleet (% vs %)', r->>'fleet_id', v_fleet; end if;
  select count(*) into n from public.fleets
   where group_id = g and player_id = uA and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'REDIRECT FAIL: % unified fleets after redirect', n; end if;

  -- the old leg is cancelled and resolved; exactly ONE live leg remains.
  select count(*) into n from public.fleet_movements
   where id = v_mv1 and status = 'cancelled' and resolved_at is not null;
  if n <> 1 then raise exception 'REDIRECT FAIL: the old leg was not cancelled+resolved'; end if;
  select count(*) into n from public.fleet_movements where fleet_id = v_fleet and status = 'moving';
  if n <> 1 then raise exception 'REDIRECT FAIL: expected exactly 1 live leg, got %', n; end if;

  -- the new leg departs from the INTERPOLATED point, as open space, to the new port.
  select origin_x, origin_y into v_ox, v_oy from public.fleet_movements where id = v_mv2;
  if (select origin_type from public.fleet_movements where id = v_mv2) is distinct from 'space' then
    raise exception 'REDIRECT FAIL: new leg origin_type is not space'; end if;
  if v_ox is distinct from v_mid_x or v_oy is distinct from v_mid_y then
    raise exception 'REDIRECT FAIL: new leg origin (%,%) is not the exact midpoint (%,%)', v_ox, v_oy, v_mid_x, v_mid_y; end if;
  if (select target_location_id from public.fleet_movements where id = v_mv2) is distinct from drift then
    raise exception 'REDIRECT FAIL: new leg does not target Driftmarch'; end if;

  raise notice 'FLEETGO_PASS_REDIRECT: same fleet, old leg cancelled, new leg departs the exact interpolated point';
end $$;

-- ════════ BLOCK GUARDS: ownership, empty, scattered, sortie, and the transition member_busy ════════
do $$
declare r jsonb; n int;
  uA uuid := (select v from fg where k='uA'); uB uuid := (select v from fg where k='uB');
  g uuid := (select v from fg where k='g'); slag uuid := (select v from fg where k='slag');
  g2 uuid;
  v_members_uA uuid[] := array[(select v from fg where k='a1'), (select v from fg where k='a2')];
begin
  perform pg_temp.snap_ships('before_guards');

  -- foreign owner: uB cannot move uA's group (resolves via auth.uid(), never the passed id).
  r := pg_temp.call_as(uB, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, slag));
  if (r->>'reason') is distinct from 'group_not_found' then
    raise exception 'GUARD FAIL foreign owner: %', r; end if;

  -- empty group.
  r := pg_temp.call_as(uA, 'public.upsert_ship_group(2, ''Empty'')');
  g2 := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g2, slag));
  if (r->>'reason') is distinct from 'empty_group' then
    raise exception 'GUARD FAIL empty group: %', r; end if;

  -- invalid destination.
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, gen_random_uuid())', g));
  if (r->>'reason') is distinct from 'invalid_location' then
    raise exception 'GUARD FAIL invalid location: %', r; end if;

  -- ★ TRANSITION GUARD (member_busy): a member flying its OWN per-ship fleet blocks the group move —
  --   otherwise that ship would be in two places at once, the exact duality §2 kills. Simulated by
  --   the member's own fleet being 'moving' (the state the live per-ship send produces).
  --   This guard MUST be deleted at step 4 when the per-ship movers are retired.
  update public.fleets set status = 'moving'
   where player_id = uA and main_ship_id = (select v from fg where k='a1') and status = 'present';
  if not found then
    -- a1's commission fleet was already dissolved; make the state explicitly.
    insert into public.fleets (player_id, status, location_mode, main_ship_id)
      values (uA, 'moving', 'movement', (select v from fg where k='a1'));
  end if;
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, slag));
  if (r->>'reason') is distinct from 'member_busy' then
    raise exception 'GUARD FAIL member_busy (a member on its own per-ship fleet must block the group): %', r; end if;

  -- ── RESTORE the simulated per-ship fleet. A fixture that mutates state MUST undo it: without this
  --    every LATER block inherits member_busy and fails for a reason that has nothing to do with what
  --    it is testing. (The CI matrix caught exactly that — the 3b coordinate block died on member_busy.)
  update public.fleets
     set status = 'completed', location_mode = 'movement', active_movement_id = null
   where player_id = uA and main_ship_id = any(v_members_uA) and status in ('moving', 'returning');
  -- prove the restore actually worked, rather than trusting it.
  select count(*) into n from public.fleets
   where player_id = uA and main_ship_id = any(v_members_uA) and status in ('moving', 'returning');
  if n <> 0 then raise exception 'GUARD FAIL: the member_busy fixture did not restore (% live per-ship fleet(s))', n; end if;

  perform pg_temp.snap_ships('after_guards');
  -- ★ §2 again: every REJECTED path must also leave ships untouched ★
  perform pg_temp.assert_ships_untouched('before_guards', 'after_guards', 'guards');

  raise notice 'FLEETGO_PASS_GUARDS: foreign-owner, empty, invalid-location, member_busy all fail closed; ships untouched';
end $$;

-- ════════ BLOCK TARGETSHAPE (3b): exactly one of {port} | {coordinate}, validated before any read ════
do $$
declare r jsonb; uA uuid := (select v from fg where k='uA'); g uuid := (select v from fg where k='g');
  slag uuid := (select v from fg where k='slag');
begin
  -- both a port AND coordinates: the server owns a port's position; a caller may not assert it (0067's rule).
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid, 5, 5)', g, slag));
  if (r->>'reason') is distinct from 'invalid_target_shape' then raise exception 'SHAPE FAIL both: %', r; end if;
  -- neither.
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid)', g));
  if (r->>'reason') is distinct from 'invalid_target_shape' then raise exception 'SHAPE FAIL neither: %', r; end if;
  -- half a coordinate.
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, 5, null)', g));
  if (r->>'reason') is distinct from 'invalid_target_shape' then raise exception 'SHAPE FAIL half: %', r; end if;
  -- non-finite.
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, ''NaN''::double precision, 5)', g));
  if (r->>'reason') is distinct from 'invalid_coordinate' then raise exception 'SHAPE FAIL NaN: %', r; end if;
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, ''Infinity''::double precision, 5)', g));
  if (r->>'reason') is distinct from 'invalid_coordinate' then raise exception 'SHAPE FAIL Inf: %', r; end if;
  -- outside the navigable square (the 0067 bound, reused).
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, 10001, 0)', g));
  if (r->>'reason') is distinct from 'target_out_of_bounds' then raise exception 'SHAPE FAIL bounds+: %', r; end if;
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, 0, -10001)', g));
  if (r->>'reason') is distinct from 'target_out_of_bounds' then raise exception 'SHAPE FAIL bounds-: %', r; end if;
  -- the 2-arg form must NOT survive as an overload (drop+create, not a second signature).
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='command_ship_group_go') <> 1 then
    raise exception 'SHAPE FAIL: command_ship_group_go has more than one signature (overload leak)'; end if;
  raise notice 'FLEETGO_PASS_TARGETSHAPE: both/neither/half/NaN/Inf/out-of-bounds all fail closed; one signature only';
end $$;

-- ════════ BLOCK COORD (3b): the fleet flies to a raw coordinate ════════
do $$
declare r jsonb; n int; uA uuid := (select v from fg where k='uA'); g uuid := (select v from fg where k='g');
  v_fleet uuid := (select v from fg where k='fleet'); v_mv uuid;
begin
  perform pg_temp.snap_ships('before_coord');
  -- 123.4/-77.6 → the integer world grid (the 0178 canonicalization rule).
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, null, 123.4, -77.6)', g));
  if (r->>'ok')::boolean is not true then raise exception 'COORD FAIL: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  perform pg_temp.snap_ships('after_coord');
  perform pg_temp.assert_ships_untouched('before_coord', 'after_coord', 'coordinate go');

  if (r->>'fleet_id')::uuid is distinct from v_fleet then
    raise exception 'COORD FAIL: a coordinate go created a different fleet'; end if;
  if (r->>'target_type') is distinct from 'space' then raise exception 'COORD FAIL: target_type %', r->>'target_type'; end if;

  select count(*) into n from public.fleet_movements
   where id = v_mv and target_type = 'space' and target_location_id is null
     and target_x = 123 and target_y = -78;   -- rounded to the grid
  if n <> 1 then raise exception 'COORD FAIL: movement is not a grid-canonical space target'; end if;

  insert into fg values ('mv_coord', v_mv);
  raise notice 'FLEETGO_PASS_COORD: fleet targets a raw coordinate, canonicalized to the integer grid, no ship touched';
end $$;

-- ════════ BLOCK SPACESETTLE (3b): a coordinate arrival PARKS the fleet in open space ════════
do $$
declare r jsonb; n int; v_fleet uuid := (select v from fg where k='fleet'); v_mv uuid := (select v from fg where k='mv_coord');
begin
  -- make it due (now() is txn-constant, so the leg must be backdated to settle at all).
  -- Make the leg DUE. Both ends must move: now() is txn-constant, so backdating only arrive_at would
  -- push it before depart_at and violate fleet_movements_check (arrive_at > depart_at).
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_mv;
  perform pg_temp.snap_ships('before_settle');
  r := public.movement_settle_arrival(v_mv);
  perform pg_temp.snap_ships('after_settle');
  -- ★ §2 through the SETTLE too — the cron must not touch a ship either ★
  perform pg_temp.assert_ships_untouched('before_settle', 'after_settle', 'space settle');

  if (r->>'settled')::boolean is not true or (r->>'outcome') is distinct from 'in_space' then
    raise exception 'SPACESETTLE FAIL: %', r; end if;
  -- the FLEET now carries the position — the thing that did not exist before 3b.
  select count(*) into n from public.fleets
   where id = v_fleet and location_mode = 'space' and status = 'idle'
     and space_x = 123 and space_y = -78
     and active_movement_id is null and current_location_id is null;
  if n <> 1 then raise exception 'SPACESETTLE FAIL: the fleet is not parked at its coordinate'; end if;
  -- open space has no port, so no presence may be invented for it.
  select count(*) into n from public.location_presence where fleet_id = v_fleet and status = 'active';
  if n <> 0 then raise exception 'SPACESETTLE FAIL: % active presence row(s) for a fleet in open space', n; end if;
  select count(*) into n from public.fleet_movements where id = v_mv and status = 'arrived' and resolved_at is not null;
  if n <> 1 then raise exception 'SPACESETTLE FAIL: leg not arrived+resolved'; end if;

  raise notice 'FLEETGO_PASS_SPACESETTLE: the FLEET holds the position (location_mode=space), no presence, no ship write';
end $$;

-- ════════ BLOCK FROMSPACE (3b): the model closes — set off again FROM open space ════════
do $$
declare r jsonb; uA uuid := (select v from fg where k='uA'); g uuid := (select v from fg where k='g');
  drift uuid := (select v from fg where k='drift'); v_fleet uuid := (select v from fg where k='fleet'); v_mv uuid; n int;
begin
  perform pg_temp.snap_ships('before_fromspace');
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, drift));
  if (r->>'ok')::boolean is not true then raise exception 'FROMSPACE FAIL: %', r; end if;
  perform pg_temp.snap_ships('after_fromspace');
  perform pg_temp.assert_ships_untouched('before_fromspace', 'after_fromspace', 'go from space');

  -- it departed the PARKED COORDINATE, with no port involved — "the fleet moves from wherever it is".
  if (r->>'origin_type') is distinct from 'space' then
    raise exception 'FROMSPACE FAIL: origin_type % (expected space)', r->>'origin_type'; end if;
  if (r->>'redirected')::boolean is not false then
    raise exception 'FROMSPACE FAIL: a parked fleet is not a redirect'; end if;
  v_mv := (r->>'movement_id')::uuid;
  select count(*) into n from public.fleet_movements
   where id = v_mv and origin_type = 'space' and origin_x = 123 and origin_y = -78 and target_location_id = drift;
  if n <> 1 then raise exception 'FROMSPACE FAIL: new leg did not depart the parked point'; end if;
  -- departing clears the parked position: the fleet is under way, not in two states.
  select count(*) into n from public.fleets
   where id = v_fleet and location_mode = 'movement' and space_x is null and space_y is null;
  if n <> 1 then raise exception 'FROMSPACE FAIL: the fleet is still parked while moving'; end if;

  raise notice 'FLEETGO_PASS_FROMSPACE: a fleet parked in open space sets off again with no port involved';
end $$;

-- ════════ BLOCK SETTLEPARITY (3b): the RE-CREATED settle left every LEGACY branch intact ════════
-- movement_settle_arrival is driven by the live 30s cron (process_fleet_movements) and by the legacy
-- on-demand RPC. 0208 re-creates it to add the 'space' branch. This proves the branches that were
-- already there still behave — asserted against the function's OWN legality rule, not a hard-coded
-- guess about which port happens to qualify.
do $$
declare r jsonb; n int; uB uuid := (select v from fg where k='uB'); b1 uuid := (select v from fg where k='b1');
  slag uuid := (select v from fg where k='slag'); v_f uuid; v_mv uuid; v_legal boolean; v_loc record; v_base record;
begin
  -- ── legacy branch 1: an ORDINARY fleet (main_ship_id NULL) arriving at a location → present + presence.
  select l.id, l.x, l.y, l.zone_id, z.sector_id into v_loc
    from public.locations l join public.zones z on z.id = l.zone_id where l.id = slag;
  select b.id, b.x, b.y into v_base from public.bases b where b.player_id = uB and b.status='active' order by b.created_at limit 1;
  insert into public.fleets (player_id, origin_base_id, status, location_mode, current_base_id)
    values (uB, v_base.id, 'idle', 'base', v_base.id) returning id into v_f;
  v_mv := public.movement_create(uB, v_f, 'base', v_base.id, null, null, v_base.x, v_base.y,
                                 'location', null, null, v_loc.id, v_loc.x, v_loc.y, 'rally', 1);
  perform public.fleet_set_moving(v_f, v_mv);
  -- Make the leg DUE. Both ends must move: now() is txn-constant, so backdating only arrive_at would
  -- push it before depart_at and violate fleet_movements_check (arrive_at > depart_at).
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'outcome') is distinct from 'present' then raise exception 'PARITY FAIL location outcome: %', r; end if;
  select count(*) into n from public.fleets where id = v_f and status='present' and current_location_id = slag;
  if n <> 1 then raise exception 'PARITY FAIL: fleet not present at the target'; end if;
  select count(*) into n from public.location_presence where fleet_id = v_f and status='active' and location_id = slag;
  if n <> 1 then raise exception 'PARITY FAIL: presence not created (the legacy location branch changed)'; end if;

  -- ── legacy branch 2: the 0153 MAIN-SHIP dock hunk still fires exactly per its own legality rule.
  --    Asserted as an IFF against mainship_space_location_target_legal — so this pins the RULE, not a
  --    guess about Slagworks, and stays true if the seed ports change.
  v_legal := (public.mainship_space_location_target_legal(slag)->>'ok')::boolean;
  update public.fleets set status='completed', location_mode='movement', active_movement_id=null
   where player_id = uB and main_ship_id = b1 and status='present';
  perform public.presence_complete(lp.id) from public.location_presence lp
    join public.fleets f on f.id = lp.fleet_id
   where f.player_id = uB and f.main_ship_id = b1 and lp.status='active';
  insert into public.fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)
    values (uB, v_base.id, 'idle', 'base', v_base.id, b1) returning id into v_f;
  v_mv := public.movement_create(uB, v_f, 'base', v_base.id, null, null, v_base.x, v_base.y,
                                 'location', null, null, v_loc.id, v_loc.x, v_loc.y, 'rally', 1);
  perform public.fleet_set_moving(v_f, v_mv);
  -- Make the leg DUE. Both ends must move: now() is txn-constant, so backdating only arrive_at would
  -- push it before depart_at and violate fleet_movements_check (arrive_at > depart_at).
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_mv;
  r := public.movement_settle_arrival(v_mv);
  if (r->>'outcome') is distinct from 'present' then raise exception 'PARITY FAIL mainship outcome: %', r; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = b1 and status='stationary' and spatial_state='at_location';
  if v_legal and n <> 1 then
    raise exception 'PARITY FAIL: dockable target did NOT dock the ship — the 0153 hunk regressed'; end if;
  if not v_legal and n <> 0 then
    raise exception 'PARITY FAIL: non-dockable target docked the ship anyway'; end if;

  raise notice 'FLEETGO_PASS_SETTLEPARITY: the re-created settle keeps the location branch + the 0153 dock rule (legal=%)', v_legal;
end $$;

-- ════════ BLOCK STOP (0209): the fleet-level BRAKE — halt and HOLD at the interpolated point ════════
-- The live stop_ship_group_transit (0164) LOOPS the per-ship stop and parks the SHIP (0155 writes
-- main_ship_instances.spatial_state='in_space' + space_x/space_y). This one parks the FLEET. Same verb,
-- opposite model — that difference is §2, so it is asserted, not asserted-about.
do $$
declare r jsonb; n int; uA uuid := (select v from fg where k='uA'); g uuid := (select v from fg where k='g');
  slag uuid := (select v from fg where k='slag'); v_fleet uuid := (select v from fg where k='fleet');
  v_mv uuid; v_mid_x double precision; v_mid_y double precision;
begin
  -- park the fleet somewhere known, then launch a fresh leg we can brake mid-flight.
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, slag));
  if (r->>'ok')::boolean is not true then raise exception 'STOP SETUP FAIL: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  -- SURGERY (no ship row touched): now() is txn-constant, so backdate to pin t = EXACTLY 0.5.
  update public.fleet_movements
     set depart_at = now() - interval '30 seconds', arrive_at = now() + interval '30 seconds'
   where id = v_mv;
  select (origin_x + target_x) / 2, (origin_y + target_y) / 2 into v_mid_x, v_mid_y
    from public.fleet_movements where id = v_mv;

  perform pg_temp.snap_ships('before_stop');
  r := pg_temp.call_as(uA, format('public.command_ship_group_stop(%L::uuid)', g));
  perform pg_temp.snap_ships('after_stop');
  -- ★ §2: the BRAKE must not touch a ship either — this is the exact write 0155 makes and 0209 must not ★
  perform pg_temp.assert_ships_untouched('before_stop', 'after_stop', 'fleet stop');

  if (r->>'ok')::boolean is not true or (r->>'stopped')::boolean is not true then
    raise exception 'STOP FAIL: %', r; end if;

  -- the leg is cancelled and the FLEET holds position at the exact turn point.
  select count(*) into n from public.fleet_movements where id = v_mv and status='cancelled' and resolved_at is not null;
  if n <> 1 then raise exception 'STOP FAIL: leg not cancelled+resolved'; end if;
  select count(*) into n from public.fleets
   where id = v_fleet and location_mode = 'space' and status = 'idle'
     and space_x = v_mid_x and space_y = v_mid_y and active_movement_id is null;
  if n <> 1 then raise exception 'STOP FAIL: the FLEET is not holding at the interpolated midpoint'; end if;

  -- STOP = HOLD, not return-home: the fleet is immediately re-commandable FROM the point it stopped at.
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, slag));
  if (r->>'ok')::boolean is not true then raise exception 'STOP FAIL: a held fleet is not re-commandable: %', r; end if;
  if (r->>'origin_type') is distinct from 'space' then
    raise exception 'STOP FAIL: re-departure origin % (expected the held point)', r->>'origin_type'; end if;
  select count(*) into n from public.fleet_movements
   where id = (r->>'movement_id')::uuid and origin_x = v_mid_x and origin_y = v_mid_y;
  if n <> 1 then raise exception 'STOP FAIL: re-departure did not leave from the held point'; end if;

  -- ── THE AGREEMENT PIN: a redirect is "stop here, then go there", so the brake and the redirect MUST
  --    compute the same "here". Braking the fresh leg at the same t must yield the same point a redirect
  --    of that leg would have departed from. If these ever diverge, one of them is lying about position.
  v_mv := (r->>'movement_id')::uuid;
  update public.fleet_movements
     set depart_at = now() - interval '30 seconds', arrive_at = now() + interval '30 seconds'
   where id = v_mv;
  select (origin_x + target_x) / 2, (origin_y + target_y) / 2 into v_mid_x, v_mid_y
    from public.fleet_movements where id = v_mv;
  r := pg_temp.call_as(uA, format('public.command_ship_group_stop(%L::uuid)', g));
  if (r->>'space_x')::double precision is distinct from v_mid_x
     or (r->>'space_y')::double precision is distinct from v_mid_y then
    raise exception 'STOP FAIL: brake point (%,%) disagrees with the redirect interpolation (%,%)',
      r->>'space_x', r->>'space_y', v_mid_x, v_mid_y; end if;

  -- idempotent: pressing the brake on a held fleet reports itself, never raises.
  r := pg_temp.call_as(uA, format('public.command_ship_group_stop(%L::uuid)', g));
  if (r->>'ok')::boolean is not true then raise exception 'STOP FAIL: double-stop raised: %', r; end if;
  if (r->>'stopped')::boolean is not false or (r->>'reason_code') is distinct from 'not_moving' then
    raise exception 'STOP FAIL: double-stop did not report not_moving: %', r; end if;

  -- foreign owner cannot brake someone else's fleet.
  r := pg_temp.call_as((select v from fg where k='uB'), format('public.command_ship_group_stop(%L::uuid)', g));
  if (r->>'reason') is distinct from 'group_not_found' then raise exception 'STOP FAIL foreign owner: %', r; end if;

  raise notice 'FLEETGO_PASS_STOP: the FLEET holds at the interpolated point (agrees with redirect), re-commandable, idempotent, no ship touched';
end $$;

-- ════════ BLOCK ISOLATION: the mover created no second combat/sortie surface and no ship movement ════
do $$
declare n int;
begin
  -- No sortie manifest rows: this is a MOVE, not a hunt. (Guards against copying hunt too literally.)
  select count(*) into n from public.group_sortie_members;
  if n <> 0 then raise exception 'ISOLATION FAIL: the mover wrote % sortie manifest row(s)', n; end if;

  -- No OSN coordinate movements: the unified mover lives in the fleet domain ONLY.
  select count(*) into n from public.main_ship_space_movements;
  if n <> 0 then raise exception 'ISOLATION FAIL: the mover created % OSN space movement(s) — wrong domain', n; end if;

  -- ★ THE 3b PAYOFF, stated as one assertion ★
  -- NOT ONE ship in the whole DB carries a coordinate or an in-transit spatial state — even though a
  -- fleet has now flown to a raw coordinate, parked there, and set off again from it. The position
  -- exists; it just lives on the FLEET. That is §2 in a single query.
  select count(*) into n from public.main_ship_instances
   where space_x is not null or space_y is not null or spatial_state in ('in_space','in_transit');
  if n <> 0 then raise exception 'ISOLATION FAIL: % ship(s) carry a position/transit state — §2 says ships have neither', n; end if;
  -- ...and the converse: the FLEET layer really did carry the position. Without this, the ship-free
  -- assertion above is satisfied by a system where nothing ever moved at all.
  -- NOT asserted on fleets.space_x: by now the fleet has departed again and CORRECTLY cleared its
  -- parked coords (FROMSPACE proves that), so current state shows nothing. The evidence that survives
  -- is the movement rows — one leg TARGETED a coordinate, and a later leg DEPARTED from one.
  -- (This guard fired on its own author: the first version asserted live coords and failed here.)
  select count(*) into n from public.fleet_movements where target_type = 'space';
  if n = 0 then
    raise exception 'ISOLATION FAIL: no fleet ever targeted a coordinate — the ship-free assertion is vacuous'; end if;
  select count(*) into n from public.fleet_movements where origin_type = 'space' and origin_x = 123 and origin_y = -78;
  if n = 0 then
    raise exception 'ISOLATION FAIL: no fleet ever departed FROM its parked coordinate — 3b is unproven'; end if;

  raise notice 'FLEETGO_PASS_ISOLATION: no sortie rows, no OSN movements, ZERO ship positions — yet the FLEET holds one (§2)';
end $$;

select 'FLEET-GO PROOF PASSED' as result;

rollback;
