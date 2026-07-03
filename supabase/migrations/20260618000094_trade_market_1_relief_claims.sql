-- Byeharu — TRADE-MARKET-1: no-softlock relief floor — ledger table + config + dark flag (additive, DARK).
--
-- Schema/config/flag slice of the relief floor: the Trade-Market-OWNED `trade_relief_claims` ledger plus the
-- relief tunables and the dark `trade_relief_enabled` gate. NO RPC and NO writer land here — the table starts
-- dark with no writer, exactly as `player_wallet`/`trade_receipts` did in 0086. Nothing reads or writes it yet.
--
-- ── TRADE-MARKET-1 DESIGN DECISIONS (planner authority) ───────────────────────────────────────────
-- 1) OWNERSHIP = Trade Market (mirrors `trade_receipts`). Trade Market is the economy orchestrator that ALREADY
--    fans out DOWNWARD to Wallet (credit), Trade Cargo (lots), and Main Ship (read). Siting relief here adds ZERO
--    new cross-system edges and keeps Wallet a pure downward leaf. The forthcoming relief orchestrator will grant
--    the relief credit THROUGH `wallet_credit` (Wallet stays the sole `player_wallet` writer) and write ONLY its
--    own `trade_relief_claims` — no second writer to any table, no cycle.
-- 2) IDEMPOTENT + ANTI-FARM SHAPE: keyed by (player_id, request_id) unique so a retried claim is a no-op replay.
--    The tunables below bound farming — a minimum cooldown between claims and a lifetime cap — while still
--    guaranteeing a genuine-softlock player can always recover. The (player_id, claimed_at) index supports the
--    cooldown/lifetime-cap lookups the RPC will do (next step).
-- 3) Account-scoped (keyed by player_id, NOT ship): relief is an account-level softlock recovery, not a per-ship
--    action — so unlike `trade_receipts` (per-ship) the owner-read policy is a direct `player_id = auth.uid()`.
--
-- OWNERSHIP (SYSTEM_BOUNDARIES): trade_relief_claims = Trade Market (owner; owner-read). Written ONLY through a
-- forthcoming Trade-Market SECURITY DEFINER RPC — NONE this step. No client write path. DARK behind
-- trade_relief_enabled (default false); no flag is set true.

-- ── A. trade_relief_claims — per-player idempotent relief ledger (account-scoped; owner-read). ──
create table if not exists public.trade_relief_claims (
  claim_id   uuid    primary key default gen_random_uuid(),
  player_id  uuid    not null references auth.users (id) on delete cascade,
  request_id uuid    not null,                                    -- idempotency key (per-player)
  amount     numeric not null check (amount >= 0),                -- credits granted at claim time
  claimed_at timestamptz not null default now(),
  unique (player_id, request_id)                                  -- per-player idempotent claim key
);

-- Supports the cooldown (most-recent claim) + lifetime-cap (count per player) lookups the relief RPC will do.
create index if not exists trade_relief_claims_player_claimed_idx
  on public.trade_relief_claims (player_id, claimed_at);

alter table public.trade_relief_claims enable row level security;
-- Owner-read only (a player sees only their own claims); granted to authenticated, NOT anon. NO insert/update/
-- delete policy and NO write grant → clients cannot mutate; Trade Market is sole writer (server-only RPC).
create policy "trade_relief_claims_select_own" on public.trade_relief_claims
  for select using (player_id = auth.uid());
grant select on public.trade_relief_claims to authenticated;

-- ── B. Relief tunables (Reference/Config; server-owned, no client write; numeric-seed idiom of 0003). ──
insert into public.game_config (key, value, description) values
  ('relief_credits', '250',
   'TRADE-MARKET-1: credit grant per no-softlock relief claim. Placeholder economy value.'),
  ('relief_cooldown_seconds', '86400',
   'TRADE-MARKET-1: minimum seconds between relief claims per player (24h) — prevents rapid re-farming.'),
  ('relief_max_lifetime_claims', '3',
   'TRADE-MARKET-1: lifetime cap on relief claims per player — bounds total relief while still guaranteeing '
   'genuine-softlock recovery.')
on conflict (key) do nothing;

-- ── C. Dark relief gate (OFF on live; bool-flag idiom of 0070). The relief RPC (next step) rejects while false. ──
insert into public.game_config (key, value, description) values
  ('trade_relief_enabled', 'false',
   'TRADE-MARKET-1: server-authoritative gate for the no-softlock relief claim RPC. '
   'OFF on live — dark until a human gate flips it.')
on conflict (key) do nothing;
