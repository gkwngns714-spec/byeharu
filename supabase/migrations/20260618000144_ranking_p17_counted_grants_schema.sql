-- Byeharu — RANKING-P17 POST-AUDIT FIX, SLICE A: the commit-safe consumption ledger schema
-- (table + RLS + index + comments ONLY; NO writer, NO reader, NO frontend — the accrual rewrite that
-- makes this table its sole writer lands in SLICE B. The feature stays fully DARK behind
-- `ranking_enabled=false` (0127); NOTHING writes or reads this table yet).
--
-- THE BUG THIS TABLE FIXES (post-audit item 2). `ranking_accrue_standings` (0130) is INCREMENTAL by a
-- TIMESTAMP high-water cursor, `ranking_standings.last_counted_at` (0128 decision 3): each run folds
-- only grants with `granted_at > last_counted_at` and advances the mark. That cursor is COMMIT-UNSAFE.
-- `reward_grants.granted_at` defaults to `now()` = the inserting transaction's START time (0015:14),
-- but a row becomes VISIBLE to the accrual reader only at COMMIT. A grant whose transaction started
-- BEFORE an accrual run (small `granted_at`) but COMMITS AFTER that run has advanced the watermark
-- past its `granted_at` is then PERMANENTLY SKIPPED — the next run's `granted_at > last_counted_at`
-- filter excludes it forever. Result: silently dropped points under normal concurrent finalization.
--
-- THE FIX — a per-(season, grant) CONSUMPTION MARKER, visibility-based, not time-based. This ledger
-- records, exactly once, that a specific `reward_grants` row has been folded into a specific active
-- season. SLICE B's accrual will select grants by an ANTI-JOIN against this table (grants NOT yet
-- marked for the season) rather than by a `granted_at` comparison — so a late-committing grant is
-- simply ABSENT from the ledger and gets picked up on the next run, regardless of `granted_at`
-- ordering. Commit-safe by construction, exactly-once (the `unique (season_id, grant_id)` key), and
-- idempotent (a re-run marks nothing new). This is the SAME per-row consumption-marker idiom the
-- codebase already uses for commit-safe idempotency — the securing processors' `secured_at` mark
-- (0100/0105) that the 0130/0128 accrual comment itself cites as its analogue; here the marker lives
-- in its own ledger row (one grant folds once PER active season it belongs to, so the mark is
-- per-(season, grant), not a single column on the grant). PERMANENT correctness structure — NOT a
-- shim; it does not retire (the timestamp cursor it replaces is what slice B stops depending on).
--
-- Mirrors the 0128 standings schema for RLS/index/comment style, deviating ONLY where required: this
-- is a SERVER-ONLY ledger (NOT public-read like standings/seasons) — it holds no leaderboard display
-- data, only Ranking's internal accrual bookkeeping — so it takes the SECURING-TABLE server-only
-- posture (RLS enabled, NO policy, NO client grant; SECURITY DEFINER writer reaches it as owner),
-- exactly like `mining_fields` (0103) / the hidden activity state. Its `dimension` CHECK reuses the
-- IDENTICAL 0128 closed-set constraint (no new spelling). Its sole writer will be
-- `ranking_accrue_standings` (slice B; SECURITY DEFINER, client-revoked).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced in the SAME step): §1 matrix gains
-- `ranking_counted_grants` under the existing **Ranking** system (sole writer = `ranking_accrue_standings`;
-- server-only, no client read; DARK behind `ranking_enabled`), adjacent to `ranking_standings`; the §2
-- Ranking row's Owns is extended. Ranking stays a READ-ONLY downward leaf: it reads Reward's
-- `reward_grants` DOWNWARD, writes ONLY its own tables, and nothing calls into Ranking — the call graph
-- is unchanged and acyclic. No writer is created here (slice B). No flag flipped; `0001–0143` unedited
-- (including the mining 0143); forward-only.

-- ── ranking_counted_grants — per-(season, grant) consumption ledger (Ranking; SERVER-ONLY) ──────────
-- `dimension` = the reward_grants.source_type domain (the 0096 closed set), 1:1 — the IDENTICAL 0128
-- constraint. `granted_at` is an informational snapshot copy of the grant's granted_at (NOT a cursor).
create table public.ranking_counted_grants (
  id         uuid primary key default gen_random_uuid(),
  season_id  uuid not null references public.ranking_seasons (season_id) on delete cascade,
  grant_id   uuid not null references public.reward_grants (id) on delete cascade,
  player_id  uuid not null references auth.users (id) on delete cascade,
  dimension  text not null
               check (dimension in ('combat', 'trade', 'exploration', 'mining')),
  score      numeric not null,
  -- informational snapshot of reward_grants.granted_at at fold time — NOT used as a cursor (the whole
  -- point of this table is to stop cursoring on a timestamp); kept for audit/debug only.
  granted_at timestamptz not null,
  counted_at timestamptz not null default now(),
  -- EXACTLY-ONCE idempotency key: a grant folds once per active season it belongs to. Slice B's
  -- accrual anti-joins on this pair (grant NOT yet marked for the season) and inserts under it, so a
  -- retry / concurrent run can never double-count and a late-committing grant is picked up next run.
  unique (season_id, grant_id)
);

-- Accrual fold/aggregation access path: group a season's marked grants by (player, dimension) to sum
-- into the matching ranking_standings row. (The (season_id, grant_id) anti-join lookup is already
-- served by the unique constraint's index above.)
create index ranking_counted_grants_fold_idx
  on public.ranking_counted_grants (season_id, player_id, dimension);

alter table public.ranking_counted_grants enable row level security;
-- SERVER-ONLY (the 0103 securing-table posture, NOT the 0128 public-read posture): RLS enabled with
-- NO policy at all and NO grant to anon/authenticated → clients can neither read nor write. This is
-- internal accrual bookkeeping, never client-facing leaderboard data. The SOLE writer is Ranking's
-- OWN `ranking_accrue_standings` (slice B; SECURITY DEFINER, client-revoked), which reaches it as its
-- definer-owner. NOTHING reads or writes this table yet — dark, inert.

comment on table public.ranking_counted_grants is
  'RANKING-P17: per-(season_id, grant_id) CONSUMPTION LEDGER making ranking accrual commit-safe. '
  'Replaces the commit-UNSAFE `ranking_standings.last_counted_at` timestamp high-water cursor (0128), '
  'which permanently skips any reward_grants row that COMMITS after an accrual run advanced the '
  'watermark past its transaction-start `granted_at`. Slice B''s `ranking_accrue_standings` selects '
  'grants by ANTI-JOIN against this table (grants not yet marked for the season) instead of by a '
  '`granted_at` comparison, so a late-committing grant is simply absent and picked up next run — '
  'commit-safe, exactly-once (unique (season_id, grant_id)), idempotent. The per-row consumption-marker '
  'idiom of the 0100/0105 securing `secured_at` mark, in its own ledger (one grant folds once per '
  'active season). SERVER-ONLY: RLS on, no client policy/grant — sole writer = `ranking_accrue_standings` '
  '(SECURITY DEFINER, client-revoked). DARK behind `ranking_enabled`; no writer/reader exists yet. '
  'PERMANENT correctness structure, not a shim.';
comment on column public.ranking_counted_grants.granted_at is
  'RANKING-P17: informational snapshot of reward_grants.granted_at at fold time. NOT a cursor — this '
  'ledger deliberately replaces timestamp-cursoring with visibility-based per-grant markers; kept for '
  'audit/debug only.';
comment on column public.ranking_counted_grants.score is
  'RANKING-P17: the per-grant score contribution folded for this (season, grant), from '
  'ranking_score_delta(reward_grants.rewards) — the same single-source value the standings row sums.';
