-- Byeharu — TRADE-MARKET-1: player_wallet + trade_receipts (Trade-Market transactional tables; additive, DARK).
--
-- Second TRADE-MARKET-1 step: the two Trade-Market-OWNED transactional tables, in one coherent additive commit.
-- Both are owner-read and written ONLY by the forthcoming flag-gated buy/sell RPCs (none this step). They add
-- NOTHING to combat/movement/fleets/cargo; nothing reads or writes them yet — DARK.
--
-- ── TRADE-MARKET-1 DESIGN DECISIONS (planner authority; §2.6) ─────────────────────────────────────
-- 1) `player_wallet` is LAZY: the row is created ON DEMAND by the Trade-Market system (its ensure/credit path,
--    landing with the buy/sell RPCs) — NO seed here. The initial-credit source is a later balance/economy
--    concern, not this schema step. Owner-read only.
-- 2) `trade_receipts` finalizes §2.6's deferred offer/qty/price columns (side/good/location/qty/unit_price/
--    total_price/created_at), on top of the frozen (receipt_id, main_ship_id, request_id,
--    unique(main_ship_id, request_id)) idempotency shape. Keyed by `main_ship_id` (NEVER player_id) —
--    identity is derived THROUGH the ship, mirroring ship_cargo_lots and the per-ship idempotency of
--    main_ship_space_movements. No account-scoped/pooled trade read exists.
-- 3) Boundary: Trade Market is the SOLE writer of both tables. The market orchestrator will write
--    player_wallet + trade_receipts, write lots via Trade Cargo, and read/validate via Main Ship — a
--    one-directional fan-out. NO cycle, NO second writer to main_ship_instances.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): player_wallet, trade_receipts = Trade Market (owner; owner-read). Writes only
-- through Trade-Market SECURITY DEFINER RPCs — NONE this step. No client write path.

-- ── A. player_wallet — lazy, owner-read credit balance (one row per player, created on demand). ──
create table if not exists public.player_wallet (
  player_id  uuid    primary key references auth.users (id) on delete cascade,
  balance    numeric not null default 0 check (balance >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.player_wallet enable row level security;
-- Owner-read only (a player sees only their own wallet); granted to authenticated, NOT anon. NO insert/update/
-- delete policy and NO write grant → clients cannot mutate; Trade Market is sole writer (server-only RPCs).
create policy "player_wallet_select_own" on public.player_wallet
  for select using (player_id = auth.uid());
grant select on public.player_wallet to authenticated;

-- ── B. trade_receipts — per-ship idempotent trade record (keyed by main_ship_id; NEVER player_id). ──
create table if not exists public.trade_receipts (
  receipt_id  uuid    primary key default gen_random_uuid(),
  main_ship_id uuid   not null references public.main_ship_instances (main_ship_id),  -- NEVER player_id
  request_id  uuid    not null,
  side        text    not null check (side in ('buy','sell')),
  good_id     text    not null references public.trade_goods (good_id),
  location_id uuid    references public.locations (id),                 -- the station the trade occurred at
  qty         numeric not null check (qty > 0),                         -- in denomination units
  unit_price  numeric not null check (unit_price >= 0),                 -- per-unit credits at trade time
  total_price numeric not null check (total_price >= 0),                -- qty * unit_price at trade time
  created_at  timestamptz not null default now(),
  unique (main_ship_id, request_id)                                     -- per-ship idempotency key (§2.6)
);

-- Owner-scoped receipt lookups join on main_ship_id (the unique (main_ship_id, request_id) index already
-- covers idempotency probes).
create index if not exists trade_receipts_main_ship_id_idx on public.trade_receipts (main_ship_id);

alter table public.trade_receipts enable row level security;
-- Owner-read via join to the owning ship (no direct player_id column to leak a pooled read); granted to
-- authenticated, NOT anon. NO client write policy/grant → Trade Market is sole writer (server-only RPCs).
create policy "trade_receipts_select_own" on public.trade_receipts
  for select using (
    exists (
      select 1 from public.main_ship_instances m
      where m.main_ship_id = trade_receipts.main_ship_id
        and m.player_id = auth.uid()
    )
  );
grant select on public.trade_receipts to authenticated;
