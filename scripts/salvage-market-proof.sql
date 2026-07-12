-- SALVAGE-MARKET — disposable REAL-CHAIN proof (runs on the actual chain 0001..0174 in a throwaway Supabase).
-- Proves SALVAGE-0/1: the port_item_demand seed (exact prices, drop-grounded, progression-free), the dark
-- gate, and the atomic sell_item_at_port surface (happy path, idempotent replay, guards, never-sellable pin).
-- Fixture users carry the 'sv1.' email prefix. The ENTIRE proof runs inside ONE transaction that ROLLBACKs —
-- it persists NO wallet, inventory, receipt, ship, or flag flip. No production access. No COMMIT anywhere.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ────────────────────────
-- The harness enables salvage_market_enabled ONLY inside this rolled-back transaction (AFTER proving the
-- dark reject); the ROLLBACK reverts it, so the committed/production flag value stays false. It transiently
-- mirrors production config a fresh chain lacks (reveal_starter_ports + mainship_space_movement_enabled) —
-- all reverted by ROLLBACK. Items are granted via the REAL secured-deposit pipeline leaf
-- public.reward_grant (0040: reward_grants row + inventory_deposit with the stable idempotency key) with a
-- synthetic combat source — the same function every settled combat bundle deposits through; the harness
-- NEVER inserts into player_inventory directly.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table sv1(k text primary key, v uuid) on commit preserve rows;
insert into sv1 values
  ('haven','b1a00001-0066-4a00-8a00-000000000001'),     -- Haven (commission port; pays best for repair_parts)
  ('slag', 'b1a00002-0066-4a00-8a00-000000000002'),     -- Slagworks (pays best for scrap + pirate_alloy)
  ('drift','b1a00003-0066-4a00-8a00-000000000003');     -- Driftmarch (pays best for engine/weapon parts)

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- two fresh players: uS (seller), uD (undocked).
do $$
declare u uuid; sk text;
begin
  foreach sk in array array['uS','uD'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'sv1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into sv1 values (sk, u);
  end loop;
end $$;

-- mirror production config a fresh disposable chain lacks (all reverted by ROLLBACK): reveal starter ports +
-- enable port-to-port movement. salvage_market_enabled stays OFF here (P0 proves the dark reject first).
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  insert into public.game_config(key,value,description)
    values('mainship_space_movement_enabled','true'::jsonb,'sv1 transient (rolled back)')
    on conflict (key) do update set value='true'::jsonb;
end $$;

-- commission each player's first ship (real RPC) → docked at Haven; grant uS loot via the REAL reward
-- pipeline leaf (reward_grant → inventory_deposit — the secured-combat-bundle deposit path, 0040/0041).
do $$
declare r jsonb; sk text; u uuid; uS uuid;
begin
  foreach sk in array array['uS','uD'] loop
    u := (select v from sv1 where sv1.k = sk);
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'SETUP FAIL first-ship %: %', sk, r; end if;
  end loop;
  uS := (select v from sv1 where k='uS');
  perform public.reward_grant('combat', gen_random_uuid(), uS, null,
    '{"items":[{"item_id":"scrap","quantity":6},{"item_id":"repair_parts","quantity":4}]}'::jsonb);
  if public.inventory_get_balance(uS, 'scrap') <> 6 or public.inventory_get_balance(uS, 'repair_parts') <> 4 then
    raise exception 'SETUP FAIL: reward_grant deposit did not land (scrap=% repair=%)',
      public.inventory_get_balance(uS, 'scrap'), public.inventory_get_balance(uS, 'repair_parts');
  end if;
  -- pre-create wallets at a KNOWN balance by direct owner insert (the tm1 funding precedent; rolled
  -- back) so every credit assert below is an EXACT delta, independent of wallet_ensure's seed.
  insert into public.player_wallet (player_id, balance) values
    ((select v from sv1 where k='uS'), 100),
    ((select v from sv1 where k='uD'), 100)
  on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- ════════ P0 — DARK gate: with salvage_market_enabled OFF, the sell RPC rejects and writes NOTHING. ════════
do $$
declare r jsonb; uS uuid := (select v from sv1 where k='uS'); v_ship uuid; v_bal numeric; n int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uS;
  select coalesce((select balance from public.player_wallet where player_id=uS), -1) into v_bal;

  r := pg_temp.call_as(uS, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'scrap', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'salvage_market_disabled' then raise exception 'P0 FAIL dark sell: %', r; end if;

  select count(*) into n from public.salvage_receipts where main_ship_id=v_ship;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % receipts', n; end if;
  if coalesce((select balance from public.player_wallet where player_id=uS), -1) <> v_bal then raise exception 'P0 FAIL dark path moved wallet'; end if;
  if public.inventory_get_balance(uS, 'scrap') <> 6 then raise exception 'P0 FAIL dark path moved inventory'; end if;

  -- enable the dark salvage capability ONLY inside this rolled-back txn (production flag stays false after ROLLBACK).
  update public.game_config set value='true'::jsonb where key='salvage_market_enabled';
  raise notice 'SV1_PASS_DARK_GATE ok: sell rejected salvage_market_disabled, zero writes (no receipt/wallet/inventory delta)';
end $$;

-- ════════ P1 — SEED pins: EXACTLY the approved 5-droppable × 3-port price table; progression items ABSENT. ════════
do $$
declare n int; v_run numeric;
begin
  -- exact-table pin: every (port, item, unit_price) below exists ACTIVE, and NOTHING else exists.
  with approved(loc, item_id, unit_price) as (values
    ((select v from sv1 where k='haven'), 'scrap',         5::numeric),
    ((select v from sv1 where k='haven'), 'pirate_alloy', 10::numeric),
    ((select v from sv1 where k='haven'), 'repair_parts', 20::numeric),
    ((select v from sv1 where k='haven'), 'engine_parts', 16::numeric),
    ((select v from sv1 where k='haven'), 'weapon_parts', 15::numeric),
    ((select v from sv1 where k='slag'),  'scrap',         8::numeric),
    ((select v from sv1 where k='slag'),  'pirate_alloy', 16::numeric),
    ((select v from sv1 where k='slag'),  'repair_parts', 12::numeric),
    ((select v from sv1 where k='slag'),  'engine_parts', 14::numeric),
    ((select v from sv1 where k='slag'),  'weapon_parts', 13::numeric),
    ((select v from sv1 where k='drift'), 'scrap',         6::numeric),
    ((select v from sv1 where k='drift'), 'pirate_alloy', 12::numeric),
    ((select v from sv1 where k='drift'), 'repair_parts', 16::numeric),
    ((select v from sv1 where k='drift'), 'engine_parts', 24::numeric),
    ((select v from sv1 where k='drift'), 'weapon_parts', 22::numeric))
  select count(*) into n from approved a
    full outer join public.port_item_demand d
      on d.location_id = a.loc and d.item_id = a.item_id and d.unit_price = a.unit_price and d.active
    where a.item_id is null or d.item_id is null;
  if n <> 0 then raise exception 'P1 FAIL: % row(s) diverge from the approved exact price table', n; end if;
  select count(*) into n from public.port_item_demand;
  if n <> 15 then raise exception 'P1 FAIL: expected exactly 15 demand rows, got %', n; end if;

  -- NEVER-SELLABLE pin (absence BY OMISSION): no demand row for any progression item, anywhere —
  -- by id AND by 0039 category (belt and braces).
  select count(*) into n from public.port_item_demand
    where item_id in ('captain_memory_shard','blueprint_fragment','artifact_core');
  if n <> 0 then raise exception 'P1 FAIL: % progression item demand row(s) exist (by id)', n; end if;
  select count(*) into n from public.port_item_demand d
    join public.item_types t on t.item_id = d.item_id where t.category = 'progression';
  if n <> 0 then raise exception 'P1 FAIL: % progression item demand row(s) exist (by category)', n; end if;

  -- drop-grounding pin: every demand item is one of the five 0041/0171 combat droppables.
  select count(*) into n from public.port_item_demand
    where item_id not in ('scrap','pirate_alloy','weapon_parts','engine_parts','repair_parts');
  if n <> 0 then raise exception 'P1 FAIL: % demand row(s) for non-combat-drop items', n; end if;

  -- the canonical-run band, recomputed from the live rows: 3 scrap + 1 alloy at Slagworks in 30..80.
  select 3 * (select unit_price from public.port_item_demand where location_id=(select v from sv1 where k='slag') and item_id='scrap')
       + (select unit_price from public.port_item_demand where location_id=(select v from sv1 where k='slag') and item_id='pirate_alloy')
    into v_run;
  if v_run < 30 or v_run > 80 then raise exception 'P1 FAIL: Snare-run sale % outside 30..80', v_run; end if;
  raise notice 'SV1_PASS_SEED_TABLE ok: exact 15-row price table pinned; progression absent (id+category); drop-grounded; Snare-run sale % in 30..80', v_run;
end $$;

-- ════════ P2 — SELL happy path: docked at Haven, sell 3 repair_parts @20 → wallet +60 EXACT, inventory 4→1, one receipt. ════════
do $$
declare r jsonb; uS uuid := (select v from sv1 where k='uS'); v_ship uuid; v_bal0 numeric; v_bal1 numeric;
  n int; v_req uuid := gen_random_uuid();
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uS;
  select balance into v_bal0 from public.player_wallet where player_id=uS;   -- known 100 (setup insert)

  r := pg_temp.call_as(uS, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'repair_parts', 3, v_req));
  if (r->>'ok')::boolean is not true then raise exception 'P2 FAIL sell: %', r; end if;
  -- Haven pays 20/repair_parts (its top-payer role) → unit_price 20, total 60 EXACT (qty x unit_price).
  if (r->>'unit_price')::numeric <> 20 or (r->>'total_price')::numeric <> 60 then raise exception 'P2 FAIL price: %', r; end if;
  if (r->>'location_id')::uuid is distinct from (select v from sv1 where k='haven') then raise exception 'P2 FAIL location: %', r; end if;

  -- wallet delta EXACT: qty × unit_price = +60, nothing else (the wallet pre-exists, so no ensure seed).
  select balance into v_bal1 from public.player_wallet where player_id=uS;
  if v_bal1 - v_bal0 <> 60 then raise exception 'P2 FAIL wallet delta % (want exactly +60)', v_bal1 - v_bal0; end if;

  -- inventory delta EXACT: repair_parts 4 → 1; scrap untouched at 6.
  if public.inventory_get_balance(uS, 'repair_parts') <> 1 then raise exception 'P2 FAIL inventory: repair_parts %', public.inventory_get_balance(uS, 'repair_parts'); end if;
  if public.inventory_get_balance(uS, 'scrap') <> 6 then raise exception 'P2 FAIL inventory: scrap moved'; end if;

  -- exactly ONE receipt row with the exact fields.
  select count(*) into n from public.salvage_receipts where main_ship_id=v_ship;
  if n <> 1 then raise exception 'P2 FAIL % receipts', n; end if;
  if not exists (select 1 from public.salvage_receipts
                   where main_ship_id=v_ship and request_id=v_req and item_id='repair_parts'
                     and qty=3 and unit_price=20 and total_price=60
                     and location_id=(select v from sv1 where k='haven')) then
    raise exception 'P2 FAIL receipt fields wrong';
  end if;

  insert into sv1 values ('sellreq', v_req);   -- stash for the idempotency replay
  raise notice 'SV1_PASS_SELL ok: docked sell 3 repair_parts @20 -> wallet +60 exact, inventory 4->1 exact, 1 receipt';
end $$;

-- ════════ P3 — idempotent replay: same (ship, request_id) → replayed, NO double credit/spend/receipt. ════════
do $$
declare r jsonb; uS uuid := (select v from sv1 where k='uS'); v_ship uuid; v_req uuid := (select v from sv1 where k='sellreq');
  v_bal0 numeric; nrec int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uS;
  select balance into v_bal0 from public.player_wallet where player_id=uS;
  select count(*) into nrec from public.salvage_receipts where main_ship_id=v_ship;

  r := pg_temp.call_as(uS, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'repair_parts', 3, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then raise exception 'P3 FAIL not replay: %', r; end if;
  if (r->>'total_price')::numeric <> 60 or (r->>'unit_price')::numeric <> 20 then raise exception 'P3 FAIL replay envelope: %', r; end if;

  if (select balance from public.player_wallet where player_id=uS) <> v_bal0 then raise exception 'P3 FAIL replay re-credited'; end if;
  if public.inventory_get_balance(uS, 'repair_parts') <> 1 then raise exception 'P3 FAIL replay re-spent'; end if;
  if (select count(*) from public.salvage_receipts where main_ship_id=v_ship) <> nrec then raise exception 'P3 FAIL replay wrote a receipt'; end if;
  raise notice 'SV1_PASS_IDEMPOTENT ok: replay -> idempotent_replay envelope verbatim, no double credit/spend/receipt';
end $$;

-- ════════ P4 — guards: invalid_quantity (zero/negative/fractional) · not_docked · no_demand · insufficient_items. ════════
do $$
declare r jsonb; uS uuid := (select v from sv1 where k='uS'); uD uuid := (select v from sv1 where k='uD');
  v_shipS uuid; v_shipD uuid; v_bal0 numeric; nrec int;
begin
  select main_ship_id into v_shipS from public.main_ship_instances where player_id=uS;
  select main_ship_id into v_shipD from public.main_ship_instances where player_id=uD;
  select balance into v_bal0 from public.player_wallet where player_id=uS;
  select count(*) into nrec from public.salvage_receipts where main_ship_id=v_shipS;

  -- ownership (M1 review pin): another player's ship id must fail closed as ship_not_found —
  -- mainship_resolve_owned_ship asserts ownership on explicit ids; zero writes on the reject.
  r := pg_temp.call_as(uS, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipD, 'scrap', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'ship_not_found' then raise exception 'P4 FAIL cross-player ship not rejected: %', r; end if;

  -- invalid_quantity: zero, negative, fractional (items are INTEGER quantities — never rounded).
  r := pg_temp.call_as(uS, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipS, 'scrap', 0, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_quantity' then raise exception 'P4 FAIL qty 0: %', r; end if;
  r := pg_temp.call_as(uS, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipS, 'scrap', -3, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_quantity' then raise exception 'P4 FAIL qty -3: %', r; end if;
  r := pg_temp.call_as(uS, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipS, 'scrap', 2.5, gen_random_uuid()));
  if (r->>'reason') is distinct from 'invalid_quantity' then raise exception 'P4 FAIL qty 2.5 (fractional must reject): %', r; end if;

  -- not_docked: uD departs toward Slagworks → in transit → the ONE docked-resolver returns null.
  r := pg_temp.call_as(uD, format('public.command_main_ship_space_move_to_location(%L::uuid, %L::uuid, %L::uuid)',
                                   (select v from sv1 where k='slag'), gen_random_uuid(), v_shipD));
  if (r->>'ok')::boolean is not true then raise exception 'P4 FAIL move uD: %', r; end if;
  r := pg_temp.call_as(uD, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipD, 'scrap', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'not_docked' then raise exception 'P4 FAIL in-transit not rejected: %', r; end if;

  -- no_demand: crystal is a REAL 0039 item with NO demand row at any port (it is a mining yield,
  -- not a combat drop) → the (port, item) demand lookup finds no row.
  r := pg_temp.call_as(uS, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipS, 'crystal', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'no_demand' then raise exception 'P4 FAIL crystal not no_demand: %', r; end if;

  -- insufficient_items: 99 scrap wanted, 6 held → envelope with have/need, nothing moved.
  r := pg_temp.call_as(uS, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_shipS, 'scrap', 99, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_items' then raise exception 'P4 FAIL not insufficient_items: %', r; end if;
  if (r->>'have')::int <> 6 or (r->>'need')::int <> 99 then raise exception 'P4 FAIL have/need: %', r; end if;

  -- ALL guards wrote nothing: wallet, inventory, receipts unchanged.
  if (select balance from public.player_wallet where player_id=uS) <> v_bal0 then raise exception 'P4 FAIL a guard moved the wallet'; end if;
  if public.inventory_get_balance(uS, 'scrap') <> 6 then raise exception 'P4 FAIL a guard moved inventory'; end if;
  if (select count(*) from public.salvage_receipts where main_ship_id=v_shipS) <> nrec then raise exception 'P4 FAIL a guard wrote a receipt'; end if;
  raise notice 'SV1_PASS_GUARDS ok: invalid_quantity (0/-3/2.5), in-transit not_docked, crystal no_demand, over-held insufficient_items — all zero-write';
end $$;

-- ════════ P5 — NEVER-SELLABLE: a HELD progression item still cannot be sold anywhere (no_demand). ════════
do $$
declare r jsonb; uS uuid := (select v from sv1 where k='uS'); v_ship uuid; v_bal0 numeric;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uS;
  -- grant ONE captain_memory_shard through the REAL pipeline (the 0171 drop rides this same path).
  perform public.reward_grant('combat', gen_random_uuid(), uS, null,
    '{"items":[{"item_id":"captain_memory_shard","quantity":1}]}'::jsonb);
  if public.inventory_get_balance(uS, 'captain_memory_shard') <> 1 then raise exception 'P5 FAIL shard grant'; end if;

  select balance into v_bal0 from public.player_wallet where player_id=uS;
  r := pg_temp.call_as(uS, format('public.sell_item_at_port(%L::uuid, %L, %s, %L::uuid)', v_ship, 'captain_memory_shard', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'no_demand' then raise exception 'P5 FAIL held shard sellable: %', r; end if;
  if public.inventory_get_balance(uS, 'captain_memory_shard') <> 1 then raise exception 'P5 FAIL shard consumed'; end if;
  if (select balance from public.player_wallet where player_id=uS) <> v_bal0 then raise exception 'P5 FAIL shard sale credited'; end if;
  raise notice 'SV1_PASS_NEVER_SELLABLE ok: held captain_memory_shard -> no_demand at every port (excluded by omission), zero writes';
end $$;

select 'SALVAGE-MARKET PROOF PASSED (dark gate; exact seed table + progression absence; sell atomic/idempotent; quantity/dock/demand/balance guards; never-sellable pin)' as result;

rollback;   -- leave ZERO persisted state: no wallet, inventory, receipt, ship, flag flip, or fixture user.
