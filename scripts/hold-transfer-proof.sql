-- ITEMS LIVE AT PORTS — disposable REAL-CHAIN proof (runs on the actual chain 0001..0333 in a
-- throwaway Supabase). Proves migration 0333: item volumes, the per-port `base_items` store where
-- items LIVE, the per-fleet `fleet_items` HOLD that carries them, the ONE docked-only transfer verb
-- between the two, and that every consuming command draws from the port you are standing in.
--
-- Fixture users carry the 'hx1.' email prefix. The ENTIRE proof runs inside ONE transaction that
-- ROLLBACKs — it persists NO player, ship, item, store, order, receipt or flag flip. No production
-- access. No COMMIT anywhere.
--
-- ── THE FOUR LAWS THIS FILE EXISTS TO PROVE ─────────────────────────────────────────────────────
--   1. Items are NOT unlimited — volume matters.        → HOLD_PASS_VOLUMES + HOLD_PASS_CAPACITY
--   2. Storage is PER-PORT.                             → HOLD_PASS_LAW3 (a) + HOLD_PASS_ISOLATION
--                                                          + HOLD_PASS_CRAFT_AT_PORT
--   3. You can reach a port's storage ONLY while DOCKED  → HOLD_PASS_LAW3 (a)(b)(c) — the one that
--      THERE. No remote retrieval, EVER.                  MUST be impossible, proved three ways,
--                                                          plus HOLD_PASS_CRAFT_AT_PORT for the
--                                                          three consuming commands
--   4. The player moves items between hold and storage. → HOLD_PASS_ROUNDTRIP + HOLD_PASS_ATOMIC
--
-- ── AND THE TWO THE MODEL ITSELF RESTS ON ───────────────────────────────────────────────────────
--   ITEMS LIVE AT PORTS. The hold is what a FLEET CARRIES, and it starts empty:
--        HOLD_PASS_ROUNDTRIP's precondition — the granted loot is in the PORT, not in the hold.
--   A DEPOSIT NEVER STRANDS; A SPEND REFUSES:            → HOLD_PASS_NEVER_STRAND
--   A HULL ORDER REMEMBERS THE PORT THAT PLACED IT:      → HOLD_PASS_HULL_REFUND
--
-- ── THE CROWN-JEWEL PROPERTY IS CONSERVATION ────────────────────────────────────────────────────
-- An item may never be duplicated and may never be lost. `pg_temp.total_of(player, item)` counts a
-- player's units of an item EVERYWHERE — every fleet hold they own plus every one of their per-port
-- stores — and every block asserts it is INVARIANT across the operation it performs, including
-- across a replay and across a cancelled build order. A transfer that wrote one side and not the
-- other, or that replayed into a double credit, breaks that number and this proof fails. RED BY
-- CONSTRUCTION: the totals are recomputed from the real tables after every call, never carried
-- forward from an expectation.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ───────────────────────
-- Every precondition this proof needs it SETS ITSELF, inside the rolled-back transaction — it never
-- asserts a seeded ambient default. station_storage_enabled is forced FALSE for the dark block and
-- TRUE afterwards; the movement/team flags are forced TRUE for the law-3 undock; the crafting and
-- shipyard flags are forced TRUE for the consuming-command blocks. The ROLLBACK reverts all of them.
-- Items are granted ONLY through the REAL secured-deposit pipeline leaf public.reward_grant
-- (0040 → inventory_deposit), never by a direct table insert; port stock is placed ONLY through
-- public.base_items_add (0333's sole writer), never by a direct base_items insert.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table hx1(k text primary key, v uuid) on commit preserve rows;
insert into hx1 values
  ('haven','b1a00001-0066-4a00-8a00-000000000001'),   -- starter port (commission dock)
  ('slag', 'b1a00002-0066-4a00-8a00-000000000002'),   -- the OTHER port — the remote-retrieval target
  ('drift','b1a00003-0066-4a00-8a00-000000000003');   -- a third port, for the undock destination

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- caller helper for a VOID rpc: set the subject then run the statement, returning nothing.
create or replace function pg_temp.act_as(p_sub uuid, p_stmt text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_stmt;
end $$;

-- ★ THE CONSERVATION ORACLE ★ — every unit of an item this player owns, ANYWHERE: every fleet hold
-- plus every per-port store they have. A transfer moves units between the two terms; it must never
-- change the sum. Recomputed from the live tables on every call.
create or replace function pg_temp.total_of(p_player uuid, p_item text) returns integer
language sql stable as $$
  select coalesce((select sum(fi.quantity)::integer from public.fleet_items fi
                     join public.fleets f on f.id = fi.fleet_id
                    where f.player_id = p_player and fi.item_id = p_item), 0)
       + coalesce((select sum(bi.quantity)::integer from public.base_items bi
                     join public.bases b on b.id = bi.base_id
                    where b.player_id = p_player and bi.item_id = p_item), 0);
$$;

-- How many units this player is CARRYING, across every fleet they own (the hold half of the total).
create or replace function pg_temp.held(p_player uuid, p_item text) returns integer
language sql stable as $$
  select coalesce((select sum(fi.quantity)::integer from public.fleet_items fi
                     join public.fleets f on f.id = fi.fleet_id
                    where f.player_id = p_player and fi.item_id = p_item), 0);
$$;

-- How many units of an item sit in ONE named port's store for this player (0 when no store yet).
create or replace function pg_temp.stored_at(p_player uuid, p_loc uuid, p_item text) returns integer
language sql stable as $$
  select coalesce((select bi.quantity from public.base_items bi
                     join public.bases b on b.id = bi.base_id
                    where b.player_id = p_player and b.location_id = p_loc and bi.item_id = p_item), 0);
$$;

-- arm a group so 0204's command-ship requirement does not mask the reason under test.
create or replace function pg_temp.arm_group(p_uid uuid, p_group uuid) returns void language plpgsql as $$
declare r jsonb; v_ship uuid;
begin
  if exists (select 1 from public.main_ship_instances where group_id = p_group and is_command_ship) then
    return;
  end if;
  select main_ship_id into v_ship from public.main_ship_instances where group_id = p_group order by main_ship_id limit 1;
  if v_ship is null then raise exception 'arm_group: group % has no member', p_group; end if;
  r := pg_temp.call_as(p_uid, format('public.set_fleet_command_ship(%L::uuid, true)', v_ship));
  if (r->>'ok')::boolean is not true then raise exception 'arm_group: set_fleet_command_ship rejected: %', r; end if;
end $$;

-- ════════ SETUP: mirror the production world a fresh disposable chain lacks (reverted by ROLLBACK) ════════
do $$
declare r jsonb; n int;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  select count(*) into n from public.locations
    where id in ((select v from hx1 where k='haven'), (select v from hx1 where k='slag'), (select v from hx1 where k='drift'))
      and status = 'active';
  if n <> 3 then raise exception 'SETUP FAIL: expected 3 active starter ports, got %', n; end if;
  -- all three must be STORABLE, or "per-port storage" has nowhere to live.
  if not (public.is_home_port_eligible((select v from hx1 where k='haven'))
          and public.is_home_port_eligible((select v from hx1 where k='slag'))) then
    raise exception 'SETUP FAIL: Haven/Slagworks are not both storable ports';
  end if;
  insert into public.game_config(key,value,description)
    values('mainship_space_movement_enabled','true'::jsonb,'hx1 transient (rolled back)')
    on conflict (key) do update set value='true'::jsonb;
end $$;

-- five fresh players: uA (the mover), uB (the foreign-owner probe), uD (the undocked world — it
-- launches a REAL fleet move, so it gets its own world and cannot poison uA's fixtures), uE (the
-- consuming commands: craft + hull order) and uF (the never-strand world).
do $$
declare u uuid; sk text;
begin
  foreach sk in array array['uA','uB','uD','uE','uF'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'hx1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into hx1 values (sk, u);
  end loop;
end $$;

insert into public.player_wallet (player_id, balance)
select v, 1000000 from hx1 where k in ('uA','uB','uD','uE','uF')
on conflict (player_id) do update set balance = excluded.balance;

-- ════════ PROVISION via the REAL commission RPC → each player docked at Haven ════════
-- Items arrive ONLY through the real reward pipeline (reward_grant → inventory_deposit, 0040/0039).
-- ★ THE MODEL, VISIBLE IN THE FIXTURE: every grant below passes a NULL base — loot with no port —
-- and every unit of it lands in the player's OLDEST ACTIVE BASE, i.e. IN A PORT. The hold starts
-- EMPTY, because the hold is what you pick up and carry, not where things live.
do $$
declare r jsonb; sk text; u uuid; uA uuid; uB uuid; uD uuid; haven uuid := (select v from hx1 where k='haven');
begin
  foreach sk in array array['uA','uB','uD','uE','uF'] loop
    u := (select v from hx1 where hx1.k = sk);
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL %: %', sk, r; end if;
    insert into hx1 select sk||'_ship', main_ship_id from public.main_ship_instances where player_id = u;
    insert into hx1 select sk||'_fleet', public.mainship_resolve_fleet(main_ship_id)
      from public.main_ship_instances where player_id = u;
  end loop;

  uA := (select v from hx1 where k='uA');
  uB := (select v from hx1 where k='uB');
  uD := (select v from hx1 where k='uD');

  -- uA gets 40 ore and NOTHING ELSE. At 2.0 m3 each that is 80 m3 of stock sitting in a port whose
  -- storage has no volume limit at all — a port is a place, not a hull. One item type only, so every
  -- m3 arithmetic in P2/P3/P6 below is exact and cannot be shifted by an unrelated stack.
  perform public.reward_grant('combat', gen_random_uuid(), uA, null,
    '{"items":[{"item_id":"ore","quantity":40}]}'::jsonb);
  perform public.reward_grant('combat', gen_random_uuid(), uB, null,
    '{"items":[{"item_id":"scrap","quantity":7}]}'::jsonb);
  perform public.reward_grant('combat', gen_random_uuid(), uD, null,
    '{"items":[{"item_id":"scrap","quantity":3}]}'::jsonb);

  -- ★ THE LOOT LANDED IN THE PORT, NOT IN THE HOLD. This single pair of assertions is the whole
  -- model correction: rev.2 of 0333 would have put all 40 into a player-wide hold.
  if pg_temp.stored_at(uA, haven, 'ore') <> 40 then
    raise exception 'PROVISION FAIL: uA''s loot did not land in Haven''s storage (stored=%)', pg_temp.stored_at(uA, haven, 'ore');
  end if;
  if pg_temp.held(uA,'ore') <> 0 then
    raise exception 'PROVISION FAIL: the hold is not empty — items must LIVE at ports, not be carried by default (held=%)', pg_temp.held(uA,'ore');
  end if;
  if (select count(*) from public.fleet_items) <> 0 then
    raise exception 'PROVISION FAIL: a fleet hold is non-empty before anybody loaded anything';
  end if;
  if pg_temp.total_of(uA,'ore') <> 40 then raise exception 'PROVISION FAIL: uA total ore %', pg_temp.total_of(uA,'ore'); end if;
  -- the null-base fallback resolved to the OLDEST ACTIVE base, and that base is the Haven store the
  -- ship is docked at — so the reads below are talking about the same row the game would use.
  if (select id from public.bases where player_id = uA and status='active' order by created_at, id limit 1)
     is distinct from public.get_or_create_store(uA, haven) then
    raise exception 'PROVISION FAIL: uA''s oldest active base is not the Haven store — the fixture would be testing two different places';
  end if;

  -- guard the guard: every ship must be the 50 m3 starter hull, or the capacity block is vacuous.
  if exists (select 1 from public.main_ship_instances where cargo_capacity_m3 <> 50) then
    raise exception 'PROVISION FAIL: a fixture ship is not the 50 m3 starter hull — the capacity block would be vacuous';
  end if;
  -- and the FLEET's capacity is the fold over its living ships — one 50 m3 hull here.
  if public.fleet_hold_capacity_m3((select v from hx1 where k='uA_fleet')) <> 50 then
    raise exception 'PROVISION FAIL: expected a 50 m3 fleet hold, got %',
      public.fleet_hold_capacity_m3((select v from hx1 where k='uA_fleet'));
  end if;
  if public.fleet_hold_used_m3((select v from hx1 where k='uA_fleet')) <> 0 then
    raise exception 'PROVISION FAIL: the fleet hold is not empty at 0 m3';
  end if;
  raise notice 'provisioned: uA(40 ore = 80 m3 LIVING in Haven''s storage, an EMPTY 50 m3 fleet hold), uB(7 scrap), uD(3 scrap), uE/uF, all docked at Haven';
end $$;

-- ════════ P0 — DARK gate: with station_storage_enabled OFF, the verb rejects and writes NOTHING. ════════
-- THE PRECONDITION IS STATED, NOT ASSUMED: this block forces the flag false itself rather than
-- trusting whatever the chain seeded (production has it TRUE; a fresh chain has it false; asserting
-- either would be asserting a WORLD, not a property).
update public.game_config set value='false'::jsonb where key='station_storage_enabled';
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  n int; v_tot int; v_stored int;
begin
  v_tot := pg_temp.total_of(uA,'ore');
  v_stored := (select count(*) from public.base_items);

  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'station_storage_disabled' then raise exception 'P0 FAIL dark to_storage: %', r; end if;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'station_storage_disabled' then raise exception 'P0 FAIL dark to_hold: %', r; end if;

  -- reject BEFORE any read: a nonexistent ship and a nonsense direction still answer the gate.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', gen_random_uuid(), 'sideways', 'nope', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'station_storage_disabled' then raise exception 'P0 FAIL gate is not first: %', r; end if;

  select count(*) into n from public.item_transfer_receipts;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % receipt(s)', n; end if;
  select count(*) into n from public.fleet_items;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % fleet_items row(s)', n; end if;
  if (select count(*) from public.base_items) <> v_stored then raise exception 'P0 FAIL dark path changed the port stores'; end if;
  if pg_temp.total_of(uA,'ore') <> v_tot then raise exception 'P0 FAIL dark path moved items'; end if;

  update public.game_config set value='true'::jsonb where key='station_storage_enabled';
  raise notice 'HOLD_PASS_DARK_GATE ok: both directions rejected station_storage_disabled before any read; zero receipts, zero fleet_items, zero item movement';
end $$;

-- ════════ P1 — VOLUMES: law 1 made unrepresentable-otherwise. ════════
do $$
declare n int; v_ore numeric; v_cap numeric;
begin
  -- not one catalog row is volumeless or weightless.
  select count(*) into n from public.item_types where volume_m3 is null or volume_m3 <= 0;
  if n <> 0 then raise exception 'P1 FAIL: % item type(s) carry no positive volume', n; end if;
  select count(*) into n from public.item_types;
  if n < 13 then raise exception 'P1 FAIL: expected at least 13 item types, got %', n; end if;

  -- the OWNER-SET five, pinned exactly as he gave them.
  if (select volume_m3 from public.item_types where item_id='ore')          <> 2.0
     or (select volume_m3 from public.item_types where item_id='crystal')      <> 1.0
     or (select volume_m3 from public.item_types where item_id='scrap')        <> 0.5
     or (select volume_m3 from public.item_types where item_id='weapon_parts') <> 0.2
     or (select volume_m3 from public.item_types where item_id='pirate_alloy') <> 0.5 then
    raise exception 'P1 FAIL: an owner-set volume drifted';
  end if;

  -- the scale MEANS something against the hull it is measured in: a 50 m3 starter hold takes
  -- exactly 25 ore, 100 scrap, 250 weapon_parts. Derived from the live rows, never hard-coded.
  select volume_m3 into v_ore from public.item_types where item_id='ore';
  select min(cargo_capacity_m3) into v_cap from public.main_ship_instances;
  if floor(v_cap / v_ore) <> 25 then raise exception 'P1 FAIL: a starter hull holds % ore, expected 25', floor(v_cap / v_ore); end if;
  if floor(v_cap / (select volume_m3 from public.item_types where item_id='scrap')) <> 100 then
    raise exception 'P1 FAIL: a starter hull holds % scrap, expected 100', floor(v_cap / (select volume_m3 from public.item_types where item_id='scrap')); end if;

  -- a zero-volume item — the "infinite items" loophole — is REJECTED by the deployed constraint,
  -- evaluated, not re-typed.
  begin
    insert into public.item_types (item_id, name, category, volume_m3) values ('_hx1_probe_','probe','material',0);
    raise exception 'P1 FAIL: the deployed CHECK accepted a zero-volume item type';
  exception when check_violation then null;
  end;

  raise notice 'HOLD_PASS_VOLUMES ok: every item type has a positive volume; the owner-set five pinned; a 50 m3 hull holds exactly 25 ore / 100 scrap; a zero-volume item is refused by the live constraint';
end $$;

-- ════════ P2 — ROUND TRIP: this port's storage → the fleet's hold → back, EXACT deltas + CONSERVATION. ════════
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  v_fleet uuid := (select v from hx1 where k='uA_fleet');
  haven uuid := (select v from hx1 where k='haven'); v_req uuid := gen_random_uuid();
  t0 int; h0 int; s0 int; n int;
begin
  t0 := pg_temp.total_of(uA,'ore');
  h0 := pg_temp.held(uA,'ore');
  s0 := pg_temp.stored_at(uA, haven, 'ore');
  if t0 <> 40 or h0 <> 0 or s0 <> 40 then raise exception 'P2 FAIL precondition: total=% held=% stored=%', t0, h0, s0; end if;

  -- LOAD 25 ore (50 m3 — EXACTLY the hull). The boundary case: it must FIT, not be refused.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 25, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P2 FAIL load exactly-fits: %', r; end if;
  if (r->>'qty')::int <> 25 or (r->>'direction') is distinct from 'to_hold' then raise exception 'P2 FAIL load envelope: %', r; end if;
  if (r->>'volume_m3')::numeric <> 50 then raise exception 'P2 FAIL moved volume % (want 50)', (r->>'volume_m3')::numeric; end if;
  if (r->>'location_id')::uuid is distinct from haven then raise exception 'P2 FAIL load location: %', r; end if;
  -- the envelope reports the hold AFTER the move: a 50 m3 load into a 50 m3 hull leaves it full.
  if (r->>'hold_used_m3')::numeric <> 50 or (r->>'hold_capacity_m3')::numeric <> 50 then
    raise exception 'P2 FAIL load envelope numbers: %', r; end if;

  -- EXACT deltas, read from the real tables.
  if pg_temp.held(uA,'ore') <> 25 then raise exception 'P2 FAIL hold after load: %', pg_temp.held(uA,'ore'); end if;
  if pg_temp.stored_at(uA, haven, 'ore') <> 15 then raise exception 'P2 FAIL storage after load: %', pg_temp.stored_at(uA, haven, 'ore'); end if;
  if public.fleet_hold_used_m3(v_fleet) <> 50 then raise exception 'P2 FAIL fleet hold occupancy: %', public.fleet_hold_used_m3(v_fleet); end if;
  -- ★ CONSERVATION ★
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P2 FAIL conservation on load: % -> %', t0, pg_temp.total_of(uA,'ore'); end if;

  -- exactly ONE receipt, with the exact fields, on the right ship, the right fleet and the right port.
  select count(*) into n from public.item_transfer_receipts where main_ship_id = v_ship;
  if n <> 1 then raise exception 'P2 FAIL % receipts after one move', n; end if;
  if not exists (select 1 from public.item_transfer_receipts
                  where main_ship_id=v_ship and request_id=v_req and direction='to_hold'
                    and item_id='ore' and qty=25 and volume_m3=50 and location_id=haven and fleet_id=v_fleet) then
    raise exception 'P2 FAIL receipt fields wrong';
  end if;

  -- UNLOAD 5 back into the port — the direction that puts items back where they LIVE.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 5, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P2 FAIL unload: %', r; end if;
  if pg_temp.held(uA,'ore') <> 20 then raise exception 'P2 FAIL hold after unload: %', pg_temp.held(uA,'ore'); end if;
  if pg_temp.stored_at(uA, haven, 'ore') <> 20 then raise exception 'P2 FAIL storage after unload: %', pg_temp.stored_at(uA, haven, 'ore'); end if;
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P2 FAIL conservation on unload: % -> %', t0, pg_temp.total_of(uA,'ore'); end if;

  -- and back to a full hold for the capacity block below.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 5, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P2 FAIL reload: %', r; end if;
  if pg_temp.held(uA,'ore') <> 25 or pg_temp.stored_at(uA, haven, 'ore') <> 15 then
    raise exception 'P2 FAIL reload deltas: held=% stored=%', pg_temp.held(uA,'ore'), pg_temp.stored_at(uA, haven, 'ore'); end if;

  insert into hx1 values ('loadreq', v_req);
  raise notice 'HOLD_PASS_ROUNDTRIP ok: 25 ore Haven storage->fleet hold (50 m3, the exactly-fits boundary, exact deltas, one receipt carrying the fleet) and 5 back; total conserved at % throughout', t0;
end $$;

-- ════════ P3 — CAPACITY: REFUSED, never clamped; the boundary is exact. ════════
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  haven uuid := (select v from hx1 where k='haven'); t0 int; h0 int; s0 int; nrec int;
begin
  t0 := pg_temp.total_of(uA,'ore');
  h0 := pg_temp.held(uA,'ore');                          -- 25 ore = 50 m3, the hull is FULL of ore
  s0 := pg_temp.stored_at(uA, haven, 'ore');             -- 15 left in the port
  select count(*) into nrec from public.item_transfer_receipts where main_ship_id=v_ship;
  if h0 <> 25 or s0 <> 15 then raise exception 'P3 FAIL precondition: held=% stored=%', h0, s0; end if;

  -- ONE more unit does not fit: 50 + 2 > 50.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'hold_over_capacity' then raise exception 'P3 FAIL one-more-unit not refused: %', r; end if;
  -- the envelope carries the NUMBERS — a cap the player cannot see is a trap.
  if (r->>'hold_used_m3')::numeric <> 50 or (r->>'hold_capacity_m3')::numeric <> 50
     or (r->>'delta_m3')::numeric <> 2 or (r->>'hold_free_m3')::numeric <> 0 then
    raise exception 'P3 FAIL over-capacity envelope is not self-explaining: %', r; end if;

  -- ★ REFUSED, NOT CLAMPED ★ — nothing moved at all, not even the part that would have fit.
  if pg_temp.held(uA,'ore') <> h0 then raise exception 'P3 FAIL the refusal moved the hold (clamped!)'; end if;
  if pg_temp.stored_at(uA, haven, 'ore') <> s0 then raise exception 'P3 FAIL the refusal moved the storage (clamped!)'; end if;
  if (select count(*) from public.item_transfer_receipts where main_ship_id=v_ship) <> nrec then
    raise exception 'P3 FAIL the refusal wrote a receipt'; end if;
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P3 FAIL conservation broken by a refusal'; end if;

  -- asking for ALL 15 remaining (30 m3 on a full hull) is refused the same way — a partial move is
  -- never substituted for the request.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 15, gen_random_uuid()));
  if (r->>'reason') is distinct from 'hold_over_capacity' then raise exception 'P3 FAIL bulk not refused: %', r; end if;
  if pg_temp.held(uA,'ore') <> h0 or pg_temp.stored_at(uA, haven, 'ore') <> s0 then
    raise exception 'P3 FAIL bulk refusal moved something'; end if;

  -- UNLOADING still works with a full hold — the way out is always open.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 5, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P3 FAIL unload from a full hold: %', r; end if;
  if pg_temp.held(uA,'ore') <> 20 or pg_temp.stored_at(uA, haven, 'ore') <> 20 then
    raise exception 'P3 FAIL unload deltas: held=% stored=%', pg_temp.held(uA,'ore'), pg_temp.stored_at(uA, haven, 'ore'); end if;

  -- and now exactly 5 fit again (40 m3 used + 10 m3 = 50) — the boundary is exact in both directions.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 5, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P3 FAIL the freed room was not usable: %', r; end if;
  if pg_temp.held(uA,'ore') <> 25 then raise exception 'P3 FAIL refill deltas'; end if;
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P3 FAIL conservation across the capacity block'; end if;

  raise notice 'HOLD_PASS_CAPACITY ok: over-capacity REFUSED with used/capacity/delta/free in the envelope and ZERO movement (never clamped); unloading a full hold always works; the 50 m3 boundary is exact in both directions; total conserved at %', t0;
end $$;

-- ════════ P4 — LAW 3: a port's storage is unreachable unless you are DOCKED THERE. ════════
-- Proved THREE independent ways, because this is the one that must be impossible.
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  uD uuid := (select v from hx1 where k='uD'); v_shipD uuid := (select v from hx1 where k='uD_ship');
  haven uuid := (select v from hx1 where k='haven'); slag uuid := (select v from hx1 where k='slag');
  drift uuid := (select v from hx1 where k='drift');
  v_slagstore uuid; g uuid; t0 int; n int; v_args text; v_fname text;
begin
  -- ── (a) REMOTE RETRIEVAL. uA is docked at HAVEN and has scrap stored at SLAGWORKS. ──────────────
  -- The Slagworks stock is placed through 0333's OWN sole writer (base_items_add), so the fixture
  -- is a state the game itself can produce.
  v_slagstore := public.get_or_create_store(uA, slag);
  perform public.base_items_add(v_slagstore, 'scrap', 9);
  if pg_temp.stored_at(uA, slag, 'scrap') <> 9 then raise exception 'P4 FAIL fixture: Slagworks stock not placed'; end if;
  if pg_temp.stored_at(uA, haven, 'scrap') <> 0 then raise exception 'P4 FAIL fixture: Haven already holds scrap'; end if;
  t0 := pg_temp.total_of(uA,'scrap');

  -- Docked at Haven, uA asks for scrap. Haven's store has none; the Slagworks pile is UNREACHABLE.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'scrap', 9, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_stored' then raise exception 'P4(a) FAIL remote retrieval was not refused: %', r; end if;
  if (r->>'have')::int <> 0 then raise exception 'P4(a) FAIL the reject read a store that is not this port: %', r; end if;
  if (r->>'location_id')::uuid is distinct from haven then raise exception 'P4(a) FAIL the reject named the wrong port: %', r; end if;
  -- the remote pile is BYTE-UNCHANGED and the total never moved.
  if pg_temp.stored_at(uA, slag, 'scrap') <> 9 then raise exception 'P4(a) FAIL the remote port''s stock was touched'; end if;
  if pg_temp.total_of(uA,'scrap') <> t0 then raise exception 'P4(a) FAIL conservation'; end if;

  -- ── (b) UNEXPRESSABLE BY CONSTRUCTION. The verb takes no port argument at all, so there is no
  --        request a client could send that names another port. This is stronger than a check.
  select pg_get_function_identity_arguments(p.oid) into v_args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='transfer_items';
  if v_args is null then raise exception 'P4(b) FAIL: transfer_items is absent'; end if;
  if v_args ilike '%location%' or v_args ilike '%base%' or v_args ilike '%store%' or v_args ilike '%port%' then
    raise exception 'P4(b) FAIL: transfer_items can be told WHICH port (%) — law 3 must be unexpressable', v_args;
  end if;
  -- and it resolves the dock through the ONE shared resolver rather than any local read.
  if position('mainship_resolve_docked_location(' in
       (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='transfer_items')) = 0 then
    raise exception 'P4(b) FAIL: transfer_items does not resolve the dock through the one shared resolver';
  end if;
  -- ...and the SAME is true of every CONSUMING command. They gained a SHIP, never a port: the port
  -- is derived from that ship's own dock, so remote crafting is equally unexpressable.
  foreach v_fname in array array['craft_module','recruit_captain','start_hull_build'] loop
    select pg_get_function_identity_arguments(p.oid) into v_args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.proname=v_fname;
    if v_args is null then raise exception 'P4(b) FAIL: public.% is absent', v_fname; end if;
    if v_args not like '%p_main_ship_id uuid%' then
      raise exception 'P4(b) FAIL: public.% did not gain the ship (%)', v_fname, v_args; end if;
    if v_args ilike '%location%' or v_args ilike '%base%' or v_args ilike '%store%' or v_args ilike '%port%' then
      raise exception 'P4(b) FAIL: public.% can be told WHICH port (%) — law 3 must be unexpressable', v_fname, v_args; end if;
    if position('mainship_resolve_docked_location(' in
         (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname=v_fname)) = 0 then
      raise exception 'P4(b) FAIL: public.% does not derive its port from the one shared resolver', v_fname; end if;
  end loop;

  -- ── (c) NOT DOCKED AT ALL. uD leaves Haven for Driftmarch through the REAL unified mover. ───────
  -- Every precondition the mover needs is STATED here, never inherited from the chain's seed.
  update public.game_config set value='true'::jsonb where key='team_command_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_movement_unified_enabled';
  update public.game_config set value='true'::jsonb where key='fleet_control_enabled';
  r := pg_temp.call_as(uD, 'public.upsert_ship_group(1, ''Runner'')');
  if (r->>'ok')::boolean is not true then raise exception 'P4(c) FAIL group: %', r; end if;
  g := (r->>'group_id')::uuid;
  r := pg_temp.call_as(uD, format('public.assign_ship_to_group(%L::uuid, %L::uuid)', v_shipD, g));
  if (r->>'ok')::boolean is not true then raise exception 'P4(c) FAIL assign: %', r; end if;
  perform pg_temp.arm_group(uD, g);
  r := pg_temp.call_as(uD, format('public.command_ship_group_go(%L::uuid, %L::uuid)', g, drift));
  if (r->>'ok')::boolean is not true then raise exception 'P4(c) FAIL go: %', r; end if;
  -- the mover really did undock it (the shared resolver is the oracle, not a status guess).
  if public.mainship_resolve_docked_location(v_shipD) is not null then
    raise exception 'P4(c) FAIL fixture: the ship is still docked after the go — the test would be vacuous';
  end if;

  select count(*) into n from public.item_transfer_receipts;
  r := pg_temp.call_as(uD, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_shipD, 'to_storage', 'scrap', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'not_docked' then raise exception 'P4(c) FAIL in-transit deposit not refused: %', r; end if;
  r := pg_temp.call_as(uD, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_shipD, 'to_hold', 'scrap', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'not_docked' then raise exception 'P4(c) FAIL in-transit withdrawal not refused: %', r; end if;
  if pg_temp.stored_at(uD, haven, 'scrap') <> 3 then raise exception 'P4(c) FAIL a refused move touched the port store'; end if;
  if pg_temp.held(uD,'scrap') <> 0 then raise exception 'P4(c) FAIL a refused move touched the hold'; end if;
  if (select count(*) from public.item_transfer_receipts) <> n then raise exception 'P4(c) FAIL a refused move wrote a receipt'; end if;

  raise notice 'HOLD_PASS_LAW3 ok: (a) a port you are not docked at is unreachable — Slagworks'' 9 scrap untouched while docked at Haven, the reject read HAVEN''s store (have=0); (b) NEITHER the transfer verb NOR any of the three consuming commands takes a port/store argument, so remote retrieval is unexpressable, and all four derive the dock through the one shared resolver; (c) a ship in transit is refused not_docked in BOTH directions with zero writes';
end $$;

-- ════════ P5 — ISOLATION: another player's ship, hold and storage are untouchable. ════════
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); uB uuid := (select v from hx1 where k='uB');
  v_shipA uuid := (select v from hx1 where k='uA_ship'); v_shipB uuid := (select v from hx1 where k='uB_ship');
  haven uuid := (select v from hx1 where k='haven'); v_storeB uuid; tB int; n int;
begin
  -- top uB's Haven pile up so "untouched" is a meaningful claim, not a vacuous one.
  v_storeB := public.get_or_create_store(uB, haven);
  perform public.base_items_add(v_storeB, 'scrap', 7);
  tB := pg_temp.total_of(uB,'scrap');
  if tB <> 14 then raise exception 'P5 FAIL fixture: uB total scrap % (want the granted 7 + the placed 7)', tB; end if;
  select count(*) into n from public.item_transfer_receipts;

  -- uA drives uB's ship id: ownership is asserted server-side, so it fails closed as ship_not_found.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_shipB, 'to_hold', 'scrap', 7, gen_random_uuid()));
  if (r->>'reason') is distinct from 'ship_not_found' then raise exception 'P5 FAIL cross-player ship not rejected: %', r; end if;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_shipB, 'to_storage', 'scrap', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'ship_not_found' then raise exception 'P5 FAIL cross-player deposit not rejected: %', r; end if;

  -- uA acting on its OWN ship at the SAME port still cannot see uB's pile: the store is resolved
  -- from (auth.uid(), the dock), so uB's 14 scrap at Haven is invisible to uA.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_shipA, 'to_hold', 'scrap', 7, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_stored' or (r->>'have')::int <> 0 then
    raise exception 'P5 FAIL uA could see uB''s pile at the shared port: %', r; end if;

  -- and the LEAVES refuse a cross-player store outright — a store belongs to exactly one player.
  begin
    perform public.inventory_spend(uA, v_storeB, 'scrap', 1);
    raise exception 'P5 FAIL inventory_spend drew from another player''s store';
  exception when raise_exception then
    if position('does not belong to player' in sqlerrm) = 0 then
      raise exception 'P5 FAIL cross-player spend refused for the wrong reason: %', sqlerrm; end if;
  end;

  -- nothing of uB's moved, and no receipt was minted on uB's ship.
  if pg_temp.total_of(uB,'scrap') <> tB then raise exception 'P5 FAIL uB''s total changed: % -> %', tB, pg_temp.total_of(uB,'scrap'); end if;
  if pg_temp.held(uB,'scrap') <> 0 or pg_temp.stored_at(uB, haven, 'scrap') <> 14 then
    raise exception 'P5 FAIL uB''s hold/storage split changed'; end if;
  if (select count(*) from public.item_transfer_receipts) <> n then raise exception 'P5 FAIL a cross-player attempt wrote a receipt'; end if;
  if exists (select 1 from public.item_transfer_receipts where main_ship_id = v_shipB) then
    raise exception 'P5 FAIL a receipt exists on uB''s ship'; end if;

  raise notice 'HOLD_PASS_ISOLATION ok: another player''s ship id fails closed as ship_not_found in both directions; two players sharing one port keep separate stores (uA sees have=0 beside uB''s 14); the spend leaf refuses another player''s store outright; uB''s 14 units and zero receipts unchanged';
end $$;

-- ════════ P6 — ATOMIC UNDER REPLAY: nothing duplicated, nothing lost, in either direction. ════════
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  haven uuid := (select v from hx1 where k='haven'); v_req uuid := (select v from hx1 where k='loadreq');
  v_req2 uuid := gen_random_uuid();
  t0 int; h0 int; s0 int; nrec int; nled int;
begin
  t0 := pg_temp.total_of(uA,'ore');
  h0 := pg_temp.held(uA,'ore');
  s0 := pg_temp.stored_at(uA, haven, 'ore');
  select count(*) into nrec from public.item_transfer_receipts where main_ship_id=v_ship;
  select count(*) into nled from public.inventory_ledger where player_id=uA;

  -- (i) replay the ORIGINAL to_hold move (P2's 25-ore load, same ship + request_id). This is the
  --     direction that both TAKES from the store and ADDS to the hold, so a broken replay here
  --     would either print an item or destroy one.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 25, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then
    raise exception 'P6 FAIL to_hold replay is not a replay: %', r; end if;
  if (r->>'qty')::int <> 25 or (r->>'direction') is distinct from 'to_hold' then
    raise exception 'P6 FAIL replay envelope is not verbatim: %', r; end if;
  if pg_temp.held(uA,'ore') <> h0 then raise exception 'P6 FAIL the replay DUPLICATED into the hold'; end if;
  if pg_temp.stored_at(uA, haven,'ore') <> s0 then raise exception 'P6 FAIL the replay took from the store again'; end if;
  if (select count(*) from public.item_transfer_receipts where main_ship_id=v_ship) <> nrec then
    raise exception 'P6 FAIL the replay minted a receipt'; end if;
  if (select count(*) from public.inventory_ledger where player_id=uA) <> nled then
    raise exception 'P6 FAIL the replay wrote an inventory ledger row'; end if;
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P6 FAIL conservation across a to_hold replay'; end if;

  -- (ii) a FRESH to_storage move, then its replay — the other direction, same guarantee.
  h0 := pg_temp.held(uA,'ore');
  s0 := pg_temp.stored_at(uA, haven, 'ore');
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 5, v_req2));
  if (r->>'ok')::boolean is not true then raise exception 'P6 FAIL to_storage: %', r; end if;
  if pg_temp.held(uA,'ore') <> h0 - 5 or pg_temp.stored_at(uA, haven,'ore') <> s0 + 5 then
    raise exception 'P6 FAIL to_storage deltas: held=% stored=%', pg_temp.held(uA,'ore'), pg_temp.stored_at(uA, haven,'ore'); end if;
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P6 FAIL conservation on to_storage'; end if;

  h0 := pg_temp.held(uA,'ore');
  s0 := pg_temp.stored_at(uA, haven, 'ore');
  select count(*) into nrec from public.item_transfer_receipts where main_ship_id=v_ship;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 5, v_req2));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then
    raise exception 'P6 FAIL to_storage replay is not a replay: %', r; end if;
  if pg_temp.held(uA,'ore') <> h0 then raise exception 'P6 FAIL the to_storage replay took from the hold again'; end if;
  if pg_temp.stored_at(uA, haven,'ore') <> s0 then raise exception 'P6 FAIL the to_storage replay DUPLICATED into the store'; end if;
  if (select count(*) from public.item_transfer_receipts where main_ship_id=v_ship) <> nrec then
    raise exception 'P6 FAIL the to_storage replay minted a receipt'; end if;
  -- ★ THE CROWN JEWEL ★
  if pg_temp.total_of(uA,'ore') <> t0 then
    raise exception 'P6 FAIL CONSERVATION: uA''s ore went % -> % across the replay block', t0, pg_temp.total_of(uA,'ore'); end if;
  if t0 <> 40 then raise exception 'P6 FAIL the conserved total is not the 40 that was granted (%)', t0; end if;

  raise notice 'HOLD_PASS_ATOMIC ok: a replayed move in EITHER direction returns the verbatim envelope and writes nothing — no second receipt, no ledger row, no duplication into the hold and no second take from the store; uA''s ore is still exactly the 40 that were granted, wherever they sit';
end $$;

-- ════════ P7 — GUARDS: the full reject envelope, each with zero writes. ════════
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  haven uuid := (select v from hx1 where k='haven'); t0 int; nrec int;
begin
  t0 := pg_temp.total_of(uA,'ore');
  select count(*) into nrec from public.item_transfer_receipts;

  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, null::uuid)', v_ship, 'to_storage', 'ore', 1));
  if (r->>'reason') is distinct from 'invalid_request' then raise exception 'P7 FAIL null request: %', r; end if;

  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'sideways', 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_direction' then raise exception 'P7 FAIL bad direction: %', r; end if;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, null, %L, %s, %L::uuid)', v_ship, 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_direction' then raise exception 'P7 FAIL null direction: %', r; end if;

  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'no_such_item', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_item' then raise exception 'P7 FAIL unknown item: %', r; end if;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', '', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_item' then raise exception 'P7 FAIL empty item: %', r; end if;

  -- items are INTEGER quantities: zero, negative and FRACTIONAL all reject; nothing is rounded.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 0, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_quantity' then raise exception 'P7 FAIL qty 0: %', r; end if;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', -3, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_quantity' then raise exception 'P7 FAIL qty -3: %', r; end if;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 2.5, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_quantity' then raise exception 'P7 FAIL qty 2.5 (fractional must reject, never round): %', r; end if;

  -- more than you carry, and more than the port holds.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 9999, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_items' then raise exception 'P7 FAIL insufficient_items: %', r; end if;
  if (r->>'need')::int <> 9999 then raise exception 'P7 FAIL insufficient_items have/need: %', r; end if;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'crystal', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_stored' then raise exception 'P7 FAIL insufficient_stored: %', r; end if;

  -- ZERO writes across every reject above.
  if (select count(*) from public.item_transfer_receipts) <> nrec then raise exception 'P7 FAIL a reject wrote a receipt'; end if;
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P7 FAIL a reject moved items'; end if;

  raise notice 'HOLD_PASS_GUARDS ok: invalid_request / invalid_direction (bad + null) / invalid_item (unknown + empty) / invalid_quantity (0, negative, FRACTIONAL) / insufficient_items / insufficient_stored — every one rejected with zero receipts and zero movement';
end $$;

-- ════════ P8 — the READ surfaces agree with the tables, and the client is never asked to compute. ════════
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  v_fleet uuid := (select v from hx1 where k='uA_fleet');
  haven uuid := (select v from hx1 where k='haven'); v_used numeric; v_cap numeric; n int;
begin
  -- get_my_hold: the numbers come from the server, and they match a fold computed here independently
  -- over THIS FLEET — not over the player, which is the distinction the whole revision turns on.
  r := pg_temp.call_as(uA, format('public.get_my_hold(%L::uuid)', v_ship));
  if (r->>'ok')::boolean is not true then raise exception 'P8 FAIL get_my_hold: %', r; end if;
  select coalesce(sum(fi.quantity * t.volume_m3),0) into v_used
    from public.fleet_items fi join public.item_types t on t.item_id=fi.item_id
   where fi.fleet_id=v_fleet and fi.quantity>0;
  select coalesce(sum(m.cargo_capacity_m3),0) into v_cap
    from public.fleets f
    join public.main_ship_instances m
      on ((f.group_id is not null and f.main_ship_id is null and m.group_id = f.group_id and m.player_id = f.player_id)
          or (f.main_ship_id is not null and m.main_ship_id = f.main_ship_id))
   where f.id = v_fleet and m.status <> 'destroyed';
  if (r->>'used_m3')::numeric <> v_used then raise exception 'P8 FAIL used_m3 % vs independent fold %', (r->>'used_m3')::numeric, v_used; end if;
  if (r->>'capacity_m3')::numeric <> v_cap then raise exception 'P8 FAIL capacity_m3 % vs independent fold %', (r->>'capacity_m3')::numeric, v_cap; end if;
  if (r->>'free_m3')::numeric <> greatest(v_cap - v_used, 0) then raise exception 'P8 FAIL free_m3: %', r; end if;
  -- every carried stack carries its volume, so no surface has to compute one.
  select count(*) into n from jsonb_array_elements(r->'items') as t(elem)
   where (t.elem->>'volume_m3') is null or (t.elem->>'stack_m3') is null;
  if n <> 0 then raise exception 'P8 FAIL % hold stack(s) arrive without a volume', n; end if;

  -- get_my_docked_store: this port's ITEM stock is projected, with volumes, and matches base_items.
  r := pg_temp.call_as(uA, format('public.get_my_docked_store(%L::uuid)', v_ship));
  if (r->>'state') is distinct from 'at_location' or (r->>'docked')::boolean is not true
     or (r->>'location_id')::uuid is distinct from haven then
    raise exception 'P8 FAIL docked_store envelope drifted: %', r; end if;
  if r->'items' is null then raise exception 'P8 FAIL docked_store carries no items key'; end if;
  select count(*) into n from jsonb_array_elements(r->'items') as t(elem)
   where (t.elem->>'quantity')::int is distinct from pg_temp.stored_at(uA, haven, t.elem->>'item_id');
  if n <> 0 then raise exception 'P8 FAIL % projected item stack(s) disagree with base_items', n; end if;
  -- ...and it projects the port's REAL stock, not an empty list that would pass the check above
  -- vacuously. Haven is holding uA's ore at this point in the proof.
  if jsonb_array_length(r->'items') = 0 then
    raise exception 'P8 FAIL the docked store projected NO items while Haven holds % ore — the agreement check above would be vacuous', pg_temp.stored_at(uA, haven, 'ore'); end if;
  -- the carried-through 0211 keys survived the re-create.
  if r->'resources' is null or r->'units' is null or (r->>'store_id') is null then
    raise exception 'P8 FAIL the re-created read lost a 0211 key: %', r; end if;

  -- an UNDOCKED player still gets the uniform envelope, items included and empty.
  r := pg_temp.call_as((select v from hx1 where k='uD'), format('public.get_my_docked_store(%L::uuid)', (select v from hx1 where k='uD_ship')));
  if (r->>'docked')::boolean is not false then raise exception 'P8 FAIL undocked store says docked: %', r; end if;
  if r->'items' is null or jsonb_array_length(r->'items') <> 0 then
    raise exception 'P8 FAIL the undocked envelope is not the uniform empty shape: %', r; end if;

  raise notice 'HOLD_PASS_READS ok: get_my_hold''s used/capacity/free match an independent FLEET-scoped fold and every stack carries its volume; get_my_docked_store projects THIS port''s real base_items with volumes, keeps every 0211 key, and answers the uniform empty shape when not docked';
end $$;

-- ════════ P10 — CRAFT AT THE PORT YOU ARE STANDING IN. ════════════════════════════════════════════
-- The command the owner's law is really about. Same materials, two ports: crafting at Haven while
-- the stock sits at Slagworks is REFUSED and moves nothing; move the stock to Haven and the same
-- call succeeds and consumes HAVEN's pile to zero. RED BY CONSTRUCTION — the first half fails on any
-- build where craft can still reach a placeless pool.
do $$
declare r jsonb; uE uuid := (select v from hx1 where k='uE'); v_ship uuid := (select v from hx1 where k='uE_ship');
  uD uuid := (select v from hx1 where k='uD'); v_shipD uuid := (select v from hx1 where k='uD_ship');
  haven uuid := (select v from hx1 where k='haven'); slag uuid := (select v from hx1 where k='slag');
  v_hstore uuid; v_sstore uuid; ing record; n int; v_before int;
begin
  update public.game_config set value='true'::jsonb where key='module_crafting_enabled';

  v_hstore := public.get_or_create_store(uE, haven);
  v_sstore := public.get_or_create_store(uE, slag);
  if (select count(*) from public.module_recipe_ingredients where module_type_id='autocannon_battery') = 0 then
    raise exception 'P10 FAIL fixture: autocannon_battery has no recipe — the block would be vacuous';
  end if;

  -- (a) THE MATERIALS ARE AT SLAGWORKS, THE SHIP IS AT HAVEN. Placed through the sole writer.
  for ing in select item_id, qty from public.module_recipe_ingredients where module_type_id='autocannon_battery' order by item_id loop
    perform public.base_items_add(v_sstore, ing.item_id, ing.qty);
  end loop;

  r := pg_temp.call_as(uE, format('public.craft_module(%L, %L, %L::uuid)', 'hx1-craft-1', 'autocannon_battery', v_ship));
  if (r->>'ok')::boolean is not false or (r->>'code') is distinct from 'insufficient_items' then
    raise exception 'P10(a) FAIL: a craft at Haven consumed a pile that is at SLAGWORKS: %', r; end if;
  -- the remote pile is BYTE-UNCHANGED and nothing was minted.
  for ing in select item_id, qty from public.module_recipe_ingredients where module_type_id='autocannon_battery' order by item_id loop
    if pg_temp.stored_at(uE, slag, ing.item_id) <> ing.qty then
      raise exception 'P10(a) FAIL: the refused craft touched Slagworks'' % (% left, want %)', ing.item_id, pg_temp.stored_at(uE, slag, ing.item_id), ing.qty; end if;
  end loop;
  if (select count(*) from public.module_instances where player_id = uE) <> 0 then
    raise exception 'P10(a) FAIL: a refused craft minted a module'; end if;
  if (select count(*) from public.module_craft_receipts where player_id = uE) <> 0 then
    raise exception 'P10(a) FAIL: a refused craft wrote a receipt'; end if;

  -- (b) THE SAME MATERIALS AT HAVEN — the port the ship is docked at. Now it works, and it consumes
  --     HAVEN'S pile, to zero, while Slagworks' identical pile is still untouched.
  for ing in select item_id, qty from public.module_recipe_ingredients where module_type_id='autocannon_battery' order by item_id loop
    perform public.base_items_add(v_hstore, ing.item_id, ing.qty);
  end loop;
  r := pg_temp.call_as(uE, format('public.craft_module(%L, %L, %L::uuid)', 'hx1-craft-2', 'autocannon_battery', v_ship));
  if (r->>'ok')::boolean is not true then raise exception 'P10(b) FAIL craft at the docked port: %', r; end if;
  for ing in select item_id, qty from public.module_recipe_ingredients where module_type_id='autocannon_battery' order by item_id loop
    if pg_temp.stored_at(uE, haven, ing.item_id) <> 0 then
      raise exception 'P10(b) FAIL: Haven''s % was not consumed to zero (% left)', ing.item_id, pg_temp.stored_at(uE, haven, ing.item_id); end if;
    if pg_temp.stored_at(uE, slag, ing.item_id) <> ing.qty then
      raise exception 'P10(b) FAIL: the craft reached across to SLAGWORKS'' % ', ing.item_id; end if;
  end loop;
  if (select count(*) from public.module_instances where player_id = uE) <> 1 then
    raise exception 'P10(b) FAIL: exactly one module should exist'; end if;

  -- (c) NOT DOCKED AT ALL → the typed refusal, never a raw Postgres string. uD is in transit (P4c).
  update public.game_config set value='true'::jsonb where key='captain_progression_enabled';
  r := pg_temp.call_as(uD, format('public.craft_module(%L, %L, %L::uuid)', 'hx1-craft-3', 'autocannon_battery', v_shipD));
  if (r->>'code') is distinct from 'not_docked' then raise exception 'P10(c) FAIL undocked craft: %', r; end if;
  if (r->>'message') is null then raise exception 'P10(c) FAIL the refusal carries no player-facing message: %', r; end if;
  r := pg_temp.call_as(uD, format('public.recruit_captain(%L, %L, %L::uuid)', 'hx1-recruit-1', 'gunnery_veteran', v_shipD));
  if (r->>'code') is distinct from 'not_docked' then raise exception 'P10(c) FAIL undocked recruit: %', r; end if;

  -- (d) AND THE LEAF ITSELF cannot be asked for a placeless balance — law 2 as a SHAPE.
  begin
    perform public.inventory_get_balance(uE, null, 'scrap');
    raise exception 'P10(d) FAIL: a balance was read with no port named';
  exception when raise_exception then
    if position('always AT a port' in sqlerrm) = 0 then
      raise exception 'P10(d) FAIL: the placeless balance was refused for the wrong reason: %', sqlerrm; end if;
  end;

  raise notice 'HOLD_PASS_CRAFT_AT_PORT ok: the SAME craft is REFUSED insufficient_items while its materials sit at Slagworks and SUCCEEDS once they are at the docked port, consuming HAVEN''s pile to zero with Slagworks'' identical pile untouched; an undocked craft AND an undocked recruit both return the typed not_docked with player-facing copy; and the balance leaf refuses to answer without a port';
end $$;

-- ════════ P11 — A HULL ORDER REMEMBERS THE PORT THAT PLACED IT, AND ITS REFUND GOES BACK THERE. ════
-- Before 0333, `build_orders_kind_coherent` FORCED base_id NULL on hull orders, and the hull arm is
-- the ONLY refund path that returns ITEMS — so the item refund had no port BY CONSTRUCTION.
do $$
declare r jsonb; uE uuid := (select v from hx1 where k='uE'); v_ship uuid := (select v from hx1 where k='uE_ship');
  haven uuid := (select v from hx1 where k='haven'); v_hstore uuid; ing record; v_order uuid; v_def text;
  v_tot_before jsonb := '{}'::jsonb; n int;
begin
  update public.game_config set value='true'::jsonb where key='shipyard_enabled';
  v_hstore := public.get_or_create_store(uE, haven);
  if (select count(*) from public.hull_recipe_ingredients where hull_type_id='strike_corvette') = 0 then
    raise exception 'P11 FAIL fixture: strike_corvette has no recipe — the block would be vacuous';
  end if;

  -- the CHECK really was flipped: a hull order may no longer be placed with no store.
  select pg_get_constraintdef(oid) into v_def from pg_constraint
   where conname='build_orders_kind_coherent' and conrelid='public.build_orders'::regclass;
  if v_def is null then raise exception 'P11 FAIL: build_orders_kind_coherent is missing'; end if;
  if position('base_id IS NULL' in v_def) <> 0 then
    raise exception 'P11 FAIL: a hull order may still carry no base_id (%) — its item refund would have no port', v_def; end if;

  -- stock the DOCKED port with exactly the bill, and remember the totals for the conservation check.
  for ing in select item_id, qty from public.hull_recipe_ingredients where hull_type_id='strike_corvette' order by item_id loop
    perform public.base_items_add(v_hstore, ing.item_id, ing.qty::integer);
    v_tot_before := v_tot_before || jsonb_build_object(ing.item_id, pg_temp.total_of(uE, ing.item_id));
  end loop;

  r := pg_temp.call_as(uE, format('public.start_hull_build(%L::uuid, %L, %L::uuid)', gen_random_uuid(), 'strike_corvette', v_ship));
  if (r->>'ok')::boolean is not true then raise exception 'P11 FAIL hull order: %', r; end if;
  v_order := (r->>'order_id')::uuid;

  -- ★ THE ORDER RECORDED ITS STORE ★ — the whole reason the refund can find a port.
  if (select base_id from public.build_orders where id = v_order) is distinct from v_hstore then
    raise exception 'P11 FAIL: the hull order did not record the store it was placed from (got %, want %)',
      (select base_id from public.build_orders where id = v_order), v_hstore; end if;
  -- and the bill really came out of THAT port.
  for ing in select item_id, qty from public.hull_recipe_ingredients where hull_type_id='strike_corvette' order by item_id loop
    if pg_temp.stored_at(uE, haven, ing.item_id) <> 0 then
      raise exception 'P11 FAIL: Haven''s % was not spent to zero by the order (% left)', ing.item_id, pg_temp.stored_at(uE, haven, ing.item_id); end if;
  end loop;

  -- CANCEL. The order is still 'waiting', so the refund is 100% — and it must land IN THAT PORT.
  if (select status from public.build_orders where id = v_order) is distinct from 'waiting' then
    raise exception 'P11 FAIL fixture: the order is not waiting, so the refund fraction would not be 100%%'; end if;
  perform pg_temp.act_as(uE, format('public.cancel_build_order(%L::uuid)', v_order));

  for ing in select item_id, qty from public.hull_recipe_ingredients where hull_type_id='strike_corvette' order by item_id loop
    if pg_temp.stored_at(uE, haven, ing.item_id) <> ing.qty::integer then
      raise exception 'P11 FAIL: the refund did not return % to the port that ordered it (% at Haven, want %)',
        ing.item_id, pg_temp.stored_at(uE, haven, ing.item_id), ing.qty::integer; end if;
    -- ...and NOWHERE ELSE. Conservation across the whole order/cancel round trip.
    if pg_temp.total_of(uE, ing.item_id) <> (v_tot_before->>ing.item_id)::int then
      raise exception 'P11 FAIL CONSERVATION on %: % -> %', ing.item_id, (v_tot_before->>ing.item_id)::int, pg_temp.total_of(uE, ing.item_id); end if;
  end loop;
  -- the hold was never involved: a refund goes to a PORT, and the fleet is carrying nothing new.
  select count(*) into n from public.fleet_items fi join public.fleets f on f.id=fi.fleet_id
   where f.player_id = uE and fi.quantity > 0;
  if n <> 0 then raise exception 'P11 FAIL: the refund put % stack(s) into a fleet hold instead of the port', n; end if;

  raise notice 'HOLD_PASS_HULL_REFUND ok: the kind-coherence CHECK now REQUIRES a store on a hull order; the order records the docked port''s store and spends THAT port''s stock to zero; cancelling returns every ingredient to exactly that port (never to a hold, never to nowhere) with the totals conserved';
end $$;

-- ════════ P12 — A DEPOSIT NEVER STRANDS; A SPEND REFUSES. ═════════════════════════════════════════
-- The asymmetry, stated as a property: never destroy an asset to satisfy a rule, but never let a
-- spend happen without a place either.
do $$
declare uF uuid := (select v from hx1 where k='uF'); haven uuid := (select v from hx1 where k='haven');
  slag uuid := (select v from hx1 where k='slag'); v_oldest uuid; v_second uuid; t0 int;
begin
  -- give uF a SECOND store, at a different port, so "oldest" is a real choice rather than the only
  -- row available — otherwise the fallback below would pass vacuously.
  v_oldest := (select id from public.bases where player_id = uF and status='active' order by created_at, id limit 1);
  v_second := public.get_or_create_store(uF, slag);
  if v_second = v_oldest then raise exception 'P12 FAIL fixture: uF still has only one store — the oldest-base rule would be vacuous'; end if;
  if (select count(*) from public.bases where player_id = uF and status='active') < 2 then
    raise exception 'P12 FAIL fixture: uF has fewer than two active stores'; end if;

  t0 := pg_temp.total_of(uF,'crystal');
  -- LOOT WITH NO PORT — the open-space secure. It must land SOMEWHERE, and that somewhere is the
  -- OLDEST ACTIVE base (0221:1031-1036, the idiom 0307:153 already uses).
  perform public.reward_grant('combat', gen_random_uuid(), uF, null,
    '{"items":[{"item_id":"crystal","quantity":3}]}'::jsonb);
  if pg_temp.total_of(uF,'crystal') <> t0 + 3 then
    raise exception 'P12 FAIL: a placeless deposit VANISHED (% -> %)', t0, pg_temp.total_of(uF,'crystal'); end if;
  if (select coalesce(quantity,0) from public.base_items where base_id = v_oldest and item_id='crystal') <> 3 then
    raise exception 'P12 FAIL: the placeless deposit did not land at the OLDEST active base'; end if;
  if (select count(*) from public.base_items where base_id = v_second and item_id='crystal') <> 0 then
    raise exception 'P12 FAIL: the placeless deposit landed at the newer base'; end if;
  if pg_temp.held(uF,'crystal') <> 0 then
    raise exception 'P12 FAIL: a deposit put items into a hold — items LIVE at ports'; end if;

  -- ...and the SAME null, on a SPEND, is refused. Evaluated, not read.
  begin
    perform public.inventory_spend(uF, null, 'crystal', 1);
    raise exception 'P12 FAIL: a spend with no port was allowed — remote retrieval would be expressible';
  exception when raise_exception then
    if position('must name the port' in sqlerrm) = 0 then
      raise exception 'P12 FAIL: the placeless spend was refused for the wrong reason: %', sqlerrm; end if;
  end;
  if pg_temp.total_of(uF,'crystal') <> t0 + 3 then raise exception 'P12 FAIL: the refused spend moved something'; end if;

  raise notice 'HOLD_PASS_NEVER_STRAND ok: loot secured with NO port lands at the player''s OLDEST active base (not the newer one, not a hold, never nowhere) while a SPEND with no port is refused outright — a deposit never destroys an asset, a spend never happens without a place';
end $$;

-- ════════ P9 — the WHOLE grant posture (the 0254/0309 lesson, and this migration's own rev.1). ════
-- rev.1 of 0333 checked three verbs here and on the real deploy died on the SELECT it never revoked,
-- because the Supabase project default grants EIGHT (arwdDxtm) on every new public table and a
-- disposable chain reproduces none of them. This block now checks all eight against a stated
-- INTENDED posture. It is honest about its own limit: on this throwaway DB the defaults are absent,
-- so passing here does NOT prove the production posture — what proves that is the migration's total
-- `revoke all`, which is a superset of any default and therefore cannot be short. What this block
-- CAN prove, and does, is the other half: that the revoke did not take too much.
do $$
declare v_g text; v_src text; v_bad text; v_n bigint; v_prev_role text;
begin
  select string_agg(t || '.' || v || ' [' || r || ']', ', ' order by t, v, r) into v_bad
    from unnest(array['base_items','fleet_items','item_transfer_receipts',
                      'item_types','inventory_ledger'])                        as t
   cross join unnest(array['INSERT','SELECT','UPDATE','DELETE',
                           'TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'])       as v
   cross join unnest(array['anon','authenticated','public'])                    as r
   where has_table_privilege(r, 'public.' || t, v)
     and not (v = 'SELECT' and r = 'authenticated')
     and not (v = 'SELECT' and r = 'anon' and t = 'item_types');
  if v_bad is not null then
    raise exception 'P9 FAIL: privilege outside the intended posture survives on: %', v_bad; end if;

  -- the reads that MUST survive. A revoke that overshoots blinds the hangar or the item catalog, and
  -- THIS is the half a disposable chain can genuinely prove.
  select string_agg(t, ', ' order by t) into v_bad
    from unnest(array['base_items','fleet_items','item_transfer_receipts',
                      'item_types','inventory_ledger']) as t
   where not has_table_privilege('authenticated', 'public.' || t, 'SELECT');
  if v_bad is not null then
    raise exception 'P9 FAIL: the revoke took an authenticated SELECT it must keep — lost on: %', v_bad; end if;
  if not has_table_privilege('anon', 'public.item_types', 'SELECT') then
    raise exception 'P9 FAIL: the revoke took anon SELECT on the PUBLIC-READ item_types catalog'; end if;

  -- the global pool is GONE, so nothing can be granted on it and no second authority can exist.
  if to_regclass('public.player_inventory') is not null then
    raise exception 'P9 FAIL: public.player_inventory still exists — two authorities for "how many do I have"'; end if;

  -- and the same answered by EXECUTION: become anon and try. Denied is the pass; item_types is the
  -- positive control so a seat that can read nothing at all cannot fake a pass. The role is saved
  -- and restored through the GUC rather than RESET ROLE, which returns to the SESSION user and is
  -- only equivalent under one connection shape.
  v_prev_role := current_setting('role');
  begin
    set local role anon;
    execute 'select count(*) from public.base_items' into v_n;
    perform set_config('role', v_prev_role, true);
    raise exception 'P9 FAIL: the anon seat could SELECT base_items';
  exception when insufficient_privilege then perform set_config('role', v_prev_role, true);
  end;
  begin
    set local role anon;
    execute 'select count(*) from public.fleet_items' into v_n;
    perform set_config('role', v_prev_role, true);
    raise exception 'P9 FAIL: the anon seat could SELECT fleet_items';
  exception when insufficient_privilege then perform set_config('role', v_prev_role, true);
  end;
  begin
    set local role anon;
    execute 'select count(*) from public.item_types' into v_n;
    perform set_config('role', v_prev_role, true);
  exception when insufficient_privilege then
    perform set_config('role', v_prev_role, true);
    raise exception 'P9 FAIL: the anon seat cannot read item_types — the probes above passed vacuously (positive control)';
  end;
  if current_setting('role') is distinct from v_prev_role then
    raise exception 'P9 FAIL: the anon probes did not restore the role'; end if;

  foreach v_g in array array['public.base_items_add(uuid,text,integer)','public.base_items_take(uuid,text,integer)',
                             'public.fleet_items_add(uuid,text,integer)','public.fleet_items_take(uuid,text,integer)',
                             'public.fleet_hold_capacity_m3(uuid)','public.fleet_hold_used_m3(uuid)',
                             'public.inventory_deposit(uuid,uuid,text,integer,text)',
                             'public.inventory_spend(uuid,uuid,text,integer)',
                             'public.inventory_get_balance(uuid,uuid,text)'] loop
    if has_function_privilege('anon', v_g, 'execute') or has_function_privilege('authenticated', v_g, 'execute') then
      raise exception 'P9 FAIL: leaf % is client-callable — an item printer', v_g; end if;
  end loop;
  if has_function_privilege('anon','public.transfer_items(uuid,text,text,numeric,uuid)','execute')
     or has_function_privilege('anon','public.get_my_hold(uuid)','execute') then
    raise exception 'P9 FAIL: anon can reach the transfer surface'; end if;
  if not has_function_privilege('authenticated','public.transfer_items(uuid,text,text,numeric,uuid)','execute')
     or not has_function_privilege('authenticated','public.get_my_hold(uuid)','execute') then
    raise exception 'P9 FAIL: authenticated cannot reach the transfer surface'; end if;
  -- the three re-signatured commands kept their client grant across the signature change.
  foreach v_g in array array['public.craft_module(text,text,uuid)','public.recruit_captain(text,text,uuid)',
                             'public.start_hull_build(uuid,text,uuid)'] loop
    if not has_function_privilege('authenticated', v_g, 'execute') then
      raise exception 'P9 FAIL: % lost its authenticated grant across the signature change', v_g; end if;
    if has_function_privilege('anon', v_g, 'execute') then
      raise exception 'P9 FAIL: anon can reach %', v_g; end if;
  end loop;

  -- CONCURRENCY. This proof runs in ONE transaction, so it cannot stage a real race; what it CAN
  -- do is refuse to pass while the only thing that makes the capacity check authoritative is
  -- missing. Without the per-player advisory lock, two ships of one fleet could each pass the
  -- check and land the hold over capacity between them — and neither fleet_items_add nor
  -- base_items_take can re-check a capacity, so there is no backstop below it.
  v_src := (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='public' and p.proname='transfer_items');
  if position('pg_advisory_xact_lock(hashtext(''item_transfer'')' in v_src) = 0 then
    raise exception 'P9 FAIL: transfer_items takes no per-player advisory lock — the capacity invariant is not authoritative across a fleet''s ships'; end if;
  if position('pg_advisory_xact_lock(' in v_src) > position('mainship_space_lock_context(' in v_src) then
    raise exception 'P9 FAIL: inverted lock order — the row lock is taken before the advisory lock'; end if;

  raise notice 'HOLD_PASS_ACL ok: all EIGHT privileges checked across 5 tables x 3 client grantees against the intended posture; the global pool is GONE; the authenticated reads and the item_types PUBLIC-READ catalog survived the revoke; the anon SEAT was denied base_items AND fleet_items by execution with item_types as the positive control; nine leaves are server-only; the two RPCs and the three re-signatured commands are authenticated-only; and the capacity check is serialized by the per-player advisory lock, taken before any row lock';
end $$;

do $$
begin
  raise notice 'ITEMS-HAVE-A-PLACE PROOF PASSED';
end $$;

rollback;
