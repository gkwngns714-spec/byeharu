#!/usr/bin/env bash
# TEAM-COMMAND ACTIVATION runner — wraps the ONE staged flip operation
# scripts/activate-team-command.sql (docs/TEAM_ACTIVATION_PACKET.md §6; recommendations approved
# 2026-07-12). ██ HUMAN TOOL ██ — never wired into CI; nothing flips at build time; each `run`
# is the human's recorded go decision for the SERVER-side switch.
#
# Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly the six approved keys (price/fleet-cap knobs +
#              commission/team/module-crafting/module-fitting flags), never captains; is one
#              timed BEGIN..COMMIT gated on the 0170 precondition; keeps its ROLLBACK section
#              commented out; and documents the follow-up one-line client PR.
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and
#              assert every stage marker. Requires the typed confirm token as the 2nd arg.
#              No local psql on this machine? Paste the .sql into the Supabase Dashboard SQL
#              editor instead — the file is self-contained and self-asserting.
#
#   bash scripts/activate-team-command.sh selftest
#   bash scripts/activate-team-command.sh run ACTIVATE_TEAM_COMMAND        # DB_URL required
#
# AFTER a green run (packet §6 stage 2.4 → stage 3):
#   1. ONE-LINE frontend PR: src/features/map/osnReleaseGates.ts →
#      TEAM_COMMAND_ENABLED = true as const  AND  MAINSHIP_ADDITIONAL_ENABLED = true as const
#      (mounts TeamRosterPanel = the roster/Hunt UI, plus the Commission-ship control + the ship
#      switcher on ShipScreen — the in-client path to ship #2+).
#   2. bash scripts/team-command-proof.sh (against the lit env) + the manual smoke list.
#   3. Captains fast-follow LATER (bump SQL + shard drop + captain flags — packet §3).
# Rollback: the commented section at the bottom of the .sql (reverse config writes only).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_TEAM_COMMAND]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-team-command.sql"
CONFIRM_TOKEN="ACTIVATE_TEAM_COMMAND"
MARKERS="ACTIVATE_TEAMCMD_PASS_PRECONDITIONS ACTIVATE_TEAMCMD_PASS_STAGE1 ACTIVATE_TEAMCMD_PASS_STAGE2 ACTIVATE_TEAMCMD_PASS_SMOKE"
PASS_LINE="TEAM-COMMAND ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # one explicit, timed BEGIN..COMMIT; abort-on-error; gated on the 0170 prep migration.
  grep -q '\\set ON_ERROR_STOP on' "$OP_SQL"                       || fail "operation must set ON_ERROR_STOP"
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -q "20260618000170" || fail "operation must precondition on the 0170 hull-stats migration"
  printf '%s' "$CLEAN" | grep -qF "(want 15/10" || fail "operation must precondition on the seeded hull stats {attack 15, defense 10}"

  # writes: ONLY the owned set_game_config writer, exactly the six approved keys, exact values;
  # NEVER a captain flag, NEVER another table, NEVER DDL. (Comment-stripped, so the commented
  # ROLLBACK section cannot satisfy or violate these.)
  # 3 call sites = the two stage-1 knob writes + the ONE stage-2 loop write over the 4-flag array.
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "3" ] || fail "operation must have exactly 3 set_game_config call sites (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('main_ship_price', '250'::jsonb)"   || fail "missing main_ship_price -> 250"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('max_active_fleets', '6'::jsonb)"   || fail "missing max_active_fleets -> 6"
  for k in mainship_additional_commission_enabled team_command_enabled module_crafting_enabled module_fitting_enabled; do
    printf '%s' "$CLEAN" | grep -qF "'$k'" || fail "missing flag $k"
  done
  printf '%s' "$CLEAN" | grep -qF "set_game_config(k, 'true'::jsonb)"                  || fail "stage-2 flags must be set to true via set_game_config"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE 'captain_(assignment|progression)_enabled' && fail "operation touches a captain flag (captains are the fast-follow window)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+public\.|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # smoke + follow-ups are documented/asserted: markers, cron pin, and the client-flip step.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                                    || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "% combat cron jobs (want exactly 1)" || fail "missing the no-second-engine cron assert"
  grep -q "TEAM_COMMAND_ENABLED" "$OP_SQL" && grep -q "MAINSHIP_ADDITIONAL_ENABLED" "$OP_SQL" \
                                                                    || fail "operation must document the one-line client flip PR (both compile mirrors)"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                             || fail "missing the marked manual ROLLBACK section"

  echo "TEAM-COMMAND ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 6 approved keys; 0170-gated timed BEGIN..COMMIT; no captain flips; rollback commented; client-flip step documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "TEAM-COMMAND ACTIVATION: OVERALL_PASS — server flags live. Next: the one-line osnReleaseGates.ts PR, then scripts/team-command-proof.sh + manual smoke."
