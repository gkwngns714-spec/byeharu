-- Byeharu — RANKING-P17 SLICE 0: the dark capability flag + the Ranking-owned root table
-- `ranking_seasons` (foundations only — NO scoring function, NO standings table, NO read RPC, NO
-- season-management writer, NO frontend, NOTHING client-writable, NO flag flipped true).
--
-- Phase 17 "Ranking / competition (weekly/monthly seasons; combat/trade/explore/mine)"
-- (ROADMAP :92 — "reads finalized events; reset by season, not deletion") introduces Ranking as a
-- NEW, DARK, READ-ONLY downward leaf owner. Grounded in the one-directional pipeline (ROADMAP §3):
--   activity → pending → secure-on-return → inventory → progression → **Ranking READS finalized
--   result events** — Ranking never mutates another system's state. Its finalized-event source
--   (later slices) is the idempotent reward ledger `reward_grants` (0015; UNIQUE (source_type,
--   source_id) — one row per SECURED activity result, `source_type` in the closed activity domain
--   ('combat','exploration','mining','trade') per 0096, `player_id` the leaderboard subject,
--   `granted_at` the season-window field). Ranking reads that DOWNWARD in a later slice; it adds NO
--   writer to `reward_grants` or any activity table, EVER.
--
-- SELF-APPROVED LOCKED DESIGN DECISIONS (owner-directed 2026-07-04; recorded in docs/DEV_LOG.md
-- this slice so later slices are grounded):
--   1. A SEASON is a named scoring WINDOW per cadence. Both a weekly AND a monthly season may run
--      concurrently over the SAME finalized events (independent leaderboards) — cadence is part of
--      the identity, not mutually exclusive. This is the direct reading of ROADMAP "weekly/monthly
--      seasons".
--   2. RESET-BY-SEASON, NEVER BY DELETION (ROADMAP law). A "reset" is a NEW season row scoping a new
--      window; the finalized event data (`reward_grants`) is never deleted or truncated. The season
--      row is the scoping mechanism, so scores partition by `[starts_at, ends_at)` without touching
--      any event.
--   3. AT MOST ONE `active` season PER CADENCE at a time (a partial unique index) — the "one active
--      window" invariant; `upcoming`/`closed` seasons are unconstrained (history + scheduling).
--   4. NO WRITER THIS SLICE. `ranking_seasons` is created with RLS on + a public-read select policy
--      (leaderboards/season info are public reads — the 0107/0117 catalog-posture read stance) and
--      NO insert/update/delete policy + NO write grant. The SOLE writer is Ranking's OWN future
--      season-management function (a later slice: `SECURITY DEFINER`, client-revoked). No RPC reads
--      or writes this table yet — it exists dark, inert.
--   5. FLAG — `ranking_enabled` seeded 'false', the exact 0097/0102/0107/0117/0124 slice-0 flag
--      idiom, including the server-side `feature_disabled` rejection posture EVERY future Ranking
--      scoring/read/season RPC must adopt (check FIRST, reject-before-any-read while false). This
--      migration does not flip any flag true.
--
-- RLS/grants — verified, not assumed: `ranking_seasons` copies the public-read catalog posture
-- (RLS enabled, ONE public-read select policy, `grant select to anon, authenticated`, NO
-- insert/update/delete policy and NO write grant → clients cannot mutate) EXCEPT it is NOT
-- migration-seeded catalog data — its rows are created at runtime by Ranking's own future writer
-- only. The game_config row inherits the table-wide public-read posture ("game_config_public_read"
-- — 0003:13–15). No function is created here, so no execute-surface relock is needed (0054
-- precedent). The table is inert: no RPC, no reader, no writer references it yet.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced in the SAME step — the 0098/0103/0117 precedent for
-- table-creating slices): §1 matrix gains `ranking_seasons` under the NEW **Ranking** system (sole
-- writer = the future Ranking season fn; public read-only; DARK behind `ranking_enabled`), and §2
-- gains the Ranking system row (a READ-ONLY downward leaf consumer of finalized events). Leaves
-- `0001–0126` unedited; forward-only. No cross-system edge exists yet (the `reward_grants` read
-- lands in a later slice), so the call graph is unchanged and acyclic.

-- ── (a) the dark capability gate (OFF / inert; no writer/reader exists yet) ───────────────────────
insert into public.game_config (key, value, description) values
  ('ranking_enabled', 'false',
   'RANKING-P17: server-authoritative dark gate for Phase-17 ranking/competition — seasons and '
   'leaderboards scored from finalized reward events (READ-ONLY downward consumer of `reward_grants`). '
   'OFF until the feature is explicitly enabled by the owner. Every Ranking scoring/read/season RPC '
   'must check this FIRST and reject-before-any-read while false; the UI surface stays hidden '
   'independently (fails closed both sides).')
on conflict (key) do nothing;

-- ── (b) ranking_seasons — the Ranking-owned root table (Ranking; public read-only, no writer yet) ──
-- A season is a named scoring WINDOW per cadence. A weekly and a monthly season may run concurrently
-- over the same finalized events (independent leaderboards). Reset-by-season = a NEW row scoping a
-- new window; event data (`reward_grants`) is NEVER deleted.
create table public.ranking_seasons (
  season_id  uuid primary key default gen_random_uuid(),
  cadence    text not null check (cadence in ('weekly', 'monthly')),
  label      text not null,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  status     text not null default 'upcoming' check (status in ('upcoming', 'active', 'closed')),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

-- At most ONE active season per cadence at a time (the "one active window" invariant). Upcoming and
-- closed seasons are unconstrained (history + scheduling).
create unique index ranking_seasons_one_active_per_cadence
  on public.ranking_seasons (cadence) where status = 'active';

alter table public.ranking_seasons enable row level security;
-- Public read-only; NO insert/update/delete policy and NO write grant → clients cannot mutate.
-- The SOLE writer is Ranking's OWN future season-management function (a later slice; SECURITY
-- DEFINER, client-revoked). Leaderboards/season info are public reads (the 0107/0117 catalog read
-- posture), so a public-read select policy is correct even though rows are runtime-created, not seeded.
create policy "ranking_seasons_public_read" on public.ranking_seasons for select using (true);
grant select on public.ranking_seasons to anon, authenticated;

comment on table public.ranking_seasons is
  'RANKING-P17: the Ranking-owned root table — a season is a named scoring WINDOW per cadence '
  '(weekly/monthly may run concurrently, independent leaderboards). Ranking is the SOLE writer (via '
  'its own future season-management function, not migration-seeded); public read-only. Seasons are '
  'the scoping mechanism for the reset-by-season law (ROADMAP :92) — a reset is a NEW season row, '
  'NEVER deletion of finalized event data. DARK behind `ranking_enabled` (every future Ranking '
  'scoring/read/season RPC rejects-before-any-read while the flag is false). No writer/reader '
  'references this table yet — it exists dark, inert.';
