-- Byeharu — TRADE-MARKET-1: market_offers price catalog (Reference/Config; additive, DARK).
--
-- First step of TRADE-MARKET-1, mirroring how TRADE-FLEET-0C began with trade_goods (0073): a pure
-- Reference/Config catalog of per-station buy/sell prices. It adds NOTHING to combat, movement, fleets,
-- or the main-ship/cargo schema. This table is DARK: nothing reads or writes it yet.
--
-- ── TRADE-MARKET-1 DESIGN DECISIONS (planner authority; §1b/§2.1/§2.6/§3) ─────────────────────────
-- 1) The WHOLE market capability ships DARK + server-rejected via a NEW game_config boolean
--    `trade_market_enabled` (default false), added ALONGSIDE the buy/sell/get-offers RPCs (next step);
--    those RPCs reject when it is false. It is NOT set true here (no flag lands this step).
-- 2) `market_offers` = Reference/Config (migration/admin-seeded, public read, NO client write). V1 prices
--    are STATIC config (dynamic pricing is future). One row per (location_id, good_id) carrying the
--    station's `buy_price` (credits the station PAYS the player when the player SELLS to it) and
--    `sell_price` (credits the player PAYS when BUYING from it), with a non-negative spread
--    (sell_price >= buy_price).
-- 3) The transactional tables (`player_wallet`, `trade_receipts`) are Trade-Market-owned and land NEXT;
--    cargo lots are written via Trade Cargo (§2.1). The market orchestrator will be a one-directional
--    fan-out (validate via Main Ship → write lots via Trade Cargo → debit Wallet → record receipts) —
--    NO cycle, NO second writer to any other system's table.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES §2.1): market_offers = Reference/Config (migration/admin sole writer;
-- public read-only). Server owns ALL prices; no client write path.

create table if not exists public.market_offers (
  offer_id    uuid    primary key default gen_random_uuid(),
  location_id uuid    not null references public.locations (id),      -- locations PK is `id`
  good_id     text    not null references public.trade_goods (good_id),
  buy_price   numeric not null check (buy_price > 0),   -- credits the STATION PAYS the player when the player SELLS to it
  sell_price  numeric not null check (sell_price > 0),  -- credits the PLAYER PAYS when BUYING from the station
  active      boolean not null default true,
  unique (location_id, good_id),                        -- one offer per station per good
  check (sell_price >= buy_price)                       -- non-negative spread (station never sells cheaper than it buys)
);

-- Every buy/sell RPC resolves offers for one docked station → index the per-location lookup.
create index if not exists market_offers_location_id_idx on public.market_offers (location_id);

alter table public.market_offers enable row level security;
-- Public read-only; NO insert/update/delete policy and NO write grant → clients cannot mutate.
-- Only migrations / service_role (admin) write.
create policy "market_offers_public_read" on public.market_offers for select using (true);
grant select on public.market_offers to anon, authenticated;

-- ── Seed the six §1c goods at Haven Reach (the canonical starter/commission port, 0066/port_entry). ──
-- Prices are CONSERVATIVE, BALANCE-NON-FINAL PLACEHOLDERS (buy/sell, credits), each carrying a spread;
-- final market balance is a later TRADE-MARKET-1 concern. Haven Reach id is the c_haven constant used by
-- port_entry_commission_writer.
insert into public.market_offers (location_id, good_id, buy_price, sell_price) values
  ('b1a00001-0066-4a00-8a00-000000000001', 'textiles',       8,  10),
  ('b1a00001-0066-4a00-8a00-000000000001', 'ore',           16,  20),
  ('b1a00001-0066-4a00-8a00-000000000001', 'provisions',    12,  15),
  ('b1a00001-0066-4a00-8a00-000000000001', 'reagents',      40,  50),
  ('b1a00001-0066-4a00-8a00-000000000001', 'machinery',     80, 100),
  ('b1a00001-0066-4a00-8a00-000000000001', 'luxury_goods', 160, 200)
on conflict (location_id, good_id) do nothing;
