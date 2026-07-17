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

-- ★ THE GHOST-DOCK ASSERTION ★ — the property NOSHIPWRITE is structurally blind to.
-- A fleet in flight must leave NO member docked behind it. 3a copied the hunt's fleet shape but not its
-- dissolve, so every go left each member with a live 'present' fleet + active presence at the origin —
-- the fleet flying while its ships kept trading at the port they left. NOSHIPWRITE cannot see it: that
-- diffs main_ship_instances, and the leak is in fleets/location_presence. Two different tables, two
-- different assertions. This is why "the proof passed" is never the same as "the code is right".
create or replace function pg_temp.assert_no_ghost_dock(p_player uuid, p_group uuid, p_ctx text)
returns void language plpgsql as $$
declare n int; m int;
begin
  select count(*) into n
    from public.fleets f
    join public.main_ship_instances s on s.main_ship_id = f.main_ship_id
   where f.player_id = p_player and s.group_id = p_group and f.status = 'present';
  if n <> 0 then
    raise exception 'GHOST-DOCK FAIL (%): % member(s) still hold a ''present'' per-ship fleet while the group flies', p_ctx, n;
  end if;
  select count(*) into m
    from public.location_presence lp
    join public.fleets f on f.id = lp.fleet_id
    join public.main_ship_instances s on s.main_ship_id = f.main_ship_id
   where lp.status = 'active' and f.player_id = p_player and s.group_id = p_group;
  if m <> 0 then
    raise exception 'GHOST-DOCK FAIL (%): % member(s) still ACTIVE at a port the fleet has left', p_ctx, m;
  end if;
end $$;

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

-- three fresh players: uA (the group under test), uB (the foreign-owner probe), uC (the 3c-2
-- hunt-overlap world — kept separate so the REAL hunt it launches cannot poison uA's fixtures).
do $$
declare u uuid; k text;
begin
  foreach k in array array['uA','uB','uC'] loop
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
-- 3c-2 (0211): the docked-store host is gated on station_storage_enabled (ON in prod, seeded false on a
-- fresh chain) — without this its dark-parity assertion would see 'disabled' and prove nothing. And the
-- HUNTOVERLAP block launches a REAL docked hunt, which needs launch_from_dock_enabled (also ON in prod).
update public.game_config set value='true'::jsonb where key='station_storage_enabled';
update public.game_config set value='true'::jsonb where key='launch_from_dock_enabled';

-- Fund the fixture wallets BEFORE any additional commission. commission_first_main_ship is free, but
-- every ADDITIONAL commission DEBITS a price from player_wallet (0091) and fresh fixtures have zero
-- balance. Kept AFTER the DARK block (which must stay unfunded/unprovisioned) and inside the txn.
-- player_wallet is lazy, so on_conflict covers a row a signup/ensure path may already have created.
-- (The trade-market-1 / team-command proofs use this same direct-owner insert.)
insert into public.player_wallet (player_id, balance)
select v, 1000000 from fg where k in ('uA','uB','uC')
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

-- ════════ BLOCK ORACLEPARITY (3c-1): with the flag OFF, the oracle is the 0056 head, verbatim ════════
-- validate_context is the transitive authority behind ten surfaces (the hangar, dock services, the three
-- trade RPCs, the map projection, OSN readiness, mining/exploration settled-safe). Its group branch is
-- dark; while dark it must be indistinguishable from the head it replaced.
--
-- PLACEMENT IS DELIBERATE — this runs BEFORE any unified go, and an earlier version did not. Asserting
-- dark parity AFTER a go tests an IMPOSSIBLE state: while the gate is false no unified go can happen, so
-- no member fleet is ever dissolved, so the "grouped ship with a dissolved fleet" case cannot arise in a
-- dark world. The CI matrix caught that (it reported contradictory_state, which is the CORRECT answer for
-- a commissioned ship whose fleet has been dissolved — see 0210's header; both recon sweeps were right
-- about different ship shapes). Parity must be asserted on states the dark world can actually reach.
do $$
declare r jsonb; a1 uuid := (select v from fg where k='a1'); b1 uuid := (select v from fg where k='b1');
  haven uuid := (select v from fg where k='haven'); n int;
begin
  -- a1 IS grouped; its group has no unified fleet yet (nothing has moved). b1 is ungrouped. Both are
  -- freshly commissioned: stationary + at_location + their own present fleet + presence.
  select count(*) into n from public.main_ship_instances where main_ship_id = a1 and group_id is not null;
  if n <> 1 then raise exception 'ORACLEPARITY FAIL: a1 is not grouped — the assertion would be vacuous'; end if;

  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';
  r := public.mainship_space_validate_context(a1);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'at_location' then
    raise exception 'ORACLEPARITY FAIL (dark, grouped): %', r; end if;
  if public.mainship_resolve_docked_location(a1) is distinct from haven then
    raise exception 'ORACLEPARITY FAIL (dark): dock resolver did not return the commission dock'; end if;
  r := public.mainship_space_validate_context(b1);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'at_location' then
    raise exception 'ORACLEPARITY FAIL (dark, ungrouped): %', r; end if;

  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  -- LIT: a1 is grouped but its group has NO unified fleet yet -> the branch cannot apply -> the
  -- transition fallback resolves its own fleet -> byte-identical. b1 is ungrouped -> likewise.
  r := public.mainship_space_validate_context(a1);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'at_location' then
    raise exception 'ORACLEPARITY FAIL (lit, grouped, no unified fleet yet): %', r; end if;
  if public.mainship_resolve_docked_location(a1) is distinct from haven then
    raise exception 'ORACLEPARITY FAIL (lit): dock resolver drifted for a group with no unified fleet'; end if;
  r := public.mainship_space_validate_context(b1);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'at_location' then
    raise exception 'ORACLEPARITY FAIL (lit, ungrouped): %', r; end if;

  raise notice 'FLEETGO_PASS_ORACLEPARITY: dark = the 0056 head; lighting the flag changes NOTHING for an ungrouped ship or a group with no fleet yet';
end $$;

-- ════════ BLOCK DOCKDEDUP-DARKPARITY (3c-2): dark, before ANY go — the three rewired hosts answer the dock ════
-- 0211 re-creates get_my_current_dock_services / get_my_docked_store / get_my_fleet_positions onto the
-- ONE resolver pair (0210). While dark, the resolver's per-ship fallback must hand each host the exact
-- row the old inline `f.main_ship_id = <ship>` read selected, so every envelope is bit-equal.
-- HOW THIS FAILS IF THE CODE WERE WRONG: if the rewire resolved through a guard the dark world cannot
-- satisfy — the resolver's group branch left UNGATED (grabbing a group-shaped fleet), or the map read
-- collapsed onto the at_location-only dock helper, or the fallback keyed on the wrong column — the
-- grouped ship a1 (or the ungrouped b1) answers incoherent / hidden / NULL below instead of haven.
do $$
declare r jsonb; e jsonb; n int; v_eligible boolean;
  uA uuid := (select v from fg where k='uA'); uB uuid := (select v from fg where k='uB');
  a1 uuid := (select v from fg where k='a1'); b1 uuid := (select v from fg where k='b1');
  haven uuid := (select v from fg where k='haven');
begin
  -- vacuity guards: a1 must really be GROUPED (the shape 0210's group branch matches) and b1 ungrouped;
  -- without these the "grouped ship still answers its dock" claim is asserted on nothing.
  select count(*) into n from public.main_ship_instances where main_ship_id = a1 and group_id is not null;
  if n <> 1 then raise exception 'DOCKDEDUP-DARKPARITY FAIL: a1 is not grouped — the grouped case would be vacuous'; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = b1 and group_id is null;
  if n <> 1 then raise exception 'DOCKDEDUP-DARKPARITY FAIL: b1 is grouped — the ungrouped case would be vacuous'; end if;

  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';

  -- (1) dock services — docked=true at the commission dock, grouped and ungrouped alike.
  r := pg_temp.call_as(uA, format('public.get_my_current_dock_services(%L::uuid)', a1));
  if (r->>'state') is distinct from 'at_location' or (r->>'docked')::boolean is not true
     or (r->>'location_id')::uuid is distinct from haven then
    raise exception 'DOCKDEDUP-DARKPARITY FAIL: dock_services(grouped a1) drifted while dark: %', r; end if;
  r := pg_temp.call_as(uB, format('public.get_my_current_dock_services(%L::uuid)', b1));
  if (r->>'state') is distinct from 'at_location' or (r->>'docked')::boolean is not true
     or (r->>'location_id')::uuid is distinct from haven then
    raise exception 'DOCKDEDUP-DARKPARITY FAIL: dock_services(ungrouped b1) drifted while dark: %', r; end if;

  -- (2) docked store — the haven hangar. store_id presence is pinned as an IFF against the function's
  --     OWN eligibility rule (the SETTLEPARITY idiom: pin the rule, not a guess about the seed port).
  v_eligible := public.is_home_port_eligible(haven);
  r := pg_temp.call_as(uA, format('public.get_my_docked_store(%L::uuid)', a1));
  if (r->>'state') is distinct from 'at_location' or (r->>'docked')::boolean is not true
     or (r->>'location_id')::uuid is distinct from haven then
    raise exception 'DOCKDEDUP-DARKPARITY FAIL: docked_store(grouped a1) drifted while dark: %', r; end if;
  if v_eligible and (r->>'store_id') is null then
    raise exception 'DOCKDEDUP-DARKPARITY FAIL: haven is store-eligible but docked_store returned no store'; end if;
  if not v_eligible and (r->>'store_id') is not null then
    raise exception 'DOCKDEDUP-DARKPARITY FAIL: haven is NOT store-eligible but docked_store invented a store'; end if;

  -- (3) the map read — place='docked' at haven for BOTH ships (grouped a1 via uA, ungrouped b1 via uB).
  r := pg_temp.call_as(uA, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = a1::text;
  if e is null or (e->>'place') is distinct from 'docked' or (e->>'location_id')::uuid is distinct from haven then
    raise exception 'DOCKDEDUP-DARKPARITY FAIL: fleet_positions(grouped a1) drifted while dark: %', e; end if;
  r := pg_temp.call_as(uB, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = b1::text;
  if e is null or (e->>'place') is distinct from 'docked' or (e->>'location_id')::uuid is distinct from haven then
    raise exception 'DOCKDEDUP-DARKPARITY FAIL: fleet_positions(ungrouped b1) drifted while dark: %', e; end if;

  -- (4) the port-entry replay (host D — the fifth copy the first cut missed): already provisioned,
  --     docked at haven, grouped and ungrouped alike. FAIL MODE: host D's envelope has no null guard,
  --     so a drifted read answers {docked:true, location_id:null} — caught by the location_id pin.
  --     (0072's classify resolves the player's ship with an unqualified select — a pre-existing
  --     single-ship wart, untouched — so with uA's two ships it picks one arbitrarily; both are docked
  --     at haven, so the assertion holds for either pick.)
  r := pg_temp.call_as(uA, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'already_provisioned')::boolean is not true
     or (r->>'docked')::boolean is not true or (r->>'location_id')::uuid is distinct from haven then
    raise exception 'DOCKDEDUP-DARKPARITY FAIL: commission replay (grouped uA) drifted while dark: %', r; end if;
  r := pg_temp.call_as(uB, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'already_provisioned')::boolean is not true
     or (r->>'docked')::boolean is not true or (r->>'location_id')::uuid is distinct from haven then
    raise exception 'DOCKDEDUP-DARKPARITY FAIL: commission replay (ungrouped uB) drifted while dark: %', r; end if;

  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_DOCKDEDUP_DARKPARITY: all four rewired hosts (dock services, hangar, map, port-entry replay) answer the dock while dark, grouped and ungrouped alike';
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
  -- ★ AND the one it is blind to: the members must not still be docked where they departed ★
  -- The bootstrap case is the worst: it RESOLVES the origin from the members' own present fleets, so
  -- those fleets provably exist at this moment and must be dissolved by the go itself.
  perform pg_temp.assert_no_ghost_dock(uA, g, 'first go (bootstrap from the dock)');

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
  raise notice 'FLEETGO_PASS_NOGHOSTDOCK: the go dissolved every member''s own dock — no ship left trading at a port the fleet has left';
end $$;

-- ════════ BLOCK COMBATDEST: a MOVE is not a HUNT — a combat destination is refused ════════
-- Found by the step-3c/4 recon, not by the 3a/3b proofs (which never flew to a hunt site).
-- The settle creates a presence carrying the target's activity_type, and an activity='hunt_pirates'
-- presence is what combat_create_encounter routes on. A unified fleet has NO combat_units and no
-- group_sortie_members manifest, so it would snapshot zero units and the tick's defeat branch would
-- DESTROY the whole fleet on arrival. Hunts go through send_ship_group_hunt, which builds the manifest.
do $$
declare r jsonb; n int; uA uuid := (select v from fg where k='uA'); g uuid := (select v from fg where k='g');
  v_hunt uuid;
begin
  select id into v_hunt from public.locations
   where status = 'active' and activity_type = 'hunt_pirates' limit 1;
  if v_hunt is null then
    raise exception 'COMBATDEST FAIL: no active hunt_pirates location in the fixture — the assertion would be vacuous';
  end if;
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, v_hunt));
  if (r->>'reason') is distinct from 'combat_destination' then
    raise exception 'COMBATDEST FAIL: the mover accepted a hunt site (the fleet would be destroyed on arrival): %', r; end if;
  -- and it refused BEFORE writing anything: no leg was created for it.
  select count(*) into n from public.fleet_movements where target_location_id = v_hunt;
  if n <> 0 then raise exception 'COMBATDEST FAIL: % leg(s) created toward a combat destination', n; end if;
  raise notice 'FLEETGO_PASS_COMBATDEST: a move refuses a combat destination (a move is not a hunt)';
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
  perform pg_temp.assert_no_ghost_dock(uA, g, 'redirect');

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
  perform pg_temp.assert_no_ghost_dock(uA, g, 'coordinate go');

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
  perform pg_temp.assert_no_ghost_dock(uA, g, 'go from space');

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

-- ════════ BLOCK GROUPREAD (3c-1): THE 3c DELIVERABLE — a ship's place IS its fleet's place ════════
-- This is the assertion the charter's step 3c is actually asking for: "the members are invisible at the
-- port the group docked at". Before 3c-1 every member resolved 'legacy_home' → place='hidden' → the whole
-- group vanished from the map on arrival and the Port tab emptied. The mover worked; the game could not
-- SEE it. Note WHY this is only provable now: 0208's ghost-dock fix dissolved the members' own per-ship
-- fleets, so there is NO per-ship row left to read — the ONLY way a member can report a place is through
-- its group's fleet. The two fixes prove each other.
do $$
declare r jsonb; e jsonb; e2 jsonb; n int; s uuid;
  uA uuid := (select v from fg where k='uA'); g uuid := (select v from fg where k='g');
  a1 uuid := (select v from fg where k='a1'); a2 uuid := (select v from fg where k='a2');
  slag uuid := (select v from fg where k='slag'); v_fleet uuid := (select v from fg where k='fleet');
  v_mv uuid; v_loc uuid; v_fx double precision; v_fy double precision; v_fm record;
begin
  -- (1) HELD IN SPACE — the STOP block left the fleet holding at its turn point. Each member's place is
  --     the FLEET's coordinate, read from fleets.space_x/space_y. No ship carries a position.
  select space_x, space_y into v_fx, v_fy from public.fleets where id = v_fleet;
  if v_fx is null then raise exception 'GROUPREAD FAIL: fixture fleet is not parked — assertion vacuous'; end if;
  foreach s in array array[a1, a2] loop
    r := public.mainship_space_validate_context(s);
    if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'in_space' then
      raise exception 'GROUPREAD FAIL: member % of a fleet parked in space reads % (expected in_space)', s, r; end if;
  end loop;

  -- ★ 3c-3 (MAPSPACE_GROUP): the MAP draws every member at the FLEET's parked coordinate. ★
  -- Before 0212 the in_space arm read s.space_x/s.space_y — SHIP columns the unified world never
  -- writes (fleet_set_in_space parks the FLEET; NOSHIPWRITE pins the omission) — so a parked/braked
  -- fleet's members all drew place='hidden': the fleet the brake just held went invisible.
  -- HOW THIS FAILS IF THE CODE WERE WRONG: against 0211 alone (revert hunks 2/3 to the ship-only
  -- read), with zero ship coords in existence — asserted below — every member reads 'hidden' here.
  -- Red-before/green-after by construction.
  -- vacuity guard: ZERO ships carry any position, so only the FLEET could have answered these coords.
  select count(*) into n from public.main_ship_instances where space_x is not null or space_y is not null;
  if n <> 0 then
    raise exception 'MAPSPACE-GROUP FAIL: % ship(s) carry a position — only the FLEET could have answered is unprovable', n; end if;
  r := pg_temp.call_as(uA, 'public.get_my_fleet_positions()');
  foreach s in array array[a1, a2] loop
    e := null;
    select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = s::text;
    if e is null or (e->>'place') is distinct from 'in_space'
       or (e->>'space_x')::double precision is distinct from v_fx
       or (e->>'space_y')::double precision is distinct from v_fy then
      raise exception 'MAPSPACE-GROUP FAIL: member % of a fleet parked at (%,%) draws % — the parked fleet is invisible on the map', s, v_fx, v_fy, e; end if;
  end loop;
  raise notice 'FLEETGO_PASS_MAPSPACE_GROUP: every member draws in_space at the FLEET''s parked coordinate (zero ships carry any position)';

  -- (2) FLY TO A PORT AND SETTLE — then the members must be VISIBLE there.
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, slag));
  if (r->>'ok')::boolean is not true then raise exception 'GROUPREAD FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;

  -- in transit, every member reports the ONE fleet's transit — not N transits.
  foreach s in array array[a1, a2] loop
    r := public.mainship_space_validate_context(s);
    if (r->>'state') is distinct from 'legacy_transit' then
      raise exception 'GROUPREAD FAIL: member % in flight reads % (expected legacy_transit)', s, r; end if;
  end loop;

  -- ★ 3c-3 (MAPTRANSIT_GROUP): mid-go, the MAP draws every member on the ONE unified leg. ★
  -- Before 0212 the legacy_transit arm keyed fleet_movements on `f.main_ship_id = s.main_ship_id` —
  -- NULL on the unified fleet — so a flying group's members drew place='hidden' for the whole flight
  -- even though the oracle (just asserted above) already said legacy_transit.
  -- HOW THIS FAILS IF THE CODE WERE WRONG: against 0211 alone this block is RED (segment select finds
  -- nothing → place='hidden'); against a rekey that resolved the WRONG fleet the segment-equality pin
  -- reds instead. Red-before/green-after by construction.
  -- vacuity guard: zero per-ship fleets exist, so no retired-layer row could have supplied a segment.
  select count(*) into n from public.fleets
   where player_id = uA and main_ship_id in (a1, a2) and status in ('idle','moving','present','returning');
  if n <> 0 then
    raise exception 'MAPTRANSIT-GROUP FAIL: % per-ship fleet(s) exist — the transit could be answered by the retired layer', n; end if;
  select * into v_fm from public.fleet_movements where id = v_mv;
  if v_fm.id is null or v_fm.status is distinct from 'moving' then
    raise exception 'MAPTRANSIT-GROUP FAIL: the unified leg is not moving — fixture vacuous'; end if;
  r := pg_temp.call_as(uA, 'public.get_my_fleet_positions()');
  e2 := null;
  foreach s in array array[a1, a2] loop
    e := null;
    select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = s::text;
    if e is null or (e->>'place') is distinct from 'transit' or (e->'segment') is null
       or jsonb_typeof(e->'segment') is distinct from 'object' then
      raise exception 'MAPTRANSIT-GROUP FAIL: member % of a flying group draws % (expected transit + a segment)', s, e; end if;
    if (e->'segment'->>'origin_x')::double precision is distinct from v_fm.origin_x
       or (e->'segment'->>'origin_y')::double precision is distinct from v_fm.origin_y
       or (e->'segment'->>'target_x')::double precision is distinct from v_fm.target_x
       or (e->'segment'->>'target_y')::double precision is distinct from v_fm.target_y
       or (e->'segment'->>'target_kind') is distinct from v_fm.target_type
       or (e->'segment'->>'depart_at')::timestamptz is distinct from v_fm.depart_at
       or (e->'segment'->>'arrive_at')::timestamptz is distinct from v_fm.arrive_at then
      raise exception 'MAPTRANSIT-GROUP FAIL: member % segment % is not the ONE unified movement', s, e->'segment'; end if;
    if e2 is not null and (e->'segment') is distinct from e2 then
      raise exception 'MAPTRANSIT-GROUP FAIL: members carry DIFFERENT segments — N transits is the composed model §2 forbids'; end if;
    e2 := e->'segment';
  end loop;
  raise notice 'FLEETGO_PASS_MAPTRANSIT_GROUP: every member draws the SAME segment = the ONE unified leg (zero per-ship fleets in existence)';

  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_mv;
  perform pg_temp.snap_ships('before_groupsettle');
  perform public.movement_settle_arrival(v_mv);
  perform pg_temp.snap_ships('after_groupsettle');
  -- ★ §2 holds through the group's ARRIVAL too — the cron docks the fleet, never a ship ★
  perform pg_temp.assert_ships_untouched('before_groupsettle', 'after_groupsettle', 'group settle at a port');

  -- ★★ THE DELIVERABLE ★★ — the group no longer vanishes on arrival.
  foreach s in array array[a1, a2] loop
    r := public.mainship_space_validate_context(s);
    if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'at_location' then
      raise exception 'GROUPREAD FAIL: member % is INVISIBLE at the port its fleet docked at — reads %', s, r; end if;
    v_loc := public.mainship_resolve_docked_location(s);
    if v_loc is distinct from slag then
      raise exception 'GROUPREAD FAIL: the dock resolver returned % for member % (expected the group''s port %)', v_loc, s, slag; end if;
  end loop;

  -- ...and it is true WITHOUT any member holding a per-ship fleet of its own. There is no other row that
  -- could have answered: the place came from the group's fleet or from nowhere.
  select count(*) into n from public.fleets
   where player_id = uA and main_ship_id in (a1, a2) and status in ('idle','moving','present','returning');
  if n <> 0 then
    raise exception 'GROUPREAD FAIL: % per-ship fleet(s) exist — the read could be answered by the retired layer', n; end if;

  raise notice 'FLEETGO_PASS_GROUPREAD: every member reads its FLEET''s place (in_space -> transit -> docked at the group''s port), with no per-ship fleet in existence';
end $$;

-- ════════ BLOCK DOCKDEDUP-GROUPDOCKED (3c-2, lit): the rewired hosts see the GROUP's dock ════════
-- GROUPREAD just docked the unified fleet at Slagworks and proved the ORACLE sees it. This block proves
-- the rewired dock/store/map hosts see it too (host D — the port-entry replay — has its own lit block
-- right after) — before 0211 each still keyed its own read on
-- `f.main_ship_id = <ship>` (NULL on a unified fleet), so dock services answered 'incoherent', the
-- hangar vanished, and the map drew nothing, even with the oracle fixed.
-- HOW THIS FAILS IF THE CODE WERE WRONG: revert any host to its inline read (or key the map read back
-- on main_ship_id) and every assertion below reads incoherent/hidden — there is no per-ship row left
-- to answer from, which is also why the vacuity guard below re-asserts that fact: with zero per-ship
-- fleets in existence, ONLY the group's fleet could have produced these answers.
do $$
declare r jsonb; e jsonb; n int; s uuid; v_eligible boolean;
  uA uuid := (select v from fg where k='uA');
  a1 uuid := (select v from fg where k='a1'); a2 uuid := (select v from fg where k='a2');
  slag uuid := (select v from fg where k='slag');
begin
  -- vacuity guard (0210's, re-asserted at this exact moment): no member holds a per-ship fleet, so no
  -- retired-layer row could fake the answers below.
  select count(*) into n from public.fleets
   where player_id = uA and main_ship_id in (a1, a2) and status in ('idle','moving','present','returning');
  if n <> 0 then
    raise exception 'DOCKDEDUP-GROUPDOCKED FAIL: % per-ship fleet(s) exist — the read could be answered by the retired layer', n; end if;

  v_eligible := public.is_home_port_eligible(slag);
  foreach s in array array[a1, a2] loop
    r := pg_temp.call_as(uA, format('public.get_my_current_dock_services(%L::uuid)', s));
    if (r->>'state') is distinct from 'at_location' or (r->>'docked')::boolean is not true
       or (r->>'location_id')::uuid is distinct from slag then
      raise exception 'DOCKDEDUP-GROUPDOCKED FAIL: dock_services(member %) cannot see the group''s port: %', s, r; end if;

    r := pg_temp.call_as(uA, format('public.get_my_docked_store(%L::uuid)', s));
    if (r->>'state') is distinct from 'at_location' or (r->>'docked')::boolean is not true
       or (r->>'location_id')::uuid is distinct from slag then
      raise exception 'DOCKDEDUP-GROUPDOCKED FAIL: docked_store(member %) cannot see the group''s port: %', s, r; end if;
    -- store presence pinned as an IFF against the function's OWN eligibility rule (never a seed guess).
    if v_eligible and (r->>'store_id') is null then
      raise exception 'DOCKDEDUP-GROUPDOCKED FAIL: the group''s port is store-eligible but member % got no store', s; end if;
    if not v_eligible and (r->>'store_id') is not null then
      raise exception 'DOCKDEDUP-GROUPDOCKED FAIL: the group''s port is NOT store-eligible but member % got a store', s; end if;
  end loop;

  -- the map: BOTH members drawn docked at the group's port (before 3c the whole group vanished here).
  r := pg_temp.call_as(uA, 'public.get_my_fleet_positions()');
  foreach s in array array[a1, a2] loop
    e := null;
    select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = s::text;
    if e is null or (e->>'place') is distinct from 'docked' or (e->>'location_id')::uuid is distinct from slag then
      raise exception 'DOCKDEDUP-GROUPDOCKED FAIL: fleet_positions hides member % of the docked group: %', s, e; end if;
  end loop;

  raise notice 'FLEETGO_PASS_DOCKDEDUP_GROUPDOCKED: dock services + hangar + map all answer the GROUP''s port for every member, with zero per-ship fleets in existence';
end $$;

-- ════════ BLOCK DOCKDEDUP-COMMISSION (3c-2, lit): the port-entry replay sees the GROUP's dock ════════
-- Host D (commission_first_main_ship) is the RPC every player's entry path replays; an existing docked
-- ship takes its 'at_location' classify branch. Before 0211 that branch read the dock with the
-- alias-free inline copy (0072:141-142) — NULL for a unified-group member whose per-ship fleet 0208
-- dissolved — and, uniquely among the four hosts, its envelope has NO null guard: the entry path would
-- report {docked:true, location_id:null}. The envelope is pre-existing and parity governs; only the
-- read was rekeyed, so the location_id pin below is the whole proof.
-- HOW THIS FAILS IF THE CODE WERE WRONG: revert host D to the 0072 inline read and — with zero
-- per-ship fleets in existence (asserted below) — v_dock resolves NULL → location_id null → the pin
-- reds. If someone instead "fixes" the null envelope away from 0072's shape, the ok/docked shape
-- assertions red.
do $$
declare r jsonb; n int;
  uA uuid := (select v from fg where k='uA');
  a1 uuid := (select v from fg where k='a1'); a2 uuid := (select v from fg where k='a2');
  slag uuid := (select v from fg where k='slag');
begin
  -- vacuity: zero per-ship fleets — only the group's fleet can answer (0210's guard, re-asserted).
  select count(*) into n from public.fleets
   where player_id = uA and main_ship_id in (a1, a2) and status in ('idle','moving','present','returning');
  if n <> 0 then
    raise exception 'DOCKDEDUP-COMMISSION FAIL: % per-ship fleet(s) exist — the replay could be answered by the retired layer', n; end if;
  -- 0072's classify resolves the player's ship with an unqualified select (pre-existing single-ship
  -- wart, untouched by 0211): with uA's TWO ships it picks one arbitrarily — but both are members
  -- docked with the same group fleet, so the assertion holds for either pick (and reds for both on
  -- the old inline body).
  r := pg_temp.call_as(uA, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'already_provisioned')::boolean is not true
     or (r->>'docked')::boolean is not true then
    raise exception 'DOCKDEDUP-COMMISSION FAIL: replay envelope drifted: %', r; end if;
  if (r->>'location_id')::uuid is distinct from slag then
    raise exception 'DOCKDEDUP-COMMISSION FAIL: replay reports location_id % — not the group''s port (the 0072 inline read leaves it NULL here)', r->>'location_id'; end if;
  raise notice 'FLEETGO_PASS_DOCKDEDUP_COMMISSION: the port-entry replay answers the GROUP''s real port for a docked member (no per-ship fleet in existence)';
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

-- ════════ BLOCK DOCKDEDUP-HUNTOVERLAP (3c-2, dark — THE CROWN JEWEL: pins 0210's LESSON THREE) ════════
-- The reachable dark hole: send_ship_group_hunt builds ONE fleet with group_id set + main_ship_id NULL —
-- EXACTLY the shape mainship_resolve_fleet's group branch matches — and the hunt's member list is FROZEN
-- in group_sortie_members at send, while the resolver reads LIVE membership. assign_ship_to_group has no
-- movement-state guard, so a player can assign a freshly-docked ship into a group whose hunt fleet is in
-- flight. This block builds that state with LIVE RPCs ONLY (real hunt, real commission, real assign) in
-- uC's separate world, and asserts every dock read still answers the ship's OWN port — twice: while the
-- hunt fleet is 'moving', and again after it settles 'present' AT the hunt site.
-- HOW THIS FAILS IF THE CODE WERE WRONG (traced line-by-line against the unpatched 0210 body; the
-- red run itself needs the CI's disposable Postgres — this machine has none): without the
-- cfg_bool gate on the resolver's group branch, resolve_fleet(c2) returns the HUNT fleet — while it is
-- 'moving' the status='present' dock reads come back NULL (dock_services/store → 'incoherent', map →
-- 'hidden': red at phase 1), and once it settles 'present' at the hunt site every read answers the HUNT
-- SITE instead of c2's port (red at phase 2). It runs DARK because that is the whole point: this wrong
-- answer would ship with the unification flag OFF.
-- PLACEMENT IS LOAD-BEARING: this MUST stay AFTER the ISOLATION block — a REAL hunt writes
-- group_sortie_members manifest rows (and its settle creates a live encounter), which ISOLATION
-- rightly asserts the unified MOVER never does. Moving this block above ISOLATION reds ISOLATION.
do $$
declare r jsonb; e jsonb; n int;
  uC uuid := (select v from fg where k='uC');
  c1 uuid; c2 uuid; gC uuid; v_hunt uuid; v_huntfleet uuid; v_huntmv uuid; v_port uuid;
begin
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';

  -- ── live-RPC provisioning: c1 docked → group → REAL hunt (launch-from-dock, ON in prod). ─────────
  r := pg_temp.call_as(uC, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTOVERLAP FAIL: commission c1: %', r; end if;
  select main_ship_id into c1 from public.main_ship_instances where player_id = uC;
  r := pg_temp.call_as(uC, 'public.upsert_ship_group(1, ''Corsairs'')');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTOVERLAP FAIL: group: %', r; end if;
  gC := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uC, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', c1, gC));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTOVERLAP FAIL: assign c1: %', r; end if;

  select id into v_hunt from public.locations
   where status = 'active' and activity_type = 'hunt_pirates'
   order by coalesce(min_power_required, 0) asc limit 1;
  if v_hunt is null then
    raise exception 'HUNTOVERLAP FAIL: no active hunt site in the fixture — the overlap cannot be built'; end if;

  r := pg_temp.call_as(uC, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gC, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTOVERLAP FAIL: real hunt send rejected: %', r; end if;
  v_huntfleet := (r->>'fleet_id')::uuid;
  v_huntmv    := (r->>'movement_id')::uuid;

  -- ── the overlap: commission a FRESH ship and assign it into the HUNTING group (live RPCs only). ──
  r := pg_temp.call_as(uC, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTOVERLAP FAIL: commission c2: %', r; end if;
  c2 := (r->>'main_ship_id')::uuid;
  r := pg_temp.call_as(uC, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', c2, gC));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTOVERLAP FAIL: assign c2 into the hunting group: %', r; end if;

  -- ── vacuity guards: the overlap must REALLY exist, or every assertion below proves nothing. ──────
  select count(*) into n from public.fleets
   where id = v_huntfleet and group_id = gC and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'HUNTOVERLAP FAIL: the hunt fleet is not live — overlap not built'; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = c2 and group_id = gC;
  if n <> 1 then raise exception 'HUNTOVERLAP FAIL: c2 is not a member of the hunting group — overlap not built'; end if;
  select count(*) into n from public.group_sortie_members where fleet_id = v_huntfleet and main_ship_id = c2;
  if n <> 0 then raise exception 'HUNTOVERLAP FAIL: c2 is ON the hunt manifest — the frozen-vs-live split is gone'; end if;
  select f.current_location_id into v_port from public.fleets f
   where f.main_ship_id = c2 and f.status = 'present';
  if v_port is null then raise exception 'HUNTOVERLAP FAIL: c2 has no present per-ship fleet — its own port is undefined'; end if;
  if v_port = v_hunt then raise exception 'HUNTOVERLAP FAIL: c2''s port IS the hunt site — right/wrong answers indistinguishable'; end if;

  -- ── phase 1: hunt fleet MOVING. Every dock read answers c2's OWN port. ───────────────────────────
  if (select status from public.fleets where id = v_huntfleet) is distinct from 'moving' then
    raise exception 'HUNTOVERLAP FAIL: hunt fleet is not moving at phase 1'; end if;
  r := public.mainship_space_validate_context(c2);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'at_location' then
    raise exception 'HUNTOVERLAP FAIL (moving): validate_context(c2) = %', r; end if;
  if public.mainship_resolve_docked_location(c2) is distinct from v_port then
    raise exception 'HUNTOVERLAP FAIL (moving): resolve_docked_location(c2) is not c2''s own port'; end if;
  r := pg_temp.call_as(uC, format('public.get_my_current_dock_services(%L::uuid)', c2));
  if (r->>'docked')::boolean is not true or (r->>'location_id')::uuid is distinct from v_port then
    raise exception 'HUNTOVERLAP FAIL (moving): dock_services(c2) = %', r; end if;
  r := pg_temp.call_as(uC, format('public.get_my_docked_store(%L::uuid)', c2));
  if (r->>'docked')::boolean is not true or (r->>'location_id')::uuid is distinct from v_port then
    raise exception 'HUNTOVERLAP FAIL (moving): docked_store(c2) = %', r; end if;
  r := pg_temp.call_as(uC, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = c2::text;
  if e is null or (e->>'place') is distinct from 'docked' or (e->>'location_id')::uuid is distinct from v_port then
    raise exception 'HUNTOVERLAP FAIL (moving): fleet_positions(c2) = %', e; end if;

  -- ── phase 2: the hunt SETTLES 'present' at the hunt site — the wrong answer becomes a concrete
  --    wrong PORT, not just a NULL. Backdate both ends (now() is txn-constant; arrive_at > depart_at
  --    must survive) and settle through the real cron entry point.
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_huntmv;
  perform public.movement_settle_arrival(v_huntmv);
  select count(*) into n from public.fleets
   where id = v_huntfleet and status = 'present' and current_location_id = v_hunt;
  if n <> 1 then raise exception 'HUNTOVERLAP FAIL: hunt fleet did not settle present at the hunt site — phase 2 vacuous'; end if;

  r := public.mainship_space_validate_context(c2);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'at_location' then
    raise exception 'HUNTOVERLAP FAIL (settled): validate_context(c2) = %', r; end if;
  if public.mainship_resolve_docked_location(c2) is distinct from v_port then
    raise exception 'HUNTOVERLAP FAIL (settled): resolve_docked_location(c2) answers the HUNT SITE, not c2''s own port'; end if;
  r := pg_temp.call_as(uC, format('public.get_my_current_dock_services(%L::uuid)', c2));
  if (r->>'docked')::boolean is not true or (r->>'location_id')::uuid is distinct from v_port then
    raise exception 'HUNTOVERLAP FAIL (settled): dock_services(c2) = %', r; end if;
  r := pg_temp.call_as(uC, format('public.get_my_docked_store(%L::uuid)', c2));
  if (r->>'docked')::boolean is not true or (r->>'location_id')::uuid is distinct from v_port then
    raise exception 'HUNTOVERLAP FAIL (settled): docked_store(c2) = %', r; end if;
  r := pg_temp.call_as(uC, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = c2::text;
  if e is null or (e->>'place') is distinct from 'docked' or (e->>'location_id')::uuid is distinct from v_port then
    raise exception 'HUNTOVERLAP FAIL (settled): fleet_positions(c2) = %', e; end if;

  insert into fg values ('c2', c2);
  -- restore the flag IN-BLOCK: a block that flips shared state must undo it (the member_busy lesson) —
  -- no later block may silently inherit this one's dark world.
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_DOCKDEDUP_HUNTOVERLAP: a ship assigned into a hunting group mid-flight keeps answering its OWN port while dark — hunt moving AND settled (the frozen-manifest-vs-live-membership hole is closed)';
end $$;

-- ════════ BLOCK DOCKDEDUP-LEGACYPRESENT (3c-2, dark): prod's stuck-ship shape still draws docked ════════
-- The guard against Finding 1's regression. 0200's dock read is reached under 'at_location' OR
-- 'legacy_present', and prod's live ships are legacy-shaped (spatial_state NULL; four sit at a lying
-- status='traveling' with their fleet honestly 'present' at a port — the diagnosed orphan shape).
-- 0211 therefore rekeys that read onto mainship_resolve_fleet, KEEPING its own status='present' filter —
-- NOT onto the at_location-only dock helper.
-- HOW THIS FAILS IF THE CODE WERE WRONG: collapse the 0200 site onto mainship_resolve_docked_location
-- (which returns NULL for anything not strictly 'at_location') and this ship maps place='hidden' — every
-- legacy-present prod ship would vanish from the map the day 0211 deploys, flag OFF.
do $$
declare r jsonb; e jsonb; n int;
  uB uuid := (select v from fg where k='uB'); b1 uuid := (select v from fg where k='b1');
  v_port uuid; v_old_status text; v_old_ss text;
begin
  -- self-contained DARK: this block flips the flag itself and restores it at the end — no implicit
  -- coupling to whichever block ran before it.
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';

  -- SURGERY (marked): manufacture the diagnosed prod shape on b1 — spatial_state NULL + status
  -- 'traveling' with NOTHING behind it, while its own fleet sits honestly 'present' at a port.
  -- This is fixture shaping for a state prod already contains; the live RPCs cannot mint it on demand.
  select status, spatial_state into v_old_status, v_old_ss
    from public.main_ship_instances where main_ship_id = b1;
  update public.main_ship_instances
     set status = 'traveling', spatial_state = null where main_ship_id = b1;

  -- vacuity guards: exactly ONE active per-ship fleet, 'present' at a real port, with a matching ACTIVE
  -- presence — otherwise the oracle answers for some other reason and the block proves nothing.
  select count(*) into n from public.fleets
   where main_ship_id = b1 and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'LEGACYPRESENT FAIL: b1 has % active fleet(s) — fixture is not prod''s shape', n; end if;
  select f.current_location_id into v_port from public.fleets f
   where f.main_ship_id = b1 and f.status = 'present';
  if v_port is null then raise exception 'LEGACYPRESENT FAIL: b1''s fleet is not present at a port — fixture vacuous'; end if;
  select count(*) into n from public.location_presence lp
    join public.fleets f on f.id = lp.fleet_id
   where f.main_ship_id = b1 and lp.status = 'active' and lp.location_id = v_port;
  if n <> 1 then raise exception 'LEGACYPRESENT FAIL: no active presence at the port — fixture vacuous'; end if;

  r := public.mainship_space_validate_context(b1);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'legacy_present' then
    raise exception 'LEGACYPRESENT FAIL: validate_context = % (expected legacy_present)', r; end if;

  r := pg_temp.call_as(uB, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = b1::text;
  if e is null or (e->>'place') is distinct from 'docked' or (e->>'location_id')::uuid is distinct from v_port then
    raise exception 'LEGACYPRESENT FAIL: the map hides prod''s legacy-present shape (0200''s wider guard regressed): %', e; end if;

  -- restore the fixture shape (surgery must undo itself — the member_busy lesson), then the flag.
  update public.main_ship_instances
     set status = v_old_status, spatial_state = v_old_ss where main_ship_id = b1;
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  raise notice 'FLEETGO_PASS_DOCKDEDUP_LEGACYPRESENT: a legacy-present ship (prod''s stuck shape) still draws place=docked at its fleet''s port';
end $$;

-- ════════ BLOCK MAPTRANSIT-DARKPARITY (3c-3, dark): a legacy in-transit ship still draws its OWN leg ════════
-- 0212's hunk 1 rekeys the map's legacy_transit read from `f.main_ship_id = s.main_ship_id` to the ONE
-- ship→fleet resolver. Dark, 'legacy_transit' comes only from the 0056 head, whose guard pins EXACTLY
-- ONE per-ship fleet in an active status carrying a moving fleet_movements row — and the resolver's
-- gated fallback returns exactly that fleet, so the new key must select the SAME row the old key did.
-- Asserted for a GROUPED ship (a1 — the resolver's group branch must stay gated off while dark) AND an
-- UNGROUPED ship (b1 — the pure fallback path).
-- HOW THIS FAILS IF THE CODE WERE WRONG: if the rekey resolved through a guard the dark world cannot
-- satisfy (group branch ungated → the group's 'present' fleet answers with NO moving leg → 'hidden';
-- resolver failing closed on a coherent single-fleet ship → 'hidden'; wrong fleet → the segment pin
-- reds), the place/segment assertions below go red for the grouped ship, the ungrouped ship, or both.
do $$
declare r jsonb; e jsonb; n int;
  uA uuid := (select v from fg where k='uA'); uB uuid := (select v from fg where k='uB');
  a1 uuid := (select v from fg where k='a1'); b1 uuid := (select v from fg where k='b1');
  slag uuid := (select v from fg where k='slag');
  v_loc record; v_base record; v_f uuid; v_mv uuid; v_fm record; v_old_ss text;
begin
  -- self-contained DARK (the LEGACYPRESENT idiom): flip, and restore at the end.
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';
  select l.id, l.x, l.y into v_loc from public.locations l where l.id = slag;

  -- ── (A) the GROUPED ship a1. vacuity: really grouped, currently fleetless. ───────────────────────
  select count(*) into n from public.main_ship_instances where main_ship_id = a1 and group_id is not null;
  if n <> 1 then raise exception 'MAPTRANSIT-DARKPARITY FAIL: a1 is not grouped — the grouped case would be vacuous'; end if;
  select count(*) into n from public.fleets
   where main_ship_id = a1 and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'MAPTRANSIT-DARKPARITY FAIL: a1 already holds % per-ship fleet(s) — fixture unclean', n; end if;
  -- SURGERY (restored below): the legacy in-transit shape — spatial_state NULL + ONE per-ship 'moving'
  -- fleet on a moving leg (the shape the live per-ship send mints; composed via the frozen primitives).
  select spatial_state into v_old_ss from public.main_ship_instances where main_ship_id = a1;
  update public.main_ship_instances set spatial_state = null where main_ship_id = a1;
  select b.id, b.x, b.y into v_base from public.bases b where b.player_id = uA and b.status='active' order by b.created_at limit 1;
  if v_base.id is null then raise exception 'MAPTRANSIT-DARKPARITY FAIL: uA has no base — fixture cannot be built'; end if;
  insert into public.fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)
    values (uA, v_base.id, 'idle', 'base', v_base.id, a1) returning id into v_f;
  v_mv := public.movement_create(uA, v_f, 'base', v_base.id, null, null, v_base.x, v_base.y,
                                 'location', null, null, v_loc.id, v_loc.x, v_loc.y, 'rally', 1);
  perform public.fleet_set_moving(v_f, v_mv);
  -- vacuity guard: the oracle must answer legacy_transit, or the marker pins nothing.
  r := public.mainship_space_validate_context(a1);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'legacy_transit' then
    raise exception 'MAPTRANSIT-DARKPARITY FAIL: grouped fixture did not reach legacy_transit — %', r; end if;
  select * into v_fm from public.fleet_movements where id = v_mv;
  r := pg_temp.call_as(uA, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = a1::text;
  if e is null or (e->>'place') is distinct from 'transit' or (e->'segment') is null then
    raise exception 'MAPTRANSIT-DARKPARITY FAIL (grouped, dark): a legacy in-transit ship draws % (expected transit)', e; end if;
  if (e->'segment'->>'origin_x')::double precision is distinct from v_fm.origin_x
     or (e->'segment'->>'origin_y')::double precision is distinct from v_fm.origin_y
     or (e->'segment'->>'target_x')::double precision is distinct from v_fm.target_x
     or (e->'segment'->>'target_y')::double precision is distinct from v_fm.target_y
     or (e->'segment'->>'target_kind') is distinct from v_fm.target_type
     or (e->'segment'->>'depart_at')::timestamptz is distinct from v_fm.depart_at
     or (e->'segment'->>'arrive_at')::timestamptz is distinct from v_fm.arrive_at then
    raise exception 'MAPTRANSIT-DARKPARITY FAIL (grouped, dark): segment % is not the fleet''s own leg', e->'segment'; end if;
  -- restore a1 (surgery must undo itself — the member_busy lesson).
  update public.fleet_movements set status='cancelled', resolved_at=now() where id = v_mv;
  update public.fleets set status='completed', location_mode='movement', active_movement_id=null where id = v_f;
  update public.main_ship_instances set spatial_state = v_old_ss where main_ship_id = a1;

  -- ── (B) the UNGROUPED ship b1. vacuity: really ungrouped. ────────────────────────────────────────
  select count(*) into n from public.main_ship_instances where main_ship_id = b1 and group_id is null;
  if n <> 1 then raise exception 'MAPTRANSIT-DARKPARITY FAIL: b1 is grouped — the ungrouped case would be vacuous'; end if;
  -- SURGERY: dissolve b1's docked state (the SETTLEPARITY idiom), then the same in-transit shape.
  -- b1's present fleet + presence are NOT rebuilt afterwards: the next block (MAPSPACE-DARKPARITY)
  -- REQUIRES b1 fleetless, and nothing after these two blocks reads b1 (the txn rolls back).
  select spatial_state into v_old_ss from public.main_ship_instances where main_ship_id = b1;
  update public.main_ship_instances set spatial_state = null where main_ship_id = b1;
  perform public.presence_complete(lp.id) from public.location_presence lp
    join public.fleets f on f.id = lp.fleet_id
   where f.player_id = uB and f.main_ship_id = b1 and lp.status='active';
  update public.fleets set status='completed', location_mode='movement', active_movement_id=null
   where player_id = uB and main_ship_id = b1 and status='present';
  select b.id, b.x, b.y into v_base from public.bases b where b.player_id = uB and b.status='active' order by b.created_at limit 1;
  if v_base.id is null then raise exception 'MAPTRANSIT-DARKPARITY FAIL: uB has no base — fixture cannot be built'; end if;
  insert into public.fleets (player_id, origin_base_id, status, location_mode, current_base_id, main_ship_id)
    values (uB, v_base.id, 'idle', 'base', v_base.id, b1) returning id into v_f;
  v_mv := public.movement_create(uB, v_f, 'base', v_base.id, null, null, v_base.x, v_base.y,
                                 'location', null, null, v_loc.id, v_loc.x, v_loc.y, 'rally', 1);
  perform public.fleet_set_moving(v_f, v_mv);
  r := public.mainship_space_validate_context(b1);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'legacy_transit' then
    raise exception 'MAPTRANSIT-DARKPARITY FAIL: ungrouped fixture did not reach legacy_transit — %', r; end if;
  select * into v_fm from public.fleet_movements where id = v_mv;
  r := pg_temp.call_as(uB, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = b1::text;
  if e is null or (e->>'place') is distinct from 'transit' or (e->'segment') is null then
    raise exception 'MAPTRANSIT-DARKPARITY FAIL (ungrouped, dark): a legacy in-transit ship draws % (expected transit)', e; end if;
  if (e->'segment'->>'origin_x')::double precision is distinct from v_fm.origin_x
     or (e->'segment'->>'target_x')::double precision is distinct from v_fm.target_x
     or (e->'segment'->>'target_kind') is distinct from v_fm.target_type
     or (e->'segment'->>'depart_at')::timestamptz is distinct from v_fm.depart_at
     or (e->'segment'->>'arrive_at')::timestamptz is distinct from v_fm.arrive_at then
    raise exception 'MAPTRANSIT-DARKPARITY FAIL (ungrouped, dark): segment % is not the fleet''s own leg', e->'segment'; end if;
  -- restore the movement/fleet to terminal; ship spatial_state back to what it was.
  update public.fleet_movements set status='cancelled', resolved_at=now() where id = v_mv;
  update public.fleets set status='completed', location_mode='movement', active_movement_id=null where id = v_f;
  update public.main_ship_instances set spatial_state = v_old_ss where main_ship_id = b1;

  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_MAPTRANSIT_DARKPARITY: a legacy in-transit ship (grouped AND ungrouped) still draws its OWN fleet''s leg while dark';
end $$;

-- ════════ BLOCK MAPSPACE-DARKPARITY (3c-3, dark): an OSN-held ship still draws its OWN coordinates ════════
-- 0212's hunks 2-3 make the in_space arm FLEET-FIRST; the ship-coordinate elsif is the preserved dark
-- parity path. Dark, the 0056 head's in_space demands ZERO active fleets, so the resolver returns NULL,
-- the fleet read matches nothing, and ONLY the elsif can answer — this block pins that it still does.
-- PLACEMENT IS LOAD-BEARING: this writes a ship coordinate, which ISOLATION rightly asserts the unified
-- flow never produces — it must stay AFTER the ISOLATION block (the HUNTOVERLAP placement rule).
-- HOW THIS FAILS IF THE CODE WERE WRONG: "clean up" the elsif (delete the ship fallback) and this ship —
-- zero fleets, so the fleet-first read finds nothing — draws place='hidden' with null coords: red here,
-- and every real OSN-held prod ship would vanish from the map the day 0212 deploys, flag OFF.
do $$
declare r jsonb; e jsonb; n int;
  uB uuid := (select v from fg where k='uB'); b1 uuid := (select v from fg where k='b1');
  v_old_status text; v_old_ss text; v_old_x double precision; v_old_y double precision;
begin
  -- self-contained DARK: flip, and restore at the end.
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';

  -- vacuity guard: ZERO active fleets on b1 (the previous block left them terminal) — the resolver MUST
  -- come back NULL, so the ship fallback is the ONLY thing that can answer below.
  select count(*) into n from public.fleets
   where main_ship_id = b1 and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'MAPSPACE-DARKPARITY FAIL: b1 holds % active fleet(s) — the ship-fallback claim would be vacuous', n; end if;

  -- SURGERY (restored below): the OSN-held shape — stationary + spatial_state='in_space' + SHIP coords
  -- (what the retired per-ship stop/settle writes; the live RPCs cannot mint it on a fixture on demand).
  select status, spatial_state, space_x, space_y into v_old_status, v_old_ss, v_old_x, v_old_y
    from public.main_ship_instances where main_ship_id = b1;
  update public.main_ship_instances
     set status='stationary', spatial_state='in_space', space_x=555, space_y=-444
   where main_ship_id = b1;

  -- vacuity guard: the oracle must answer in_space, or the marker pins nothing.
  r := public.mainship_space_validate_context(b1);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'in_space' then
    raise exception 'MAPSPACE-DARKPARITY FAIL: fixture did not reach in_space — %', r; end if;

  r := pg_temp.call_as(uB, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = b1::text;
  if e is null or (e->>'place') is distinct from 'in_space'
     or (e->>'space_x')::double precision is distinct from 555::double precision
     or (e->>'space_y')::double precision is distinct from (-444)::double precision then
    raise exception 'MAPSPACE-DARKPARITY FAIL: an OSN-held ship draws % (expected in_space at its OWN 555,-444) — the ship fallback died', e; end if;

  -- restore the surgery, then the flag.
  update public.main_ship_instances
     set status=v_old_status, spatial_state=v_old_ss, space_x=v_old_x, space_y=v_old_y
   where main_ship_id = b1;
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_MAPSPACE_DARKPARITY: an OSN-held ship (zero fleets) still draws in_space at its OWN ship coordinates — the elsif fallback (dark parity path) survives';
end $$;

select 'FLEET-GO PROOF PASSED' as result;

rollback;
