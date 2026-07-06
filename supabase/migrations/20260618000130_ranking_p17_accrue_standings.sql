-- Byeharu — RANKING-P17 SLICE 3: the core standings-scoring accrual — `ranking_accrue_standings`,
-- THE SOLE writer of `ranking_standings` (0128), reading `reward_grants` (0015) DOWNWARD. PRIVATE,
-- SECURITY DEFINER, service-role-only, DARK behind `ranking_enabled=false` (0127). NO read RPC, NO
-- player wrapper, NO cron schedule, NO frontend this slice.
--
-- Phase 17 "Ranking / competition … reads finalized events; reset by season, not deletion"
-- (ROADMAP :92). This is the first REALIZED cross-system read edge for Ranking: Ranking → Reward
-- (`reward_grants`), one-directional DOWNWARD — Reward never reads Ranking, and nothing calls into
-- Ranking, so the call graph stays ACYCLIC and Ranking remains a read-only leaf consumer.
--
-- METRIC LOCK — grounded in the CONFIRMED `reward_grants.rewards` bundle shape (0040:3):
--   { "metal": <number>, "items": [ { "item_id": "...", "quantity": <int> }, ... ] }
-- the item quantity key is `quantity` (0040:64 `(el->>'quantity')::numeric`), NOT guessed. The
-- per-event score is defined ONCE in `ranking_score_delta` (single-source, testable): event value =
-- coalesce(metal,0) + coalesce(sum of item quantities,0). Rationale: standings are PER-DIMENSION
-- separate leaderboards (slice 1), so absolute scale is irrelevant within a board; a reward-magnitude
-- metric is uniform across dimensions, deterministic, and computed purely from the finalized event.
--
-- IDIOM SOURCES:
--   · DARK GATE FIRST — `cfg_bool('ranking_enabled')` false → reject before any read/write, folding
--     nothing while dark (0129 / the 0097/0102 reject-before-any-read law). `cfg_bool` (0046)
--     coalesces a missing key to false — the ONE cross-system read edge besides Reward.
--   · advisory lock serializing concurrent runs (the 0129 `pg_advisory_xact_lock` idiom; scope 0 —
--     one global accrual, not per-cadence/player).
--   · INCREMENTAL high-water fold via `ranking_standings.last_counted_at` (0128) — the securing
--     processors' `secured_at` idempotency analogue (0100/0105): re-runs with no new grants are a
--     no-op. Unlike a per-row `secured_at`, this is a per-standings-row high-water mark (the grant
--     ledger is append-only + idempotent per (source_type, source_id), so a monotonic
--     `granted_at` cursor is the natural incremental key).
--   · service-role-only ACL (0129 private-writer block). No public wrapper — accrual is a
--     server/cron/admin op, not a player command.
--
-- LOCKED-DECISION ENFORCEMENT (Phase-17 design; DEV_LOG 2026-07-04 SLICES 0–2):
--   · SOLE WRITER of ranking_standings — the concrete function the 0128 §1/§2 "future scoring fn"
--     note promised; no second write path to the table, ever.
--   · dimension = `rg.source_type` DIRECTLY (the slice-1 1:1 domain lock — no translation layer). The
--     fold is scoped to the standings dimension domain (the 0096 closed set); an out-of-domain
--     source_type (none exist today — the carrier constrains it) is skipped, never aborting the batch
--     or violating the dimension CHECK.
--   · RESET BY SEASON, NEVER BY DELETION. The fold's window is bounded by each ACTIVE season's
--     [starts_at, ends_at]; a CLOSED season stops accruing (it is no longer joined) but KEEPS its
--     standings rows — a "reset" is a new active season (0129) scoping a fresh standings set, never a
--     delete of any standings or event data.
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): ranking_standings' sole writer is now
-- the CONCRETE `ranking_accrue_standings` (0130) (was "future scoring fn"). NEW realized edge,
-- DOWNWARD: Ranking → Reward (`reward_grants` read) + the existing Ranking → Reference/Config
-- (`cfg_bool`) — acyclic, nothing calls into Ranking. No cron scheduled (deferred; the dark-gated fn
-- is a safe no-op until the human activates + schedules). No flag flipped; `0001–0129` unedited;
-- forward-only.

-- ── 1) ranking_score_delta — the ONE definition of a finalized event's score value ────────────────
-- Single-source, testable, IMMUTABLE (pure over its jsonb input). event value =
-- coalesce(metal,0) + coalesce(sum of item quantities,0), using the confirmed 0040 bundle keys. The
-- items sum is guarded to a real jsonb array (a malformed 'items' value can never abort the batch —
-- the 0040 "fail safely" ethos; combat metal-only bundles simply have no 'items' key → 0).
create or replace function public.ranking_score_delta(p_rewards jsonb)
returns numeric
language sql
immutable
set search_path = public
as $$
  select coalesce((p_rewards->>'metal')::numeric, 0)
       + coalesce((
           select sum((el->>'quantity')::numeric)
           from jsonb_array_elements(
                  case when jsonb_typeof(p_rewards->'items') = 'array'
                       then p_rewards->'items' else '[]'::jsonb end) el
           where (el->>'quantity') is not null
         ), 0);
$$;

revoke execute on function public.ranking_score_delta(jsonb) from public, anon, authenticated;
grant  execute on function public.ranking_score_delta(jsonb) to service_role;

-- ── 2) ranking_accrue_standings — PRIVATE writer; THE SOLE writer of ranking_standings ────────────
create or replace function public.ranking_accrue_standings()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seasons integer;
  v_rows    integer;
  v_events  integer;
begin
  -- 1) DARK GATE FIRST (0127 law / 0129 idiom): while ranking_enabled is false, fold NOTHING and
  --    write NOTHING — reject before any read.
  if not public.cfg_bool('ranking_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- 2) serialize concurrent accruals (0129 advisory-lock idiom; one global accrual — scope 0).
  perform pg_advisory_xact_lock(hashtext('ranking_accrue_standings'), 0);

  -- 3) INCREMENTAL, IDEMPOTENT FOLD — one statement. The data-modifying `upserted` CTE runs to
  --    completion regardless of whether the final SELECT reads it (Postgres WITH semantics), so the
  --    summary is computed from `folded` while the upsert lands.
  with folded as (
    select s.season_id,
           rg.player_id,
           rg.source_type                              as dimension,
           sum(public.ranking_score_delta(rg.rewards)) as score,
           count(*)                                    as events_counted,
           max(rg.granted_at)                          as last_counted_at
    from reward_grants rg
    -- each active season whose window contains the grant (a grant can fold into BOTH a weekly and a
    -- monthly active season concurrently — slice 0 independent leaderboards).
    join ranking_seasons s
      on s.status = 'active'
     and rg.granted_at between s.starts_at and s.ends_at
    -- the existing standings row (if any) supplies the per-row high-water mark.
    left join ranking_standings st
      on st.season_id = s.season_id
     and st.player_id = rg.player_id
     and st.dimension = rg.source_type
    where
      -- scope to the standings dimension domain (the 0096 1:1 set); an out-of-domain source_type
      -- (none exist today) is skipped, never aborting the batch or tripping the dimension CHECK.
      rg.source_type in ('combat', 'trade', 'exploration', 'mining')
      -- HIGH-WATER FILTER: fold only grants not already counted. NULL high-water (fresh standings
      -- row) counts from the season start inclusive; strict `>` afterward makes re-runs a no-op.
      and ((st.last_counted_at is null and rg.granted_at >= s.starts_at)
           or (rg.granted_at > st.last_counted_at))
    group by s.season_id, rg.player_id, rg.source_type
  ),
  upserted as (
    insert into ranking_standings as t
      (season_id, player_id, dimension, score, events_counted, last_counted_at, updated_at)
    select season_id, player_id, dimension, score, events_counted, last_counted_at, now()
    from folded
    on conflict (season_id, player_id, dimension) do update
      set score           = t.score + excluded.score,
          events_counted  = t.events_counted + excluded.events_counted,
          last_counted_at  = greatest(t.last_counted_at, excluded.last_counted_at),
          updated_at       = now()
    returning 1
  )
  select count(distinct f.season_id),
         count(*),
         coalesce(sum(f.events_counted), 0)
    into v_seasons, v_rows, v_events
    from folded f;

  return jsonb_build_object('ok', true,
    'seasons_scored', coalesce(v_seasons, 0),
    'rows_upserted',  coalesce(v_rows, 0),
    'events_folded',  coalesce(v_events, 0));
end;
$$;

-- ── 3) ACL (anti-cheat; the 0129 private-writer block). No public wrapper: accrual is a
--       server/cron/admin op, not a player command, so the writer stays OFF the client surface. No
--       cron is scheduled this slice — the dark-gated fn is a safe no-op until the human activates.
revoke execute on function public.ranking_accrue_standings() from public, anon, authenticated;
grant  execute on function public.ranking_accrue_standings() to service_role;
