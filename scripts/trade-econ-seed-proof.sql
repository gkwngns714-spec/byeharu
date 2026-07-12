-- TRADE-ECON-SEED-1 — disposable REAL-CHAIN proof (runs on the actual chain incl. 0173 in a throwaway Supabase).
-- Proves the differentiated three-port economy seed: all 18 market_offers rows (3 starter ports × 6 goods)
-- carry EXACTLY the owner-approved price table; 3+ routes are profitable (recomputed from the seeded rows,
-- never hardcode-trusted); the anti-pump spread holds on every row; and the port role identities are real
-- (Slagworks is the cheapest ore seller; Driftmarch pays the most for machinery).
--
-- READ-ONLY over Reference/Config: it toggles NO server flag, provisions NO fixture user/ship, and
-- writes NOTHING — but still runs inside ONE transaction that ROLLBACKs, per the trade-proof idiom.
-- Price semantics (0085): buy_price = station PAYS the player (player SELLS); sell_price = the player PAYS
-- (player BUYS). Route direction law: profitable route = dest.buy_price > origin.sell_price.

\set ON_ERROR_STOP on

begin;   -- read-only, but the trailing ROLLBACK guarantees ZERO persisted state regardless.

-- ════════ E1 — MULTIPORT: all 18 rows present, ACTIVE, at exactly the approved prices. ════════
do $$
declare
  v_bad int; v_n int;
begin
  with expected(location_id, good_id, buy_price, sell_price) as (values
    -- Haven Reach (city/consumer)
    ('b1a00001-0066-4a00-8a00-000000000001'::uuid, 'textiles',       8::numeric,  10::numeric),
    ('b1a00001-0066-4a00-8a00-000000000001', 'ore',           16,  20),
    ('b1a00001-0066-4a00-8a00-000000000001', 'provisions',    12,  15),
    ('b1a00001-0066-4a00-8a00-000000000001', 'reagents',      40,  50),
    ('b1a00001-0066-4a00-8a00-000000000001', 'machinery',     80, 100),
    ('b1a00001-0066-4a00-8a00-000000000001', 'luxury_goods', 160, 200),
    -- Slagworks Anchorage (industrial)
    ('b1a00002-0066-4a00-8a00-000000000002', 'textiles',      11,  14),
    ('b1a00002-0066-4a00-8a00-000000000002', 'ore',            9,  12),
    ('b1a00002-0066-4a00-8a00-000000000002', 'provisions',    19,  24),
    ('b1a00002-0066-4a00-8a00-000000000002', 'reagents',      44,  48),
    ('b1a00002-0066-4a00-8a00-000000000002', 'machinery',     70,  88),
    ('b1a00002-0066-4a00-8a00-000000000002', 'luxury_goods', 230, 280),
    -- Driftmarch Waypost (frontier)
    ('b1a00003-0066-4a00-8a00-000000000003', 'textiles',      12,  15),
    ('b1a00003-0066-4a00-8a00-000000000003', 'ore',           14,  18),
    ('b1a00003-0066-4a00-8a00-000000000003', 'provisions',    20,  25),
    ('b1a00003-0066-4a00-8a00-000000000003', 'reagents',      60,  75),
    ('b1a00003-0066-4a00-8a00-000000000003', 'machinery',    120, 150),
    ('b1a00003-0066-4a00-8a00-000000000003', 'luxury_goods', 250, 310)
  )
  select count(*) into v_bad
    from expected e
    left join public.market_offers o
      on o.location_id = e.location_id and o.good_id = e.good_id and o.active
    where o.offer_id is null
       or o.buy_price  <> e.buy_price
       or o.sell_price <> e.sell_price;
  if v_bad <> 0 then raise exception 'E1 FAIL: % of 18 seeded rows missing/inactive/price-mismatched', v_bad; end if;

  -- exactly 6 active offers per port over the six goods (no dupes possible — unique(location_id, good_id)).
  select count(*) into v_n from public.market_offers
    where location_id in ('b1a00001-0066-4a00-8a00-000000000001',
                          'b1a00002-0066-4a00-8a00-000000000002',
                          'b1a00003-0066-4a00-8a00-000000000003')
      and good_id in ('textiles','ore','provisions','reagents','machinery','luxury_goods')
      and active;
  if v_n <> 18 then raise exception 'E1 FAIL: expected 18 active offers across the 3 ports, got %', v_n; end if;
  raise notice 'ES1_PASS_MULTIPORT ok: 18/18 active rows match the approved 3-port x 6-good price table exactly';
end $$;

-- ════════ E2 — ROUTES: 3 concrete profitable routes, recomputed from the seeded rows. ════════
-- profit/unit = dest.buy_price - origin.sell_price (player buys at origin sell, sells at dest buy).
do $$
declare
  c_haven constant uuid := 'b1a00001-0066-4a00-8a00-000000000001';
  c_slag  constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_drift constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  v_profit numeric;
  route_profit numeric[] := '{}';   -- collected recomputed profits (route_profit independent-computation)
begin
  -- (a) ore: Slagworks (sell 12) → Haven (buy 16) → +4/unit.
  select h.buy_price - s.sell_price into v_profit
    from public.market_offers s, public.market_offers h
    where s.location_id = c_slag and s.good_id = 'ore' and s.active
      and h.location_id = c_haven and h.good_id = 'ore' and h.active;
  if v_profit is null or v_profit <= 0 then raise exception 'E2 FAIL ore Slag->Haven profit % (want > 0)', v_profit; end if;
  if v_profit <> 4 then raise exception 'E2 FAIL ore Slag->Haven profit % (approved table says +4)', v_profit; end if;
  route_profit := route_profit || v_profit;

  -- (b) provisions: Haven (sell 15) → Slagworks (buy 19) → +4/unit.
  select s.buy_price - h.sell_price into v_profit
    from public.market_offers h, public.market_offers s
    where h.location_id = c_haven and h.good_id = 'provisions' and h.active
      and s.location_id = c_slag and s.good_id = 'provisions' and s.active;
  if v_profit is null or v_profit <= 0 then raise exception 'E2 FAIL provisions Haven->Slag profit % (want > 0)', v_profit; end if;
  if v_profit <> 4 then raise exception 'E2 FAIL provisions Haven->Slag profit % (approved table says +4)', v_profit; end if;
  route_profit := route_profit || v_profit;

  -- (c) machinery: Slagworks (sell 88) → Driftmarch (buy 120) → +32/unit.
  select d.buy_price - s.sell_price into v_profit
    from public.market_offers s, public.market_offers d
    where s.location_id = c_slag and s.good_id = 'machinery' and s.active
      and d.location_id = c_drift and d.good_id = 'machinery' and d.active;
  if v_profit is null or v_profit <= 0 then raise exception 'E2 FAIL machinery Slag->Drift profit % (want > 0)', v_profit; end if;
  if v_profit <> 32 then raise exception 'E2 FAIL machinery Slag->Drift profit % (approved table says +32)', v_profit; end if;
  route_profit := route_profit || v_profit;

  if array_length(route_profit, 1) < 3 then raise exception 'E2 FAIL: fewer than 3 profitable routes'; end if;
  raise notice 'ES1_PASS_ROUTES ok: 3 recomputed profitable routes — ore Slag->Haven +4, provisions Haven->Slag +4, machinery Slag->Drift +32 (profit = dest.buy - origin.sell)';
end $$;

-- ════════ E3 — ANTIPUMP: sell_price >= buy_price on EVERY seeded row (spread never negative). ════════
do $$
declare v_bad int;
begin
  select count(*) into v_bad from public.market_offers
    where location_id in ('b1a00001-0066-4a00-8a00-000000000001',
                          'b1a00002-0066-4a00-8a00-000000000002',
                          'b1a00003-0066-4a00-8a00-000000000003')
      and sell_price < buy_price;   -- anti_pump invariant (also a table CHECK; asserted independently here)
  if v_bad <> 0 then raise exception 'E3 FAIL: % row(s) violate the anti-pump spread', v_bad; end if;
  raise notice 'ES1_PASS_ANTIPUMP ok: sell_price >= buy_price holds on every seeded row at all 3 ports';
end $$;

-- ════════ E4 — ROLES: the port identities are real in the data, not just in comments. ════════
do $$
declare
  c_slag  constant uuid := 'b1a00002-0066-4a00-8a00-000000000002';
  c_drift constant uuid := 'b1a00003-0066-4a00-8a00-000000000003';
  v_id uuid;
begin
  -- Slagworks (industrial) is the strictly cheapest ore SELLER (min sell_price) among the 3 ports.
  select location_id into v_id from public.market_offers
    where good_id = 'ore' and active
      and location_id in ('b1a00001-0066-4a00-8a00-000000000001', c_slag, c_drift)
    order by sell_price asc limit 1;
  if v_id is distinct from c_slag then raise exception 'E4 FAIL: cheapest ore seller is %, want Slagworks', v_id; end if;

  -- Driftmarch (frontier) PAYS the most for machinery (max buy_price) among the 3 ports.
  select location_id into v_id from public.market_offers
    where good_id = 'machinery' and active
      and location_id in ('b1a00001-0066-4a00-8a00-000000000001', c_slag, c_drift)
    order by buy_price desc limit 1;
  if v_id is distinct from c_drift then raise exception 'E4 FAIL: top machinery payer is %, want Driftmarch', v_id; end if;
  raise notice 'ES1_PASS_ROLES ok: Slagworks is the cheapest ore seller; Driftmarch pays the most for machinery';
end $$;

select 'TRADE-ECON-SEED PROOF PASSED (18-row multiport table exact; 3 recomputed profitable routes; anti-pump on all rows; port roles real)' as result;

rollback;   -- read-only anyway; guarantees zero persisted state.
