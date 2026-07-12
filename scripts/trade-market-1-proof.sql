-- TRADE-MARKET-1 — disposable REAL-CHAIN proof (runs on the actual chain 0001..0091 in a throwaway Supabase).
-- Proves the atomic trade surface (get_market_offers / market_buy / market_sell) + the priced add-ship debit.
-- Fixture users carry the 'tm1.' email prefix. The ENTIRE proof runs inside ONE transaction that ROLLBACKs —
-- it persists NO wallet, lot, receipt, ship, or flag flip. No production access. No COMMIT anywhere.
--
-- ── DARK-CAPABILITY EXERCISE (sanctioned; never crosses a flag human-gate) ────────────────────────
-- The harness enables trade_market_enabled + mainship_additional_commission_enabled ONLY inside this
-- rolled-back transaction to exercise the dark trade + add-ship capabilities; the ROLLBACK reverts them, so
-- the committed/production flag values stay false. It also transiently mirrors production config a fresh chain
-- lacks (reveal_starter_ports + mainship_space_movement_enabled=true) and transiently perturbs an offer price
-- (P6 FIFO) — ALL reverted by ROLLBACK. Wallets are funded by a direct owner insert into player_wallet (the
-- harness runs as the DB owner, bypassing RLS) — also rolled back.

\set ON_ERROR_STOP on

begin;   -- everything below is transient; the trailing ROLLBACK leaves ZERO persisted state.

create temp table tm1(k text primary key, v uuid) on commit preserve rows;
insert into tm1 values
  ('haven','b1a00001-0066-4a00-8a00-000000000001'),     -- Haven (commission port; seeded market_offers)
  ('slag', 'b1a00002-0066-4a00-8a00-000000000002');     -- Slagworks (a different active port)

-- caller helper: set the authenticated subject then run an RPC, returning its jsonb.
create or replace function pg_temp.call_as(p_sub uuid, p_fn text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub::text, 'role','authenticated')::text, true);
  execute 'select ' || p_fn into v;
  return v;
end $$;

-- four fresh players: uT (trader), uD (no-dock), uP (poor), uA (affluent add-ship).
do $$
declare u uuid; k text;
begin
  foreach k in array array['uT','uD','uP','uA'] loop
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated',
              'tm1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
      returning id into u;
    insert into tm1 values (k, u);
  end loop;
end $$;

-- mirror production config a fresh disposable chain lacks (all reverted by ROLLBACK): reveal starter ports +
-- enable the port-to-port movement domain. trade_market_enabled stays OFF here (P0 proves the dark reject first).
do $$
declare r jsonb;
begin
  r := public.reveal_starter_ports();
  if (r->>'ok')::boolean is not true then raise exception 'SETUP FAIL: reveal_starter_ports %', r; end if;
  insert into public.game_config(key,value,description)
    values('mainship_space_movement_enabled','true'::jsonb,'tm1 transient (rolled back)')
    on conflict (key) do update set value='true'::jsonb;
end $$;

-- commission each player's first ship (real RPC) → docked at Haven; fund wallets by direct owner insert.
do $$
-- loop var named sk, NOT k: a plpgsql variable `k` is ambiguous against tm1's `k` column inside the
-- queries below (plpgsql variable_conflict=error). Latent until the 0C step first went green
-- 2026-07-12 — this block had never executed in CI.
declare r jsonb; sk text; u uuid;
begin
  foreach sk in array array['uT','uD','uP','uA'] loop
    u := (select v from tm1 where tm1.k = sk);
    r := pg_temp.call_as(u, 'public.commission_first_main_ship()');
    if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'SETUP FAIL first-ship %: %', sk, r; end if;
  end loop;
  -- fund: trader/no-dock/affluent rich; poor keeps 5 credits (buys nothing meaningful).
  insert into public.player_wallet (player_id, balance) values
    ((select v from tm1 where k='uT'), 100000),
    ((select v from tm1 where k='uD'), 100000),
    ((select v from tm1 where k='uP'), 5),
    ((select v from tm1 where k='uA'), 100000)
  on conflict (player_id) do update set balance = excluded.balance;
end $$;

-- ════════ P0 — DARK gate: with trade_market_enabled OFF, every trade RPC rejects and writes nothing. ════════
do $$
declare r jsonb; uT uuid := (select v from tm1 where k='uT'); v_ship uuid; v_bal numeric; n int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uT;
  select balance into v_bal from public.player_wallet where player_id=uT;

  r := pg_temp.call_as(uT, format('public.get_market_offers(%L::uuid)', v_ship));
  if (r->>'reason') is distinct from 'trade_market_disabled' then raise exception 'P0 FAIL offers: %', r; end if;
  r := pg_temp.call_as(uT, format('public.market_buy(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'trade_market_disabled' then raise exception 'P0 FAIL buy: %', r; end if;
  r := pg_temp.call_as(uT, format('public.market_sell(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'trade_market_disabled' then raise exception 'P0 FAIL sell: %', r; end if;

  select count(*) into n from public.ship_cargo_lots where main_ship_id=v_ship;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % lots', n; end if;
  select count(*) into n from public.trade_receipts where main_ship_id=v_ship;
  if n <> 0 then raise exception 'P0 FAIL dark path wrote % receipts', n; end if;
  if (select balance from public.player_wallet where player_id=uT) <> v_bal then raise exception 'P0 FAIL dark path moved wallet'; end if;

  -- enable the dark trade capability ONLY inside this rolled-back txn (production flag stays false after ROLLBACK).
  update public.game_config set value='true'::jsonb where key='trade_market_enabled';
  raise notice 'TM1_PASS_DARK_GATE ok: offers/buy/sell rejected trade_market_disabled, zero writes';
end $$;

-- ════════ P1 — get_market_offers: docked → six Haven offers; non-docked → not_docked. ════════
do $$
declare r jsonb; uT uuid := (select v from tm1 where k='uT'); uD uuid := (select v from tm1 where k='uD');
  v_shipT uuid; v_shipD uuid;
begin
  select main_ship_id into v_shipT from public.main_ship_instances where player_id=uT;
  select main_ship_id into v_shipD from public.main_ship_instances where player_id=uD;

  r := pg_temp.call_as(uT, format('public.get_market_offers(%L::uuid)', v_shipT));
  if (r->>'ok')::boolean is not true then raise exception 'P1 FAIL offers not ok: %', r; end if;
  if (r->>'location_id')::uuid is distinct from (select v from tm1 where k='haven') then raise exception 'P1 FAIL wrong location: %', r; end if;
  if jsonb_array_length(r->'offers') <> 6 then raise exception 'P1 FAIL expected 6 Haven offers, got %', r->'offers'; end if;

  -- move uD to Slagworks → in transit → not docked.
  r := pg_temp.call_as(uD, format('public.command_main_ship_space_move_to_location(%L::uuid, %L::uuid, %L::uuid)',
                                   (select v from tm1 where k='slag'), gen_random_uuid(), v_shipD));
  if (r->>'ok')::boolean is not true then raise exception 'P1 FAIL move uD: %', r; end if;
  r := pg_temp.call_as(uD, format('public.get_market_offers(%L::uuid)', v_shipD));
  if (r->>'reason') is distinct from 'not_docked' then raise exception 'P1 FAIL non-docked not rejected: %', r; end if;
  raise notice 'TM1_PASS_OFFERS ok: docked → 6 offers at Haven; in-transit → not_docked';
end $$;

-- ════════ P2 — buy atomic: one lot, one receipt, wallet debited by sell_price*qty. ════════
do $$
declare r jsonb; uT uuid := (select v from tm1 where k='uT'); v_ship uuid; v_bal0 numeric; v_bal1 numeric;
  n int; v_lotqty numeric; v_lotcost numeric; v_req uuid := gen_random_uuid();
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uT;
  select balance into v_bal0 from public.player_wallet where player_id=uT;

  r := pg_temp.call_as(uT, format('public.market_buy(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 3, v_req));
  if (r->>'ok')::boolean is not true or (r->>'side') <> 'buy' then raise exception 'P2 FAIL buy: %', r; end if;
  -- ore seeded 16/20 → unit_price (sell_price)=20, total=60.
  if (r->>'unit_price')::numeric <> 20 or (r->>'total_price')::numeric <> 60 then raise exception 'P2 FAIL price: %', r; end if;

  select count(*), coalesce(max(qty),0), coalesce(max(unit_cost_basis),0) into n, v_lotqty, v_lotcost
    from public.ship_cargo_lots where main_ship_id=v_ship and good_id='ore';
  if n <> 1 or v_lotqty <> 3 or v_lotcost <> 20 then raise exception 'P2 FAIL lot (n=% qty=% cost=%)', n, v_lotqty, v_lotcost; end if;
  select count(*) into n from public.trade_receipts where main_ship_id=v_ship and side='buy';
  if n <> 1 then raise exception 'P2 FAIL % buy receipts', n; end if;
  select balance into v_bal1 from public.player_wallet where player_id=uT;
  if v_bal0 - v_bal1 <> 60 then raise exception 'P2 FAIL wallet delta % (want 60)', v_bal0 - v_bal1; end if;

  insert into tm1 values ('buyreq', v_req);   -- stash for the idempotency replay
  raise notice 'TM1_PASS_BUY ok: 1 lot (qty 3 @ cost 20), 1 buy receipt, wallet -60';
end $$;

-- ════════ P3 — buy idempotency: same (ship, request_id) → replay, no second lot/receipt, no further debit. ════════
do $$
declare r jsonb; uT uuid := (select v from tm1 where k='uT'); v_ship uuid; v_req uuid := (select v from tm1 where k='buyreq');
  v_bal0 numeric; nlot int; nrec int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uT;
  select balance into v_bal0 from public.player_wallet where player_id=uT;
  select count(*) into nlot from public.ship_cargo_lots where main_ship_id=v_ship;
  select count(*) into nrec from public.trade_receipts where main_ship_id=v_ship;

  r := pg_temp.call_as(uT, format('public.market_buy(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 3, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then raise exception 'P3 FAIL not replay: %', r; end if;

  if (select count(*) from public.ship_cargo_lots where main_ship_id=v_ship) <> nlot then raise exception 'P3 FAIL replay wrote a lot'; end if;
  if (select count(*) from public.trade_receipts where main_ship_id=v_ship) <> nrec then raise exception 'P3 FAIL replay wrote a receipt'; end if;
  if (select balance from public.player_wallet where player_id=uT) <> v_bal0 then raise exception 'P3 FAIL replay re-charged'; end if;
  raise notice 'TM1_PASS_BUY_IDEMPOTENT ok: replay → idempotent_replay, no 2nd lot/receipt, no re-debit';
end $$;

-- ════════ P4 — buy volume check: qty*unit_volume_m3 > cargo_capacity_m3 → insufficient_volume, no write. ════════
do $$
declare r jsonb; uT uuid := (select v from tm1 where k='uT'); v_ship uuid; v_bal0 numeric; nlot int; nrec int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uT;
  select balance into v_bal0 from public.player_wallet where player_id=uT;
  select count(*) into nlot from public.ship_cargo_lots where main_ship_id=v_ship;
  select count(*) into nrec from public.trade_receipts where main_ship_id=v_ship;

  -- cap = 50 m³, ore = 1.0 m³/unit, already 3 used → buying 60 → 63 > 50.
  r := pg_temp.call_as(uT, format('public.market_buy(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 60, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_volume' then raise exception 'P4 FAIL not volume-rejected: %', r; end if;
  if (r->>'capacity_m3')::numeric <> 50 then raise exception 'P4 FAIL capacity_m3 %', r; end if;

  if (select count(*) from public.ship_cargo_lots where main_ship_id=v_ship) <> nlot then raise exception 'P4 FAIL wrote a lot'; end if;
  if (select count(*) from public.trade_receipts where main_ship_id=v_ship) <> nrec then raise exception 'P4 FAIL wrote a receipt'; end if;
  if (select balance from public.player_wallet where player_id=uT) <> v_bal0 then raise exception 'P4 FAIL moved wallet'; end if;
  raise notice 'TM1_PASS_VOLUME ok: over-capacity buy → insufficient_volume, zero writes';
end $$;

-- ════════ P5 — buy credit check: cost > wallet balance → insufficient_credits, no write. ════════
do $$
declare r jsonb; uP uuid := (select v from tm1 where k='uP'); v_ship uuid; nlot int; nrec int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uP;   -- uP balance = 5
  r := pg_temp.call_as(uP, format('public.market_buy(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 1, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_credits' then raise exception 'P5 FAIL not credit-rejected: %', r; end if;

  select count(*) into nlot from public.ship_cargo_lots where main_ship_id=v_ship;
  select count(*) into nrec from public.trade_receipts where main_ship_id=v_ship;
  if nlot <> 0 or nrec <> 0 then raise exception 'P5 FAIL wrote (lots=% receipts=%)', nlot, nrec; end if;
  if (select balance from public.player_wallet where player_id=uP) <> 5 then raise exception 'P5 FAIL moved wallet'; end if;
  raise notice 'TM1_PASS_CREDITS ok: over-budget buy → insufficient_credits, zero writes, wallet intact';
end $$;

-- ════════ P6 — sell + FIFO margin: two lots at different cost, sell across the boundary; margin from consumed cost. ════════
do $$
declare r jsonb; uT uuid := (select v from tm1 where k='uT'); v_ship uuid; v_bal0 numeric; v_bal1 numeric;
  v_req uuid := gen_random_uuid(); v_lot2qty numeric; n int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uT;   -- has lot1: 3 ore @ cost 20

  -- transiently raise ore sell_price at Haven so the SECOND buy lands a lot at a different cost basis (rolled back).
  update public.market_offers set sell_price = 30 where location_id=(select v from tm1 where k='haven') and good_id='ore';
  r := pg_temp.call_as(uT, format('public.market_buy(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 2, gen_random_uuid()));
  if (r->>'ok')::boolean is not true or (r->>'unit_price')::numeric <> 30 then raise exception 'P6 FAIL 2nd buy: %', r; end if;
  -- now: lot1 (3 @ 20, older) + lot2 (2 @ 30, newer) = 5 ore.

  select balance into v_bal0 from public.player_wallet where player_id=uT;
  -- SELL 4 ore at buy_price=16 → FIFO consumes lot1(3@20) + 1 of lot2(1@30) → cost_basis = 3*20 + 1*30 = 90.
  r := pg_temp.call_as(uT, format('public.market_sell(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 4, v_req));
  if (r->>'ok')::boolean is not true or (r->>'side') <> 'sell' then raise exception 'P6 FAIL sell: %', r; end if;
  if (r->>'unit_price')::numeric <> 16 or (r->>'total_price')::numeric <> 64 then raise exception 'P6 FAIL sell price: %', r; end if;
  if (r->>'cost_basis_consumed')::numeric <> 90 then raise exception 'P6 FAIL cost basis % (want 90)', r->>'cost_basis_consumed'; end if;
  if (r->>'realized_margin')::numeric <> (64 - 90) then raise exception 'P6 FAIL margin % (want -26)', r->>'realized_margin'; end if;

  -- FIFO consumed oldest first: lot1 (cost 20) gone, lot2 (cost 30) reduced to qty 1.
  if exists (select 1 from public.ship_cargo_lots where main_ship_id=v_ship and good_id='ore' and unit_cost_basis=20) then raise exception 'P6 FAIL oldest lot not consumed first'; end if;
  select coalesce(sum(qty),0) into v_lot2qty from public.ship_cargo_lots where main_ship_id=v_ship and good_id='ore';
  if v_lot2qty <> 1 then raise exception 'P6 FAIL remaining ore % (want 1)', v_lot2qty; end if;
  select count(*) into n from public.trade_receipts where main_ship_id=v_ship and side='sell';
  if n <> 1 then raise exception 'P6 FAIL % sell receipts', n; end if;
  select balance into v_bal1 from public.player_wallet where player_id=uT;
  if v_bal1 - v_bal0 <> 64 then raise exception 'P6 FAIL wallet credit % (want 64)', v_bal1 - v_bal0; end if;

  insert into tm1 values ('sellreq', v_req);   -- stash for the idempotency replay
  raise notice 'TM1_PASS_SELL_FIFO ok: FIFO oldest-first, credit +64, realized_margin -26 from consumed cost 90';
end $$;

-- ════════ P7 — sell idempotency + insufficient cargo. ════════
do $$
declare r jsonb; uT uuid := (select v from tm1 where k='uT'); v_ship uuid; v_req uuid := (select v from tm1 where k='sellreq');
  v_bal0 numeric; v_ore numeric; nrec int;
begin
  select main_ship_id into v_ship from public.main_ship_instances where player_id=uT;
  select balance into v_bal0 from public.player_wallet where player_id=uT;
  select coalesce(sum(qty),0) into v_ore from public.ship_cargo_lots where main_ship_id=v_ship and good_id='ore';   -- = 1
  select count(*) into nrec from public.trade_receipts where main_ship_id=v_ship;

  -- replay the same sell → idempotent, no double-credit, no double-consume.
  r := pg_temp.call_as(uT, format('public.market_sell(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 4, v_req));
  if (r->>'ok')::boolean is not true or (r->>'idempotent_replay')::boolean is not true then raise exception 'P7 FAIL not replay: %', r; end if;
  if (select balance from public.player_wallet where player_id=uT) <> v_bal0 then raise exception 'P7 FAIL replay re-credited'; end if;
  if (select coalesce(sum(qty),0) from public.ship_cargo_lots where main_ship_id=v_ship and good_id='ore') <> v_ore then raise exception 'P7 FAIL replay re-consumed'; end if;
  if (select count(*) from public.trade_receipts where main_ship_id=v_ship) <> nrec then raise exception 'P7 FAIL replay wrote a receipt'; end if;

  -- sell more than held → insufficient_cargo, no write (only 1 ore left).
  r := pg_temp.call_as(uT, format('public.market_sell(%L::uuid, %L, %s, %L::uuid)', v_ship, 'ore', 10, gen_random_uuid()));
  if (r->>'reason') is distinct from 'insufficient_cargo' then raise exception 'P7 FAIL not cargo-rejected: %', r; end if;
  if (r->>'available')::numeric <> 1 then raise exception 'P7 FAIL available % (want 1)', r->>'available'; end if;
  if (select balance from public.player_wallet where player_id=uT) <> v_bal0 then raise exception 'P7 FAIL cargo-reject moved wallet'; end if;
  if (select coalesce(sum(qty),0) from public.ship_cargo_lots where main_ship_id=v_ship and good_id='ore') <> v_ore then raise exception 'P7 FAIL cargo-reject consumed'; end if;
  raise notice 'TM1_PASS_SELL_GUARDS ok: sell replay idempotent; over-held sell → insufficient_cargo, zero writes';
end $$;

-- ════════ P8 — priced add-ship (§1b): funded → ok + wallet -main_ship_price; too poor → insufficient_credits, no ship/debit. ════════
do $$
declare r jsonb; uA uuid := (select v from tm1 where k='uA'); uP uuid := (select v from tm1 where k='uP');
  v_price numeric; v_bal0 numeric; v_bal1 numeric; nA0 int; nA1 int; nP0 int; nP1 int; pbal0 numeric;
begin
  update public.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';
  v_price := coalesce((select (value #>> '{}')::numeric from public.game_config where key='main_ship_price'), 1000);

  -- funded affluent player → additional ship succeeds; wallet drops by exactly the price.
  select count(*) into nA0 from public.main_ship_instances where player_id=uA;
  select balance into v_bal0 from public.player_wallet where player_id=uA;
  r := pg_temp.call_as(uA, 'public.commission_additional_main_ship()');
  if (r->>'ok')::boolean is not true or (r->>'created')::boolean is not true then raise exception 'P8 FAIL add-ship: %', r; end if;
  if (r->>'price')::numeric <> v_price then raise exception 'P8 FAIL price in payload % (want %)', r->>'price', v_price; end if;
  select count(*) into nA1 from public.main_ship_instances where player_id=uA;
  select balance into v_bal1 from public.player_wallet where player_id=uA;
  if nA1 <> nA0 + 1 then raise exception 'P8 FAIL ship count % → %', nA0, nA1; end if;
  if v_bal0 - v_bal1 <> v_price then raise exception 'P8 FAIL wallet delta % (want %)', v_bal0 - v_bal1, v_price; end if;

  -- too-poor player (uP, balance 5 << price) → insufficient_credits, NO new ship, NO debit; first ship stays free.
  select count(*) into nP0 from public.main_ship_instances where player_id=uP;
  select balance into pbal0 from public.player_wallet where player_id=uP;
  r := pg_temp.call_as(uP, 'public.commission_additional_main_ship()');
  if (r->>'reason') is distinct from 'insufficient_credits' then raise exception 'P8 FAIL poor not credit-rejected: %', r; end if;
  select count(*) into nP1 from public.main_ship_instances where player_id=uP;
  if nP1 <> nP0 or nP0 <> 1 then raise exception 'P8 FAIL poor got a ship (% → %)', nP0, nP1; end if;
  if (select balance from public.player_wallet where player_id=uP) <> pbal0 then raise exception 'P8 FAIL poor was debited'; end if;
  raise notice 'TM1_PASS_ADD_SHIP_PRICE ok: funded add-ship debits main_ship_price; too-poor → insufficient_credits, no ship/debit; first ship free';
end $$;

select 'TRADE-MARKET-1 PROOF PASSED (dark gate; get_offers; buy atomic/idempotent/volume/credit; sell FIFO-margin/idempotent/cargo; priced add-ship §1b)' as result;

rollback;   -- leave ZERO persisted state: no wallet, lot, receipt, ship, flag flip, offer change, or fixture user.
