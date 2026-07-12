-- Byeharu — ECON-SEED-1: differentiated three-port economy seed (Reference/Config; additive, DARK).
--
-- Queue slice #4 of the full-capacity plan: seeds the owner-approved multiport price table (master plan
-- §C P1) into `market_offers` (0085) for ALL THREE starter ports (0066) × the six 0073 goods, so that
-- trade activation (ACT-TRADE, queue #5) lights up a real buy-low/travel/sell-high economy instead of a
-- single-port market. PURE SEED: no schema change, no RPC change, no flag change, no client change.
-- Trade stays DARK (`trade_market_enabled=false`); `market_offers` remains static Reference/Config with
-- NO runtime writer (0136's price drift composes a multiplier at read time and never writes here).
--
-- Depends ONLY on: locations (0066 fixed port UUIDs), trade_goods (0073), market_offers (0085).
-- Independent of 0171/0172 content by design.
--
-- ── Port role identities (price semantics: buy_price = station PAYS the player when the player SELLS;
--    sell_price = the player PAYS when BUYING; check (sell_price >= buy_price) = anti-pump spread) ──────
--   Haven      b1a00001-… (city/consumer): pays well for ore + provisions consumption; baseline elsewhere.
--   Slagworks  b1a00002-… (industrial):    sells ore cheap (the cheapest ore seller); pays for its
--                                          provisions + machinery inputs.
--   Driftmarch b1a00003-… (frontier):      pays premiums for everything (top machinery payer) but sells
--                                          little cheaply.
--
-- Haven reconciliation: 0085's Haven placeholder rows ALREADY equal the approved table (8/10, 16/20,
-- 12/15, 40/50, 80/100, 160/200) — the upsert below converges them with ZERO price deltas; the
-- `do update` arm exists so any future divergence (e.g. a hotfixed price) still converges to the
-- approved table on re-apply (idempotent).

insert into public.market_offers (location_id, good_id, buy_price, sell_price) values
  -- Haven Reach — city/consumer (identical to the 0085 placeholder; re-asserted here as the approved table).
  ('b1a00001-0066-4a00-8a00-000000000001', 'textiles',       8,  10),
  ('b1a00001-0066-4a00-8a00-000000000001', 'ore',           16,  20),
  ('b1a00001-0066-4a00-8a00-000000000001', 'provisions',    12,  15),
  ('b1a00001-0066-4a00-8a00-000000000001', 'reagents',      40,  50),
  ('b1a00001-0066-4a00-8a00-000000000001', 'machinery',     80, 100),
  ('b1a00001-0066-4a00-8a00-000000000001', 'luxury_goods', 160, 200),
  -- Slagworks Anchorage — industrial (cheap ore out; pays for provisions/machinery inputs).
  ('b1a00002-0066-4a00-8a00-000000000002', 'textiles',      11,  14),
  ('b1a00002-0066-4a00-8a00-000000000002', 'ore',            9,  12),
  ('b1a00002-0066-4a00-8a00-000000000002', 'provisions',    19,  24),
  ('b1a00002-0066-4a00-8a00-000000000002', 'reagents',      44,  48),
  ('b1a00002-0066-4a00-8a00-000000000002', 'machinery',     70,  88),
  ('b1a00002-0066-4a00-8a00-000000000002', 'luxury_goods', 230, 280),
  -- Driftmarch Waypost — frontier (pays premiums; sells dear).
  ('b1a00003-0066-4a00-8a00-000000000003', 'textiles',      12,  15),
  ('b1a00003-0066-4a00-8a00-000000000003', 'ore',           14,  18),
  ('b1a00003-0066-4a00-8a00-000000000003', 'provisions',    20,  25),
  ('b1a00003-0066-4a00-8a00-000000000003', 'reagents',      60,  75),
  ('b1a00003-0066-4a00-8a00-000000000003', 'machinery',    120, 150),
  ('b1a00003-0066-4a00-8a00-000000000003', 'luxury_goods', 250, 310)
on conflict (location_id, good_id) do update
  set buy_price  = excluded.buy_price,
      sell_price = excluded.sell_price,
      active     = true;

-- ── Self-assert: the seeded economy is complete, spread-safe, and actually profitable to sail. ─────────
-- Route direction law: the player BUYS at the origin station's sell_price and SELLS at the destination
-- station's buy_price → a route is profitable iff dest.buy_price > origin.sell_price.
do $$
declare
  c_haven constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  c_slag  constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_drift constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  v_goods constant text[] := array['textiles','ore','provisions','reagents','machinery','luxury_goods'];
  v_n int;
  v_profit numeric;
begin
  -- 1. Completeness: each of the three ports carries exactly one ACTIVE offer per seeded good (6 each).
  select count(*) into v_n from unnest(array[c_haven, c_slag, c_drift]) p
    where (select count(*) from public.market_offers o
             where o.location_id = p and o.good_id = any(v_goods) and o.active) <> 6;
  if v_n <> 0 then
    raise exception 'ECON-SEED-1 self-assert FAIL: % starter port(s) do not carry exactly 6 active offers', v_n;
  end if;

  -- 2. Anti-pump invariant on EVERY seeded row (belt-and-braces beside the table CHECK constraint).
  select count(*) into v_n from public.market_offers
    where location_id in (c_haven, c_slag, c_drift) and good_id = any(v_goods)
      and sell_price < buy_price;
  if v_n <> 0 then
    raise exception 'ECON-SEED-1 self-assert FAIL: % seeded row(s) violate sell_price >= buy_price', v_n;
  end if;

  -- 3. Three CONCRETE profitable routes, recomputed from the seeded rows (dest.buy > origin.sell):
  --    (a) ore:       buy at Slagworks sell 12 → sell at Haven buy 16      (+4/unit)
  select h.buy_price - s.sell_price into v_profit
    from public.market_offers s, public.market_offers h
    where s.location_id = c_slag  and s.good_id = 'ore'
      and h.location_id = c_haven and h.good_id = 'ore';
  if v_profit is null or v_profit <= 0 then
    raise exception 'ECON-SEED-1 self-assert FAIL: ore route Slagworks→Haven not profitable (profit=%)', v_profit;
  end if;

  --    (b) provisions: buy at Haven sell 15 → sell at Slagworks buy 19     (+4/unit)
  select s.buy_price - h.sell_price into v_profit
    from public.market_offers h, public.market_offers s
    where h.location_id = c_haven and h.good_id = 'provisions'
      and s.location_id = c_slag  and s.good_id = 'provisions';
  if v_profit is null or v_profit <= 0 then
    raise exception 'ECON-SEED-1 self-assert FAIL: provisions route Haven→Slagworks not profitable (profit=%)', v_profit;
  end if;

  --    (c) machinery: buy at Slagworks sell 88 → sell at Driftmarch buy 120 (+32/unit)
  select d.buy_price - s.sell_price into v_profit
    from public.market_offers s, public.market_offers d
    where s.location_id = c_slag  and s.good_id = 'machinery'
      and d.location_id = c_drift and d.good_id = 'machinery';
  if v_profit is null or v_profit <= 0 then
    raise exception 'ECON-SEED-1 self-assert FAIL: machinery route Slagworks→Driftmarch not profitable (profit=%)', v_profit;
  end if;

  raise notice 'ECON-SEED-1 self-assert ok: 3 ports x 6 active offers; anti-pump holds on all rows; 3 concrete profitable routes (ore Slag->Haven, provisions Haven->Slag, machinery Slag->Drift)';
end $$;
