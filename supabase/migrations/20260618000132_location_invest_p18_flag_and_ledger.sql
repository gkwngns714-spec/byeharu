-- Byeharu — LOCATION-INVEST-P18 SLICE 0: the dark capability flag + the Location-Investment-owned
-- persistent root table `location_investments` (foundations only — NO writer function, NO invest
-- command, NO read RPC, NO aggregate read surface, NO frontend, NO cron, NOTHING client-writable,
-- NO tunables beyond the flag, NO flag flipped true).
--
-- Phase 18 "Location investment (seasonal investment score vs persistent state)" (ROADMAP :93 —
-- guard "no infinite exploit") introduces Location Investment as a NEW, DARK, downward LEAF owner.
-- Grounded in the one-directional pipeline: a player spends credits DOWNWARD into a location and the
-- system records an append-only contribution — Investment never mutates another system's state. Its
-- credit sink (a later slice) is the internal Wallet writer `wallet_debit(player, amount)` (0093 —
-- row-locking conditional debit, cannot overdraw, internal/no client grant); its target-validity
-- source is the Map-owned `locations` (0002; `locations.id` is the PK — confirmed). Investment reads
-- both DOWNWARD in a later slice; it adds NO writer to `player_wallet`, `locations`, or any other
-- system's table, EVER.
--
-- SELF-APPROVED LOCKED DESIGN DECISIONS (owner-directed 2026-07-04; recorded in docs/DEV_LOG.md this
-- slice so later slices are grounded):
--   1. PERSISTENT STATE = the all-time SUM of contributions per location (its "development") —
--      DERIVED from this append-only ledger (sum by location_id), monotonic, never deleted. There is
--      NO denormalized aggregate column/table (no second write path to keep in sync — the Ranking
--      "OVERALL is derived at read time" stance, 0131).
--   2. SEASONAL SCORE = the SUM of a player's contributions within the CURRENT season WINDOW, where
--      the window is derived DETERMINISTICALLY from config (a period length + epoch tunable) in the
--      read slice that consumes it. NO season table and NO season-open writer — Investment does NOT
--      duplicate Ranking's `ranking_season_open` season machinery (the no-duplication hard rule) and
--      introduces NO cross-system season coupling to Ranking. "Reset by season, not deletion"
--      (ROADMAP law) is honored STRUCTURALLY: a new window resets the windowed SCORE read while the
--      ledger (persistent state) is never touched. (The season-window/min-amount tunables are NOT
--      seeded this slice — they land in the slice that consumes them; no dead config.)
--   3. NO INFINITE EXPLOIT (the ROADMAP guard) = investment is a strict ONE-WAY SINK. `amount` is
--      CHECK (> 0); the future invest command debits credits via `wallet_debit` DOWNWARD and appends
--      a row. There is NO withdrawal path and NO payout returning value, so score/development can
--      never be farmed in a loop. Structurally reinforced: the ledger is append-only, owner-read,
--      client-unwritable.
--   4. NO WRITER THIS SLICE. `location_investments` is created with RLS on + an OWNER-READ select
--      policy (`player_id = auth.uid()`) and `grant select to authenticated` ONLY — NO insert/
--      update/delete policy + NO write grant, so clients cannot mutate. The SOLE writer is
--      Investment's OWN future invest command (a later slice: `SECURITY DEFINER`, client-revoked).
--      Individual contribution rows stay owner-read; public per-location development + seasonal
--      leaderboards are exposed LATER via `security definer` aggregate read RPCs (the Ranking
--      public-aggregate posture, 0131 — an aggregate leaks no other player's raw rows). No RPC reads
--      or writes this table yet — it exists dark, inert.
--   5. FLAG — `location_investment_enabled` seeded 'false', the exact 0097/0102/0107/0117/0124/0127
--      slice-0 flag idiom, including the server-side `feature_disabled` rejection posture EVERY
--      future Investment RPC must adopt (check FIRST, reject-before-any-read while false). This
--      migration does not flip any flag true.
--
-- RECEIPT-IDIOM MATCH (verified, not guessed — the confirmed per-player idempotency-ledger shape):
--   `player_id uuid not null references auth.users (id) on delete cascade` and `request_id text not
--   null` with `unique (player_id, request_id)` — mirrored POINT-FOR-POINT from `module_craft_receipts`
--   (0109:58–66); investment is non-spatial per-player, so it takes the PLAYER-scoped receipt keying,
--   NOT the ship-scoped `main_ship_space_command_receipts`/`trade_receipts` keying.
--
-- RLS/grants — verified, not assumed: `location_investments` copies the owner-read receipt posture
-- (RLS enabled, ONE owner-read select policy `player_id = auth.uid()`, `grant select to authenticated`
-- only — NOT anon, NO insert/update/delete policy and NO write grant → clients cannot mutate; sole
-- writer is Investment's own future SECURITY DEFINER command). The game_config row inherits the
-- table-wide public-read posture ("game_config_public_read" — 0003:13–15). No function is created
-- here, so no execute-surface relock is needed (0054/0127 precedent). The table is inert: no RPC, no
-- reader, no writer references it yet.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced in the SAME step — the 0098/0103/0127 precedent for
-- table-creating slices): §1 matrix gains `location_investments` under the NEW **Location Investment**
-- system (sole writer = the future Investment invest command; owner read; DARK behind
-- `location_investment_enabled`), and §2 gains the Location Investment system row (a NEW DARK downward
-- LEAF). Leaves `0001–0131` unedited; forward-only. NO cross-system edge exists yet (the Wallet debit
-- + Map read land in a later slice), so the call graph is unchanged and acyclic.

-- ── (a) the dark capability gate (OFF / inert; no writer/reader exists yet) ───────────────────────
insert into public.game_config (key, value, description) values
  ('location_investment_enabled', 'false',
   'LOCATION-INVEST-P18: server-authoritative dark gate for Phase-18 location investment — a player '
   'spends credits into a location, recorded as an append-only contribution (persistent development '
   '= all-time sum per location; seasonal score = windowed sum). OFF until the feature is explicitly '
   'enabled by the owner. Every Investment RPC must check this FIRST and reject-before-any-read while '
   'false; the UI surface stays hidden independently (fails closed both sides).')
on conflict (key) do nothing;

-- ── (b) location_investments — the Location-Investment-owned root table (owner read, no writer yet) ─
-- APPEND-ONLY, monotonic per-contribution ledger. Persistent development is DERIVED (sum by
-- location_id); seasonal score is DERIVED (sum by player_id within a config-derived window) — no
-- denormalized aggregate is stored (no second write path). Contributions are strictly positive (the
-- one-way sink — no infinite exploit); the ledger is never deleted or truncated to "reset".
create table public.location_investments (
  investment_id uuid primary key default gen_random_uuid(),
  player_id     uuid not null references auth.users (id) on delete cascade,
  request_id    text not null,                                        -- idempotency key (per-player)
  location_id   uuid not null references public.locations (id),       -- the Map-owned target (id = PK)
  amount        numeric not null check (amount > 0),                  -- strictly positive: the one-way sink
  invested_at   timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  unique (player_id, request_id)                                      -- per-player idempotent invest key
);
-- Supporting indexes for the two derived reads (later slices):
--   · sum-by-location (persistent development, all-time) — leads on location_id.
--   · sum-by-player-within-a-time-window (seasonal score) — leads on player_id, then invested_at.
-- (The unique (player_id, request_id) index covers idempotency probes + owner lookups; it does NOT
--  serve the windowed range scan, so the (player_id, invested_at) index is not redundant.)
create index location_investments_by_location on public.location_investments (location_id, invested_at);
create index location_investments_by_player_window on public.location_investments (player_id, invested_at);

alter table public.location_investments enable row level security;
-- Owner-read only (the 0109 module_craft_receipts posture verbatim); granted to authenticated, NOT
-- anon. NO insert/update/delete policy and NO write grant → clients cannot mutate; Investment is sole
-- writer (its own future SECURITY DEFINER command). Public per-location/seasonal aggregates arrive
-- later via SECURITY DEFINER aggregate read RPCs (the 0131 public-aggregate posture), not raw rows.
create policy "location_investments_select_own" on public.location_investments
  for select using (player_id = auth.uid());
grant select on public.location_investments to authenticated;

comment on table public.location_investments is
  'LOCATION-INVEST-P18: the Location-Investment-owned root table — an APPEND-ONLY, monotonic '
  'per-contribution ledger (Investment is the SOLE writer via its own future invest command, not '
  'migration-seeded; owner-read). PERSISTENT STATE (a location''s development) = the all-time SUM of '
  'contributions per location, DERIVED from this ledger (never a denormalized column). SEASONAL SCORE '
  '= the SUM of a player''s contributions within a config-derived season WINDOW (no season table — '
  'reset-by-season is a new window over the untouched ledger, not deletion). NO INFINITE EXPLOIT: '
  'amount > 0 and investment is a strict one-way SINK (credits in via wallet_debit, no withdrawal / '
  'no payout). DARK behind `location_investment_enabled` (every future Investment RPC '
  'rejects-before-any-read while the flag is false). No writer/reader references this table yet — it '
  'exists dark, inert.';
