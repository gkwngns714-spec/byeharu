-- Byeharu — RANKING-P17 POST-AUDIT FIX, SLICE B: make `ranking_accrue_standings` COMMIT-SAFE by
-- folding through the `ranking_counted_grants` ledger (0144) instead of the `granted_at` timestamp
-- high-water cursor. CREATE OR REPLACE of the accrual writer ONLY; the fold is the ONLY thing that
-- changes. `ranking_score_delta` is UNCHANGED and deliberately NOT redefined here (0130 owns it).
--
-- THE BUG (post-audit item 2). 0130's fold is INCREMENTAL by a TIMESTAMP high-water cursor,
-- `ranking_standings.last_counted_at`: it folds only grants with `granted_at > last_counted_at` and
-- advances the mark. `reward_grants.granted_at` defaults to the inserting txn's START time (0015:14),
-- but a row is VISIBLE to the accrual reader only at COMMIT. A grant whose txn started BEFORE a run
-- (small `granted_at`) yet COMMITS AFTER that run advanced the watermark past its `granted_at` is then
-- PERMANENTLY SKIPPED — the next run's `granted_at > last_counted_at` filter excludes it forever.
--
-- THE FIX — a VISIBILITY-BASED, exactly-once fold through the per-(season, grant) ledger (0144). The
-- fold no longer compares timestamps to decide what to count; it counts every finalized grant that is
-- NOT YET in the ledger for an active season it falls within (`not exists` anti-join), inserting the
-- consumption marker in the SAME statement. Commit-safe BY CONSTRUCTION: a late-committing grant is
-- simply absent from the ledger and is picked up on the next run, regardless of `granted_at` ordering;
-- exactly-once via the `unique (season_id, grant_id)` key + `on conflict do nothing` (belt-and-braces
-- with the global advisory lock); idempotent (a re-run with no unmarked grants inserts nothing and
-- upserts nothing). This is the securing processors' per-row `secured_at` consumption-marker idiom
-- (0100/0105) the 0128/0130 accrual comment already cites, materialized in its own ledger row.
--
-- `last_counted_at` is STILL WRITTEN (max `granted_at` among the grants folded this run, kept via
-- `greatest`), but it is now INFORMATIONAL ONLY — it is NEVER read back as a cursor. The ledger's
-- anti-join is the correctness cursor. Removing the `last_counted_at` COLUMN is intentionally NOT done
-- (it stays as an informational/audit field; a forward-only column drop is out of scope for this fix).
--
-- PRESERVED VERBATIM from 0130 (only the fold body changed): the signature
-- `ranking_accrue_standings() returns jsonb`, `language plpgsql security definer set search_path =
-- public`, the DARK-GATE-FIRST `cfg_bool('ranking_enabled')` reject, the
-- `pg_advisory_xact_lock(hashtext('ranking_accrue_standings'), 0)` global serialize, the
-- `jsonb_build_object('ok', true, 'seasons_scored', …, 'rows_upserted', …, 'events_folded', …)` result
-- shape, and the service-role-only ACL block. `ranking_accrue_standings` remains the SOLE writer of
-- `ranking_standings` (0128) AND now the realized SOLE writer of `ranking_counted_grants` (0144).
--
-- Ownership (docs/SYSTEM_BOUNDARIES.md, synced this same step): §1 `ranking_counted_grants` sole
-- writer is now the REALIZED `ranking_accrue_standings` (was "slice B"); the §2 Ranking contract states
-- the cursor is the commit-safe ledger anti-join and `last_counted_at` is informational. Edges
-- unchanged: Ranking → Reward (`reward_grants` read) + Reference/Config (`cfg_bool`), DOWNWARD, acyclic;
-- Ranking writes only its own tables and nothing calls into Ranking. No flag flipped; `0001–0144`
-- unedited (incl. mining 0143 and the slice-A schema 0144); forward-only. Still DARK, no cron.

-- ── ranking_accrue_standings — PRIVATE writer; SOLE writer of ranking_standings AND ranking_counted_grants ──
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
  --    write NOTHING — reject before any read. [PRESERVED VERBATIM from 0130]
  if not public.cfg_bool('ranking_enabled') then
    return jsonb_build_object('ok', false, 'code', 'feature_disabled');
  end if;

  -- 2) serialize concurrent accruals (0129 advisory-lock idiom; one global accrual — scope 0).
  --    [PRESERVED VERBATIM from 0130]
  perform pg_advisory_xact_lock(hashtext('ranking_accrue_standings'), 0);

  -- 3) COMMIT-SAFE FOLD — one statement, visibility-based (NOT timestamp-cursor based).
  --    `newly_counted` is the commit-safe cursor: it inserts a per-(season, grant) consumption marker
  --    (0144) for every finalized grant that falls within an ACTIVE season's window and is NOT YET in
  --    the ledger for that season (the `not exists` anti-join). A grant that committed AFTER any prior
  --    run — no matter how small its txn-start `granted_at` — is simply absent from the ledger and is
  --    folded NOW; `unique (season_id, grant_id)` + `on conflict do nothing` make each (season, grant)
  --    fold AT MOST ONCE (belt-and-braces with the advisory lock). The data-modifying CTEs run to
  --    completion regardless of what the final SELECT reads (Postgres WITH semantics — the 0130
  --    reliance), so the standings upsert lands while the summary reads `aggregated`.
  with newly_counted as (
    insert into ranking_counted_grants
      (season_id, grant_id, player_id, dimension, score, granted_at, counted_at)
    select s.season_id,
           rg.id,
           rg.player_id,
           rg.source_type,
           public.ranking_score_delta(rg.rewards),
           rg.granted_at,
           now()
    from reward_grants rg
    -- each active season whose window contains the grant (a grant can fold into BOTH a weekly and a
    -- monthly active season concurrently — slice 0 independent leaderboards).
    join ranking_seasons s
      on s.status = 'active'
     and rg.granted_at between s.starts_at and s.ends_at
    where
      -- scope to the standings dimension domain (the 0096 1:1 set); an out-of-domain source_type
      -- (none exist today) is skipped, never aborting the batch or tripping the dimension CHECK.
      rg.source_type in ('combat', 'trade', 'exploration', 'mining')
      -- COMMIT-SAFE ANTI-JOIN (replaces the 0130 `granted_at > last_counted_at` high-water filter):
      -- fold only grants NOT already marked for this season. Visibility-based, ordering-independent.
      and not exists (
        select 1 from ranking_counted_grants c
        where c.season_id = s.season_id and c.grant_id = rg.id)
    on conflict (season_id, grant_id) do nothing
    returning season_id, player_id, dimension, score, granted_at
  ),
  -- aggregate ONLY the newly-inserted markers into per-(season, player, dimension) deltas (the 0130
  -- `folded` shape — score = Σ, events_counted = count, last_counted_at = max granted_at (informational)).
  aggregated as (
    select season_id,
           player_id,
           dimension,
           sum(score)      as score,
           count(*)        as events_counted,
           max(granted_at) as last_counted_at
    from newly_counted
    group by season_id, player_id, dimension
  ),
  upserted as (
    insert into ranking_standings as t
      (season_id, player_id, dimension, score, events_counted, last_counted_at, updated_at)
    select season_id, player_id, dimension, score, events_counted, last_counted_at, now()
    from aggregated
    on conflict (season_id, player_id, dimension) do update
      set score           = t.score + excluded.score,
          events_counted  = t.events_counted + excluded.events_counted,
          -- last_counted_at is INFORMATIONAL now (max granted_at counted); the ledger anti-join is the
          -- correctness cursor, so this is never read back — kept for audit/display only.
          last_counted_at  = greatest(t.last_counted_at, excluded.last_counted_at),
          updated_at       = now()
    returning 1
  )
  select count(distinct a.season_id),
         count(*),
         coalesce(sum(a.events_counted), 0)
    into v_seasons, v_rows, v_events
    from aggregated a;

  return jsonb_build_object('ok', true,
    'seasons_scored', coalesce(v_seasons, 0),
    'rows_upserted',  coalesce(v_rows, 0),
    'events_folded',  coalesce(v_events, 0));
end;
$$;

-- ── ACL (anti-cheat; the 0129/0130 private-writer block, PRESERVED VERBATIM). No public wrapper:
--       accrual is a server/cron/admin op, not a player command. No cron scheduled this slice — the
--       dark-gated fn is a safe no-op until the human activates. ranking_score_delta is UNCHANGED and
--       NOT redefined here, so its 0130 grants are untouched.
revoke execute on function public.ranking_accrue_standings() from public, anon, authenticated;
grant  execute on function public.ranking_accrue_standings() to service_role;
