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
-- S1-BERTH (0216): the snapshot now covers berth_location_id too — under the berth model a ship's
-- LOCATION for the unfleeted case lives in that column, so the §2 law ("a mover never writes a
-- ship") must cover it: a go/redirect/brake/settle that moved a berth would be a ship write.
create or replace function pg_temp.snap_ships(p_tag text) returns void language plpgsql as $$
begin
  insert into pg_temp.ship_snap
    select p_tag, main_ship_id, status, spatial_state, space_x, space_y, berth_location_id, updated_at
      from public.main_ship_instances;
end $$;

create temp table ship_snap(
  tag text, main_ship_id uuid, status text, spatial_state text,
  space_x double precision, space_y double precision, berth_location_id uuid, updated_at timestamptz
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
    (select main_ship_id,status,spatial_state,space_x,space_y,berth_location_id,updated_at from pg_temp.ship_snap where tag=p_before
     except
     select main_ship_id,status,spatial_state,space_x,space_y,berth_location_id,updated_at from pg_temp.ship_snap where tag=p_after)
    union all
    (select main_ship_id,status,spatial_state,space_x,space_y,berth_location_id,updated_at from pg_temp.ship_snap where tag=p_after
     except
     select main_ship_id,status,spatial_state,space_x,space_y,berth_location_id,updated_at from pg_temp.ship_snap where tag=p_before)
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

-- eight fresh players: uA (the group under test), uB (the foreign-owner probe), uC (the 3c-2
-- hunt-overlap world — kept separate so the REAL hunt it launches cannot poison uA's fixtures),
-- uD (the 4b-0 assign-guard world — its OWN hunt-in-flight fixture, same isolation reasoning),
-- uE/uF/uG/uH (the 4b-1 hunt-unification worlds: dark parity / the lit consume chain / the lit
-- =0 bootstrap pin / the from-space consume — each its own world because every one of them
-- launches a REAL hunt, and a hunt's manifest + 'hunting' ship writes poison any shared fixture),
-- uI (the 0215 brake-sortie world — its own REAL hunt, driven all the way to a RETAINED completed
-- manifest, so it must not share fixtures for the same reason as uE..uH),
-- uJ/uK (the S1-BERTH 0216 worlds: uJ runs the whole berth chain — commission → berthed map read →
-- first-assign mint → unassign → delete; uK exists ONLY to exercise the SECOND ship creator,
-- ensure_main_ship_for_player, whose create branch needs a zero-ship player).
do $$
declare u uuid; k text;
begin
  foreach k in array array['uA','uB','uC','uD','uE','uF','uG','uH','uI','uJ','uK'] loop
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
-- 3c-2 (0211): the docked-store host is gated on station_storage_enabled (ON in prod, seeded false on a
-- fresh chain) — without this its dark-parity assertion would see 'disabled' and prove nothing. And the
-- HUNTOVERLAP block launches a REAL docked hunt, which needs launch_from_dock_enabled (also ON in prod).
update public.game_config set value='true'::jsonb where key='station_storage_enabled';
update public.game_config set value='true'::jsonb where key='launch_from_dock_enabled';
-- 4b-0 (0213): the PERMEMBER-TAG block launches a REAL legacy expedition (send_ship_group_expedition
-- → send_main_ship_expedition), which is gated on mainship_send_enabled (ON in prod, seeded false on
-- a fresh chain — 0050).
update public.game_config set value='true'::jsonb where key='mainship_send_enabled';

-- Fund the fixture wallets BEFORE any additional commission. commission_first_main_ship is free, but
-- every ADDITIONAL commission DEBITS a price from player_wallet (0091) and fresh fixtures have zero
-- balance. Kept AFTER the DARK block (which must stay unfunded/unprovisioned) and inside the txn.
-- player_wallet is lazy, so on_conflict covers a row a signup/ensure path may already have created.
-- (The trade-market-1 / team-command proofs use this same direct-owner insert.)
insert into public.player_wallet (player_id, balance)
select v, 1000000 from fg where k in ('uA','uB','uC','uD','uE','uF','uG','uH','uI','uJ','uK')
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

-- S1-BERTH (0216): the unification flag lights only NOW — AFTER provisioning. The fixture assigns
-- above must run DARK: a LIT first-assign into an EMPTY group now MINTS the group's fleet at the
-- assignee's berth (its own behavior, pinned by ASSIGN_CLEARS_BERTH below), and every pre-0216
-- world in this proof — the bootstrap go, ORACLEPARITY's "group with no fleet yet", the hunt
-- bootstrap arms — is built on a FLEETLESS provisioned group. Dark fixture-building preserves
-- those worlds byte-for-byte; the mint is exercised deliberately, in its own world (uJ).
update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

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
declare r jsonb; e jsonb; n int; v_flag jsonb; r_before jsonb; r_after jsonb;
  uA uuid := (select v from fg where k='uA'); uB uuid := (select v from fg where k='uB');
  a1 uuid := (select v from fg where k='a1'); b1 uuid := (select v from fg where k='b1');
  slag uuid := (select v from fg where k='slag');
  v_loc record; v_base record; v_f uuid; v_mv uuid; v_fm record;
  v_old_status text; v_old_ss text; v_frow record; v_had_pres boolean; v_act text;
begin
  -- self-contained DARK: save the flag's ACTUAL prior value and restore IT at the end (never a
  -- hardcoded 'true' — a hardcoded restore silently rewrites whatever the previous block left).
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';
  select l.id, l.x, l.y into v_loc from public.locations l where l.id = slag;

  -- ── (A) the GROUPED ship a1. vacuity: really grouped, currently fleetless. ───────────────────────
  select count(*) into n from public.main_ship_instances where main_ship_id = a1 and group_id is not null;
  if n <> 1 then raise exception 'MAPTRANSIT-DARKPARITY FAIL: a1 is not grouped — the grouped case would be vacuous'; end if;
  select count(*) into n from public.fleets
   where main_ship_id = a1 and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'MAPTRANSIT-DARKPARITY FAIL: a1 already holds % per-ship fleet(s) — fixture unclean', n; end if;
  r_before := public.mainship_space_validate_context(a1);
  -- SURGERY (restored + read-back-verified below): the legacy in-transit shape — status 'traveling' +
  -- spatial_state NULL (the LEGACYPRESENT block's shape: 'traveling' is the correct legacy in-transit
  -- signal, not a CHECK-dodge) with ONE per-ship 'moving' fleet on a moving leg.
  -- ⚠ BOTH ship columns move in ONE update. main_ship_instances_stationary_spatial_state
  -- (0055:159-161, IS TRUE deliberate) REJECTS status='stationary' + spatial_state NULL — nulling
  -- spatial_state alone on a commission-born (stationary/at_location) ship red the CI run for real
  -- (run 29587517266). A partial write of a CHECK-coupled column set is a constraint violation.
  select status, spatial_state into v_old_status, v_old_ss
    from public.main_ship_instances where main_ship_id = a1;
  update public.main_ship_instances set status = 'traveling', spatial_state = null where main_ship_id = a1;
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
  -- restore a1 (surgery must undo itself — the member_busy lesson): leg cancelled, fixture fleet
  -- terminal, BOTH ship columns back in ONE update — then PROVE the rewind instead of trusting it.
  update public.fleet_movements set status='cancelled', resolved_at=now() where id = v_mv;
  update public.fleets set status='completed', location_mode='movement', active_movement_id=null where id = v_f;
  update public.main_ship_instances set status = v_old_status, spatial_state = v_old_ss where main_ship_id = a1;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = a1 and status is not distinct from v_old_status and spatial_state is not distinct from v_old_ss;
  if n <> 1 then raise exception 'MAPTRANSIT-DARKPARITY FAIL: a1 ship restore did not put the row back'; end if;
  select count(*) into n from public.fleets
   where main_ship_id = a1 and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'MAPTRANSIT-DARKPARITY FAIL: a1 restore left % active per-ship fleet(s)', n; end if;
  r_after := public.mainship_space_validate_context(a1);
  if r_after is distinct from r_before then
    raise exception 'MAPTRANSIT-DARKPARITY FAIL: a1 was not restored to what it was (oracle % -> %)', r_before, r_after; end if;

  -- ── (B) the UNGROUPED ship b1. vacuity: really ungrouped, exactly ONE active per-ship fleet. ─────
  select count(*) into n from public.main_ship_instances where main_ship_id = b1 and group_id is null;
  if n <> 1 then raise exception 'MAPTRANSIT-DARKPARITY FAIL: b1 is grouped — the ungrouped case would be vacuous'; end if;
  select count(*) into n from public.fleets
   where main_ship_id = b1 and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'MAPTRANSIT-DARKPARITY FAIL: b1 holds % active fleet(s) — the one-fleet fixture shape is gone', n; end if;
  r_before := public.mainship_space_validate_context(b1);
  -- SURGERY (restored + read-back-verified below): the SAME one-update rule as (A) — see the CHECK
  -- note there. The transit leg is flown on b1's OWN fleet (released idle, then the frozen
  -- primitives), so the restore is a column-exact rewind of the SAME row: this block leaves b1
  -- EXACTLY as it found it (present at its port, active presence re-created) and leaves NO leftover
  -- state for any later block — each fixture stands alone (the 0208 fixture-poisoning lesson).
  select f.id, f.status, f.location_mode, f.active_movement_id,
         f.current_sector_id, f.current_zone_id, f.current_location_id, f.current_base_id
    into v_frow
    from public.fleets f
   where f.main_ship_id = b1 and f.status in ('idle','moving','present','returning');
  v_had_pres := exists (select 1 from public.location_presence lp where lp.fleet_id = v_frow.id and lp.status = 'active');
  select status, spatial_state into v_old_status, v_old_ss
    from public.main_ship_instances where main_ship_id = b1;
  update public.main_ship_instances set status = 'traveling', spatial_state = null where main_ship_id = b1;
  perform public.presence_complete(lp.id) from public.location_presence lp
   where lp.fleet_id = v_frow.id and lp.status = 'active';
  -- release the fleet to idle (the mover's own release shape, 0208) so fleet_set_moving's frozen
  -- precondition holds — compose the primitive, don't bypass it.
  update public.fleets set status='idle', location_mode='movement', active_movement_id=null,
         current_location_id=null, current_zone_id=null, current_sector_id=null, updated_at=now()
   where id = v_frow.id;
  select b.id, b.x, b.y into v_base from public.bases b where b.player_id = uB and b.status='active' order by b.created_at limit 1;
  if v_base.id is null then raise exception 'MAPTRANSIT-DARKPARITY FAIL: uB has no base — fixture cannot be built'; end if;
  v_mv := public.movement_create(uB, v_frow.id, 'base', v_base.id, null, null, v_base.x, v_base.y,
                                 'location', null, null, v_loc.id, v_loc.x, v_loc.y, 'rally', 1);
  perform public.fleet_set_moving(v_frow.id, v_mv);
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
  -- restore b1 EXACTLY as found: cancel the leg, rewind the fleet row column-for-column, re-create
  -- the active presence (presence rows are a complete+create cycle; the completed row is ordinary
  -- history), BOTH ship columns back in ONE update — then PROVE the rewind with the oracle.
  update public.fleet_movements set status='cancelled', resolved_at=now() where id = v_mv;
  update public.fleets
     set status=v_frow.status, location_mode=v_frow.location_mode, active_movement_id=v_frow.active_movement_id,
         current_sector_id=v_frow.current_sector_id, current_zone_id=v_frow.current_zone_id,
         current_location_id=v_frow.current_location_id, current_base_id=v_frow.current_base_id,
         updated_at=now()
   where id = v_frow.id;
  if v_had_pres then
    select l.activity_type into v_act from public.locations l where l.id = v_frow.current_location_id;
    perform public.presence_create(uB, v_frow.id, v_frow.current_sector_id, v_frow.current_zone_id,
                                   v_frow.current_location_id, v_act);
  end if;
  update public.main_ship_instances set status = v_old_status, spatial_state = v_old_ss where main_ship_id = b1;
  r_after := public.mainship_space_validate_context(b1);
  if r_after is distinct from r_before then
    raise exception 'MAPTRANSIT-DARKPARITY FAIL: b1 was not restored to what it was (oracle % -> %)', r_before, r_after; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
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
declare r jsonb; e jsonb; n int; v_flag jsonb; r_before jsonb; r_after jsonb;
  uB uuid := (select v from fg where k='uB'); b1 uuid := (select v from fg where k='b1');
  v_old_status text; v_old_ss text; v_old_x double precision; v_old_y double precision;
  v_frow record; v_had_pres boolean; v_act text;
begin
  -- self-contained DARK: save the flag's ACTUAL prior value and restore IT at the end.
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';

  -- SELF-SUFFICIENT fixture — no cross-block coupling: b1 arrives here docked at its port (every
  -- earlier block restores what it found). This block dissolves b1's own fleet ITSELF to build the
  -- zero-fleet OSN-held shape and rewinds everything at the end, so a future reorder cannot change
  -- what it tests — the shape is built and torn down entirely in-block.
  select count(*) into n from public.fleets
   where main_ship_id = b1 and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'MAPSPACE-DARKPARITY FAIL: b1 holds % active fleet(s) (expected its one docked fleet) — fixture shape drifted', n; end if;
  r_before := public.mainship_space_validate_context(b1);
  select f.id, f.status, f.location_mode, f.active_movement_id,
         f.current_sector_id, f.current_zone_id, f.current_location_id, f.current_base_id
    into v_frow
    from public.fleets f
   where f.main_ship_id = b1 and f.status in ('idle','moving','present','returning');
  v_had_pres := exists (select 1 from public.location_presence lp where lp.fleet_id = v_frow.id and lp.status = 'active');

  -- SURGERY (restored + read-back-verified below): dissolve the fleet (the mover's own dissolve
  -- shape, 0208), then the OSN-held ship shape — what the retired per-ship stop/settle writes; the
  -- live RPCs cannot mint it on a fixture on demand.
  -- ⚠ ALL FOUR ship columns move in ONE update: the 0054 space_coords CHECK ties coords to
  -- spatial_state='in_space' EXACTLY (both null everywhere else) and the 0055 stationary CHECK ties
  -- status to spatial_state — a partial write of a CHECK-coupled column set is a constraint
  -- violation (the CI lesson, run 29587517266).
  perform public.presence_complete(lp.id) from public.location_presence lp
   where lp.fleet_id = v_frow.id and lp.status = 'active';
  update public.fleets set status='completed', location_mode='movement', active_movement_id=null,
         current_base_id=null, current_location_id=null, current_zone_id=null, current_sector_id=null,
         updated_at=now()
   where id = v_frow.id;
  select status, spatial_state, space_x, space_y into v_old_status, v_old_ss, v_old_x, v_old_y
    from public.main_ship_instances where main_ship_id = b1;
  update public.main_ship_instances
     set status='stationary', spatial_state='in_space', space_x=555, space_y=-444
   where main_ship_id = b1;

  -- vacuity guards: ZERO active fleets (the resolver MUST return NULL — only the ship fallback can
  -- answer), and the oracle must answer in_space, or the marker pins nothing.
  select count(*) into n from public.fleets
   where main_ship_id = b1 and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'MAPSPACE-DARKPARITY FAIL: b1 holds % active fleet(s) — the ship-fallback claim would be vacuous', n; end if;
  r := public.mainship_space_validate_context(b1);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'in_space' then
    raise exception 'MAPSPACE-DARKPARITY FAIL: fixture did not reach in_space — %', r; end if;

  r := pg_temp.call_as(uB, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = b1::text;
  if e is null or (e->>'place') is distinct from 'in_space'
     or (e->>'space_x')::double precision is distinct from 555::double precision
     or (e->>'space_y')::double precision is distinct from (-444)::double precision then
    raise exception 'MAPSPACE-DARKPARITY FAIL: an OSN-held ship draws % (expected in_space at its OWN 555,-444) — the ship fallback died', e; end if;

  -- restore b1 EXACTLY as found: ship row back (all four columns, ONE update), fleet row rewound
  -- column-for-column, active presence re-created — then PROVE the rewind with the oracle.
  update public.main_ship_instances
     set status=v_old_status, spatial_state=v_old_ss, space_x=v_old_x, space_y=v_old_y
   where main_ship_id = b1;
  update public.fleets
     set status=v_frow.status, location_mode=v_frow.location_mode, active_movement_id=v_frow.active_movement_id,
         current_sector_id=v_frow.current_sector_id, current_zone_id=v_frow.current_zone_id,
         current_location_id=v_frow.current_location_id, current_base_id=v_frow.current_base_id,
         updated_at=now()
   where id = v_frow.id;
  if v_had_pres then
    select l.activity_type into v_act from public.locations l where l.id = v_frow.current_location_id;
    perform public.presence_create(uB, v_frow.id, v_frow.current_sector_id, v_frow.current_zone_id,
                                   v_frow.current_location_id, v_act);
  end if;
  r_after := public.mainship_space_validate_context(b1);
  if r_after is distinct from r_before then
    raise exception 'MAPSPACE-DARKPARITY FAIL: b1 was not restored to what it was (oracle % -> %)', r_before, r_after; end if;
  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_MAPSPACE_DARKPARITY: an OSN-held ship (zero fleets) still draws in_space at its OWN ship coordinates — the elsif fallback (dark parity path) survives';
end $$;

-- ════════ BLOCK ASSIGNGUARD-HUNTWORLD (4b-0, 0213): dark parity, unassign, in-flight, hunt-present,
-- and the obligation's own read-right pin — all on ONE real-hunt fixture in uD's isolated world ════════
-- The guard's charter is 0210's LESSON THREE lit-world half: assign_ship_to_group must not put a
-- docked ship into a group whose fleet is elsewhere, because lit membership IS position. This block
-- builds the EXACT reachable state the defect lives in — team_command live, a REAL hunt fleet in
-- flight, a freshly docked ship assigned into that group — with live RPCs only, and walks it through
-- every phase the guard must handle.
-- PLACEMENT IS LOAD-BEARING: after ISOLATION (a real hunt writes group_sortie_members manifest rows,
-- which ISOLATION rightly asserts the unified MOVER never does — the HUNTOVERLAP placement rule).
do $$
declare r jsonb; n int; v_flag jsonb;
  uD uuid := (select v from fg where k='uD');
  d1 uuid; d2 uuid; gD uuid; v_hunt uuid; v_huntfleet uuid; v_huntmv uuid; v_portD uuid;
  v_eligible boolean;
begin
  -- self-contained flag discipline: save the ACTUAL prior value, restore IT at the end (never a
  -- hardcoded 'true' — the MAPTRANSIT lesson).
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';

  -- ── live-RPC provisioning: d1 docked → group → REAL hunt in flight; d2 commissioned docked. ─────
  r := pg_temp.call_as(uD, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD FAIL: commission d1: %', r; end if;
  select main_ship_id into d1 from public.main_ship_instances where player_id = uD;
  r := pg_temp.call_as(uD, 'public.upsert_ship_group(1, ''Reavers'')');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD FAIL: group: %', r; end if;
  gD := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', d1, gD));
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD FAIL: assign d1: %', r; end if;
  select id into v_hunt from public.locations
   where status = 'active' and activity_type = 'hunt_pirates'
   order by coalesce(min_power_required, 0) asc limit 1;
  if v_hunt is null then raise exception 'ASSIGNGUARD FAIL: no active hunt site — the fixture cannot be built'; end if;
  r := pg_temp.call_as(uD, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gD, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD FAIL: real hunt send rejected: %', r; end if;
  v_huntfleet := (r->>'fleet_id')::uuid;
  v_huntmv    := (r->>'movement_id')::uuid;
  r := pg_temp.call_as(uD, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD FAIL: commission d2: %', r; end if;
  d2 := (r->>'main_ship_id')::uuid;

  -- ── vacuity guards: the reachable state must REALLY exist, or every phase proves nothing. ───────
  select count(*) into n from public.fleets
   where id = v_huntfleet and group_id = gD and main_ship_id is null and status = 'moving';
  if n <> 1 then raise exception 'ASSIGNGUARD FAIL: the hunt fleet is not moving — the in-flight state was not built'; end if;
  select count(*) into n from public.group_sortie_members where fleet_id = v_huntfleet and main_ship_id = d2;
  if n <> 0 then raise exception 'ASSIGNGUARD FAIL: d2 is ON the hunt manifest — the frozen-vs-live split is gone'; end if;
  select f.current_location_id into v_portD from public.fleets f
   where f.main_ship_id = d2 and f.status = 'present';
  if v_portD is null then raise exception 'ASSIGNGUARD FAIL: d2 has no present per-ship fleet — its own port is undefined'; end if;
  if v_portD = v_hunt then raise exception 'ASSIGNGUARD FAIL: d2''s port IS the hunt site — right/wrong answers indistinguishable'; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = d2 and group_id is null;
  if n <> 1 then raise exception 'ASSIGNGUARD FAIL: d2 is already grouped — the assign under test would be a no-op'; end if;

  -- ── ★ DARKPARITY ★ flag OFF, hunt in flight: the assign SUCCEEDS with the 0204 envelope, byte-equal,
  --    and the row is written. This is the load-bearing REACHABLE dark state (the 0210 lesson: parity
  --    on states the dark world can actually reach, not a convenient fixture) — the exact overlap
  --    HUNTOVERLAP pins for the READS, asserted here for the WRITE the guard must not touch while dark.
  --    HOW THIS FAILS IF THE CODE WERE WRONG: an un-gated guard (or a guard keyed before the flag
  --    read) rejects here → red. MUTATION (documented in the sh): force v_unified true → red here.
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', d2, gD));
  if r is distinct from jsonb_build_object('ok', true, 'main_ship_id', d2, 'group_id', gD) then
    raise exception 'ASSIGNGUARD-DARKPARITY FAIL: dark envelope is not the 0204 head''s, byte-equal: %', r; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = d2 and group_id = gD;
  if n <> 1 then raise exception 'ASSIGNGUARD-DARKPARITY FAIL: the dark assign did not write group_id'; end if;
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_DARKPARITY: dark + hunt in flight -> assign succeeds, envelope byte-equal to the 0204 head, row written';

  -- ── light the flag for the lit phases. ──────────────────────────────────────────────────────────
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- ── ★ UNASSIGN ★ REWRITTEN BY S1-BERTH (0216): leaving a fleet means BERTHING, and a ship cannot
  --    berth in open space — so a LIT unassign while the group's fleet is IN FLIGHT is now REFUSED
  --    ('fleet_in_flight'), with zero writes; DARK the head's always-allowed semantics survive
  --    (flag-exact rollback), and the dark unassign BERTHS the ship at its own real port (the
  --    transition arm). Both halves asserted on the same real-hunt fixture.
  --    HOW THIS FAILS IF THE CODE WERE WRONG: drop 0216's unassign guard → the lit probe answers
  --    ok:true and d2 leaves with group NULL + a berth while the manifest still binds it → red on
  --    the reason; un-gate the guard → the dark restore probe is refused → red on ok.
  if (select status from public.fleets where id = v_huntfleet) is distinct from 'moving' then
    raise exception 'ASSIGNGUARD FAIL: hunt fleet no longer moving — the unassign phase would be vacuous'; end if;
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, null)', d2));
  if (r->>'reason') is distinct from 'fleet_in_flight' then
    raise exception 'ASSIGNGUARD-UNASSIGN FAIL: lit unassign from an in-flight group answered % (ok here = a ship berthed in open space)', r; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = d2 and group_id = gD and berth_location_id is null;
  if n <> 1 then raise exception 'ASSIGNGUARD-UNASSIGN FAIL: the refused unassign wrote the ship row (group/berth changed)'; end if;
  -- DARK: the head's always-allowed unassign survives, and the transition arm berths d2 at its OWN
  -- present per-ship port (v_portD) — this also RESTORES d2 to ungrouped for the later phases.
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, null)', d2));
  if (r->>'ok')::boolean is not true then
    raise exception 'ASSIGNGUARD-UNASSIGN FAIL: DARK unassign was rejected — the rollback contract broke: %', r; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = d2 and group_id is null and berth_location_id = v_portD;
  if n <> 1 then raise exception 'ASSIGNGUARD-UNASSIGN FAIL: dark unassign did not berth d2 at its own port'; end if;
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_UNASSIGN: lit unassign from an in-flight fleet -> fleet_in_flight, zero writes; dark unassign stays always-allowed and berths the ship at its own port';

  -- ── ★ INFLIGHT ★ lit, fleet 'moving': the assign is rejected with ZERO writes — snapshot-diff of
  --    ALL THREE tables the ghost-dock class lives in, both ways (the NOSHIPWRITE idiom; NOSHIPWRITE
  --    itself is blind to fleets/location_presence — the recorded 3a lesson).
  create temp table ag_ships_before as select * from public.main_ship_instances;
  create temp table ag_fleets_before as select * from public.fleets;
  create temp table ag_pres_before  as select * from public.location_presence;
  select count(*) into n from ag_ships_before;
  if n = 0 then raise exception 'ASSIGNGUARD-INFLIGHT FAIL: empty before-snapshot — the zero-write diff would be vacuous'; end if;
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', d2, gD));
  if (r->>'reason') is distinct from 'group_fleet_in_flight' then
    raise exception 'ASSIGNGUARD-INFLIGHT FAIL: assign into a group whose fleet is MOVING answered %', r; end if;
  select count(*) into n from (
    (table ag_ships_before except select * from public.main_ship_instances)
    union all (select * from public.main_ship_instances except table ag_ships_before)) d;
  if n <> 0 then raise exception 'ASSIGNGUARD-INFLIGHT FAIL: the rejected assign wrote % main_ship_instances row(s)', n; end if;
  select count(*) into n from (
    (table ag_fleets_before except select * from public.fleets)
    union all (select * from public.fleets except table ag_fleets_before)) d;
  if n <> 0 then raise exception 'ASSIGNGUARD-INFLIGHT FAIL: the rejected assign wrote % fleets row(s)', n; end if;
  select count(*) into n from (
    (table ag_pres_before except select * from public.location_presence)
    union all (select * from public.location_presence except table ag_pres_before)) d;
  if n <> 0 then raise exception 'ASSIGNGUARD-INFLIGHT FAIL: the rejected assign wrote % location_presence row(s)', n; end if;
  drop table ag_ships_before; drop table ag_fleets_before; drop table ag_pres_before;
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_INFLIGHT: lit + fleet moving -> group_fleet_in_flight, zero writes across ships/fleets/presence (both-way diff)';

  -- ── ★ HUNTPRESENT ★ the hunt SETTLES 'present' AT the hunt site (the charter's own example: "then
  --    docked at the HUNT SITE") — a status-only ('moving','returning') guard reopens exactly here.
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_huntmv;
  perform public.movement_settle_arrival(v_huntmv);
  select count(*) into n from public.fleets
   where id = v_huntfleet and status = 'present' and current_location_id = v_hunt;
  if n <> 1 then raise exception 'ASSIGNGUARD FAIL: hunt fleet did not settle present at the hunt site — the present phase is vacuous'; end if;
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', d2, gD));
  if (r->>'reason') is distinct from 'group_fleet_elsewhere' then
    raise exception 'ASSIGNGUARD-HUNTPRESENT FAIL: assign into a group settled PRESENT at the hunt site answered % (a moving/returning-only guard reopens the charter''s own branch)', r; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = d2 and group_id is null;
  if n <> 1 then raise exception 'ASSIGNGUARD-HUNTPRESENT FAIL: the rejected assign wrote group_id'; end if;
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_HUNTPRESENT: lit + hunt fleet present AT the hunt site -> rejected (the status-only guard''s hole is closed)';

  -- ── ★ READRIGHT ★ the obligation's OWN marker: after the rejected assign, the would-be assignee's
  --    reads still answer its REAL port. DELETE THE GUARD HUNK and this goes red on the wrong-port
  --    store: the assign succeeds, d2 joins the group, the lit resolver (0210) answers the HUNT fleet
  --    — validate_context says at_location AT THE HUNT SITE and get_my_docked_store would
  --    get_or_create_store at the wrong port. That is §0's ghost-dock duality in READ form — the
  --    defect this whole migration exists to close.
  r := public.mainship_space_validate_context(d2);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'at_location' then
    raise exception 'ASSIGNGUARD-READRIGHT FAIL: validate_context(d2) = %', r; end if;
  if public.mainship_resolve_docked_location(d2) is distinct from v_portD then
    raise exception 'ASSIGNGUARD-READRIGHT FAIL: resolve_docked_location(d2) is not d2''s REAL port'; end if;
  v_eligible := public.is_home_port_eligible(v_portD);
  r := pg_temp.call_as(uD, format('public.get_my_docked_store(%L::uuid)', d2));
  if (r->>'docked')::boolean is not true or (r->>'location_id')::uuid is distinct from v_portD then
    raise exception 'ASSIGNGUARD-READRIGHT FAIL: docked_store(d2) answers % — the store is at the WRONG port', r; end if;
  if v_eligible and (r->>'store_id') is null then
    raise exception 'ASSIGNGUARD-READRIGHT FAIL: d2''s port is store-eligible but no store came back'; end if;
  if not v_eligible and (r->>'store_id') is not null then
    raise exception 'ASSIGNGUARD-READRIGHT FAIL: d2''s port is NOT store-eligible but a store was invented'; end if;
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_READRIGHT: after the rejected assign, validate_context + docked_store answer d2''s REAL port (delete the guard and the store lands at the hunt site)';

  -- hand the uD world to the ONSORTIE block (the settled sortie state persists deliberately).
  insert into fg values ('d2', d2), ('gD', gD), ('huntD', v_hunt), ('huntfleetD', v_huntfleet);
  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
end $$;

-- ════════ BLOCK ASSIGNGUARD-ONSORTIE (4b-0, lit): co-location does NOT override an OPEN SORTIE ════════
-- The 0213 review's Finding 1 — the ghost-dock hole re-entering through the ALLOW arm. Without the
-- sortie check: group gD's hunt fleet sits 'present' AT hunt site X mid-sortie (manifest FROZEN in
-- group_sortie_members); a ship whose OWN present fleet + active presence sit at the SAME X is
-- co-located → ALLOW. Then combat ends, the fleet departs 'returning' on its frozen manifest (the
-- new member is NOT on it), and mainship_resolve_fleet answers the group fleet for a ship the
-- reconciler will never dock — §0's exact defect, through the guard's own front door.
-- HUNTPRESENT structurally CANNOT test this: its vacuity guard REQUIRES the assignee's port to
-- differ from the hunt site (right/wrong indistinguishable otherwise). This block builds the ONE
-- state HUNTPRESENT excludes — the assignee docked AT the site itself.
-- HOW THIS FAILS IF THE CODE WERE WRONG: remove the sortie check and the co-location arm sees the
-- fleet present at X + the assignee docked at X → ok:true → red below (mutation-tested; the sh's
-- static token check also reds).
do $$
declare r jsonb; n int; v_flag jsonb; r_before jsonb; r_after jsonb;
  uD uuid := (select v from fg where k='uD'); d2 uuid := (select v from fg where k='d2');
  gD uuid := (select v from fg where k='gD'); v_hunt uuid := (select v from fg where k='huntD');
  v_huntfleet uuid := (select v from fg where k='huntfleetD');
  v_zone uuid; v_sector uuid; v_frow record; v_prow record; v_berth_save uuid;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  r_before := public.mainship_space_validate_context(d2);

  -- SURGERY (restored + read-back-verified below; touches NO ship row, no CHECK-coupled column):
  -- move d2's OWN per-ship fleet + active presence to the hunt site. The live RPCs cannot mint
  -- this state on demand (a hunt site is not dockable by the dock paths), but nothing forbids the
  -- rows, and the co-location arm reads exactly this fleet+presence pair.
  select l.zone_id, z.sector_id into v_zone, v_sector
    from public.locations l join public.zones z on z.id = l.zone_id where l.id = v_hunt;
  select f.id, f.current_location_id, f.current_zone_id, f.current_sector_id into v_frow
    from public.fleets f where f.main_ship_id = d2 and f.status = 'present';
  if v_frow.id is null then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: d2 has no present per-ship fleet — the fixture cannot be built'; end if;
  select lp.id, lp.location_id, lp.zone_id, lp.sector_id into v_prow
    from public.location_presence lp where lp.fleet_id = v_frow.id and lp.status = 'active';
  if v_prow.id is null then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: d2 has no active presence — the fixture cannot be built'; end if;
  update public.fleets set current_location_id = v_hunt, current_zone_id = v_zone, current_sector_id = v_sector
   where id = v_frow.id;
  update public.location_presence set location_id = v_hunt, zone_id = v_zone, sector_id = v_sector
   where id = v_prow.id;
  -- S1-BERTH (0216): the guard's ship-side read is now d2's BERTH, so the surgery must move it with
  -- the dock pair (the backfill/unassign law: berth follows the real dock; the fixture mirrors it).
  -- CHECK-coupled: d2 is UNGROUPED, so berth stays non-null throughout — the XOR holds.
  select berth_location_id into v_berth_save from public.main_ship_instances where main_ship_id = d2;
  update public.main_ship_instances set berth_location_id = v_hunt where main_ship_id = d2;

  -- vacuity guards: the assignee's own dock IS the hunt site, the group fleet is present there, and
  -- an OPEN SORTIE exists for gD — the exact state the co-location arm would otherwise ALLOW.
  select count(*) into n from public.fleets f
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active' and lp.location_id = v_hunt
   where f.main_ship_id = d2 and f.status = 'present' and f.current_location_id = v_hunt;
  if n <> 1 then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: the co-located-sortie state was not built (assignee not docked AT the site)'; end if;
  -- S1-BERTH (0216): the co-location read under test is the BERTH — pin it moved with the dock.
  select count(*) into n from public.main_ship_instances
   where main_ship_id = d2 and group_id is null and berth_location_id = v_hunt;
  if n <> 1 then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: d2 is not BERTHED at the site — the co-located-sortie state was not built (0216 reads berth)'; end if;
  select count(*) into n from public.fleets
   where id = v_huntfleet and group_id = gD and main_ship_id is null
     and status = 'present' and current_location_id = v_hunt;
  if n <> 1 then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: the hunt fleet is not present at the site — the co-located-sortie state was not built'; end if;
  select count(*) into n from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = uD and f.group_id = gD and f.status in ('moving','present','returning');
  if n = 0 then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: no open sortie for gD — the sortie arm would be untested'; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = d2 and group_id is null;
  if n <> 1 then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: d2 is already grouped — the assign under test would be a no-op'; end if;

  -- ── ★ ONSORTIE ★ co-located AND mid-sortie: the assign MUST be rejected with the mover's token. ──
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', d2, gD));
  if (r->>'reason') is distinct from 'group_on_sortie' then
    raise exception 'ASSIGNGUARD-ONSORTIE FAIL: co-located assign into an OPEN SORTIE answered % — the frozen-manifest ghost-dock hole is open', r; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = d2 and group_id is null;
  if n <> 1 then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: the rejected assign wrote group_id'; end if;

  -- restore the surgery EXACTLY and PROVE it (read-back + oracle envelope compare).
  update public.fleets
     set current_location_id = v_frow.current_location_id,
         current_zone_id = v_frow.current_zone_id, current_sector_id = v_frow.current_sector_id
   where id = v_frow.id;
  update public.location_presence
     set location_id = v_prow.location_id, zone_id = v_prow.zone_id, sector_id = v_prow.sector_id
   where id = v_prow.id;
  -- S1-BERTH (0216): restore the berth with the dock pair (and prove it below with the rest).
  update public.main_ship_instances set berth_location_id = v_berth_save where main_ship_id = d2;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = d2 and berth_location_id is not distinct from v_berth_save;
  if n <> 1 then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: the berth restore did not put the row back'; end if;
  select count(*) into n from public.fleets
   where id = v_frow.id and current_location_id is not distinct from v_frow.current_location_id
     and current_zone_id is not distinct from v_frow.current_zone_id;
  if n <> 1 then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: the fleet restore did not put the row back'; end if;
  select count(*) into n from public.location_presence
   where id = v_prow.id and location_id is not distinct from v_prow.location_id;
  if n <> 1 then raise exception 'ASSIGNGUARD-ONSORTIE FAIL: the presence restore did not put the row back'; end if;
  r_after := public.mainship_space_validate_context(d2);
  if r_after is distinct from r_before then
    raise exception 'ASSIGNGUARD-ONSORTIE FAIL: d2 was not restored to what it was (oracle % -> %)', r_before, r_after; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_ONSORTIE: co-location does NOT override an open sortie — assign is rejected even AT the site (the frozen-manifest ghost-dock hole through the ALLOW arm is closed)';
end $$;

-- ════════ BLOCK ASSIGNGUARD-COLOCATION (4b-0, lit): elsewhere / idle-in-space / co-located, on uA's
-- REAL unified fleet (the mover, brake and settle this proof already exercised) ════════
-- The predicate is CO-LOCATION, not "not in a movement": post-flip, present-at-port is the NORMAL
-- state of every docked fleet, so a flat reject on 'present' would ban the roster's bread-and-butter
-- operation. COLOCATED is the too-wide guard's proof; ELSEWHERE/IDLESPACE are the too-narrow one's.
do $$
declare r jsonb; n int; v_flag jsonb;
  uA uuid := (select v from fg where k='uA'); g uuid := (select v from fg where k='g');
  a3 uuid; slag uuid := (select v from fg where k='slag'); drift uuid := (select v from fg where k='drift');
  haven uuid := (select v from fg where k='haven'); v_fleet uuid := (select v from fg where k='fleet');
  v_mv uuid;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- a3: a fresh REAL commission — docked at haven with its own present fleet + active presence.
  r := pg_temp.call_as(uA, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD FAIL: commission a3: %', r; end if;
  a3 := (r->>'main_ship_id')::uuid;

  -- vacuity: the group's unified fleet is 'present' at slag (the GROUPREAD settle left it there);
  -- a3 is ungrouped and docked at haven — a DIFFERENT port, or right/wrong is indistinguishable.
  select count(*) into n from public.fleets
   where id = v_fleet and group_id = g and main_ship_id is null and status = 'present' and current_location_id = slag;
  if n <> 1 then raise exception 'ASSIGNGUARD FAIL: the unified fleet is not present at slag — the elsewhere phase is vacuous'; end if;
  select count(*) into n from public.fleets f
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active' and lp.location_id = haven
   where f.main_ship_id = a3 and f.player_id = uA and f.status = 'present' and f.current_location_id = haven;
  if n <> 1 then raise exception 'ASSIGNGUARD FAIL: the assignee is not docked (fleet+presence) at haven — co-location has nothing to compare'; end if;
  -- S1-BERTH (0216): the guard's ship-side read is now the BERTH — pin that a3 was BORN berthed at
  -- haven (the commission hunk), so the phases below exercise the berth read, not the corpse.
  select count(*) into n from public.main_ship_instances
   where main_ship_id = a3 and group_id is null and berth_location_id = haven;
  if n <> 1 then raise exception 'ASSIGNGUARD FAIL: a3 is not BERTHED at haven — co-location has nothing to compare (0216 reads berth)'; end if;

  -- ── ★ ELSEWHERE ★ fleet present at slag, assignee docked at haven ≠ slag → reject. ──────────────
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a3, g));
  if (r->>'reason') is distinct from 'group_fleet_elsewhere' then
    raise exception 'ASSIGNGUARD-ELSEWHERE FAIL: assign across ports answered %', r; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = a3 and group_id is null;
  if n <> 1 then raise exception 'ASSIGNGUARD-ELSEWHERE FAIL: the rejected assign wrote group_id'; end if;
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_ELSEWHERE: lit + fleet present at L, assignee docked at M<>L -> group_fleet_elsewhere';

  -- ── ★ IDLESPACE ★ the fleet stopped/parked in OPEN SPACE via the real brake (0209): durable idle
  --    is a position (0208), and no ship can be docked there → reject.
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, drift));
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD FAIL: go for the idle-space fixture: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  update public.fleet_movements
     set depart_at = now() - interval '30 seconds', arrive_at = now() + interval '30 seconds'
   where id = v_mv;
  r := pg_temp.call_as(uA, format('public.command_ship_group_stop(%L::uuid)', g));
  if (r->>'ok')::boolean is not true or (r->>'stopped')::boolean is not true then
    raise exception 'ASSIGNGUARD FAIL: brake for the idle-space fixture: %', r; end if;
  select count(*) into n from public.fleets
   where id = v_fleet and status = 'idle' and location_mode = 'space' and space_x is not null;
  if n <> 1 then raise exception 'ASSIGNGUARD FAIL: the fleet is not parked idle in space — the idle phase is vacuous'; end if;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a3, g));
  if (r->>'reason') is distinct from 'group_fleet_elsewhere' then
    raise exception 'ASSIGNGUARD-IDLESPACE FAIL: assign into a group parked in open space answered %', r; end if;
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_IDLESPACE: lit + fleet parked idle in open space -> rejected (a dock cannot be co-located with a coordinate)';

  -- ── ★ COLOCATED ★ fly the fleet TO the assignee's port and settle: present at haven, a3 docked at
  --    haven → the assign SUCCEEDS. This is the too-wide guard's proof — a flat reject on 'present'
  --    (or on "fleet exists") bans the normal post-flip roster operation and reds here.
  r := pg_temp.call_as(uA, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, haven));
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD FAIL: go to haven: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_mv;
  perform public.movement_settle_arrival(v_mv);
  select count(*) into n from public.fleets
   where id = v_fleet and status = 'present' and location_mode = 'location' and current_location_id = haven;
  if n <> 1 then raise exception 'ASSIGNGUARD FAIL: the fleet did not settle present at haven — the co-located phase is vacuous'; end if;
  r := pg_temp.call_as(uA, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', a3, g));
  if r is distinct from jsonb_build_object('ok', true, 'main_ship_id', a3, 'group_id', g) then
    raise exception 'ASSIGNGUARD-COLOCATED FAIL: co-located assign (fleet AND ship both at haven) answered % — the guard is too wide', r; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = a3 and group_id = g;
  if n <> 1 then raise exception 'ASSIGNGUARD-COLOCATED FAIL: the allowed assign did not write group_id'; end if;
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_COLOCATED: lit + fleet present at the assignee''s OWN port -> ok:true, row written (the guard is not a movement ban)';

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
end $$;

-- ════════ BLOCK ASSIGNGUARD-PERMEMBER-TAG (4b-0, lit): the legacy expedition's display-only
-- group_id tag on PER-MEMBER fleets must NOT trip the guard — pins the main_ship_id IS NULL key ════════
-- send_ship_group_expedition (0204:316-318) tags fleets.group_id onto each member's OWN fleet after a
-- send — display-only, "ROUTING NEVER reads fleets.group_id". A guard keyed on group_id ALONE (the
-- exact key mistake 0210:69-71 records) would see that tagged per-member fleet 'moving' and reject
-- every assign into a group that merely has a legacy expedition out — banning assignment for the
-- whole LIVE game. Built with live RPCs in uB's world: b1 docked → group → REAL expedition (the
-- NOHOME docked launch) → fresh commission b2 → assign b2 into the group mid-flight → MUST succeed.
do $$
declare r jsonb; n int; v_flag jsonb;
  uB uuid := (select v from fg where k='uB'); b1 uuid := (select v from fg where k='b1');
  b2 uuid; gB uuid; drift uuid := (select v from fg where k='drift');
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  r := pg_temp.call_as(uB, 'public.upsert_ship_group(1, ''Haulers'')');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD-PERMEMBER FAIL: group: %', r; end if;
  gB := (r->>'group_id')::uuid;
  -- S1-BERTH (0216): b1's fixture assign runs DARK — a LIT first-assign into an EMPTY group now
  -- MINTS the group fleet at the assignee's berth (its own world, ASSIGN_CLEARS_BERTH, pins that),
  -- and THIS block's whole point requires gB to stay FLEETLESS. The lit 0-rows bootstrap pin this
  -- assign used to carry lives on b2's assign below (a NON-empty fleetless group: allow, no mint).
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';
  r := pg_temp.call_as(uB, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', b1, gB));
  if (r->>'ok')::boolean is not true then
    raise exception 'ASSIGNGUARD-PERMEMBER FAIL: dark fixture assign of b1 was rejected: %', r; end if;
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- the REAL legacy expedition send (docked launch — launch_from_dock is lit): mints b1's OWN
  -- per-member fleet and tags it with gB. Destination DRIFT, not slag: b1 is docked AT slag (the
  -- SETTLEPARITY block flew it there and the 0153 hunk docked it), and the single send rejects a
  -- destination equal to the ship's current dock ('already at that location') — the CI run caught
  -- exactly that on the first cut of this fixture.
  r := pg_temp.call_as(uB, format('public.send_ship_group_expedition(%L::uuid, %L::uuid)', gB, drift));
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD-PERMEMBER FAIL: legacy expedition send: %', r; end if;

  r := pg_temp.call_as(uB, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGNGUARD-PERMEMBER FAIL: commission b2: %', r; end if;
  b2 := (r->>'main_ship_id')::uuid;

  -- vacuity: the tagged per-member fleet REALLY exists and is moving (group_id = gB with
  -- main_ship_id = b1 — the display tag), and NO group-shaped (main_ship_id NULL) fleet exists.
  select count(*) into n from public.fleets
   where group_id = gB and player_id = uB and main_ship_id = b1 and status = 'moving';
  if n <> 1 then raise exception 'ASSIGNGUARD-PERMEMBER FAIL: no moving tagged per-member fleet — the tag fixture is vacuous'; end if;
  select count(*) into n from public.fleets
   where group_id = gB and player_id = uB and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'ASSIGNGUARD-PERMEMBER FAIL: a group-shaped fleet exists — the key under test is not isolated'; end if;

  -- ── ★ PERMEMBER_TAG ★ assign b2 into gB while the TAGGED fleet flies: MUST succeed. ─────────────
  -- HOW THIS FAILS IF THE CODE WERE WRONG: key the leaf on group_id alone and the tagged 'moving'
  -- fleet resolves → group_fleet_in_flight → red.
  r := pg_temp.call_as(uB, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', b2, gB));
  if (r->>'ok')::boolean is not true then
    raise exception 'ASSIGNGUARD-PERMEMBER FAIL: assign blocked by the display-only per-member tag (the leaf keys on group_id alone): %', r; end if;
  select count(*) into n from public.main_ship_instances where main_ship_id = b2 and group_id = gB;
  if n <> 1 then raise exception 'ASSIGNGUARD-PERMEMBER FAIL: the allowed assign did not write group_id'; end if;
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_PERMEMBER_TAG: a legacy expedition''s group_id-tagged per-member fleet does not trip the guard (main_ship_id IS NULL key pinned)';

  -- hand the uB world to the AMBIGUOUS block.
  insert into fg values ('b2', b2), ('gB', gB);
  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
end $$;

-- ════════ BLOCK ASSIGNGUARD-AMBIGUOUS (4b-0, lit): the broken-invariant arm fails CLOSED ════════
-- The 0213 review's Finding 2: the >1-fleets arm had ZERO coverage — delete it and every other
-- marker (and both self-asserts as first written) stayed green, because a non-strict read would
-- answer an arbitrary row. The state is REACHABLE lit: the charter's second pre-flip obligation
-- records that a hunt can mint a SECOND unified-shape fleet while one is alive (0210:162-167's
-- "at-most-one by construction" is false lit). The resolver fails closed (NULL, 0210:90-92) on this
-- exact state; the guard must fail closed too, with the mover/brake's own token (0207/0209).
-- SURGERY (marked, self-restoring): two idle group-shaped fleets are minted DIRECTLY — the live
-- RPCs are what maintain at-most-one, which is precisely why the arm needs a manufactured fixture.
-- HOW THIS FAILS IF THE CODE WERE WRONG: delete the v_gf_n > 1 branch and the leaf scan lands
-- v_gf_n = 2 → the =1 branch is skipped → fall-through ALLOW → ok:true → red below.
do $$
declare r jsonb; n int; v_flag jsonb;
  uB uuid := (select v from fg where k='uB'); b2 uuid := (select v from fg where k='b2');
  gB uuid := (select v from fg where k='gB'); f1 uuid; f2 uuid;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- SURGERY: two live group-shaped fleets for gB (group_id set + main_ship_id NULL + live status).
  insert into public.fleets (player_id, status, location_mode, group_id)
    values (uB, 'idle', 'movement', gB) returning id into f1;
  insert into public.fleets (player_id, status, location_mode, group_id)
    values (uB, 'idle', 'movement', gB) returning id into f2;

  -- vacuity: EXACTLY two live group-shaped fleets exist for gB (the tagged per-member expedition
  -- fleet does not count — main_ship_id set), or the >1 arm is not what the assign below exercises.
  select count(*) into n from public.fleets
   where group_id = gB and player_id = uB and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 2 then raise exception 'ASSIGNGUARD-AMBIGUOUS FAIL: expected exactly 2 group-shaped fleets, got % — the two-fleet broken invariant was not built', n; end if;

  -- ── ★ AMBIGUOUS ★ the assign fails CLOSED with the mover's token — never picks a row. ──────────
  r := pg_temp.call_as(uB, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', b2, gB));
  if (r->>'reason') is distinct from 'fleet_ambiguous' then
    raise exception 'ASSIGNGUARD-AMBIGUOUS FAIL: assign under a two-fleet broken invariant answered % (a non-strict read picked an arbitrary row)', r; end if;

  -- restore: the manufactured fleets are deleted outright and the deletion is PROVEN.
  delete from public.fleets where id in (f1, f2);
  select count(*) into n from public.fleets
   where group_id = gB and player_id = uB and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'ASSIGNGUARD-AMBIGUOUS FAIL: the manufactured fleets were not removed (% left)', n; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_ASSIGNGUARD_AMBIGUOUS: two live group-shaped fleets -> fleet_ambiguous, fail closed (the broken-invariant arm is no longer decoration)';
end $$;

-- ════════ BLOCK HUNTUNI-DARKPARITY (4b-1, 0214, dark): the hunt IS the 0204 head while dark ════════
-- send_ship_group_hunt is a LIVE hot function (team_command ON in prod); 0214 re-creates it with
-- three hunks. Flag OFF, on the load-bearing REACHABLE dark state (a real docked-group hunt), it
-- must behave byte-for-byte as the head: same envelope keys, the 0199 docked-launch origin, the
-- ship status='hunting' write, the frozen manifest — and a SECOND hunt while the sortie is live
-- must answer the HEAD's reason (member_not_ready: the members read 'hunting').
-- HOW THIS FAILS IF THE CODE WERE WRONG / MUTATION (documented in the sh): force `v_unified :=
-- true` in 0214 and the second probe answers group_fleet_in_flight (Hunk C sees the live hunt
-- fleet) instead of member_not_ready → red. The FIRST hunt alone cannot catch that mutation (a
-- fleetless group falls through Hunk C identically), which is why the second probe exists.
do $$
declare r jsonb; n int; v_flag jsonb;
  uE uuid := (select v from fg where k='uE'); haven uuid := (select v from fg where k='haven');
  e1 uuid; gE uuid; v_hunt uuid; v_huntfleet uuid; v_huntmv uuid;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';

  -- live-RPC provisioning: e1 docked at haven → group → real hunt (the 0199 docked launch).
  r := pg_temp.call_as(uE, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-DARKPARITY FAIL: commission e1: %', r; end if;
  select main_ship_id into e1 from public.main_ship_instances where player_id = uE;
  r := pg_temp.call_as(uE, 'public.upsert_ship_group(1, ''Hounds'')');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-DARKPARITY FAIL: group: %', r; end if;
  gE := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uE, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', e1, gE));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-DARKPARITY FAIL: assign e1: %', r; end if;
  select id into v_hunt from public.locations
   where status = 'active' and activity_type = 'hunt_pirates'
   order by coalesce(min_power_required, 0) asc limit 1;
  if v_hunt is null then raise exception 'HUNTUNI-DARKPARITY FAIL: no active hunt site — the fixture cannot be built'; end if;
  -- vacuity: e1 really is docked (the 0199 lit arm's input shape) and gE has NO group-shaped fleet.
  select count(*) into n from public.main_ship_instances
   where main_ship_id = e1 and status = 'stationary' and spatial_state = 'at_location';
  if n <> 1 then raise exception 'HUNTUNI-DARKPARITY FAIL: e1 is not docked — the docked-launch head path would be vacuous'; end if;
  select count(*) into n from public.fleets
   where group_id = gE and player_id = uE and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'HUNTUNI-DARKPARITY FAIL: a group-shaped fleet already exists — this is not the head''s reachable dark state'; end if;

  -- the real hunt, dark: the 0204/0199 head behavior, pinned piece by piece.
  r := pg_temp.call_as(uE, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gE, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-DARKPARITY FAIL: dark hunt rejected: %', r; end if;
  -- the head's exact envelope KEY SET (ids are minted, so the shape is the comparable thing).
  if (select array_agg(k order by k) from jsonb_object_keys(r) k)
     is distinct from array['arrive_at','fleet_id','group_id','member_count','movement_id','ok','return_location_id'] then
    raise exception 'HUNTUNI-DARKPARITY FAIL: dark envelope keys drifted from the 0204 head: %', r; end if;
  if (r->>'group_id')::uuid is distinct from gE or (r->>'member_count')::int is distinct from 1
     or (r->>'return_location_id')::uuid is distinct from haven then
    raise exception 'HUNTUNI-DARKPARITY FAIL: dark envelope values drifted from the 0204 head: %', r; end if;
  v_huntfleet := (r->>'fleet_id')::uuid;
  v_huntmv    := (r->>'movement_id')::uuid;
  -- the 0199 docked-launch origin: the leg departs the COMMON DOCKED PORT, not the base.
  select count(*) into n from public.fleet_movements
   where id = v_huntmv and origin_type = 'location' and origin_location_id = haven and target_location_id = v_hunt;
  if n <> 1 then raise exception 'HUNTUNI-DARKPARITY FAIL: dark hunt did not depart the docked port (the 0199 head arm drifted)'; end if;
  -- the head's ship write survives: status='hunting', spatial cleared.
  select count(*) into n from public.main_ship_instances
   where main_ship_id = e1 and status = 'hunting' and spatial_state is null;
  if n <> 1 then raise exception 'HUNTUNI-DARKPARITY FAIL: the head''s status=hunting ship write is missing while dark'; end if;
  -- the frozen manifest, and the member's own dock dissolved (the head's own block).
  select count(*) into n from public.group_sortie_members where fleet_id = v_huntfleet and main_ship_id = e1;
  if n <> 1 then raise exception 'HUNTUNI-DARKPARITY FAIL: e1 is not on the frozen manifest'; end if;
  select count(*) into n from public.fleets
   where player_id = uE and main_ship_id = e1 and status = 'present';
  if n <> 0 then raise exception 'HUNTUNI-DARKPARITY FAIL: e1''s own dock fleet was not dissolved (the head''s dissolve drifted)'; end if;

  -- ── the SECOND probe — the mutation-sensitive pin. Head: members read 'hunting' → the readiness
  --    arm answers member_not_ready. Forced-lit Hunk C would answer group_fleet_in_flight instead.
  if (select status from public.fleets where id = v_huntfleet) is distinct from 'moving' then
    raise exception 'HUNTUNI-DARKPARITY FAIL: the hunt fleet is not moving — the second probe would be vacuous'; end if;
  r := pg_temp.call_as(uE, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gE, v_hunt));
  if (r->>'reason') is distinct from 'member_not_ready' then
    raise exception 'HUNTUNI-DARKPARITY FAIL: second dark hunt answered % (the head says member_not_ready; group_fleet_in_flight here means Hunk C ran while dark)', r; end if;

  -- hand the uE world to the ONSORTIE block (the live sortie persists deliberately).
  insert into fg values ('e1', e1), ('gE', gE), ('huntE', v_hunt),
                        ('huntfleetE', v_huntfleet), ('huntmvE', v_huntmv);
  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'HUNTUNI_DARKPARITY: dark hunt = the 0204 head (envelope keys+values, docked-port origin, hunting write, frozen manifest, dissolve) and the second probe answers the HEAD''s member_not_ready';
end $$;

-- ════════ BLOCK HUNTUNI-ONSORTIE (4b-1, 0214, lit): AN OPEN SORTIE IS NEVER CONSUMABLE ════════
-- The 0214 review's F1 (HIGH) made red. A hunt's sortie fleet sits 'present' AT ITS HUNT SITE for
-- the whole encounter (0169's race pin: 'present' = MID-COMBAT), with a LIVE combat_encounters row
-- and an active presence. A status-only in-flight arm waves that fleet through as "settled" — and
-- consuming it would presence_complete the live encounter's presence and complete the fleet under
-- it; the escape/extract tick (0169:210-230) then runs fleet_set_returning on a completed fleet:
-- wedged encounter or resurrected fleet → v_n=2 → the blackout 0214 exists to kill, re-minted by
-- its own consume. 0214's manifest read (the mover's guard-8 read, 0213's token) must reject this
-- with group_on_sortie and ZERO writes: no second fleet, no second manifest, the encounter and its
-- presence untouched.
-- HOW THIS FAILS IF THE CODE WERE WRONG / MUTATION (documented in the sh): drop the gsm read and
-- the 'present' sortie fleet enters the consume path — the live encounter's presence is closed,
-- the fleet completed, a second sortie minted (or the zero-distance leg raises) → red here.
do $$
declare r jsonb; n int; n2 int; v_flag jsonb;
  uE uuid := (select v from fg where k='uE'); e1 uuid := (select v from fg where k='e1');
  gE uuid := (select v from fg where k='gE'); v_hunt uuid := (select v from fg where k='huntE');
  v_huntfleet uuid := (select v from fg where k='huntfleetE');
  v_huntmv uuid := (select v from fg where k='huntmvE');
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';

  -- settle the sortie leg through the real cron entry point: the fleet docks 'present' AT the hunt
  -- site, presence_create fires activity_start('hunt_pirates') → a LIVE group encounter.
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_huntmv;
  perform public.movement_settle_arrival(v_huntmv);

  -- vacuity guards: the mid-combat state must REALLY exist, or the rejection below proves nothing.
  select count(*) into n from public.fleets
   where id = v_huntfleet and status = 'present' and current_location_id = v_hunt;
  if n <> 1 then raise exception 'HUNTUNI-ONSORTIE FAIL: the sortie fleet is not present at the hunt site — the mid-combat sortie state was not built'; end if;
  select count(*) into n from public.group_sortie_members where fleet_id = v_huntfleet;
  if n = 0 then raise exception 'HUNTUNI-ONSORTIE FAIL: no open manifest on the sortie fleet — the mid-combat sortie state was not built'; end if;
  select count(*) into n from public.combat_encounters
   where fleet_id = v_huntfleet and status = 'active';
  if n <> 1 then raise exception 'HUNTUNI-ONSORTIE FAIL: no live encounter on the sortie fleet — consuming it would be untested where it hurts'; end if;
  select count(*) into n from public.location_presence
   where fleet_id = v_huntfleet and status = 'active' and location_id = v_hunt;
  if n <> 1 then raise exception 'HUNTUNI-ONSORTIE FAIL: no active presence under the encounter — the consume would have nothing to wrongly close'; end if;

  -- ── ★ ONSORTIE ★ lit, second hunt against the mid-combat group: rejected, ZERO writes. ─────────
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  create temp table os_ships_before as select * from public.main_ship_instances;
  create temp table os_fleets_before as select * from public.fleets;
  create temp table os_pres_before  as select * from public.location_presence;
  select count(*) into n from public.group_sortie_members;
  select count(*) into n2 from public.combat_encounters;
  r := pg_temp.call_as(uE, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gE, v_hunt));
  if (r->>'reason') is distinct from 'group_on_sortie' then
    raise exception 'HUNTUNI-ONSORTIE FAIL: a second hunt against a mid-combat sortie answered % — the consume just ate a live encounter''s fleet', r; end if;
  if (select count(*) from public.group_sortie_members) <> n then
    raise exception 'HUNTUNI-ONSORTIE FAIL: the rejected hunt changed the manifest row count'; end if;
  if (select count(*) from public.combat_encounters) <> n2 then
    raise exception 'HUNTUNI-ONSORTIE FAIL: the rejected hunt changed the encounter row count'; end if;
  select count(*) into n from (
    (table os_ships_before except select * from public.main_ship_instances)
    union all (select * from public.main_ship_instances except table os_ships_before)) d;
  if n <> 0 then raise exception 'HUNTUNI-ONSORTIE FAIL: the rejected hunt wrote % main_ship_instances row(s)', n; end if;
  select count(*) into n from (
    (table os_fleets_before except select * from public.fleets)
    union all (select * from public.fleets except table os_fleets_before)) d;
  if n <> 0 then raise exception 'HUNTUNI-ONSORTIE FAIL: the rejected hunt wrote % fleets row(s)', n; end if;
  select count(*) into n from (
    (table os_pres_before except select * from public.location_presence)
    union all (select * from public.location_presence except table os_pres_before)) d;
  if n <> 0 then raise exception 'HUNTUNI-ONSORTIE FAIL: the rejected hunt wrote % location_presence row(s)', n; end if;
  drop table os_ships_before; drop table os_fleets_before; drop table os_pres_before;
  -- exactly ONE live group-shaped fleet (the sortie), still present, encounter still active.
  select count(*) into n from public.fleets
   where group_id = gE and player_id = uE and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'HUNTUNI-ONSORTIE FAIL: % live group-shaped fleets after the rejected hunt', n; end if;
  select count(*) into n from public.combat_encounters where fleet_id = v_huntfleet and status = 'active';
  if n <> 1 then raise exception 'HUNTUNI-ONSORTIE FAIL: the live encounter did not survive the rejected hunt'; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'HUNTUNI_REJECT_ONSORTIE: lit + sortie fleet present MID-COMBAT at its hunt site -> group_on_sortie, zero writes, one live fleet, the encounter untouched (an open sortie is never consumable)';
end $$;

-- ════════ BLOCK HUNTUNI-CONSUME (4b-1, 0214, lit): go → present → hunt CONSUMES the fleet ════════
-- The obligation itself. uF's world: a lit go docks the unified fleet at slag; then a hunt must
-- not double-mint (the v_n=2 map-blackout catastrophe) — it consumes the settled fleet and mints
-- the sortie from ITS position. Six markers on one chain:
--   HUNTUNI_REJECT_INFLIGHT — fleet moving → hunt rejected group_fleet_in_flight, zero writes.
--   HUNTUNI_PASS_NOSECONDFLEET — after the consuming hunt, EXACTLY ONE live group-shaped fleet.
--   HUNTUNI_PASS_NOGHOSTDOCK — the consumed fleet is terminal and its presence CLOSED (§0's class).
--   HUNTUNI_PASS_RESOLVER — members resolve to the ONE hunt fleet and the map draws them NOT hidden.
--   HUNTUNI_REJECT_MEMBERBUSY — a member flying its OWN per-ship fleet → member_busy (the F2
--   transition guard, the mover's guard-7 twin), self-restoring fixture.
--   HUNTUNI_PASS_AMBIGUOUS — a manufactured two-fleet broken invariant → fleet_ambiguous, and the
--   arm fires BEFORE the in-flight arm (runtime order pin).
-- FIXTURE SHAPE: before the consuming hunt, f1/f2 are rewritten to the LEGACY 'home' shape
-- (spatial_state NULL — prod's 73/76 majority shape); f3 keeps its co-located dock. ⚠ HONEST
-- RED-AXIS NOTE (the 0214 review's F4 — the earlier version of this comment overclaimed): with f3
-- docked in the group, UNPATCHED code fails CLOSED on this exact fixture (mixed home+docked →
-- v_docked=1≠3 → member_not_ready), not open. The fail-OPEN double-mint (readiness passes → the
-- 0168 arm mints a SECOND fleet → v_n=2 → every member hidden) is driven by the ALL-home,
-- no-co-located shape — the prod-majority group with no fresh assignee. This block's red axis is
-- therefore the MUTATION (skip Hunk C's fleet-complete → two live fleets → NOSECONDFLEET red),
-- plus unpatched-red-by-rejection; do not read this fixture as a demo of the open blackout.
-- (The home write is CHECK-safe — 0055 constrains only 'stationary' — and is consumed by the
-- hunt's own status='hunting' write; nothing to restore.)
-- MUTATIONS (documented in the sh): skip Hunk C's fleet-complete → two live fleets → NOSECONDFLEET
-- red. Delete the in-flight arm → the moving fleet is "consumed" from its anchor → INFLIGHT red.
-- Delete the >1 arm → the two-fleet fixture falls into the consume/mint path → AMBIGUOUS red.
-- Delete the member-busy guard → the manufactured busy fleet is waved through → MEMBERBUSY red.
do $$
declare r jsonb; e jsonb; n int; v_flag jsonb; s uuid;
  uF uuid := (select v from fg where k='uF'); slag uuid := (select v from fg where k='slag');
  f1 uuid; f2 uuid; f3 uuid; v_f3fleet uuid; gF uuid; v_gofleet uuid; v_gomv uuid;
  v_hunt uuid; v_huntfleet uuid; v_huntmv uuid; v_fm record; amb uuid;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- live-RPC provisioning: two ships, one group.
  r := pg_temp.call_as(uF, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-CONSUME FAIL: commission f1: %', r; end if;
  select main_ship_id into f1 from public.main_ship_instances where player_id = uF;
  r := pg_temp.call_as(uF, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-CONSUME FAIL: commission f2: %', r; end if;
  f2 := (r->>'main_ship_id')::uuid;
  r := pg_temp.call_as(uF, 'public.upsert_ship_group(1, ''Lancers'')');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-CONSUME FAIL: group: %', r; end if;
  gF := (r->>'group_id')::uuid;
  -- S1-BERTH (0216): f1's fixture assign runs DARK (a lit first-assign into an empty group mints
  -- the group fleet — ASSIGN_CLEARS_BERTH's world; this chain must start fleetless so the GO below
  -- exercises the bootstrap origin exactly as before). f2's assign stays LIT: a non-empty
  -- fleetless group is the 0-rows bootstrap-allow arm, no mint.
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';
  r := pg_temp.call_as(uF, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', f1, gF));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-CONSUME FAIL: assign f1: %', r; end if;
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  r := pg_temp.call_as(uF, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', f2, gF));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-CONSUME FAIL: assign f2: %', r; end if;
  select id into v_hunt from public.locations
   where status = 'active' and activity_type = 'hunt_pirates'
   order by coalesce(min_power_required, 0) asc limit 1;
  if v_hunt is null then raise exception 'HUNTUNI-CONSUME FAIL: no active hunt site — the fixture cannot be built'; end if;

  -- the lit go: the group's ONE unified fleet departs the commission dock for slag.
  r := pg_temp.call_as(uF, format('public.command_ship_group_go(%L::uuid, %L::uuid)', gF, slag));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-CONSUME FAIL: go: %', r; end if;
  v_gofleet := (r->>'fleet_id')::uuid;
  v_gomv    := (r->>'movement_id')::uuid;

  -- ── ★ INFLIGHT ★ fleet 'moving' → the hunt is rejected with the guard-8 twin, ZERO writes across
  --    the three ghost-dock tables (the NOSHIPWRITE idiom widened — the recorded 3a lesson).
  if (select status from public.fleets where id = v_gofleet) is distinct from 'moving' then
    raise exception 'HUNTUNI-INFLIGHT FAIL: the unified fleet is not moving — the in-flight state was not built'; end if;
  create temp table hu_ships_before as select * from public.main_ship_instances;
  create temp table hu_fleets_before as select * from public.fleets;
  create temp table hu_pres_before  as select * from public.location_presence;
  select count(*) into n from hu_ships_before;
  if n = 0 then raise exception 'HUNTUNI-INFLIGHT FAIL: empty before-snapshot — the zero-write diff would be vacuous'; end if;
  r := pg_temp.call_as(uF, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gF, v_hunt));
  if (r->>'reason') is distinct from 'group_fleet_in_flight' then
    raise exception 'HUNTUNI-INFLIGHT FAIL: hunt while the unified fleet is MOVING answered %', r; end if;
  select count(*) into n from (
    (table hu_ships_before except select * from public.main_ship_instances)
    union all (select * from public.main_ship_instances except table hu_ships_before)) d;
  if n <> 0 then raise exception 'HUNTUNI-INFLIGHT FAIL: the rejected hunt wrote % main_ship_instances row(s)', n; end if;
  select count(*) into n from (
    (table hu_fleets_before except select * from public.fleets)
    union all (select * from public.fleets except table hu_fleets_before)) d;
  if n <> 0 then raise exception 'HUNTUNI-INFLIGHT FAIL: the rejected hunt wrote % fleets row(s)', n; end if;
  select count(*) into n from (
    (table hu_pres_before except select * from public.location_presence)
    union all (select * from public.location_presence except table hu_pres_before)) d;
  if n <> 0 then raise exception 'HUNTUNI-INFLIGHT FAIL: the rejected hunt wrote % location_presence row(s)', n; end if;
  drop table hu_ships_before; drop table hu_fleets_before; drop table hu_pres_before;
  raise notice 'HUNTUNI_REJECT_INFLIGHT: lit + unified fleet moving -> group_fleet_in_flight, zero writes across ships/fleets/presence (both-way diff)';

  -- settle the go: the unified fleet docks 'present' at slag with an active presence.
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_gomv;
  perform public.movement_settle_arrival(v_gomv);
  select count(*) into n from public.fleets
   where id = v_gofleet and status = 'present' and location_mode = 'location' and current_location_id = slag;
  if n <> 1 then raise exception 'HUNTUNI-CONSUME FAIL: the unified fleet did not settle present at slag — the consume phase is vacuous'; end if;
  select count(*) into n from public.location_presence where fleet_id = v_gofleet and status = 'active' and location_id = slag;
  if n <> 1 then raise exception 'HUNTUNI-CONSUME FAIL: no active presence at slag — the ghost-dock assertion would be vacuous'; end if;

  -- f3: the 0213 CO-LOCATED ASSIGNEE — a member who joins the settled group still holding its OWN
  -- per-ship present fleet + active presence at the group's port (0213 chose guard-assignment over
  -- dissolve-at-assignment, so the ALLOW arm leaves the pair alive). Live RPCs only: commission
  -- (haven) → the LIVE legacy per-ship move to slag (mainship_send_enabled, lit in-txn) → settle →
  -- lit assign (co-located, no open sortie → ALLOW). The consuming hunt MUST dissolve this dock —
  -- a sortie that left it active is a ship hunting AND docked at once (§0 through the hunt's own
  -- front door). MUTATION (documented in the sh): drop 0214's member-dissolve hunk → f3's fleet
  -- stays 'present' with an active presence → the NOGHOSTDOCK asserts below go red.
  r := pg_temp.call_as(uF, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-CONSUME FAIL: commission f3: %', r; end if;
  f3 := (r->>'main_ship_id')::uuid;
  select id into v_f3fleet from public.fleets
   where player_id = uF and main_ship_id = f3 and status = 'present';
  if v_f3fleet is null then raise exception 'HUNTUNI-CONSUME FAIL: f3 has no present commission fleet — the co-located fixture cannot be built'; end if;
  -- ⚠ ENVELOPE SHAPE (verified at the 0156 TRUE head — 0053→0152→0156 are its only re-creates,
  -- loose-grep derived): the per-ship legacy movers do NOT return the group RPCs' {ok:...}
  -- envelope. move_main_ship_to_location returns a BARE movement envelope — {fleet_id, movement_id,
  -- main_ship_id, from, from_location_id, to_location_id, arrive_at} — and every failure path
  -- RAISES (0156:87-187), which call_as propagates, so a genuinely failed move aborts this block
  -- with the RPC's own error. Success is therefore asserted on what the head actually returns: a
  -- minted movement_id targeting slag. An `->>'ok'` check here reads NULL and raises on a
  -- SUCCESSFUL move (the CI caught exactly that — the third fixture-envelope class in this arc).
  r := pg_temp.call_as(uF, format('public.move_main_ship_to_location(%L::uuid, %L::uuid)', v_f3fleet, slag));
  if (r->>'movement_id') is null or (r->>'to_location_id')::uuid is distinct from slag then
    raise exception 'HUNTUNI-CONSUME FAIL: legacy move of f3 returned no movement toward slag: %', r; end if;
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = (r->>'movement_id')::uuid;
  perform public.movement_settle_arrival((r->>'movement_id')::uuid);
  select count(*) into n from public.fleets f
    join public.location_presence lp on lp.fleet_id = f.id and lp.status = 'active' and lp.location_id = slag
   where f.id = v_f3fleet and f.status = 'present' and f.current_location_id = slag;
  if n <> 1 then raise exception 'HUNTUNI-CONSUME FAIL: f3''s own dock (fleet+presence) is not at slag — the co-located shape was not built'; end if;
  -- S1-BERTH (0216) FIXTURE SYNC: the LIVE legacy per-ship mover maintains no berth (it is dark in
  -- prod; the migration's backfill did this conversion once for real pre-flip ships). The fixture
  -- mirrors the backfill so f3's berth follows its REAL dock — the co-location guard reads BERTH
  -- now. CHECK-coupled: f3 is ungrouped, berth stays non-null → the XOR holds.
  update public.main_ship_instances set berth_location_id = slag where main_ship_id = f3;
  r := pg_temp.call_as(uF, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', f3, gF));
  if (r->>'ok')::boolean is not true then
    raise exception 'HUNTUNI-CONSUME FAIL: the co-located assign of f3 was rejected: % (0213''s ALLOW arm regressed?)', r; end if;

  -- SURGERY (consumed by the hunt's own status write — see the block header): the LEGACY 'home'
  -- shape, prod's majority, on f1/f2. THIS is the shape whose pre-0214 path fails OPEN into the
  -- double-mint. f3 deliberately KEEPS its co-located-dock shape — that is the state under test.
  update public.main_ship_instances set status = 'home', spatial_state = null
   where main_ship_id in (f1, f2);
  -- vacuity: f1/f2 hold zero per-ship fleets — their only position is the group fleet's.
  select count(*) into n from public.fleets
   where player_id = uF and main_ship_id in (f1, f2) and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'HUNTUNI-CONSUME FAIL: % per-ship fleet(s) exist — the catastrophe shape was not built', n; end if;

  -- ── ★ MEMBERBUSY ★ (F2, the mover's guard-7 twin) SURGERY (self-restoring, proven): a moving
  --    per-ship fleet for f1 — the state the live per-ship send produces (the GUARDS block's own
  --    fixture idiom). hp-only readiness would mint f1 'hunting' while its own leg flies; when
  --    that leg settles present+active the ship is hunting AND docked (§0 through a third door).
  --    The consume path must reject member_busy BEFORE any write.
  insert into public.fleets (player_id, status, location_mode, main_ship_id)
    values (uF, 'moving', 'movement', f1);
  select count(*) into n from public.fleets
   where player_id = uF and main_ship_id = f1 and status in ('moving','returning');
  if n <> 1 then raise exception 'HUNTUNI-MEMBERBUSY FAIL: the busy-member state was not built'; end if;
  r := pg_temp.call_as(uF, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gF, v_hunt));
  if (r->>'reason') is distinct from 'member_busy' then
    raise exception 'HUNTUNI-MEMBERBUSY FAIL: hunt with a member flying its own per-ship fleet answered % (ok here = that member ends hunting AND docked when its leg settles)', r; end if;
  -- restore: delete the manufactured fleet and PROVE it (the member_busy lesson).
  delete from public.fleets
   where player_id = uF and main_ship_id = f1 and status = 'moving' and active_movement_id is null;
  select count(*) into n from public.fleets
   where player_id = uF and main_ship_id = f1 and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'HUNTUNI-MEMBERBUSY FAIL: the busy fixture did not restore (% left)', n; end if;
  raise notice 'HUNTUNI_REJECT_MEMBERBUSY: lit + a member flying its OWN per-ship fleet -> member_busy (the guard-7 transition twin), fixture restored and proven';

  -- ── ★ NOSECONDFLEET ★ the hunt CONSUMES the settled fleet and mints the sortie from ITS port. ──
  r := pg_temp.call_as(uF, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gF, v_hunt));
  if (r->>'ok')::boolean is not true then
    raise exception 'HUNTUNI-NOSECONDFLEET FAIL: the consuming hunt was rejected: % (member_not_ready here = the retired per-ship readiness is still being read)', r; end if;
  v_huntfleet := (r->>'fleet_id')::uuid;
  v_huntmv    := (r->>'movement_id')::uuid;
  -- THE catastrophe made red: EXACTLY ONE live group-shaped fleet after the hunt.
  select count(*) into n from public.fleets
   where group_id = gF and player_id = uF and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'HUNTUNI-NOSECONDFLEET FAIL: % live group-shaped fleets after the hunt — v_n=% and every member goes hidden (0210:90-92)', n, n; end if;
  if v_huntfleet = v_gofleet then
    raise exception 'HUNTUNI-NOSECONDFLEET FAIL: the hunt reused the consumed fleet id — the consume/mint split collapsed'; end if;
  -- origin captured FROM THE FLEET: the sortie departs slag (the consumed fleet's port), and the
  -- return port defaults to it (the 0199 rule applied to the fleet's position).
  select count(*) into n from public.fleet_movements
   where id = v_huntmv and origin_type = 'location' and origin_location_id = slag and target_location_id = v_hunt;
  if n <> 1 then raise exception 'HUNTUNI-NOSECONDFLEET FAIL: the sortie did not depart the CONSUMED FLEET''s port'; end if;
  if (r->>'return_location_id')::uuid is distinct from slag then
    raise exception 'HUNTUNI-NOSECONDFLEET FAIL: return port % is not the consumed fleet''s port', r->>'return_location_id'; end if;
  -- the hunt's own layer survives lit: 'hunting' writes + the frozen manifest (all THREE members,
  -- including the co-located f3).
  select count(*) into n from public.main_ship_instances
   where main_ship_id in (f1, f2, f3) and status = 'hunting' and spatial_state is null;
  if n <> 3 then raise exception 'HUNTUNI-NOSECONDFLEET FAIL: the status=hunting ship write is missing lit (% of 3)', n; end if;
  select count(*) into n from public.group_sortie_members where fleet_id = v_huntfleet;
  if n <> 3 then raise exception 'HUNTUNI-NOSECONDFLEET FAIL: the frozen manifest has % member(s), expected 3', n; end if;
  raise notice 'HUNTUNI_PASS_NOSECONDFLEET: go -> present -> hunt leaves EXACTLY ONE live group-shaped fleet; the sortie departs the consumed fleet''s port with the head''s hunting write + manifest intact';

  -- ── ★ NOGHOSTDOCK ★ the consumed fleet AND the co-located member's own dock are TERMINAL with
  --    their presence CLOSED — §0's bug class, on BOTH pairs the consuming path must dissolve. ───
  select count(*) into n from public.fleets where id = v_gofleet and status = 'completed';
  if n <> 1 then raise exception 'HUNTUNI-NOGHOSTDOCK FAIL: the consumed fleet is not terminal'; end if;
  select count(*) into n from public.location_presence where fleet_id = v_gofleet and status = 'active';
  if n <> 0 then raise exception 'HUNTUNI-NOGHOSTDOCK FAIL: % active presence row(s) survive on the consumed fleet — the group is docked and hunting at once', n; end if;
  -- the co-located assignee's OWN dock pair (the mutation target: drop the member-dissolve → red).
  select count(*) into n from public.fleets where id = v_f3fleet and status = 'completed';
  if n <> 1 then raise exception 'HUNTUNI-NOGHOSTDOCK FAIL: f3''s own per-ship fleet was not dissolved — the co-located member is hunting AND docked at once (§0 through the hunt''s front door)'; end if;
  select count(*) into n from public.location_presence where fleet_id = v_f3fleet and status = 'active';
  if n <> 0 then raise exception 'HUNTUNI-NOGHOSTDOCK FAIL: % active presence row(s) survive on f3''s dissolved dock', n; end if;
  -- ...and world-wide for uF: NOTHING of this player's is left actively docked anywhere.
  select count(*) into n from public.location_presence lp
    join public.fleets f on f.id = lp.fleet_id
   where f.player_id = uF and lp.status = 'active';
  if n <> 0 then raise exception 'HUNTUNI-NOGHOSTDOCK FAIL: % orphan active presence row(s) in the whole world after the consuming hunt', n; end if;
  raise notice 'HUNTUNI_PASS_NOGHOSTDOCK: the consumed fleet AND the co-located member''s own dock are terminal with presence closed — no orphan location_presence after the consuming path';

  -- ── ★ RESOLVER ★ the members resolve to the ONE hunt fleet and the map draws them NOT hidden. ──
  -- Vacuity first: zero per-ship fleets, so only the group fleet could answer (the 0210 guard).
  select count(*) into n from public.fleets
   where player_id = uF and main_ship_id in (f1, f2, f3) and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'HUNTUNI-RESOLVER FAIL: % per-ship fleet(s) exist — the resolution could come from the retired layer', n; end if;
  foreach s in array array[f1, f2, f3] loop
    if public.mainship_resolve_fleet(s) is distinct from v_huntfleet then
      raise exception 'HUNTUNI-RESOLVER FAIL: member % does not resolve to the ONE hunt fleet (NULL here = v_n<>1 = the blackout)', s; end if;
  end loop;
  select * into v_fm from public.fleet_movements where id = v_huntmv;
  if v_fm.status is distinct from 'moving' then
    raise exception 'HUNTUNI-RESOLVER FAIL: the sortie leg is not moving — the map pin would be vacuous'; end if;
  r := pg_temp.call_as(uF, 'public.get_my_fleet_positions()');
  foreach s in array array[f1, f2, f3] loop
    e := null;
    select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = s::text;
    if e is null or (e->>'place') is distinct from 'transit' or (e->'segment') is null then
      raise exception 'HUNTUNI-RESOLVER FAIL: member % of the hunting group draws % — hidden IS the catastrophe this migration closes', s, e; end if;
    if (e->'segment'->>'origin_x')::double precision is distinct from v_fm.origin_x
       or (e->'segment'->>'target_x')::double precision is distinct from v_fm.target_x
       or (e->'segment'->>'depart_at')::timestamptz is distinct from v_fm.depart_at
       or (e->'segment'->>'arrive_at')::timestamptz is distinct from v_fm.arrive_at then
      raise exception 'HUNTUNI-RESOLVER FAIL: member % segment % is not the ONE sortie leg', s, e->'segment'; end if;
  end loop;
  raise notice 'HUNTUNI_PASS_RESOLVER: every member resolves to the ONE hunt fleet and the map draws transit on the sortie leg — nobody is hidden';

  -- ── ★ AMBIGUOUS ★ SURGERY (self-restoring, proven): mint ONE extra idle group-shaped fleet →
  --    two live → the hunt fails CLOSED with the shared token, and it does so BEFORE the in-flight
  --    arm could answer (the sortie fleet is 'moving' right now — a wrong arm order would say
  --    group_fleet_in_flight): a runtime pin of the guard order, not just the prosrc one.
  insert into public.fleets (player_id, status, location_mode, group_id)
    values (uF, 'idle', 'movement', gF) returning id into amb;
  select count(*) into n from public.fleets
   where group_id = gF and player_id = uF and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 2 then raise exception 'HUNTUNI-AMBIGUOUS FAIL: expected exactly 2 group-shaped fleets, got % — the two-fleet broken invariant was not built', n; end if;
  r := pg_temp.call_as(uF, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gF, v_hunt));
  if (r->>'reason') is distinct from 'fleet_ambiguous' then
    raise exception 'HUNTUNI-AMBIGUOUS FAIL: hunt under a two-fleet broken invariant answered % (in_flight here = wrong arm order; ok here = a third fleet was minted on top of a broken invariant)', r; end if;
  delete from public.fleets where id = amb;
  select count(*) into n from public.fleets
   where group_id = gF and player_id = uF and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'HUNTUNI-AMBIGUOUS FAIL: the manufactured fleet was not removed (% left)', n; end if;
  -- behavioral restore proof: with the invariant healed, the same call is back to the in-flight arm.
  r := pg_temp.call_as(uF, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gF, v_hunt));
  if (r->>'reason') is distinct from 'group_fleet_in_flight' then
    raise exception 'HUNTUNI-AMBIGUOUS FAIL: after the restore the hunt answered % (expected the in-flight arm again)', r; end if;
  raise notice 'HUNTUNI_PASS_AMBIGUOUS: two live group-shaped fleets -> fleet_ambiguous BEFORE the in-flight arm, fail closed, fixture restored and re-proven';

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
end $$;

-- ════════ BLOCK HUNTUNI-BOOTSTRAP (4b-1, 0214, lit): the =0 arm falls through to the head VERBATIM ════
-- The bootstrap-parity pin: a group that has NEVER moved (no group-shaped fleet — the 0213 leaf
-- returns zero rows) still carries per-ship dock shapes, and lit those shapes ARE the truth. Hunk C
-- must fall through and let the head's 0199 docked-launch arm run unchanged: same envelope keys as
-- the dark run, docked-port origin, hunting write, manifest, dissolve.
-- HOW THIS FAILS IF THE CODE WERE WRONG: gate the head's arms out entirely (a lit-only rewrite
-- instead of a fall-through) and a fleetless group can never hunt again → red on ok. Skip the
-- readiness in the =0 arm too and a scattered/undocked group would mint from base — the dissolve
-- and origin pins below would drift.
do $$
declare r jsonb; n int; v_flag jsonb;
  uG uuid := (select v from fg where k='uG'); haven uuid := (select v from fg where k='haven');
  g1 uuid; gG uuid; v_hunt uuid; v_huntfleet uuid; v_huntmv uuid;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  r := pg_temp.call_as(uG, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-BOOTSTRAP FAIL: commission g1: %', r; end if;
  select main_ship_id into g1 from public.main_ship_instances where player_id = uG;
  r := pg_temp.call_as(uG, 'public.upsert_ship_group(1, ''Pathfinders'')');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-BOOTSTRAP FAIL: group: %', r; end if;
  gG := (r->>'group_id')::uuid;
  -- S1-BERTH (0216): the fixture assign runs DARK — a lit first-assign into an empty group now
  -- MINTS the group fleet, and this block's whole point is the leaf returning ZERO rows.
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';
  r := pg_temp.call_as(uG, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', g1, gG));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-BOOTSTRAP FAIL: assign g1: %', r; end if;
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  select id into v_hunt from public.locations
   where status = 'active' and activity_type = 'hunt_pirates'
   order by coalesce(min_power_required, 0) asc limit 1;
  if v_hunt is null then raise exception 'HUNTUNI-BOOTSTRAP FAIL: no active hunt site — the fixture cannot be built'; end if;
  -- vacuity: the leaf REALLY returns zero rows (the =0 arm is what runs), and g1 is docked.
  select count(*) into n from public.ship_group_resolve_fleet(uG, gG);
  if n <> 0 then raise exception 'HUNTUNI-BOOTSTRAP FAIL: a group-shaped fleet exists — this would not exercise the =0 arm'; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = g1 and status = 'stationary' and spatial_state = 'at_location';
  if n <> 1 then raise exception 'HUNTUNI-BOOTSTRAP FAIL: g1 is not docked — the 0199 arm would be vacuous'; end if;

  r := pg_temp.call_as(uG, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gG, v_hunt));
  if (r->>'ok')::boolean is not true then
    raise exception 'HUNTUNI-BOOTSTRAP FAIL: lit hunt from a fleetless docked group rejected: % (the =0 arm must fall through to the head)', r; end if;
  if (select array_agg(k order by k) from jsonb_object_keys(r) k)
     is distinct from array['arrive_at','fleet_id','group_id','member_count','movement_id','ok','return_location_id'] then
    raise exception 'HUNTUNI-BOOTSTRAP FAIL: lit =0 envelope keys drifted from the head: %', r; end if;
  if (r->>'return_location_id')::uuid is distinct from haven then
    raise exception 'HUNTUNI-BOOTSTRAP FAIL: return port % is not the docked port', r->>'return_location_id'; end if;
  v_huntfleet := (r->>'fleet_id')::uuid;
  v_huntmv    := (r->>'movement_id')::uuid;
  select count(*) into n from public.fleet_movements
   where id = v_huntmv and origin_type = 'location' and origin_location_id = haven and target_location_id = v_hunt;
  if n <> 1 then raise exception 'HUNTUNI-BOOTSTRAP FAIL: the =0 hunt did not depart the docked port (head-arm drift)'; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = g1 and status = 'hunting' and spatial_state is null;
  if n <> 1 then raise exception 'HUNTUNI-BOOTSTRAP FAIL: the head''s hunting write is missing on the =0 path'; end if;
  select count(*) into n from public.group_sortie_members where fleet_id = v_huntfleet and main_ship_id = g1;
  if n <> 1 then raise exception 'HUNTUNI-BOOTSTRAP FAIL: g1 is not on the frozen manifest'; end if;
  select count(*) into n from public.fleets
   where player_id = uG and main_ship_id = g1 and status = 'present';
  if n <> 0 then raise exception 'HUNTUNI-BOOTSTRAP FAIL: g1''s own dock fleet was not dissolved (head-arm drift)'; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'HUNTUNI_PASS_BOOTSTRAP: lit, leaf=0 -> the head''s 0199 docked arm runs verbatim (envelope keys, docked origin, hunting write, manifest, dissolve)';
end $$;

-- ════════ BLOCK HUNTUNI-FROMSPACE (4b-1, 0214, lit): a fleet parked in open space can hunt ════════
-- The model closing through the hunt: go → brake (0209) → the fleet holds idle in open space at its
-- own coordinate (0208) → a hunt launches FROM that coordinate, consuming the parked fleet. The
-- origin is captured from fleets.space_x/space_y — the position that, under §2, exists NOWHERE else
-- (zero ships carry one; asserted).
-- HOW THIS FAILS IF THE CODE WERE WRONG: read the origin from the members (per-ship space_x is
-- NULL everywhere) and movement_create raises / the origin pin reds; treat idle-in-space as
-- not-settled and the hunt rejects → red on ok.
do $$
declare r jsonb; n int; v_flag jsonb;
  uH uuid := (select v from fg where k='uH'); drift uuid := (select v from fg where k='drift');
  h1 uuid; gH uuid; v_hunt uuid; v_gofleet uuid; v_gomv uuid; v_huntfleet uuid; v_huntmv uuid;
  v_x double precision; v_y double precision;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  r := pg_temp.call_as(uH, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-FROMSPACE FAIL: commission h1: %', r; end if;
  select main_ship_id into h1 from public.main_ship_instances where player_id = uH;
  r := pg_temp.call_as(uH, 'public.upsert_ship_group(1, ''Drifters'')');
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-FROMSPACE FAIL: group: %', r; end if;
  gH := (r->>'group_id')::uuid;
  -- S1-BERTH (0216): the fixture assign runs DARK (no first-assign mint) so the go below exercises
  -- the same bootstrap chain it always did — worlds stay byte-stable; the mint has its own world.
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';
  r := pg_temp.call_as(uH, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', h1, gH));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-FROMSPACE FAIL: assign h1: %', r; end if;
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  select id into v_hunt from public.locations
   where status = 'active' and activity_type = 'hunt_pirates'
   order by coalesce(min_power_required, 0) asc limit 1;
  if v_hunt is null then raise exception 'HUNTUNI-FROMSPACE FAIL: no active hunt site — the fixture cannot be built'; end if;

  -- go, backdate to mid-leg, brake: the REAL 0209 park (no manufactured space state).
  r := pg_temp.call_as(uH, format('public.command_ship_group_go(%L::uuid, %L::uuid)', gH, drift));
  if (r->>'ok')::boolean is not true then raise exception 'HUNTUNI-FROMSPACE FAIL: go: %', r; end if;
  v_gofleet := (r->>'fleet_id')::uuid;
  v_gomv    := (r->>'movement_id')::uuid;
  update public.fleet_movements
     set depart_at = now() - interval '30 seconds', arrive_at = now() + interval '30 seconds'
   where id = v_gomv;
  r := pg_temp.call_as(uH, format('public.command_ship_group_stop(%L::uuid)', gH));
  if (r->>'ok')::boolean is not true or (r->>'stopped')::boolean is not true then
    raise exception 'HUNTUNI-FROMSPACE FAIL: brake: %', r; end if;
  select space_x, space_y into v_x, v_y from public.fleets
   where id = v_gofleet and status = 'idle' and location_mode = 'space';
  if v_x is null then raise exception 'HUNTUNI-FROMSPACE FAIL: the fleet is not parked idle in space — the from-space state was not built'; end if;
  -- vacuity: ZERO ships carry a position — only the FLEET could supply the origin below (§2).
  select count(*) into n from public.main_ship_instances where space_x is not null or space_y is not null;
  if n <> 0 then raise exception 'HUNTUNI-FROMSPACE FAIL: % ship(s) carry a position — the origin could come from the retired layer', n; end if;

  -- ── ★ FROMSPACE ★ the hunt consumes the parked fleet and departs its coordinate. ───────────────
  r := pg_temp.call_as(uH, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gH, v_hunt));
  if (r->>'ok')::boolean is not true then
    raise exception 'HUNTUNI-FROMSPACE FAIL: hunt from a space-parked fleet rejected: %', r; end if;
  v_huntfleet := (r->>'fleet_id')::uuid;
  v_huntmv    := (r->>'movement_id')::uuid;
  select count(*) into n from public.fleet_movements
   where id = v_huntmv and origin_type = 'space' and origin_x = v_x and origin_y = v_y
     and origin_location_id is null and target_location_id = v_hunt;
  if n <> 1 then raise exception 'HUNTUNI-FROMSPACE FAIL: the sortie did not depart the FLEET''s parked coordinate (%,%)', v_x, v_y; end if;
  -- no port origin → the return port is only what the caller chose (none here).
  if (r->>'return_location_id') is not null then
    raise exception 'HUNTUNI-FROMSPACE FAIL: a space-parked hunt invented return port %', r->>'return_location_id'; end if;
  -- consumed: terminal, coords cleared, exactly ONE live group-shaped fleet remains.
  select count(*) into n from public.fleets
   where id = v_gofleet and status = 'completed' and space_x is null and space_y is null;
  if n <> 1 then raise exception 'HUNTUNI-FROMSPACE FAIL: the consumed fleet is not terminal with cleared coords'; end if;
  select count(*) into n from public.fleets
   where group_id = gH and player_id = uH and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'HUNTUNI-FROMSPACE FAIL: % live group-shaped fleets after the from-space hunt', n; end if;
  -- and the ghost-dock class stays closed on this path too (a space fleet holds no presence).
  select count(*) into n from public.location_presence lp
    join public.fleets f on f.id = lp.fleet_id
   where f.player_id = uH and lp.status = 'active';
  if n <> 0 then raise exception 'HUNTUNI-FROMSPACE FAIL: % orphan active presence row(s) after the from-space consume', n; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = h1 and status = 'hunting' and spatial_state is null;
  if n <> 1 then raise exception 'HUNTUNI-FROMSPACE FAIL: the hunting write is missing on the from-space path'; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'HUNTUNI_PASS_FROMSPACE: a fleet parked in open space (via the real 0209 brake) hunts FROM its own coordinate — origin captured from the fleet, consumed fleet terminal, one live fleet';
end $$;

-- ════════ BLOCK STOP-SORTIE (0215, lit): THE BRAKE REFUSES AN OPEN SORTIE — BOTH PHASES ════════
-- The bricking class 0215 exists to kill: the brake resolves the group fleet by the exact shape a
-- hunt's sortie fleet has, so unguarded it cancels the encounter's leg and parks the fleet IDLE
-- with its manifest attached — idle is immortal (0047 collects only terminal fleets), the manifest
-- never clears, and every later guard answers the sortie reject forever. Two phases, because the
-- two failure shapes differ:
--   • IN FLIGHT (fleet 'moving'): unguarded, the brake CANCELS the sortie leg — the catastrophic
--     write. Pinned by reason + the leg still moving/unresolved + byte-diffs on fleets AND
--     group_sortie_members (the charter's lesson: diff the table the bug hides in).
--   • MID-COMBAT (fleet 'present' at its site, live encounter): unguarded, the brake answers the
--     idempotent not_moving skip (ok:true) — wrong POSTURE. A sortie is "refuse", never "nothing
--     to do" (0213's token+posture arm). Pinned by demanding the reject token itself.
-- HOW THIS FAILS IF THE CODE WERE WRONG / MUTATION (executed statically here; runtime needs CI's
-- disposable Postgres): strip the 0215 hunk → phase 1 cancels the leg (reason/diff pins red) and
-- phase 2 answers ok:true not_moving → red; the sh's body-scoped hunk grep and 0215's own
-- self-assert also red.
do $$
declare r jsonb; n int; v_flag jsonb; v_manifest_n int;
  uI uuid := (select v from fg where k='uI'); haven uuid := (select v from fg where k='haven');
  i1 uuid; gI uuid; v_hunt uuid; v_huntfleet uuid; v_huntmv uuid;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- live-RPC provisioning: i1 docked at haven → group → REAL lit hunt (the proven =0 docked arm).
  r := pg_temp.call_as(uI, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'STOP-SORTIE FAIL: commission i1: %', r; end if;
  select main_ship_id into i1 from public.main_ship_instances where player_id = uI;
  r := pg_temp.call_as(uI, 'public.upsert_ship_group(1, ''Brakemen'')');
  if (r->>'ok')::boolean is not true then raise exception 'STOP-SORTIE FAIL: group: %', r; end if;
  gI := (r->>'group_id')::uuid;
  -- S1-BERTH (0216): the fixture assign runs DARK (no first-assign mint) so the hunt below still
  -- launches through the head's =0 docked arm exactly as this block documents.
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';
  r := pg_temp.call_as(uI, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', i1, gI));
  if (r->>'ok')::boolean is not true then raise exception 'STOP-SORTIE FAIL: assign i1: %', r; end if;
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  select id into v_hunt from public.locations
   where status = 'active' and activity_type = 'hunt_pirates'
   order by coalesce(min_power_required, 0) asc limit 1;
  if v_hunt is null then raise exception 'STOP-SORTIE FAIL: no active hunt site — the fixture cannot be built'; end if;
  r := pg_temp.call_as(uI, format('public.send_ship_group_hunt(%L::uuid, %L::uuid)', gI, v_hunt));
  if (r->>'ok')::boolean is not true then raise exception 'STOP-SORTIE FAIL: lit hunt rejected: %', r; end if;
  v_huntfleet := (r->>'fleet_id')::uuid;
  v_huntmv    := (r->>'movement_id')::uuid;

  -- ── PHASE 1: IN FLIGHT. Vacuity: the sortie really is moving with a live manifest. ─────────────
  select count(*) into n from public.fleets where id = v_huntfleet and status = 'moving';
  if n <> 1 then raise exception 'STOP-SORTIE FAIL: the in-flight sortie state was not built (fleet not moving)'; end if;
  select count(*) into v_manifest_n from public.group_sortie_members where fleet_id = v_huntfleet;
  if v_manifest_n = 0 then raise exception 'STOP-SORTIE FAIL: the in-flight sortie state was not built (no manifest rows)'; end if;

  create temp table bs1_ships  as select * from public.main_ship_instances;
  create temp table bs1_fleets as select * from public.fleets;
  create temp table bs1_gsm    as select * from public.group_sortie_members;
  if (select count(*) from bs1_fleets) = 0 then
    raise exception 'STOP-SORTIE FAIL: the sortie snapshot is empty — the zero-write diff would be vacuous'; end if;

  r := pg_temp.call_as(uI, format('public.command_ship_group_stop(%L::uuid)', gI));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'group_on_sortie' then
    raise exception 'STOP-SORTIE FAIL: braking an IN-FLIGHT sortie answered % — the brake just cancelled a hunt leg and parked an immortal manifest-attached idle fleet', r; end if;
  -- the sortie leg is STILL moving and unresolved; nothing was cancelled.
  select count(*) into n from public.fleet_movements
   where id = v_huntmv and status = 'moving' and resolved_at is null;
  if n <> 1 then raise exception 'STOP-SORTIE FAIL: the sortie leg is no longer moving/unresolved after the rejected brake'; end if;
  select count(*) into n from public.fleet_movements where fleet_id = v_huntfleet and status = 'cancelled';
  if n <> 0 then raise exception 'STOP-SORTIE FAIL: % cancelled leg(s) on the sortie fleet after the rejected brake', n; end if;
  -- byte-diffs, both ways, on the tables the bug hides in — plus §2's own table.
  select count(*) into n from (
    (table bs1_ships except select * from public.main_ship_instances)
    union all (select * from public.main_ship_instances except table bs1_ships)) d;
  if n <> 0 then raise exception 'STOP-SORTIE FAIL: the rejected brake wrote % main_ship_instances row(s)', n; end if;
  select count(*) into n from (
    (table bs1_fleets except select * from public.fleets)
    union all (select * from public.fleets except table bs1_fleets)) d;
  if n <> 0 then raise exception 'STOP-SORTIE FAIL: the rejected brake wrote % fleets row(s)', n; end if;
  select count(*) into n from (
    (table bs1_gsm except select * from public.group_sortie_members)
    union all (select * from public.group_sortie_members except table bs1_gsm)) d;
  if n <> 0 then raise exception 'STOP-SORTIE FAIL: the rejected brake wrote % group_sortie_members row(s)', n; end if;
  if (select count(*) from public.group_sortie_members where fleet_id = v_huntfleet) <> v_manifest_n then
    raise exception 'STOP-SORTIE FAIL: the rejected brake changed the manifest row count'; end if;
  drop table bs1_ships; drop table bs1_fleets; drop table bs1_gsm;

  -- ── PHASE 2: MID-COMBAT. Settle the sortie at its site through the real cron entry point. ──────
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_huntmv;
  perform public.movement_settle_arrival(v_huntmv);
  -- vacuity: present AT the hunt site, live encounter, active presence, manifest still open.
  select count(*) into n from public.fleets
   where id = v_huntfleet and status = 'present' and current_location_id = v_hunt;
  if n <> 1 then raise exception 'STOP-SORTIE FAIL: the mid-combat brake state was not built (fleet not present at the hunt site)'; end if;
  select count(*) into n from public.combat_encounters where fleet_id = v_huntfleet and status = 'active';
  if n <> 1 then raise exception 'STOP-SORTIE FAIL: no live encounter under the brake probe — the mid-combat phase would be vacuous'; end if;
  select count(*) into n from public.location_presence
   where fleet_id = v_huntfleet and status = 'active' and location_id = v_hunt;
  if n <> 1 then raise exception 'STOP-SORTIE FAIL: the mid-combat brake state was not built (no active presence)'; end if;

  create temp table bs2_fleets as select * from public.fleets;
  create temp table bs2_gsm    as select * from public.group_sortie_members;
  r := pg_temp.call_as(uI, format('public.command_ship_group_stop(%L::uuid)', gI));
  if (r->>'ok')::boolean is not false or (r->>'reason') is distinct from 'group_on_sortie' then
    raise exception 'STOP-SORTIE FAIL: braking a MID-COMBAT sortie answered % — a sortie must be REFUSED, never idempotent-skipped (0213 posture)', r; end if;
  select count(*) into n from (
    (table bs2_fleets except select * from public.fleets)
    union all (select * from public.fleets except table bs2_fleets)) d;
  if n <> 0 then raise exception 'STOP-SORTIE FAIL: the mid-combat rejected brake wrote % fleets row(s)', n; end if;
  select count(*) into n from (
    (table bs2_gsm except select * from public.group_sortie_members)
    union all (select * from public.group_sortie_members except table bs2_gsm)) d;
  if n <> 0 then raise exception 'STOP-SORTIE FAIL: the mid-combat rejected brake wrote % group_sortie_members row(s)', n; end if;
  select count(*) into n from public.combat_encounters where fleet_id = v_huntfleet and status = 'active';
  if n <> 1 then raise exception 'STOP-SORTIE FAIL: the live encounter did not survive the rejected brake'; end if;
  drop table bs2_fleets; drop table bs2_gsm;

  -- hand the mid-combat world to DARKINERT + LIVESCOPE (the sortie persists deliberately).
  insert into fg values ('i1', i1), ('gI', gI), ('huntI', v_hunt), ('huntfleetI', v_huntfleet);
  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_STOP_REJECTS_SORTIE: lit brake vs an open sortie -> group_on_sortie in BOTH phases (moving: leg untouched; mid-combat: refused, not skipped); fleets + manifest byte-unchanged, encounter alive';
end $$;

-- ════════ BLOCK STOP-DARKINERT (0215, dark): THE HUNK SITS BEHIND THE 0209 GATE ════════
-- 0215 adds NO flag of its own: the 0209 head is in-body gated on fleet_movement_unified_enabled
-- BEFORE any read (0209:56), and the hunk sits strictly after that gate. A live sortie is REACHABLE
-- while dark (the legacy hunt, team_command_enabled, mints the same shape — the 0211 lesson), so
-- this pins that the dark brake answers the GATE, never the sortie read: dark = the head,
-- byte-identical by construction.
-- MUTATION (traced): move the guard above the gate → this answers group_on_sortie while dark → red
-- (0215's self-assert order chain also reds statically).
do $$
declare r jsonb; n int; v_flag jsonb;
  uI uuid := (select v from fg where k='uI'); gI uuid := (select v from fg where k='gI');
  v_huntfleet uuid := (select v from fg where k='huntfleetI');
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';

  -- vacuity: the LIVE sortie really exists while dark (the guard's own join shape).
  select count(*) into n
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.player_id = uI and f.group_id = gI
     and f.status in ('moving', 'present', 'returning');
  if n = 0 then raise exception 'STOP-DARKINERT FAIL: the dark sortie state was not built — the gate probe would be vacuous'; end if;

  create temp table bd_fleets as select * from public.fleets;
  r := pg_temp.call_as(uI, format('public.command_ship_group_stop(%L::uuid)', gI));
  if (r->>'reason') is distinct from 'unified_movement_disabled' then
    raise exception 'STOP-DARKINERT FAIL: dark brake over a live sortie answered % (group_on_sortie here means the hunk ran BEFORE the gate — the sortie read leaked into the dark world)', r; end if;
  select count(*) into n from (
    (table bd_fleets except select * from public.fleets)
    union all (select * from public.fleets except table bd_fleets)) d;
  if n <> 0 then raise exception 'STOP-DARKINERT FAIL: the dark brake wrote % fleets row(s)', n; end if;
  select count(*) into n from public.combat_encounters where fleet_id = v_huntfleet and status = 'active';
  if n <> 1 then raise exception 'STOP-DARKINERT FAIL: the live encounter did not survive the dark brake'; end if;
  drop table bd_fleets;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_STOP_DARKINERT: dark + live sortie -> unified_movement_disabled (the gate answers; the sortie read is never reached; zero writes)';
end $$;

-- ════════ BLOCK STOP-LIVESCOPE (0215, lit): A RETAINED DEAD MANIFEST MUST NOT BLOCK THE BRAKE ════
-- THE ANTI-OVERREACH HALF. A finished sortie's manifest is RETAINED up to 14d (0169's retention
-- decision; 0047 collects it only with its terminal fleet). A bare-EXISTS "fix" of the brake would
-- green REJECTS_SORTIE and then brick every post-hunt stop the group ever makes. So: finish the
-- sortie through the REAL chain (Retreat → escape tick → return settle → reconciler), prove the
-- manifest is retained on the completed fleet, then launch a NEW unified go and STOP it — the
-- brake MUST succeed, and the retained manifest must survive it untouched.
-- MUTATION (traced): widen the guard to a bare EXISTS (drop the live-status join) → the go's brake
-- below answers group_on_sortie → red (the sh's body-scoped live-status grep and 0215's
-- self-assert (c) also red statically).
do $$
declare r jsonb; n int; v_flag jsonb; v_manifest_n int;
  uI uuid := (select v from fg where k='uI'); gI uuid := (select v from fg where k='gI');
  i1 uuid := (select v from fg where k='i1'); v_huntfleet uuid := (select v from fg where k='huntfleetI');
  slag uuid := (select v from fg where k='slag');
  v_pres uuid; v_enc uuid; v_rmv uuid; v_gofleet uuid; v_gomv uuid;
  v_mid_x double precision; v_mid_y double precision;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- ── finish the sortie the way the PLAYER does: Retreat → escape → return → settle → reconcile.
  select id into v_pres from public.location_presence where fleet_id = v_huntfleet and status = 'active';
  select id into v_enc  from public.combat_encounters where fleet_id = v_huntfleet and status = 'active';
  if v_pres is null or v_enc is null then
    raise exception 'STOP-LIVESCOPE FAIL: no live sortie handed over — nothing to finish'; end if;
  -- ENVELOPE (verified at the true head — 0019:80, delegating to presence_request_leave, 0018):
  -- request_retreat RAISES on every failure and, for a COMBAT presence, succeeds with the BARE
  -- envelope {"return_movement_id": null} — NO 'ok' key, and the null is CORRECT: the combat
  -- branch only ARMS the retreat (presence 'retreating' + combat_set_retreating); the return
  -- movement is created LATER by process_combat_ticks once the delay elapses. Asserting {ok} here
  -- is the RPC-shape mistake the fixture-discipline note warns about — the first cut of this block
  -- did exactly that and CI reddened it on a SUCCESSFUL call. So: pin the key (and that its value
  -- is null — a non-null id here would mean the instant-leave 'none' branch ran, the WRONG branch),
  -- then assert the STATE the call must produce (the team-command-proof idiom).
  r := pg_temp.call_as(uI, format('public.request_retreat(%L::uuid)', v_pres));
  if not (r ? 'return_movement_id') then
    raise exception 'STOP-LIVESCOPE FAIL: request_retreat envelope drifted (no return_movement_id key): %', r; end if;
  if (r->>'return_movement_id') is not null then
    raise exception 'STOP-LIVESCOPE FAIL: request_retreat returned a movement id % mid-combat — the instant-leave branch ran instead of the retreat arm', r->>'return_movement_id'; end if;
  select count(*) into n from public.combat_encounters
   where id = v_enc and status = 'retreating' and retreat_started_at is not null;
  if n <> 1 then raise exception 'STOP-LIVESCOPE FAIL: request_retreat did not arm the encounter (retreating + retreat_started_at)'; end if;
  select count(*) into n from public.location_presence where id = v_pres and status = 'retreating';
  if n <> 1 then raise exception 'STOP-LIVESCOPE FAIL: request_retreat did not set the presence retreating'; end if;
  -- SURGERY (retreat-clock rewind, the COMBATPARITY idiom): now() is txn-constant, so no real
  -- retreat delay can elapse in this txn; rewind the clock instead of faking the end state.
  update public.combat_encounters
     set retreat_started_at = retreat_started_at - interval '1 minute',
         last_resolved_at   = last_resolved_at   - interval '1 minute'
   where id = v_enc;
  -- GLOBAL-TICK NOTE: process_combat_ticks (and process_mainship_expeditions below) sweep EVERY
  -- live row, so they also advance uC's and uE's deliberately-persisted encounters by one combat
  -- step. That is safe HERE and only here: this is the LAST proof block (nothing downstream reads
  -- uC/uE state), both encounters sit on fresh full-hp commission ships at danger≈1 (one step
  -- cannot defeat them, so no destructive branch can fire), and the team-command proof runs the
  -- same global ticks over concurrent worlds. If a block is ever added AFTER this one that asserts
  -- uC/uE encounter state, it must re-snapshot — do not inherit those worlds across this tick.
  perform public.process_combat_ticks();
  select count(*) into n from public.combat_encounters where id = v_enc and status = 'escaped';
  if n <> 1 then raise exception 'STOP-LIVESCOPE FAIL: the encounter did not settle escaped'; end if;
  select id into v_rmv from public.fleet_movements
   where fleet_id = v_huntfleet and mission_type = 'return_home' and status = 'moving';
  if v_rmv is null then raise exception 'STOP-LIVESCOPE FAIL: the escape did not mint a return leg'; end if;
  -- make the return DUE (both ends move — arrive_at > depart_at is CHECK-enforced) and settle it.
  update public.fleet_movements
     set depart_at = now() - interval '2 minutes', arrive_at = now() - interval '1 minute'
   where id = v_rmv;
  r := public.movement_settle_arrival(v_rmv);
  if (r->>'outcome') is distinct from 'completed' then
    raise exception 'STOP-LIVESCOPE FAIL: return settle answered %', r; end if;

  -- vacuity: the EXACT overreach shape — fleet completed, manifest RETAINED, zero live group fleets.
  select count(*) into n from public.fleets where id = v_huntfleet and status = 'completed';
  if n <> 1 then raise exception 'STOP-LIVESCOPE FAIL: the retained-manifest state was not built (sortie fleet not completed)'; end if;
  select count(*) into v_manifest_n from public.group_sortie_members where fleet_id = v_huntfleet;
  if v_manifest_n = 0 then raise exception 'STOP-LIVESCOPE FAIL: the retained-manifest state was not built (manifest gone — retention law drifted?)'; end if;
  select count(*) into n from public.fleets
   where group_id = gI and player_id = uI and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'STOP-LIVESCOPE FAIL: a live group-shaped fleet survived the completed sortie — the anti-overreach probe would be ambiguous'; end if;
  -- reconcile the member home (the real post-sortie world; the retained manifest must survive it).
  perform public.process_mainship_expeditions();
  if (select count(*) from public.group_sortie_members where fleet_id = v_huntfleet) <> v_manifest_n then
    raise exception 'STOP-LIVESCOPE FAIL: the reconciler deleted manifest rows (sole-writer law drifted)'; end if;

  -- ── ★ LIVESCOPE ★ a NEW unified go, then the brake — BOTH must clear the retained manifest. ────
  r := pg_temp.call_as(uI, format('public.command_ship_group_go(%L::uuid, %L::uuid)', gI, slag));
  if (r->>'ok')::boolean is not true then
    raise exception 'STOP-LIVESCOPE FAIL: a post-hunt unified go answered % — a RETAINED completed-sortie manifest is blocking the MOVER (its guard 8 lost its live scope?)', r; end if;
  v_gofleet := (r->>'fleet_id')::uuid;
  v_gomv    := (r->>'movement_id')::uuid;
  -- SURGERY (no ship row touched): backdate to pin t = exactly 0.5.
  update public.fleet_movements
     set depart_at = now() - interval '30 seconds', arrive_at = now() + interval '30 seconds'
   where id = v_gomv;
  select (origin_x + target_x) / 2, (origin_y + target_y) / 2 into v_mid_x, v_mid_y
    from public.fleet_movements where id = v_gomv;
  r := pg_temp.call_as(uI, format('public.command_ship_group_stop(%L::uuid)', gI));
  if (r->>'reason') is not distinct from 'group_on_sortie' then
    raise exception 'STOP-LIVESCOPE FAIL: a RETAINED completed-sortie manifest blocked the brake — the guard is not live-scoped (bare EXISTS bricks every post-hunt stop)'; end if;
  if (r->>'ok')::boolean is not true or (r->>'stopped')::boolean is not true then
    raise exception 'STOP-LIVESCOPE FAIL: the post-hunt brake answered %', r; end if;
  -- the brake really braked: leg cancelled, fleet holding at the exact midpoint.
  select count(*) into n from public.fleet_movements
   where id = v_gomv and status = 'cancelled' and resolved_at is not null;
  if n <> 1 then raise exception 'STOP-LIVESCOPE FAIL: the go leg was not cancelled+resolved'; end if;
  select count(*) into n from public.fleets
   where id = v_gofleet and status = 'idle' and location_mode = 'space'
     and space_x = v_mid_x and space_y = v_mid_y and active_movement_id is null;
  if n <> 1 then raise exception 'STOP-LIVESCOPE FAIL: the fleet is not holding at the interpolated midpoint'; end if;
  -- and the retained manifest survived the successful brake byte-for-byte (zero rows deleted).
  if (select count(*) from public.group_sortie_members where fleet_id = v_huntfleet) <> v_manifest_n then
    raise exception 'STOP-LIVESCOPE FAIL: the successful brake changed the retained manifest row count'; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'FLEETGO_PASS_STOP_SORTIE_LIVESCOPE: sortie finished through the real chain, manifest RETAINED on the completed fleet -> a NEW go and its brake BOTH succeed; the manifest survives untouched';
end $$;

-- ═════════════════════════════ S1 — THE BERTH MODEL (migration 0216) ═════════════════════════════
-- A ship is FLEETED xor BERTHED, as a SCHEMA FACT. Eight markers over uD/uJ/uK's worlds plus one
-- world-wide sweep. NOTE (the LIVESCOPE global-tick rule): these blocks run AFTER the global
-- combat/reconciler ticks and deliberately read NO uC/uE encounter state; the CROSSGROUP block
-- reads uD's deliberately-persisted open sortie and guards its own vacuity (one global combat step
-- cannot finish a full-hp low-danger encounter — the LIVESCOPE argument — and if that ever drifts
-- the vacuity guard raises rather than passing hollow).

-- ════════ BLOCK ASSIGN_CROSSGROUP_GUARDED (0216, lit — review MAJOR-1 + MINOR-5): the leave-guards
-- cannot be bypassed through a direct cross-group assign; a same-group re-assign is never blocked ══
-- THE SIDE DOOR: assign(S, G2) never used to inspect S's CURRENT group, so a ship bound to a
-- mid-sortie FROZEN MANIFEST in G1 could be assigned into an empty G2 — stepping off the manifest
-- (the exact state the unassign refusals forbid), resolving to nothing, going hidden, and minting
-- a stray fleet at its stale berth. One rule, one door now: cross-group movement = unassign first.
-- FAIL MODES: drop the must_unassign_first arm → the cross-group probe answers ok (the member
-- left the manifest's group) → red; drop the same-group short-circuit → the re-assign probe hits
-- the co-location arm with a NULL berth → group_fleet_elsewhere → red (the 0204 :294 promise).
do $$
declare r jsonb; n int; v_flag jsonb; v_manifest_n int; g2 uuid; d1 uuid;
  uD uuid := (select v from fg where k='uD'); gD uuid := (select v from fg where k='gD');
  v_huntfleet uuid := (select v from fg where k='huntfleetD');
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- vacuity: a gD member exists, it is ON the open manifest, and the sortie fleet is LIVE — the
  -- exact shape the side door would leak (a finished sortie would make both probes hollow).
  select main_ship_id into d1 from public.main_ship_instances where player_id = uD and group_id = gD;
  if d1 is null then raise exception 'ASSIGN_CROSSGROUP FAIL: gD has no member — the cross-group probe would be vacuous'; end if;
  select count(*) into n
    from public.group_sortie_members gsm
    join public.fleets f on f.id = gsm.fleet_id
   where gsm.main_ship_id = d1 and f.id = v_huntfleet
     and f.status in ('moving', 'present', 'returning');
  if n = 0 then raise exception 'ASSIGN_CROSSGROUP FAIL: the open-sortie state was not built (member off the live manifest)'; end if;
  select count(*) into v_manifest_n from public.group_sortie_members where fleet_id = v_huntfleet;

  r := pg_temp.call_as(uD, 'public.upsert_ship_group(2, ''Sidedoor'')');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGN_CROSSGROUP FAIL: group 2: %', r; end if;
  g2 := (r->>'group_id')::uuid;

  -- ── ★ the side door is CLOSED ★ mid-sortie member → empty group: refused, zero writes, no mint.
  create temp table cg_ships_before as select * from public.main_ship_instances;
  if (select count(*) from cg_ships_before) = 0 then
    raise exception 'ASSIGN_CROSSGROUP FAIL: empty before-snapshot — the zero-write diff would be vacuous'; end if;
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', d1, g2));
  if (r->>'reason') is distinct from 'must_unassign_first' then
    raise exception 'ASSIGN_CROSSGROUP FAIL: cross-group assign of a mid-sortie member answered % (ok here = the member stepped off the frozen manifest and went hidden)', r; end if;
  select count(*) into n from (
    (table cg_ships_before except select * from public.main_ship_instances)
    union all (select * from public.main_ship_instances except table cg_ships_before)) d;
  if n <> 0 then raise exception 'ASSIGN_CROSSGROUP FAIL: the refused cross-group assign wrote % ship row(s)', n; end if;
  select count(*) into n from public.fleets
   where group_id = g2 and player_id = uD and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'ASSIGN_CROSSGROUP FAIL: the refused assign minted % fleet(s) for the empty group', n; end if;

  -- ── ★ MINOR-5 ★ same-group re-assign of the SAME mid-sortie member: ok, zero writes (a member's
  --    berth is NULL — without the short-circuit this reads group_fleet_elsewhere).
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', d1, gD));
  if r is distinct from jsonb_build_object('ok', true, 'main_ship_id', d1, 'group_id', gD) then
    raise exception 'ASSIGN_CROSSGROUP FAIL: same-group re-assign answered % (the 0204 :294 never-blocked promise broke)', r; end if;
  select count(*) into n from (
    (table cg_ships_before except select * from public.main_ship_instances)
    union all (select * from public.main_ship_instances except table cg_ships_before)) d;
  if n <> 0 then raise exception 'ASSIGN_CROSSGROUP FAIL: the idempotent re-assign wrote % ship row(s)', n; end if;
  drop table cg_ships_before;

  -- the frozen manifest survived both probes byte-count-intact.
  if (select count(*) from public.group_sortie_members where fleet_id = v_huntfleet) <> v_manifest_n then
    raise exception 'ASSIGN_CROSSGROUP FAIL: a probe changed the manifest row count'; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'ASSIGN_CROSSGROUP_GUARDED: mid-sortie member -> must_unassign_first (no write, no mint, manifest intact); same-group re-assign -> ok with zero writes';
end $$;

-- ════════ BLOCK COMMISSION_BERTHED (0216): a new ship is BORN berthed at Haven, in BOTH creators ══
-- FAIL MODE: drop either creator's berth hunk → that INSERT lands group NULL + berth NULL → the XOR
-- CHECK raises at commission time (a raw error here), or — were the CHECK also dropped — the
-- explicit shape asserts below go red.
do $$
declare r jsonb; n int;
  uJ uuid := (select v from fg where k='uJ'); uK uuid := (select v from fg where k='uK');
  haven uuid := (select v from fg where k='haven'); j1 uuid;
  v_row public.main_ship_instances%rowtype;
begin
  -- creator 1: the port-entry commission chain (→ port_entry_commission_build).
  r := pg_temp.call_as(uJ, 'public.commission_first_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'COMMISSION_BERTHED FAIL: commission j1: %', r; end if;
  select main_ship_id into j1 from public.main_ship_instances where player_id = uJ;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = j1 and group_id is null and berth_location_id = haven;
  if n <> 1 then raise exception 'COMMISSION_BERTHED FAIL: build-creator ship is not born berthed at Haven (ungrouped)'; end if;

  -- creator 2: ensure_main_ship_for_player (the legacy bootstrap — service-role internal; the
  -- proof session is superuser). Its create branch needs a ZERO-ship player: uK.
  v_row := public.ensure_main_ship_for_player(uK);
  if v_row.group_id is not null or v_row.berth_location_id is distinct from haven then
    raise exception 'COMMISSION_BERTHED FAIL: ensure-creator ship is not born berthed at Haven (group %, berth %)', v_row.group_id, v_row.berth_location_id; end if;

  -- creator consistency, world-wide: after EVERY creator and mutator this proof has run, zero rows
  -- violate the XOR anywhere.
  select count(*) into n from public.main_ship_instances
   where (group_id is null) <> (berth_location_id is not null);
  if n <> 0 then raise exception 'COMMISSION_BERTHED FAIL: % ship row(s) violate the XOR world-wide', n; end if;

  insert into fg values ('j1', j1);
  raise notice 'COMMISSION_BERTHED: both creators birth berthed-at-Haven ungrouped ships; zero XOR violations world-wide';
end $$;

-- ════════ BLOCK BERTH_RESOLVER (0216): the map read answers place='berthed' — and ONLY when the ═══
-- resolver has no fleet ════════
-- Three phases on j1 + a contrast pin on uA's fleeted a1 (impersonation via call_as, the
-- reconcile/flip-proof idiom):
--   A) transition truth: j1's commission corpse is still 'present' → the resolver answers it →
--      place='docked' and the berthed branch stays QUIET (no double authority).
--   B) the post-4c shape (SURGERY: corpse completed + presence closed + the prod-majority legacy
--      'home' ship shape — deliberately NOT restored: the later berth blocks build on it) →
--      resolver NULL + berth set → place='berthed' at the berth.
--   C) DARK → the branch is gated → 'hidden' (the 0212 behavior; flag-exact rollback).
-- FAIL MODES: drop the 0216 hunk → phase B draws 'hidden' (the ship-tab blackout) → red; un-gate
-- it → phase C draws 'berthed' while dark → red; key it on something other than resolver-NULL →
-- phase A stops answering 'docked' → red.
do $$
declare r jsonb; e jsonb; n int; v_flag jsonb;
  uJ uuid := (select v from fg where k='uJ'); j1 uuid := (select v from fg where k='j1');
  uA uuid := (select v from fg where k='uA'); a1 uuid := (select v from fg where k='a1');
  haven uuid := (select v from fg where k='haven');
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- phase A: the corpse is live → docked, not berthed.
  select count(*) into n from public.fleets where main_ship_id = j1 and status = 'present';
  if n <> 1 then raise exception 'BERTH_RESOLVER FAIL: j1 has no present commission fleet — phase A would be vacuous'; end if;
  r := pg_temp.call_as(uJ, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = j1::text;
  if e is null or (e->>'place') is distinct from 'docked' or (e->>'location_id')::uuid is distinct from haven then
    raise exception 'BERTH_RESOLVER FAIL (phase A): a corpse-docked ship drew % — the berthed branch must yield to the resolver', e; end if;

  -- phase B SURGERY: the post-4c shape (the corpses die at 4c/4d; the backfill made berth carry
  -- their truth). CHECK-coupled columns move together: j1 stays ungrouped + berthed → XOR holds.
  perform public.presence_complete(lp.id)
    from public.location_presence lp
    join public.fleets f on f.id = lp.fleet_id
   where f.main_ship_id = j1 and lp.status = 'active';
  update public.fleets
     set status = 'completed', location_mode = 'movement', active_movement_id = null,
         current_base_id = null, current_location_id = null, current_zone_id = null, current_sector_id = null,
         updated_at = now()
   where main_ship_id = j1 and status = 'present';
  update public.main_ship_instances set status = 'home', spatial_state = null where main_ship_id = j1;
  if public.mainship_resolve_fleet(j1) is not null then
    raise exception 'BERTH_RESOLVER FAIL: j1 still resolves a fleet — phase B could be answered by the retired layer'; end if;
  r := pg_temp.call_as(uJ, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = j1::text;
  if e is null or (e->>'place') is distinct from 'berthed' or (e->>'location_id')::uuid is distinct from haven
     or (e->>'space_x') is not null or (e->'segment') is distinct from 'null'::jsonb then
    raise exception 'BERTH_RESOLVER FAIL (phase B): an unfleeted berthed ship drew % — hidden here is the ship-tab blackout', e; end if;

  -- contrast: a FLEETED ship reads its FLEET's place (uA's a1 — grouped, fleet present at haven
  -- after the COLOCATED settle), through the same call.
  select count(*) into n from public.fleets f
    join public.main_ship_instances s on s.group_id = f.group_id
   where s.main_ship_id = a1 and f.main_ship_id is null and f.status = 'present' and f.current_location_id = haven;
  if n <> 1 then raise exception 'BERTH_RESOLVER FAIL: uA''s fleet is not present at haven — the contrast pin would be vacuous'; end if;
  r := pg_temp.call_as(uA, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = a1::text;
  if e is null or (e->>'place') is distinct from 'docked' or (e->>'location_id')::uuid is distinct from haven then
    raise exception 'BERTH_RESOLVER FAIL (contrast): the FLEETED ship drew % — fleeted must read the fleet, never a berth', e; end if;

  -- phase C: dark → the branch is gated off → hidden (0212 byte-behavior; the rollback contract).
  update public.game_config set value='false'::jsonb where key='fleet_movement_unified_enabled';
  r := pg_temp.call_as(uJ, 'public.get_my_fleet_positions()');
  select t.elem into e from jsonb_array_elements(r) as t(elem) where t.elem->>'main_ship_id' = j1::text;
  if e is null or (e->>'place') is distinct from 'hidden' then
    raise exception 'BERTH_RESOLVER FAIL (phase C): dark drew % — the berthed branch leaked into the rolled-back world', e; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'BERTH_RESOLVER: berthed answers ONLY when the resolver has no fleet (corpse->docked, post-4c->berthed at the berth, fleeted->docked via the fleet, dark->hidden)';
end $$;

-- ════════ BLOCK ASSIGN_CLEARS_BERTH (0216): assign clears the berth; the FIRST assign into an ═════
-- EMPTY group MINTS the group fleet 'present' at the berth port ════════
-- FAIL MODES: drop HUNK E's berth clause → the assign lands group+berth both set → the XOR raises
-- (raw error); drop HUNK F → no fleet exists → the minted-fleet asserts and the oracle handoff
-- assert go red (j1 would be LOCATIONLESS: berth gone, no fleet); mint on non-empty groups too →
-- the second-assign single-fleet assert goes red.
do $$
declare r jsonb; n int; v_flag jsonb;
  uJ uuid := (select v from fg where k='uJ'); j1 uuid := (select v from fg where k='j1');
  haven uuid := (select v from fg where k='haven'); gJ uuid; j2 uuid; v_fleet uuid;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  r := pg_temp.call_as(uJ, 'public.upsert_ship_group(1, ''Berthmen'')');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGN_CLEARS_BERTH FAIL: group: %', r; end if;
  gJ := (r->>'group_id')::uuid;

  -- vacuity: j1 is the post-4c berthed shape (no fleets at all) — the mint's port can ONLY come
  -- from the berth.
  select count(*) into n from public.fleets
   where main_ship_id = j1 and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'ASSIGN_CLEARS_BERTH FAIL: j1 holds a live per-ship fleet — the mint port could come from the retired layer'; end if;

  -- ── the FIRST assign into the EMPTY group. ──
  r := pg_temp.call_as(uJ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', j1, gJ));
  if r is distinct from jsonb_build_object('ok', true, 'main_ship_id', j1, 'group_id', gJ) then
    raise exception 'ASSIGN_CLEARS_BERTH FAIL: first assign answered %', r; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = j1 and group_id = gJ and berth_location_id is null;
  if n <> 1 then raise exception 'ASSIGN_CLEARS_BERTH FAIL: the assign did not land FLEETED-no-berth (XOR shape)'; end if;
  -- the MINT: exactly ONE group-shaped fleet, 'present' at the berth port, with an active presence.
  select count(*) into n from public.fleets
   where group_id = gJ and player_id = uJ and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'ASSIGN_CLEARS_BERTH FAIL: expected the ONE minted group fleet, found % — an unminted empty-group first assign leaves the ship locationless', n; end if;
  select id into v_fleet from public.fleets
   where group_id = gJ and player_id = uJ and main_ship_id is null
     and status = 'present' and location_mode = 'location' and current_location_id = haven;
  if v_fleet is null then raise exception 'ASSIGN_CLEARS_BERTH FAIL: the minted fleet is not present at the BERTH port'; end if;
  select count(*) into n from public.location_presence
   where fleet_id = v_fleet and status = 'active' and location_id = haven;
  if n <> 1 then raise exception 'ASSIGN_CLEARS_BERTH FAIL: the minted fleet has no active presence at the berth port'; end if;
  -- the read HANDOFF is seamless: the oracle now answers the FLEET at the same port the berth
  -- answered a moment ago, and the map draws docked there.
  r := public.mainship_space_validate_context(j1);
  if (r->>'ok')::boolean is not true or (r->>'state') is distinct from 'at_location' then
    raise exception 'ASSIGN_CLEARS_BERTH FAIL: post-assign oracle answered % (the berth->fleet handoff broke)', r; end if;
  if public.mainship_resolve_docked_location(j1) is distinct from haven then
    raise exception 'ASSIGN_CLEARS_BERTH FAIL: post-assign dock resolver is not the berth port'; end if;

  -- ── the SECOND assign (j2, co-located) into the now NON-empty group: no second mint. ──
  r := pg_temp.call_as(uJ, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true then raise exception 'ASSIGN_CLEARS_BERTH FAIL: commission j2: %', r; end if;
  j2 := (r->>'main_ship_id')::uuid;
  r := pg_temp.call_as(uJ, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', j2, gJ));
  if (r->>'ok')::boolean is not true then
    raise exception 'ASSIGN_CLEARS_BERTH FAIL: co-located second assign rejected: %', r; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = j2 and group_id = gJ and berth_location_id is null;
  if n <> 1 then raise exception 'ASSIGN_CLEARS_BERTH FAIL: j2 did not land FLEETED-no-berth'; end if;
  select count(*) into n from public.fleets
   where group_id = gJ and player_id = uJ and main_ship_id is null
     and status in ('idle','moving','present','returning');
  if n <> 1 then raise exception 'ASSIGN_CLEARS_BERTH FAIL: % group fleets after the second assign — the mint must fire ONLY on the first-into-empty case', n; end if;

  insert into fg values ('gJ', gJ), ('j2', j2), ('fleetJ', v_fleet);
  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'ASSIGN_CLEARS_BERTH: assign lands fleeted-no-berth; the first-into-empty assign mints the ONE group fleet present at the berth port (presence + oracle handoff); no second mint';
end $$;

-- ════════ BLOCK UNASSIGN_BERTHS (0216): unassign from a DOCKED fleet berths at that port; from a ══
-- MOVING fleet it is refused with no write ════════
-- FAIL MODES: drop the unassign berth resolution → the unassign lands both-NULL → the XOR raises;
-- drop the in-flight refusal → the moving-phase probe answers ok and j1 "berths" mid-flight → red
-- on the reason + the zero-write diff.
do $$
declare r jsonb; n int; v_flag jsonb;
  uJ uuid := (select v from fg where k='uJ'); j1 uuid := (select v from fg where k='j1');
  j2 uuid := (select v from fg where k='j2'); gJ uuid := (select v from fg where k='gJ');
  v_fleet uuid := (select v from fg where k='fleetJ');
  haven uuid := (select v from fg where k='haven'); drift uuid := (select v from fg where k='drift');
  v_mv uuid;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- ── DOCKED: the fleet is present at haven → unassigning j2 BERTHS it there. ──
  select count(*) into n from public.fleets
   where id = v_fleet and status = 'present' and current_location_id = haven;
  if n <> 1 then raise exception 'UNASSIGN_BERTHS FAIL: the fleet is not docked at haven — the docked phase would be vacuous'; end if;
  r := pg_temp.call_as(uJ, format('public.assign_ship_to_group(%L::uuid, null)', j2));
  if (r->>'ok')::boolean is not true then
    raise exception 'UNASSIGN_BERTHS FAIL: unassign from a DOCKED fleet was rejected: %', r; end if;
  select count(*) into n from public.main_ship_instances
   where main_ship_id = j2 and group_id is null and berth_location_id = haven;
  if n <> 1 then raise exception 'UNASSIGN_BERTHS FAIL: j2 is not BERTHED at the fleet''s port after the unassign'; end if;

  -- ── MOVING: launch the fleet, then try to unassign j1 mid-flight → refused, zero writes. ──
  r := pg_temp.call_as(uJ, format('public.command_ship_group_go(%L::uuid, %L::uuid)', gJ, drift));
  if (r->>'ok')::boolean is not true then raise exception 'UNASSIGN_BERTHS FAIL: go: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  if (select status from public.fleets where id = v_fleet) is distinct from 'moving' then
    raise exception 'UNASSIGN_BERTHS FAIL: the fleet is not moving — the in-flight phase would be vacuous'; end if;
  create temp table ub_ships_before as select * from public.main_ship_instances;
  if (select count(*) from ub_ships_before) = 0 then
    raise exception 'UNASSIGN_BERTHS FAIL: empty before-snapshot — the zero-write diff would be vacuous'; end if;
  r := pg_temp.call_as(uJ, format('public.assign_ship_to_group(%L::uuid, null)', j1));
  if (r->>'reason') is distinct from 'fleet_in_flight' then
    raise exception 'UNASSIGN_BERTHS FAIL: unassign from a MOVING fleet answered % (ok here = a ship berthed in open space)', r; end if;
  select count(*) into n from (
    (table ub_ships_before except select * from public.main_ship_instances)
    union all (select * from public.main_ship_instances except table ub_ships_before)) d;
  if n <> 0 then raise exception 'UNASSIGN_BERTHS FAIL: the refused unassign wrote % ship row(s)', n; end if;
  drop table ub_ships_before;

  -- settle the leg at drift for the DELETE block (the fleet ends docked at drift with member j1).
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_mv;
  perform public.movement_settle_arrival(v_mv);
  select count(*) into n from public.fleets
   where id = v_fleet and status = 'present' and current_location_id = drift;
  if n <> 1 then raise exception 'UNASSIGN_BERTHS FAIL: the fleet did not settle at drift (handoff to DELETE_BERTHS broke)'; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'UNASSIGN_BERTHS: unassign from a docked fleet berths at that port; unassign from a moving fleet -> fleet_in_flight with zero ship writes';
end $$;

-- ════════ BLOCK DELETE_BERTHS (0216): delete berths the members at the group's docked port and ════
-- consumes the fleet; a flying fleet refuses the delete ════════
-- FAIL MODES: drop HUNK C (the member berth UPDATE) → the delete's FK SET NULL lands both-NULL →
-- the XOR raises (raw error, never a silent un-group); drop HUNK B's refusal arms → the flying
-- phase deletes a group under a live leg → red on the reason; drop the consume → an orphan live
-- group-shaped fleet + active presence survive with no group → the ghost-dock asserts go red.
do $$
declare r jsonb; n int; v_flag jsonb;
  uJ uuid := (select v from fg where k='uJ'); j1 uuid := (select v from fg where k='j1');
  gJ uuid := (select v from fg where k='gJ'); v_fleet uuid := (select v from fg where k='fleetJ');
  drift uuid := (select v from fg where k='drift'); haven uuid := (select v from fg where k='haven');
  v_mv uuid;
begin
  select value into v_flag from public.game_config where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';

  -- ── FLYING: a live leg refuses the delete, zero writes across ships/groups. ──
  r := pg_temp.call_as(uJ, format('public.command_ship_group_go(%L::uuid, %L::uuid)', gJ, haven));
  if (r->>'ok')::boolean is not true then raise exception 'DELETE_BERTHS FAIL: go for the flying phase: %', r; end if;
  v_mv := (r->>'movement_id')::uuid;
  if (select status from public.fleets where id = v_fleet) is distinct from 'moving' then
    raise exception 'DELETE_BERTHS FAIL: the fleet is not moving — the flying phase would be vacuous'; end if;
  create temp table db_ships_before as select * from public.main_ship_instances;
  r := pg_temp.call_as(uJ, format('public.delete_ship_group(%L::uuid)', gJ));
  if (r->>'reason') is distinct from 'fleet_in_flight' then
    raise exception 'DELETE_BERTHS FAIL: deleting a group with a FLYING fleet answered %', r; end if;
  select count(*) into n from (
    (table db_ships_before except select * from public.main_ship_instances)
    union all (select * from public.main_ship_instances except table db_ships_before)) d;
  if n <> 0 then raise exception 'DELETE_BERTHS FAIL: the refused delete wrote % ship row(s)', n; end if;
  drop table db_ships_before;
  select count(*) into n from public.ship_groups where group_id = gJ;
  if n <> 1 then raise exception 'DELETE_BERTHS FAIL: the refused delete removed the group'; end if;

  -- ── DOCKED: settle at haven, then delete → members berthed THERE, fleet consumed, group gone. ──
  update public.fleet_movements
     set depart_at = now() - interval '10 seconds', arrive_at = now() - interval '1 second'
   where id = v_mv;
  perform public.movement_settle_arrival(v_mv);
  select count(*) into n from public.fleets
   where id = v_fleet and status = 'present' and current_location_id = haven;
  if n <> 1 then raise exception 'DELETE_BERTHS FAIL: the fleet did not settle at haven — the docked phase would be vacuous'; end if;
  r := pg_temp.call_as(uJ, format('public.delete_ship_group(%L::uuid)', gJ));
  if (r->>'ok')::boolean is not true then raise exception 'DELETE_BERTHS FAIL: docked delete answered %', r; end if;
  -- the member is BERTHED at the port the fleet was docked at; the XOR holds; the ship survives.
  select count(*) into n from public.main_ship_instances
   where main_ship_id = j1 and group_id is null and berth_location_id = haven;
  if n <> 1 then raise exception 'DELETE_BERTHS FAIL: j1 is not berthed at the group''s docked port after the delete'; end if;
  select count(*) into n from public.ship_groups where group_id = gJ;
  if n <> 0 then raise exception 'DELETE_BERTHS FAIL: the group survived its delete'; end if;
  -- the fleet was CONSUMED: terminal, presence closed, nothing group-shaped left alive — a deleted
  -- group must not leave a ghost dock (§0's class).
  select count(*) into n from public.fleets where id = v_fleet and status = 'completed';
  if n <> 1 then raise exception 'DELETE_BERTHS FAIL: the group fleet was not consumed (terminal) by the delete'; end if;
  select count(*) into n from public.location_presence where fleet_id = v_fleet and status = 'active';
  if n <> 0 then raise exception 'DELETE_BERTHS FAIL: % active presence row(s) survive the deleted group — a ghost dock', n; end if;
  select count(*) into n from public.fleets
   where player_id = uJ and main_ship_id is null and group_id is not null
     and status in ('idle','moving','present','returning');
  if n <> 0 then raise exception 'DELETE_BERTHS FAIL: % live group-shaped fleet(s) survive after the delete', n; end if;
  -- and the ship's location survives the whole trip: the map now answers BERTHED at haven.
  r := pg_temp.call_as(uJ, 'public.get_my_fleet_positions()');
  select count(*) into n from jsonb_array_elements(r) as t(elem)
   where t.elem->>'main_ship_id' = j1::text and t.elem->>'place' = 'berthed'
     and (t.elem->>'location_id')::uuid = haven;
  if n <> 1 then raise exception 'DELETE_BERTHS FAIL: j1 does not read berthed at haven after the delete: %', r; end if;

  update public.game_config set value = v_flag where key='fleet_movement_unified_enabled';
  raise notice 'DELETE_BERTHS: flying fleet -> refused with zero writes; docked delete berths the members at the fleet''s port, consumes the fleet (no ghost dock), and the map reads berthed';
end $$;

-- ════════ BLOCK BERTH_XOR (0216): the CHECK rejects both-null and both-set; accepts both legal ════
-- shapes ════════
-- Direct column probes (deliberately NOT through the RPCs — the CHECK is the last line of defense
-- when some future writer forgets the pair). FAIL MODE: drop the CHECK → both probes "succeed" →
-- the not-raised branches raise loudly.
do $$
declare n int;
  j1 uuid := (select v from fg where k='j1'); g uuid := (select v from fg where k='g');
  haven uuid := (select v from fg where k='haven');
begin
  -- vacuity: both LEGAL shapes exist in the world right now (else "the CHECK accepts them" is vacuous).
  select count(*) into n from public.main_ship_instances where group_id is null and berth_location_id is not null;
  if n = 0 then raise exception 'BERTH_XOR FAIL: no berthed-no-group ship exists — the accept half is vacuous'; end if;
  select count(*) into n from public.main_ship_instances where group_id is not null and berth_location_id is null;
  if n = 0 then raise exception 'BERTH_XOR FAIL: no fleeted-no-berth ship exists — the accept half is vacuous'; end if;

  -- reject BOTH-NULL: strip j1's berth while ungrouped.
  begin
    update public.main_ship_instances set berth_location_id = null where main_ship_id = j1;
    raise exception 'BERTH_XOR FAIL: a both-NULL ship row was accepted — the ship has NO location and the XOR is decoration';
  exception when check_violation then null; end;

  -- reject BOTH-SET: give j1 a group (any FK-valid group) while it keeps its berth.
  begin
    update public.main_ship_instances set group_id = g where main_ship_id = j1;
    raise exception 'BERTH_XOR FAIL: a both-SET ship row was accepted — the ship is fleeted AND berthed at once';
  exception when check_violation then null; end;

  -- and the probes really were rejected: j1 is byte-unchanged (still berthed at haven, ungrouped).
  select count(*) into n from public.main_ship_instances
   where main_ship_id = j1 and group_id is null and berth_location_id = haven;
  if n <> 1 then raise exception 'BERTH_XOR FAIL: a rejected probe still mutated j1'; end if;

  raise notice 'BERTH_XOR: both-null and both-set REJECTED (check_violation); fleeted-no-berth and berthed-no-group both live in-world';
end $$;

-- ════════ BLOCK BERTH_BACKFILL (0216): every ungrouped ship in the WHOLE world ends berthed ═══════
-- HONESTY: the backfill DML itself ran at MIGRATION time — on prod over the REAL pre-flip ships
-- (its in-file assert RAISES the deploy if any ungrouped ship is left berthless); a fresh CI chain
-- has zero pre-existing ships, so that execution is vacuous HERE and cannot be re-staged (the XOR
-- admits no berthless-ungrouped fixture afterward, by design). What this block pins at runtime is
-- the INVARIANT the backfill exists to establish, over every ship every world in this proof
-- created, moved, assigned, unassigned, consumed, hunted, braked and deleted: ungrouped ⇒ berthed
-- (at a real port), grouped ⇒ berthless. The derivation shape (most-recent 'present' corpse port,
-- else Haven) is pinned statically by the selftest (fleetgo-proof.sh) and by 0216's own in-file
-- assert — stated plainly: the real-data run is TRACED here, executed only at the prod deploy.
do $$
declare n int; m int;
begin
  select count(*) into n from public.main_ship_instances where group_id is null;
  select count(*) into m from public.main_ship_instances where group_id is not null;
  if n = 0 or m = 0 then
    raise exception 'BERTH_BACKFILL FAIL: the world has % ungrouped / % grouped ships — the sweep would be vacuous', n, m; end if;
  select count(*) into n from public.main_ship_instances
   where group_id is null and berth_location_id is null;
  if n <> 0 then raise exception 'BERTH_BACKFILL FAIL: % ungrouped ship(s) berthless', n; end if;
  select count(*) into n from public.main_ship_instances s
   where s.group_id is null
     and not exists (select 1 from public.locations l where l.id = s.berth_location_id);
  if n <> 0 then raise exception 'BERTH_BACKFILL FAIL: % berth(s) point at no real port', n; end if;
  select count(*) into n from public.main_ship_instances
   where group_id is not null and berth_location_id is not null;
  if n <> 0 then raise exception 'BERTH_BACKFILL FAIL: % grouped ship(s) carry a berth', n; end if;
  raise notice 'BERTH_BACKFILL: world-wide after every mutation — ungrouped ⇒ berthed at a real port; grouped ⇒ berthless (the invariant the migration-time backfill establishes)';
end $$;

-- ════════ BLOCK TERRITORY_PASS_SEEDED (0217): the CASE seed landed on the decided radius map ══════
-- trade_outpost → 25, pirate_hunt/pirate_den → 35, safe_zone/rally_point → 15, every other type
-- NULL — asserted on the WHOLE world, plus named probes (slag, an ACTIVE hunt site) so a red is
-- actionable. VACUITY: each probed class must exist or the sweep greens while proving nothing.
-- FAIL MODE: drop the migration's CASE seed → slag reads NULL → the 25-probe raises.
do $$
declare n int;
  slag uuid := (select v from fg where k='slag');
begin
  -- vacuity guards: the probed rows exist.
  select count(*) into n from public.locations where id = slag and location_type = 'trade_outpost';
  if n <> 1 then raise exception 'TERRITORY_SEEDED FAIL: slag is not a trade_outpost row — the port probe would be vacuous'; end if;
  select count(*) into n from public.locations where location_type in ('pirate_hunt', 'pirate_den') and status = 'active';
  if n = 0 then raise exception 'TERRITORY_SEEDED FAIL: no ACTIVE hunt site exists — the hostile probe would be vacuous'; end if;
  select count(*) into n from public.locations where location_type = 'safe_zone';
  if n = 0 then raise exception 'TERRITORY_SEEDED FAIL: no safe_zone exists — the safe probe would be vacuous'; end if;

  -- named probes: the decided values, on real rows.
  select count(*) into n from public.locations where id = slag and territory_radius = 25;
  if n <> 1 then raise exception 'TERRITORY_SEEDED FAIL: slag''s (trade_outpost) territory_radius is not 25'; end if;
  select count(*) into n from public.locations
   where location_type in ('pirate_hunt', 'pirate_den') and status = 'active' and territory_radius is distinct from 35;
  if n <> 0 then raise exception 'TERRITORY_SEEDED FAIL: % ACTIVE hunt site(s) off territory_radius=35', n; end if;

  -- the world-wide sweep: every location on the map obeys the CASE map (25/35/15/NULL).
  select count(*) into n from public.locations
   where (location_type = 'trade_outpost' and territory_radius is distinct from 25)
      or (location_type in ('pirate_hunt', 'pirate_den') and territory_radius is distinct from 35)
      or (location_type in ('safe_zone', 'rally_point') and territory_radius is distinct from 15)
      or (location_type in ('mining_site', 'derelict_station', 'event_site') and territory_radius is not null);
  if n <> 0 then raise exception 'TERRITORY_PASS_SEEDED FAIL: % location(s) off the decided radius map', n; end if;

  raise notice 'TERRITORY_PASS_SEEDED: slag=25, every ACTIVE hunt site=35, world-wide sweep clean (trade 25 / hostile 35 / safe+rally 15 / else NULL)';
end $$;

-- ════════ BLOCK TERRITORY_PASS_MAPREAD (0217): get_world_map carries territory_radius, ADDITIVELY ═
-- Three pins: (1) STRUCTURAL — the DEPLOYED body still filters all three levels on status='active';
-- the 0175 hidden-port pin ran BEFORE the 0217 re-create on this chain, so it cannot vouch for the
-- new body — re-pin it here. (2) VALUE — slag's JSON element carries territory_radius = 25.
-- (3) NULL-KEY — a NULL-territory ACTIVE location still returns the KEY (json null), never a
-- conditionally-omitted field. SURGERY: the live seed has no NULL-territory ACTIVE location
-- (mining/derelict/event sites are unseeded), so pin 3 inserts ONE active mining_site fixture —
-- rolled back with the txn (the committed world is still written only by its declared owner).
do $$
declare n int; v_map jsonb; v_src text;
  slag uuid := (select v from fg where k='slag');
  v_fix uuid := gen_random_uuid();
begin
  -- (1) structural: the three status='active' filters survive in the DEPLOYED 0217 body.
  select prosrc into v_src from pg_proc where oid = to_regprocedure('public.get_world_map()')::oid;
  if v_src is null then raise exception 'TERRITORY_MAPREAD FAIL: public.get_world_map() does not exist'; end if;
  if position('l.zone_id = z.id and l.status = ''active''' in v_src) = 0
     or position('z.sector_id = se.id and z.status = ''active''' in v_src) = 0
     or position('se.status = ''active''' in v_src) = 0 then
    raise exception 'TERRITORY_MAPREAD FAIL: the deployed get_world_map lost a status=''active'' filter — hidden ports would leak';
  end if;

  -- (2) value: slag's location JSON carries the seeded 25. Vacuity: slag must be IN the read at all.
  v_map := public.get_world_map();
  select count(*) into n
    from jsonb_array_elements(v_map->'sectors') as se(sec),
         jsonb_array_elements(sec->'zones') as z(zn),
         jsonb_array_elements(zn->'locations') as l(lc)
   where lc->>'id' = slag::text;
  if n <> 1 then raise exception 'TERRITORY_MAPREAD FAIL: slag is not in get_world_map — the parity probe would be vacuous'; end if;
  select count(*) into n
    from jsonb_array_elements(v_map->'sectors') as se(sec),
         jsonb_array_elements(sec->'zones') as z(zn),
         jsonb_array_elements(zn->'locations') as l(lc)
   where lc->>'id' = slag::text and (lc ? 'territory_radius') and (lc->>'territory_radius')::numeric = 25;
  if n <> 1 then raise exception 'TERRITORY_MAPREAD FAIL: slag''s map JSON does not carry territory_radius=25'; end if;

  -- (3) NULL-KEY: an active NULL-territory location returns the key as json null (additive, never
  -- conditional). SURGERY: the fixture insert (see header) — reverted by the txn ROLLBACK.
  insert into public.locations (id, zone_id, name, location_type, x, y, activity_type, status)
  values (v_fix, (select zone_id from public.locations where id = slag),
          'Territory Null Probe', 'mining_site', 71, -11, 'none', 'active');
  v_map := public.get_world_map();
  select count(*) into n
    from jsonb_array_elements(v_map->'sectors') as se(sec),
         jsonb_array_elements(sec->'zones') as z(zn),
         jsonb_array_elements(zn->'locations') as l(lc)
   where lc->>'id' = v_fix::text;
  if n <> 1 then raise exception 'TERRITORY_MAPREAD FAIL: the mining_site fixture is not in get_world_map — the NULL-key probe would be vacuous'; end if;
  select count(*) into n
    from jsonb_array_elements(v_map->'sectors') as se(sec),
         jsonb_array_elements(sec->'zones') as z(zn),
         jsonb_array_elements(zn->'locations') as l(lc)
   where lc->>'id' = v_fix::text and (lc ? 'territory_radius') and jsonb_typeof(lc->'territory_radius') = 'null';
  if n <> 1 then raise exception 'TERRITORY_MAPREAD FAIL: the NULL-territory location does not return the territory_radius KEY as json null — the field went conditional'; end if;
  -- and additivity holds map-wide: EVERY location element carries the key.
  select count(*) into n
    from jsonb_array_elements(v_map->'sectors') as se(sec),
         jsonb_array_elements(sec->'zones') as z(zn),
         jsonb_array_elements(zn->'locations') as l(lc)
   where not (lc ? 'territory_radius');
  if n <> 0 then raise exception 'TERRITORY_MAPREAD FAIL: % map location(s) MISSING the territory_radius key — additive means every element', n; end if;

  raise notice 'TERRITORY_PASS_MAPREAD: three-level active filter re-pinned on the 0217 body; slag carries territory_radius=25; a NULL-territory location returns the key as json null; every map element carries the key';
end $$;

select 'FLEET-GO PROOF PASSED' as result;

rollback;
