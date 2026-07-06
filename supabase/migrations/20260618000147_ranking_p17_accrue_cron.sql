-- Byeharu — RANKING-P17 POST-AUDIT FIX (item 5): schedule the ranking-accrual background job.
--
-- WHAT THIS ADDS: a pg_cron schedule for public.ranking_accrue_standings() (0130, made commit-safe by
-- the 0144/0145 ledger fold), which until now had NO scheduler (0130/0145 shipped it as a safe dark
-- no-op, cron "deferred"). Mirrors the existing cron idiom in 20260617000033_cron_location_state.sql
-- EXACTLY: `create extension if not exists pg_cron;` → the idempotent unschedule `do`-block with the
-- `undefined_table` guard → `select cron.schedule(name, schedule, $$select …;$$)`.
--
-- SAFE TO SCHEDULE NOW — DARK NO-OP UNTIL THE HUMAN FLIPS THE FLAG. The scheduled function self-checks
-- `ranking_enabled` FIRST (0145: dark gate before any read/write) and returns {ok:false,
-- code:'feature_disabled'} without folding or writing anything while the flag is 'false'. So installing
-- this schedule changes NOTHING observable today — every firing is an instant no-op — and it begins
-- accruing standings the moment the owner flips `ranking_enabled` true (no further migration needed).
-- The function is service-role-granted (0145 ACL) and idempotent + commit-safe (the 0144/0145 per-
-- (season, grant) ledger anti-join), so repeated / overlapping firings never double-count.
--
-- CADENCE — every 5 minutes (`*/5 * * * *`). Design decision (self-approved): standings are a SLOW
-- INCREMENTAL aggregate and `ranking_accrue_standings` is idempotent + commit-safe, so cadence affects
-- ONLY leaderboard freshness, never correctness. 5 minutes keeps boards fresh at negligible load —
-- versus the 60s world heartbeat below — and a missed/late run simply folds the backlog on the next
-- firing (the ledger anti-join guarantees no grant is ever skipped, regardless of timing).
--
-- SCHEDULED DIRECTLY — NO WRAPPER. Unlike 0033 (which wraps `worldstate_tick()` in
-- `process_location_state_ticks()`), `ranking_accrue_standings` is ALREADY a self-contained,
-- service-role-granted entry point with its own dark gate; a `process_*` wrapper would be dead
-- abstraction, so the cron calls the function directly. NO new function or table is added here.
--
-- WORLD-BALANCE WORLD-TICK IS INTENTIONALLY *NOT* SCHEDULED HERE — it is ALREADY driven. Phase-19
-- (WORLD-BALANCE-P19) folded ALL its dynamics INTO `worldstate_tick()` itself: pirate-pressure (0135),
-- price-drift (0136), and field-depletion (0137) are `create or replace` extensions of that ONE
-- function. `worldstate_tick()` is already invoked every 60s by the pre-existing
-- `process-location-state-ticks` cron (0033 → `process_location_state_ticks()` → `worldstate_tick()`).
-- Adding a SECOND schedule for the world-tick would DOUBLE-TICK every world-balance dynamic (double
-- pressure decay, double price drift, double field regen/depletion), so NONE is added. World-balance
-- stays gated by its own dark no-op flag `world_balance_enabled` (0135; the tick's dynamics are inert
-- while it is 'false'). The ONLY genuinely-unscheduled background job was ranking-accrual — this file.
--
-- Cron cadence summary across the game (extends the 0033 header list):
--   movement   : 30s   (process_fleet_movements)
--   combat     :  2s   (process_combat_ticks)
--   worldstate : 60s   (process_location_state_ticks → worldstate_tick; carries world-balance 0135-0137)
--   ranking    :  5min (ranking_accrue_standings)  ← this file
--
-- No flag flipped; `0001–0146` unedited (incl. mining 0143, ranking 0144/0145, exploration 0146); no new
-- function/table; forward-only. Not applied/dispatched to any database by this migration.

-- ── Schedule ranking-accrual every 5 minutes (idempotent re-run — the 0033 idiom verbatim) ──────────
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid)
  from cron.job
  where jobname = 'ranking-accrue-standings';
exception
  when undefined_table then null;  -- cron schema not ready yet (first run handles it)
end;
$$;

select cron.schedule(
  'ranking-accrue-standings',
  '*/5 * * * *',
  $$select public.ranking_accrue_standings();$$
);
