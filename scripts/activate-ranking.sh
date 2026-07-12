#!/usr/bin/env bash
# RANKING ACTIVATION runner — wraps the ONE Phase-17 flip operation scripts/activate-ranking.sql
# (docs/FULL_CAPACITY_PLAN.md §B rung 5 "Ranking"; queue slice #9 RANK-SEASON + ACT-RANKING; the
# ranking stack 0127-0131 + 0144/0145 + the 0147 cron is fully built dark). ██ HUMAN TOOL ██ —
# never wired into CI; nothing flips at build time; each `run` is the human's recorded go decision.
#
# The activate-trade.sh / activate-captains.sh / activate-exploration.sh pattern, ranking domain.
# Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly ONE approved key (ranking_enabled -> true), never
#              another window's flag and never a table directly (seasons go ONLY through
#              ranking_season_open, the 0129 sole writer — both cadence calls present and
#              CONDITIONAL on no current active season, so a re-run is a no-op success and a
#              later re-run is the manual season roll); is one timed BEGIN..COMMIT gated on the
#              ranking migrations + the 0145 commit-safe accrual prosrc pins (ranking_counted_grants
#              anti-join ledger — the stale-0130 timestamp-cursor guard) + the 0147 cron scheduled
#              exactly once; contains NO psql meta-command (management-API compatible); keeps its
#              ROLLBACK section commented out (flag-only; seasons deliberately left active);
#              documents the flag-BEFORE-seasons ordering (ranking_season_open dark-gates on the
#              flag), the no-auto-roll operational item, and the server-lit mount
#              (CommandScreen.tsx:83 — NO client PR needed, no compile constant exists).
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and
#              assert every stage marker. Requires the typed confirm token as the 2nd arg.
#              No local psql on this machine? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead — it is self-contained, self-asserting,
#              and meta-command-free.
#
#   bash scripts/activate-ranking.sh selftest
#   bash scripts/activate-ranking.sh run ACTIVATE_RANKING                 # DB_URL required
#
# AFTER a green run:
#   1. NO client PR — RankingPanel is already mounted server-lit on the CommandScreen aside rail
#      (CommandScreen.tsx:83; isServerLit gate RankingPanel.tsx:87; no RANKING_* constant in
#      osnReleaseGates.ts or anywhere in src). The board appears on the next Dashboard render.
#   2. Manual smoke: open the Dashboard -> the Leaderboard card shows the weekly + monthly seasons
#      and "No standings yet"; clear a pirate wave / secure a return -> within ~5 min the cron
#      (ranking-accrue-standings) folds the grant and the combat board + own-standing line move.
#   3. OPERATIONAL: seasons do NOT auto-roll (nothing closes a season at ends_at; the only ranking
#      cron is the accrual). Roll manually each Monday 00:00 UTC / 1st of the month — a re-run of
#      this script IS the roll (the conditional stage opens the current window and
#      ranking_season_open closes the expired one) — until a RANK-ROLL automation slice ships.
# Rollback: the commented section at the bottom of the .sql (ONE reverse config write — standings
# freeze intact; seasons deliberately left active: a closed window can never be reactivated, and
# the ledger anti-join backfills in-window grants on re-light with no gap).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_RANKING]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-ranking.sql"
CONFIRM_TOKEN="ACTIVATE_RANKING"
MARKERS="ACTIVATE_RANKING_PASS_PRECONDITIONS ACTIVATE_RANKING_PASS_STAGE1 ACTIVATE_RANKING_PASS_STAGE2 ACTIVATE_RANKING_PASS_SMOKE"
PASS_LINE="RANKING ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere (nothing for a runner to strip).
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT under txn-local UTC (the window anchors are UTC-defined).
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -qF "set local time zone 'UTC'" || fail "operation must pin the txn-local timezone to UTC (the season-window anchors are UTC-defined)"
  printf '%s' "$CLEAN" | grep -q "20260618000147" || fail "operation must precondition on the 0147 accrue-cron migration"
  printf '%s' "$CLEAN" | grep -qF "'20260618000145'" || fail "operation must precondition on the 0145 commit-safe accrual migration being recorded"

  # the deployed-body pins: the accrual must be the 0145 commit-safe ledger fold, not the stale 0130.
  printf '%s' "$CLEAN" | grep -qF "position('ranking_counted_grants' in v_src)" || fail "operation must prosrc-pin the deployed accrual body to the 0144/0145 counted-grants ledger (the stale-0130 guard)"
  printf '%s' "$CLEAN" | grep -qF "position('on conflict (season_id, grant_id) do nothing' in v_src)" || fail "operation must prosrc-pin the exactly-once ledger insert guard in the deployed accrual body"

  # the cron precondition: jobname pinned, scheduled exactly once, invoking the accrual.
  printf '%s' "$CLEAN" | grep -qF "jobname = 'ranking-accrue-standings'" || fail "operation must pin the 0147 cron jobname (ranking-accrue-standings)"
  printf '%s' "$CLEAN" | grep -qF "%ranking_accrue_standings%" || fail "operation must assert the cron command invokes ranking_accrue_standings"

  # writes: ONLY the owned set_game_config writer, exactly ONE call site, the ONE approved key ->
  # true; NEVER another window's flag, NEVER a table directly, NEVER DDL. Seasons are created ONLY
  # through ranking_season_open (the 0129 sole writer), both cadences, each CONDITIONAL on no
  # current active season (re-run = no-op success / later re-run = the manual roll) with the jsonb
  # envelope asserted (ok + active status — a replayed CLOSED window must fail loudly).
  # count INVOCATIONS (a literal key follows the paren) — the to_regprocedure signature string
  # 'public.set_game_config(text, jsonb)' in the preconditions is existence, not a call site.
  n="$(printf '%s' "$CLEAN" | grep -c "set_game_config('" || true)"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('ranking_enabled', 'true'::jsonb)" || fail "missing ranking_enabled -> true (the only flag write)"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(exploration_enabled|mining_enabled|trade_market_enabled|trade_relief_enabled|team_command_enabled|mainship_additional_commission_enabled|module_crafting_enabled|module_fitting_enabled|captain_assignment_enabled|captain_progression_enabled|captain_shard_drop_rate|station_storage_enabled|salvage_market_enabled|location_investment_enabled|world_balance_enabled|phase20_polish_enabled)'" \
    && fail "operation writes another window's key (out of the ranking window's scope)" || true
  printf '%s' "$CLEAN" | grep -qF "ranking_season_open('weekly'" || fail "missing the weekly ranking_season_open call"
  printf '%s' "$CLEAN" | grep -qF "ranking_season_open('monthly'" || fail "missing the monthly ranking_season_open call"
  printf '%s' "$CLEAN" | grep -qF "cadence = 'weekly' and status = 'active'" || fail "the weekly season creation must be conditional on no current active weekly season (re-run no-op)"
  printf '%s' "$CLEAN" | grep -qF "cadence = 'monthly' and status = 'active'" || fail "the monthly season creation must be conditional on no current active monthly season (re-run no-op)"
  printf '%s' "$CLEAN" | grep -qF -- "->> 'ok'" || fail "the season-open jsonb envelopes must be asserted (ok)"
  printf '%s' "$CLEAN" | grep -qF -- "->> 'status' is distinct from 'active'" || fail "the season-open envelopes must assert status active (a replayed CLOSED window is never reactivated — must fail loudly)"
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config + ranking_season_open only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # smoke + follow-ups documented/asserted: markers, the function-existence smoke over the REAL
  # ranking signatures (incl. the two client RPCs rankingApi.ts actually calls), the client-RPC
  # lit smoke, the tables sanity selects, the flag-before-seasons ordering rationale, the
  # no-auto-roll operational note, the server-lit mount doc, and the commented rollback.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                                    || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "to_regprocedure(fn)" || fail "missing the function-existence smoke"
  for fn in "public.ranking_season_open(text, timestamptz, timestamptz, text)" \
            "public.ranking_accrue_standings()" "public.ranking_score_delta(jsonb)" \
            "public.get_ranking_seasons()" "public.get_ranking_leaderboard(uuid, text, int)" \
            "public.cfg_bool(text)" "public.set_game_config(text, jsonb)"; do
    printf '%s' "$CLEAN" | grep -qF "'$fn'" || fail "preconditions do not cover $fn"
  done
  printf '%s' "$CLEAN" | grep -qF "public.get_ranking_seasons();" || fail "missing the lit-client-RPC smoke (get_ranking_seasons call)"
  printf '%s' "$CLEAN" | grep -qF "public.get_ranking_leaderboard(v_weekly, 'overall'" || fail "missing the lit-client-RPC smoke (get_ranking_leaderboard call)"
  printf '%s' "$CLEAN" | grep -qF "from public.ranking_standings" || fail "missing the ranking_standings sanity select"
  printf '%s' "$CLEAN" | grep -qF "from public.ranking_counted_grants" || fail "missing the ranking_counted_grants sanity select"
  printf '%s' "$CLEAN" | grep -qF "from public.reward_grants" || fail "missing the reward_grants FYI read (readable, never a gate)"
  grep -q "ORDERED BEFORE THE SEASON OPENS" "$OP_SQL"               || fail "operation must document the flag-BEFORE-seasons ordering (ranking_season_open dark-gates on the flag)"
  grep -q "NO auto-roll" "$OP_SQL"                                  || fail "operation must document the no-auto-roll operational item (manual season rolling)"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL"                              || fail "operation must document the re-run no-op semantics"
  grep -q "NO CLIENT PR IS NEEDED" "$OP_SQL"                        || fail "operation must document that the surface is server-lit (no compile constant)"
  grep -q "CommandScreen.tsx:83" "$OP_SQL"                          || fail "operation must document the verified RankingPanel mount (CommandScreen aside rail)"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                             || fail "missing the marked manual ROLLBACK section"

  echo "RANKING ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 1 approved key -> true; seasons only via ranking_season_open, both cadences, conditional + envelope-asserted; single timed UTC BEGIN..COMMIT gated on the ranking migrations + 0145 prosrc pins + the 0147 cron exactly once; no meta-commands; no other-window or direct-table writes; rollback commented; flag-before-seasons ordering, no-auto-roll item and the server-lit mount documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "RANKING ACTIVATION: OVERALL_PASS — ranking live server-side (weekly + monthly seasons open; the 5-min accrue cron folds grants from its next firing). NO client PR needed — RankingPanel mounts server-lit (CommandScreen.tsx:83). Remember: seasons do NOT auto-roll — re-run this script each Monday / 1st (it IS the roll) until RANK-ROLL automation ships."
