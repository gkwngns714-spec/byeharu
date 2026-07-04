-- Byeharu — RANKING-P17 SLICE 1: the standings (leaderboard) schema
-- (table + RLS + leaderboard index + comments ONLY; NO scoring function, NO season-management
-- writer, NO read RPC, NO frontend; the feature stays fully DARK behind `ranking_enabled=false`
-- from 0127 — NOTHING can write this table yet, and no reader references it).
--
-- Mirrors the prior schema-only slices (0118 captain_instances / 0108 module_instances) for the
-- table/RLS/index/comment style, deviating where the Phase-17 locked decisions require it: this is
-- a PUBLIC-READ leaderboard state table (not owner-read), and NO writer function is created THIS
-- slice — the sole writer is Ranking's OWN future season-scoring function (a later slice), exactly
-- as `ranking_seasons` (0127) has its writer deferred.
--
-- Phase 17 "Ranking / competition … reads finalized events; reset by season, not deletion"
-- (ROADMAP :92). `ranking_standings` is the per-player, per-season, per-dimension SCORE row Ranking
-- computes (in a later slice) by reading `reward_grants` DOWNWARD.
--
-- SELF-APPROVED LOCKED DESIGN DECISIONS (owner-directed 2026-07-04; recorded in docs/DEV_LOG.md
-- this slice so later slices are grounded):
--   1. DIMENSION MAPS 1:1 TO THE READ SOURCE — NO TRANSLATION LAYER. `dimension` is exactly the
--      `reward_grants.source_type` domain: the closed activity-source set `('combat','trade',
--      'exploration','mining')` established by the 0096 `fleet_movements_reward_source_type_domain`
--      CHECK (the carrier that feeds `reward_grant(source_type,…)`). The scoring fn will read a
--      grant's `source_type` and fold it into the row of the SAME literal — no lookup, no mapping.
--      A future activity source is an additive forward-only CHECK change here + at 0096, in lockstep.
--      (Live depositors today: combat/exploration/mining call `reward_grant` directly; `trade` is in
--      the domain but has NO depositor yet — Trade V1 banks via the Wallet path, not `reward_grants`
--      — so its standings stay 0 until a trade activity deposits a grant. Including it now keeps the
--      dimension domain 1:1 with the source and matches ROADMAP "combat/trade/explore/mine".)
--   2. ONE SCORE ROW PER (season_id, player_id, dimension). The PK is that triple. The "OVERALL"
--      ranking is DERIVED AT READ TIME (sum of a player's dimension scores within a season), NEVER a
--      stored denormalized row — so there is no second write path to keep in sync (one place the
--      score lives per dimension; overall is a pure read-time aggregate).
--   3. INCREMENTAL, IDEMPOTENT ACCRUAL via `last_counted_at` — the high-water mark of the latest
--      `reward_grants.granted_at` already folded into this row. The future scoring fn accrues only
--      grants with `granted_at > last_counted_at` (advancing the mark in the same write), so a
--      re-run never double-counts and never re-reads old events. This is the standings analogue of
--      the securing processors' `secured_at` idempotency mark (0100/0105).
--   4. NO WRITER THIS SLICE. Created with RLS on + a PUBLIC-READ select policy (leaderboards are
--      public) + NO insert/update/delete policy + NO write grant. The SOLE writer is Ranking's OWN
--      future season-scoring function (a later slice: `SECURITY DEFINER`, client-revoked). No RPC
--      reads or writes this table yet — dark, inert.
--   5. RESET BY SEASON, NEVER BY DELETION. A reset is a NEW `season_id` scoping a FRESH standings
--      set; old standings rows (and the finalized `reward_grants` they were computed from) are never
--      deleted. The `on delete cascade` on `season_id` is a schema-integrity guard for an
--      intentionally-removed season, NOT the reset mechanism (reset = new season, old kept).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced in the SAME step): §1 matrix gains `ranking_standings`
-- under the existing **Ranking** system (sole writer = the future scoring fn; public read-only; DARK
-- behind `ranking_enabled`), adjacent to `ranking_seasons`; the §2 Ranking row's Owns is extended.
-- Ranking remains a READ-ONLY downward leaf: no writer to `reward_grants` or any activity table, and
-- the `reward_grants` read lands in a later slice, so the call graph is unchanged and acyclic.
-- No flag flipped; `0001–0127` unedited; forward-only.

-- ── ranking_standings — per-(season, player, dimension) score row (Ranking; public read-only) ──────
-- `dimension` = the reward_grants.source_type domain (the 0096 closed set), 1:1 with the read source.
create table public.ranking_standings (
  season_id       uuid not null references public.ranking_seasons (season_id) on delete cascade,
  player_id       uuid not null references auth.users (id) on delete cascade,
  dimension       text not null
                    check (dimension in ('combat', 'trade', 'exploration', 'mining')),
  score           numeric not null default 0,
  events_counted  integer not null default 0,
  -- high-water mark: the latest reward_grants.granted_at already folded into this row. NULL until
  -- the first grant is counted. The future scoring fn accrues only granted_at > last_counted_at and
  -- advances it in the same write — incremental + idempotent (the 0100/0105 secured_at analogue).
  last_counted_at timestamptz,
  updated_at      timestamptz not null default now(),
  primary key (season_id, player_id, dimension)
);

-- Leaderboard read index: rank a season's dimension by descending score (the future read RPC's
-- access path — one dimension's board within a season, best first).
create index ranking_standings_leaderboard_idx
  on public.ranking_standings (season_id, dimension, score desc);

alter table public.ranking_standings enable row level security;
-- Public read-only (leaderboards are public — the ranking_seasons 0127 posture); NO
-- insert/update/delete policy and NO write grant → clients cannot mutate. The SOLE writer is
-- Ranking's OWN future season-scoring function (a later slice; SECURITY DEFINER, client-revoked).
-- NOTHING reads or writes this table yet.
create policy "ranking_standings_public_read" on public.ranking_standings for select using (true);
grant select on public.ranking_standings to anon, authenticated;

comment on table public.ranking_standings is
  'RANKING-P17: per-(season_id, player_id, dimension) leaderboard score row. `dimension` is exactly '
  'the reward_grants.source_type domain (the 0096 closed activity-source set; 1:1, no translation). '
  'ONE row per (season, player, dimension); the OVERALL ranking is DERIVED at read time (sum across '
  'dimensions), NEVER a stored denormalized row (no second write path to sync). Sole writer = '
  'Ranking''s OWN future season-scoring function (a later slice; SECURITY DEFINER, client-revoked); '
  'public read-only. DARK behind `ranking_enabled` — no writer/reader exists yet. Scores reset BY '
  'SEASON (a new `season_id` scopes a fresh standings set; old rows and the `reward_grants` they '
  'were computed from are never deleted — ROADMAP :92).';
comment on column public.ranking_standings.last_counted_at is
  'RANKING-P17: high-water mark — the latest reward_grants.granted_at already folded into this row '
  '(NULL until the first grant is counted). The future scoring fn accrues only grants with '
  'granted_at > last_counted_at and advances the mark in the same write, so a re-run never '
  'double-counts and never re-reads old events (the 0100/0105 secured_at idempotency analogue).';
