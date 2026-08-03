-- ITEMS-HAVE-A-PLACE — disposable REAL-CHAIN proof (runs on the actual chain 0001..0332 in a
-- throwaway Supabase). Proves migration 0332: item volumes, the per-port `base_items` store, and
-- the ONE docked-only transfer verb between the ship's hold and that port's storage.
--
-- Fixture users carry the 'hx1.' email prefix. The ENTIRE proof runs inside ONE transaction that
-- ROLLBACKs — it persists NO player, ship, item, store, receipt or flag flip. No production access.
-- No COMMIT anywhere.
--
-- ── THE FOUR LAWS THIS FILE EXISTS TO PROVE ─────────────────────────────────────────────────────
--   1. Items are NOT unlimited — volume matters.        → HOLD_PASS_VOLUMES + HOLD_PASS_CAPACITY
--   2. Storage is PER-PORT.                             → HOLD_PASS_LAW3 (a) + HOLD_PASS_ISOLATION
--   3. You can reach a port's storage ONLY while DOCKED  → HOLD_PASS_LAW3 (a)(b)(c) — the one that
--      THERE. No remote retrieval, EVER.                  MUST be impossible, proved three ways
--   4. The player moves items between hold and storage. → HOLD_PASS_ROUNDTRIP + HOLD_PASS_ATOMIC
--
-- ── THE CROWN-JEWEL PROPERTY IS CONSERVATION ────────────────────────────────────────────────────
-- An item may never be duplicated and may never be lost. `pg_temp.total_of(player, item)` counts a
-- player's units of an item EVERYWHERE — the hold plus every one of their per-port stores — and
-- every block asserts it is INVARIANT across the operation it performs, including across a replay.
-- A transfer that wrote one side and not the other, or that replayed into a double credit, breaks
-- that number and this proof fails. RED BY CONSTRUCTION: the totals are recomputed from the real
-- tables after every call, never carried forward from an expectation.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ───────────────────────
-- Every precondition this proof needs it SETS ITSELF, inside the rolled-back transaction — it never
-- asserts a seeded ambient default. station_storage_enabled is forced FALSE for the dark block and
-- TRUE afterwards; the movement/team flags are forced TRUE for the law-3 undock. The ROLLBACK
-- reverts all of them. Items are granted ONLY through the REAL secured-deposit pipeline leaf
-- public.reward_grant (0040 → inventory_deposit), never by a direct player_inventory insert; port
-- stock is placed ONLY through public.base_items_add (0332's sole writer), never by a direct
-- base_items insert.

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

-- ★ THE CONSERVATION ORACLE ★ — every unit of an item this player owns, ANYWHERE: the hold plus
-- every per-port store they have. A transfer moves units between the two terms; it must never
-- change the sum. Recomputed from the live tables on every call.
create or replace function pg_temp.total_of(p_player uuid, p_item text) returns integer
language sql stable as $$
  select coalesce((select quantity from public.player_inventory
                    where player_id = p_player and item_id = p_item), 0)
       + coalesce((select sum(bi.quantity)::integer from public.base_items bi
                     join public.bases b on b.id = bi.base_id
                    where b.player_id = p_player and bi.item_id = p_item), 0);
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

-- three fresh players: uA (the mover), uB (the foreign-owner probe), uD (the undocked world — it
-- launches a REAL fleet move, so it gets its own world and cannot poison uA's fixtures).
do $$
declare u uuid; sk text;
begin
  foreach sk in array array['uA','uB','uD'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'hx1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into hx1 values (sk, u);
  end loop;
end $$;

insert into public.player_wallet (player_id, balance)
select v, 1000000 from hx1 where k in ('uA','uB','uD')
on conflict (player_id) do update set balance = excluded.balance;

-- ════════ PROVISION via the REAL commission RPC → each player docked at Haven ════════
-- Items arrive ONLY through the real reward pipeline (reward_grant → inventory_deposit, 0040/0039).
do $$
declare r jsonb; sk text; u uuid; uA uuid; uB uuid; uD uuid;
begin
  foreach sk in array array['uA','uB','uD'] loop
    u := (select v from hx1 where hx1.k = sk);
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true then raise exception 'PROVISION FAIL %: %', sk, r; end if;
    insert into hx1 select sk||'_ship', main_ship_id from public.main_ship_instances where player_id = u;
  end loop;

  uA := (select v from hx1 where k='uA');
  uB := (select v from hx1 where k='uB');
  uD := (select v from hx1 where k='uD');

  -- uA gets 40 ore and NOTHING ELSE. At 2.0 m3 each that is 80 m3 against a 50 m3 hull — the hold
  -- is OVER CAPACITY the moment the loot lands, and that is DELIBERATE AND CORRECT: a grant never
  -- refuses (refusing would destroy combat loot and abort cancel-refunds), so over-capacity is a
  -- legal state to be PROVEN, not an impossible one. One item type only, so every m3 arithmetic in
  -- P2/P3/P6 below is exact and cannot be shifted by an unrelated stack.
  perform public.reward_grant('combat', gen_random_uuid(), uA, null,
    '{"items":[{"item_id":"ore","quantity":40}]}'::jsonb);
  perform public.reward_grant('combat', gen_random_uuid(), uB, null,
    '{"items":[{"item_id":"scrap","quantity":7}]}'::jsonb);
  perform public.reward_grant('combat', gen_random_uuid(), uD, null,
    '{"items":[{"item_id":"scrap","quantity":3}]}'::jsonb);

  if public.inventory_get_balance(uA,'ore') <> 40 then
    raise exception 'PROVISION FAIL: uA reward_grant deposit did not land (ore=%)', public.inventory_get_balance(uA,'ore');
  end if;
  if (select count(*) from public.player_inventory where player_id = uA and quantity > 0) <> 1 then
    raise exception 'PROVISION FAIL: uA holds more than the one ore stack — the exact m3 arithmetic below would drift';
  end if;
  -- the grant DID push the hold over capacity, and nothing refused it. If this is ever false the
  -- over-capacity block downstream is testing a world that cannot happen.
  if public.hold_used_m3(uA) <> 80 or public.hold_capacity_m3(uA) <> 50 then
    raise exception 'PROVISION FAIL: expected an 80 m3 hold in a 50 m3 hull, got % in %',
      public.hold_used_m3(uA), public.hold_capacity_m3(uA);
  end if;
  -- guard the guard: every ship must be the 50 m3 starter hull, or the capacity block is vacuous.
  if exists (select 1 from public.main_ship_instances where cargo_capacity_m3 <> 50) then
    raise exception 'PROVISION FAIL: a fixture ship is not the 50 m3 starter hull — the capacity block would be vacuous';
  end if;
  raise notice 'provisioned: uA(40 ore = 80 m3 in a 50 m3 hull — an over-capacity hold a grant produced and nothing refused), uB(7 scrap), uD(3 scrap), all docked at Haven';
end $$;

-- ════════ P0 — DARK gate: with station_storage_enabled OFF, the verb rejects and writes NOTHING. ════════
-- THE PRECONDITION IS STATED, NOT ASSUMED: this block forces the flag false itself rather than
-- trusting whatever the chain seeded (production has it TRUE; a fresh chain has it false; asserting
-- either would be asserting a WORLD, not a property).
update public.game_config set value='false'::jsonb where key='station_storage_enabled';
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  n int; v_tot int;
begin
  v_tot := pg_temp.total_of(uA,'ore');

  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'station_storage_disabled' then raise exception 'P0 FAIL dark to_storage: %', r; end if;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'station_storage_disabled' then raise exception 'P0 FAIL dark to_hold: %', r; end if;

  -- reject BEFORE any read: a nonexistent ship and a nonsense direction still answer the gate.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', gen_random_uuid(), 'sideways', 'nope', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'station_storage_disabled' then raise exception 'P0 FAIL gate is not first: %', r; end if;

  select count(*) into n from public.item_transfer_receipts;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % receipt(s)', n; end if;
  select count(*) into n from public.base_items;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % base_items row(s)', n; end if;
  if pg_temp.total_of(uA,'ore') <> v_tot then raise exception 'P0 FAIL dark path moved items'; end if;

  update public.game_config set value='true'::jsonb where key='station_storage_enabled';
  raise notice 'HOLD_PASS_DARK_GATE ok: both directions rejected station_storage_disabled before any read; zero receipts, zero base_items, zero item movement';
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

-- ════════ P2 — ROUND TRIP: hold → this port's storage → back, with EXACT deltas and CONSERVATION. ════════
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  haven uuid := (select v from hx1 where k='haven'); v_req uuid := gen_random_uuid();
  t0 int; h0 int; s0 int; n int;
begin
  t0 := pg_temp.total_of(uA,'ore');
  h0 := public.inventory_get_balance(uA,'ore');
  s0 := pg_temp.stored_at(uA, haven, 'ore');
  if t0 <> 40 or h0 <> 40 or s0 <> 0 then raise exception 'P2 FAIL precondition: total=% hold=% stored=%', t0, h0, s0; end if;
  if (select count(*) from public.base_items) <> 0 then raise exception 'P2 FAIL precondition: base_items is not empty'; end if;

  -- DEPOSIT 40 ore. Note the hold is currently 80 m3 in a 50 m3 hull — over capacity — and this
  -- direction MUST still work: unloading is the way out, and refusing it would strand the player.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 40, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P2 FAIL deposit: %', r; end if;
  if (r->>'qty')::int <> 40 or (r->>'direction') is distinct from 'to_storage' then raise exception 'P2 FAIL deposit envelope: %', r; end if;
  if (r->>'volume_m3')::numeric <> 80 then raise exception 'P2 FAIL moved volume % (want 80)', (r->>'volume_m3')::numeric; end if;
  if (r->>'location_id')::uuid is distinct from haven then raise exception 'P2 FAIL deposit location: %', r; end if;
  -- the envelope reports the hold AFTER the move: 80 m3 emptied into the port leaves 0.
  if (r->>'hold_used_m3')::numeric <> 0 or (r->>'hold_capacity_m3')::numeric <> 50 then
    raise exception 'P2 FAIL deposit envelope numbers: %', r; end if;

  -- EXACT deltas, read from the real tables.
  if public.inventory_get_balance(uA,'ore') <> 0 then raise exception 'P2 FAIL hold after deposit: %', public.inventory_get_balance(uA,'ore'); end if;
  if pg_temp.stored_at(uA, haven, 'ore') <> 40 then raise exception 'P2 FAIL storage after deposit: %', pg_temp.stored_at(uA, haven, 'ore'); end if;
  if public.hold_used_m3(uA) <> 0 then raise exception 'P2 FAIL the hold is not empty after unloading everything: %', public.hold_used_m3(uA); end if;
  -- ★ CONSERVATION ★
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P2 FAIL conservation on deposit: % -> %', t0, pg_temp.total_of(uA,'ore'); end if;

  -- exactly ONE receipt, with the exact fields, on the right ship and the right port.
  select count(*) into n from public.item_transfer_receipts where main_ship_id = v_ship;
  if n <> 1 then raise exception 'P2 FAIL % receipts after one move', n; end if;
  if not exists (select 1 from public.item_transfer_receipts
                  where main_ship_id=v_ship and request_id=v_req and direction='to_storage'
                    and item_id='ore' and qty=40 and volume_m3=80 and location_id=haven) then
    raise exception 'P2 FAIL receipt fields wrong';
  end if;

  -- WITHDRAW 25 back (50 m3 — exactly the hull). The boundary case: it must FIT, not be refused.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 25, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P2 FAIL withdraw exactly-fits: %', r; end if;
  if public.inventory_get_balance(uA,'ore') <> 25 then raise exception 'P2 FAIL hold after withdraw: %', public.inventory_get_balance(uA,'ore'); end if;
  if pg_temp.stored_at(uA, haven, 'ore') <> 15 then raise exception 'P2 FAIL storage after withdraw: %', pg_temp.stored_at(uA, haven, 'ore'); end if;
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P2 FAIL conservation on withdraw: % -> %', t0, pg_temp.total_of(uA,'ore'); end if;

  insert into hx1 values ('depreq', v_req);
  raise notice 'HOLD_PASS_ROUNDTRIP ok: 40 ore hold->Haven storage (80 m3, exact deltas, one receipt) and 25 back (the exactly-fits boundary); total conserved at % throughout', t0;
end $$;

-- ════════ P3 — CAPACITY: REFUSED, never clamped; the boundary is exact. ════════
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  haven uuid := (select v from hx1 where k='haven'); t0 int; h0 int; s0 int; nrec int;
begin
  t0 := pg_temp.total_of(uA,'ore');
  h0 := public.inventory_get_balance(uA,'ore');          -- 25 ore = 50 m3, the hull is FULL of ore
  s0 := pg_temp.stored_at(uA, haven, 'ore');             -- 15 left in storage
  select count(*) into nrec from public.item_transfer_receipts where main_ship_id=v_ship;
  if h0 <> 25 or s0 <> 15 then raise exception 'P3 FAIL precondition: hold=% stored=%', h0, s0; end if;

  -- ONE more unit does not fit: 50 + 2 > 50.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'hold_over_capacity' then raise exception 'P3 FAIL one-more-unit not refused: %', r; end if;
  -- the envelope carries the NUMBERS — a cap the player cannot see is a trap.
  if (r->>'hold_used_m3')::numeric <> 50 or (r->>'hold_capacity_m3')::numeric <> 50
     or (r->>'delta_m3')::numeric <> 2 or (r->>'hold_free_m3')::numeric <> 0 then
    raise exception 'P3 FAIL over-capacity envelope is not self-explaining: %', r; end if;

  -- ★ REFUSED, NOT CLAMPED ★ — nothing moved at all, not even the part that would have fit.
  if public.inventory_get_balance(uA,'ore') <> h0 then raise exception 'P3 FAIL the refusal moved the hold (clamped!)'; end if;
  if pg_temp.stored_at(uA, haven, 'ore') <> s0 then raise exception 'P3 FAIL the refusal moved the storage (clamped!)'; end if;
  if (select count(*) from public.item_transfer_receipts where main_ship_id=v_ship) <> nrec then
    raise exception 'P3 FAIL the refusal wrote a receipt'; end if;
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P3 FAIL conservation broken by a refusal'; end if;

  -- asking for ALL 15 remaining (30 m3 on a full hull) is refused the same way — a partial move is
  -- never substituted for the request.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 15, gen_random_uuid()));
  if (r->>'reason') is distinct from 'hold_over_capacity' then raise exception 'P3 FAIL bulk not refused: %', r; end if;
  if public.inventory_get_balance(uA,'ore') <> h0 or pg_temp.stored_at(uA, haven, 'ore') <> s0 then
    raise exception 'P3 FAIL bulk refusal moved something'; end if;

  -- UNLOADING still works with a full hold — the way out is always open.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 5, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P3 FAIL unload from a full hold: %', r; end if;
  if public.inventory_get_balance(uA,'ore') <> 20 or pg_temp.stored_at(uA, haven, 'ore') <> 20 then
    raise exception 'P3 FAIL unload deltas: hold=% stored=%', public.inventory_get_balance(uA,'ore'), pg_temp.stored_at(uA, haven, 'ore'); end if;

  -- and now exactly 5 fit again (40 m3 used + 10 m3 = 50) — the boundary is exact in both directions.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 5, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P3 FAIL the freed room was not usable: %', r; end if;
  if public.inventory_get_balance(uA,'ore') <> 25 then raise exception 'P3 FAIL refill deltas'; end if;
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
  v_slagstore uuid; g uuid; t0 int; n int; v_args text;
begin
  -- ── (a) REMOTE RETRIEVAL. uA is docked at HAVEN and has scrap stored at SLAGWORKS. ──────────────
  -- The Slagworks stock is placed through 0332's OWN sole writer (base_items_add), so the fixture
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
  if public.inventory_get_balance(uD,'scrap') <> 3 then raise exception 'P4(c) FAIL a refused move touched the hold'; end if;
  if (select count(*) from public.item_transfer_receipts) <> n then raise exception 'P4(c) FAIL a refused move wrote a receipt'; end if;

  raise notice 'HOLD_PASS_LAW3 ok: (a) a port you are not docked at is unreachable — Slagworks'' 9 scrap untouched while docked at Haven, the reject read HAVEN''s store (have=0); (b) the verb takes NO port/store argument (%) so remote retrieval is unexpressable, and it resolves the dock through the one shared resolver; (c) a ship in transit is refused not_docked in BOTH directions with zero writes', v_args;
end $$;

-- ════════ P5 — ISOLATION: another player's ship, hold and storage are untouchable. ════════
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); uB uuid := (select v from hx1 where k='uB');
  v_shipA uuid := (select v from hx1 where k='uA_ship'); v_shipB uuid := (select v from hx1 where k='uB_ship');
  haven uuid := (select v from hx1 where k='haven'); v_storeB uuid; tB int; n int;
begin
  -- give uB a real pile at Haven so "untouched" is a meaningful claim, not a vacuous one.
  v_storeB := public.get_or_create_store(uB, haven);
  perform public.base_items_add(v_storeB, 'scrap', 7);
  tB := pg_temp.total_of(uB,'scrap');
  if tB <> 14 then raise exception 'P5 FAIL fixture: uB total scrap % (want 7 held + 7 stored)', tB; end if;
  select count(*) into n from public.item_transfer_receipts;

  -- uA drives uB's ship id: ownership is asserted server-side, so it fails closed as ship_not_found.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_shipB, 'to_hold', 'scrap', 7, gen_random_uuid()));
  if (r->>'reason') is distinct from 'ship_not_found' then raise exception 'P5 FAIL cross-player ship not rejected: %', r; end if;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_shipB, 'to_storage', 'scrap', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'ship_not_found' then raise exception 'P5 FAIL cross-player deposit not rejected: %', r; end if;

  -- uA acting on its OWN ship at the SAME port still cannot see uB's pile: the store is resolved
  -- from (auth.uid(), the dock), so uB's 7 scrap at Haven is invisible to uA.
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_shipA, 'to_hold', 'scrap', 7, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_stored' or (r->>'have')::int <> 0 then
    raise exception 'P5 FAIL uA could see uB''s pile at the shared port: %', r; end if;

  -- nothing of uB's moved, and no receipt was minted on uB's ship.
  if pg_temp.total_of(uB,'scrap') <> tB then raise exception 'P5 FAIL uB''s total changed: % -> %', tB, pg_temp.total_of(uB,'scrap'); end if;
  if public.inventory_get_balance(uB,'scrap') <> 7 or pg_temp.stored_at(uB, haven, 'scrap') <> 7 then
    raise exception 'P5 FAIL uB''s hold/storage split changed'; end if;
  if (select count(*) from public.item_transfer_receipts) <> n then raise exception 'P5 FAIL a cross-player attempt wrote a receipt'; end if;
  if exists (select 1 from public.item_transfer_receipts where main_ship_id = v_shipB) then
    raise exception 'P5 FAIL a receipt exists on uB''s ship'; end if;

  raise notice 'HOLD_PASS_ISOLATION ok: another player''s ship id fails closed as ship_not_found in both directions; two players sharing one port keep separate stores (uA sees have=0 beside uB''s 7); uB''s 14 units and zero receipts unchanged';
end $$;

-- ════════ P6 — ATOMIC UNDER REPLAY: nothing duplicated, nothing lost, in either direction. ════════
do $$
declare r jsonb; uA uuid := (select v from hx1 where k='uA'); v_ship uuid := (select v from hx1 where k='uA_ship');
  haven uuid := (select v from hx1 where k='haven'); v_req uuid := (select v from hx1 where k='depreq');
  v_req2 uuid := gen_random_uuid();
  t0 int; h0 int; s0 int; nrec int; nled int;
begin
  t0 := pg_temp.total_of(uA,'ore');
  h0 := public.inventory_get_balance(uA,'ore');
  s0 := pg_temp.stored_at(uA, haven, 'ore');
  select count(*) into nrec from public.item_transfer_receipts where main_ship_id=v_ship;
  select count(*) into nled from public.inventory_ledger where player_id=uA;

  -- (i) replay the ORIGINAL to_storage move (P2's 40-ore deposit, same ship + request_id).
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 40, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then
    raise exception 'P6 FAIL to_storage replay is not a replay: %', r; end if;
  if (r->>'qty')::int <> 40 or (r->>'direction') is distinct from 'to_storage' then
    raise exception 'P6 FAIL replay envelope is not verbatim: %', r; end if;
  if public.inventory_get_balance(uA,'ore') <> h0 or pg_temp.stored_at(uA, haven,'ore') <> s0 then
    raise exception 'P6 FAIL the replay MOVED something'; end if;
  if (select count(*) from public.item_transfer_receipts where main_ship_id=v_ship) <> nrec then
    raise exception 'P6 FAIL the replay minted a receipt'; end if;
  if (select count(*) from public.inventory_ledger where player_id=uA) <> nled then
    raise exception 'P6 FAIL the replay wrote an inventory ledger row'; end if;
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P6 FAIL conservation across a to_storage replay'; end if;

  -- (ii) a FRESH to_hold move, then its replay — the direction that both DEPOSITS to the hold and
  --      TAKES from the store, so a broken replay here would either print or destroy an item.
  --      Unload 5 first to make room (the hold is exactly full at 25 ore).
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_storage', 'ore', 5, gen_random_uuid()));
  if (r->>'ok')::boolean is not true then raise exception 'P6 FAIL make-room unload: %', r; end if;

  h0 := public.inventory_get_balance(uA,'ore');
  s0 := pg_temp.stored_at(uA, haven, 'ore');
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 5, v_req2));
  if (r->>'ok')::boolean is not true then raise exception 'P6 FAIL to_hold: %', r; end if;
  if public.inventory_get_balance(uA,'ore') <> h0 + 5 or pg_temp.stored_at(uA, haven,'ore') <> s0 - 5 then
    raise exception 'P6 FAIL to_hold deltas: hold=% stored=%', public.inventory_get_balance(uA,'ore'), pg_temp.stored_at(uA, haven,'ore'); end if;
  if pg_temp.total_of(uA,'ore') <> t0 then raise exception 'P6 FAIL conservation on to_hold'; end if;

  h0 := public.inventory_get_balance(uA,'ore');
  s0 := pg_temp.stored_at(uA, haven, 'ore');
  select count(*) into nrec from public.item_transfer_receipts where main_ship_id=v_ship;
  r := pg_temp.call_as(uA, format('public.transfer_items(%L::uuid, %L, %L, %s, %L::uuid)', v_ship, 'to_hold', 'ore', 5, v_req2));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then
    raise exception 'P6 FAIL to_hold replay is not a replay: %', r; end if;
  if public.inventory_get_balance(uA,'ore') <> h0 then raise exception 'P6 FAIL the to_hold replay DUPLICATED into the hold'; end if;
  if pg_temp.stored_at(uA, haven,'ore') <> s0 then raise exception 'P6 FAIL the to_hold replay took from the store again'; end if;
  if (select count(*) from public.item_transfer_receipts where main_ship_id=v_ship) <> nrec then
    raise exception 'P6 FAIL the to_hold replay minted a receipt'; end if;
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
  haven uuid := (select v from hx1 where k='haven'); v_used numeric; v_cap numeric; n int;
begin
  -- get_my_hold: the numbers come from the server, and they match a fold computed here independently.
  r := pg_temp.call_as(uA, 'public.get_my_hold()');
  if (r->>'ok')::boolean is not true then raise exception 'P8 FAIL get_my_hold: %', r; end if;
  select coalesce(sum(pi.quantity * t.volume_m3),0) into v_used
    from public.player_inventory pi join public.item_types t on t.item_id=pi.item_id
   where pi.player_id=uA and pi.quantity>0;
  select coalesce(sum(m.cargo_capacity_m3),0) into v_cap
    from public.main_ship_instances m where m.player_id=uA and m.status <> 'destroyed';
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
  -- the carried-through 0211 keys survived the re-create.
  if r->'resources' is null or r->'units' is null or (r->>'store_id') is null then
    raise exception 'P8 FAIL the re-created read lost a 0211 key: %', r; end if;

  -- an UNDOCKED player still gets the uniform envelope, items included and empty.
  r := pg_temp.call_as((select v from hx1 where k='uD'), format('public.get_my_docked_store(%L::uuid)', (select v from hx1 where k='uD_ship')));
  if (r->>'docked')::boolean is not false then raise exception 'P8 FAIL undocked store says docked: %', r; end if;
  if r->'items' is null or jsonb_array_length(r->'items') <> 0 then
    raise exception 'P8 FAIL the undocked envelope is not the uniform empty shape: %', r; end if;

  raise notice 'HOLD_PASS_READS ok: get_my_hold''s used/capacity/free match an independent fold and every stack carries its volume; get_my_docked_store projects THIS port''s base_items with volumes, keeps every 0211 key, and answers the uniform empty shape when not docked';
end $$;

-- ════════ P9 — the write surface is locked down (the danger_zones 2026-07-20 lesson). ════════
do $$
declare v_t text; v_g text; v_src text;
begin
  foreach v_t in array array['public.base_items','public.item_transfer_receipts',
                             'public.player_inventory','public.item_types','public.inventory_ledger'] loop
    foreach v_g in array array['anon','authenticated'] loop
      if has_table_privilege(v_g, v_t, 'insert') or has_table_privilege(v_g, v_t, 'update')
         or has_table_privilege(v_g, v_t, 'delete') then
        raise exception 'P9 FAIL: % holds client write on %', v_g, v_t; end if;
    end loop;
  end loop;
  foreach v_g in array array['public.base_items_add(uuid,text,integer)','public.base_items_take(uuid,text,integer)',
                             'public.hold_capacity_m3(uuid)','public.hold_used_m3(uuid)'] loop
    if has_function_privilege('anon', v_g, 'execute') or has_function_privilege('authenticated', v_g, 'execute') then
      raise exception 'P9 FAIL: leaf % is client-callable — an item printer', v_g; end if;
  end loop;
  if has_function_privilege('anon','public.transfer_items(uuid,text,text,numeric,uuid)','execute')
     or has_function_privilege('anon','public.get_my_hold()','execute') then
    raise exception 'P9 FAIL: anon can reach the transfer surface'; end if;
  if not has_function_privilege('authenticated','public.transfer_items(uuid,text,text,numeric,uuid)','execute')
     or not has_function_privilege('authenticated','public.get_my_hold()','execute') then
    raise exception 'P9 FAIL: authenticated cannot reach the transfer surface'; end if;

  -- CONCURRENCY. This proof runs in ONE transaction, so it cannot stage a real race; what it CAN
  -- do is refuse to pass while the only thing that makes the capacity check authoritative is
  -- missing. Without the per-player advisory lock, two of one player's ships could each pass the
  -- check and land the hold over capacity between them — and neither inventory_deposit nor
  -- base_items_take can re-check a capacity, so there is no backstop below it.
  v_src := (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
             where n.nspname='public' and p.proname='transfer_items');
  if position('pg_advisory_xact_lock(hashtext(''item_transfer'')' in v_src) = 0 then
    raise exception 'P9 FAIL: transfer_items takes no per-player advisory lock — the capacity invariant is not authoritative across a player''s ships'; end if;
  if position('pg_advisory_xact_lock(' in v_src) > position('mainship_space_lock_context(' in v_src) then
    raise exception 'P9 FAIL: inverted lock order — the row lock is taken before the advisory lock'; end if;

  raise notice 'HOLD_PASS_ACL ok: client INSERT/UPDATE/DELETE revoked on all five load-bearing tables; the four leaves are server-only; the two RPCs are authenticated-only and closed to anon; and the capacity check is serialized by the per-player advisory lock, taken before any row lock';
end $$;

do $$
begin
  raise notice 'ITEMS-HAVE-A-PLACE PROOF PASSED';
end $$;

rollback;
