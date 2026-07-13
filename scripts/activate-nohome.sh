#!/usr/bin/env bash
# NO-HOME ACTIVATION runner — wraps the ONE staged flip scripts/activate-nohome.sql (migration 0199).
# ██ HUMAN TOOL ██ — never wired into CI; nothing flips at build time; each `run` is the human's
# recorded go decision for the SERVER-side switch that lights launch-from-dock.
#
# Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly ONE key (launch_from_dock_enabled → true); is one
#              timed BEGIN..COMMIT gated on the 0199 precondition; keeps its ROLLBACK commented out.
#   run      — execute against $DB_URL and assert every stage marker. Requires the typed confirm token.
#
#   bash scripts/activate-nohome.sh selftest
#   bash scripts/activate-nohome.sh run ACTIVATE_NOHOME        # DB_URL required
#
# AFTER a green run: the client is data-driven off the flag (strictConfigFlag over game_config) — no
# compile mirror to flip. Then run scripts/team-command-proof.sh (against the lit env) — the
# TEAMCMD_PASS_NOHOME block proves a docked ship/team launches from its port and docks at the chosen
# return port. Rollback: the commented section at the bottom of the .sql (reverse the one config write).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_NOHOME]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-nohome.sql"
CONFIRM_TOKEN="ACTIVATE_NOHOME"
MARKERS="ACTIVATE_NOHOME_PASS_PRECONDITIONS ACTIVATE_NOHOME_PASS_STAGE1 ACTIVATE_NOHOME_PASS_SMOKE"
PASS_LINE="NO-HOME ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  grep -q '\\set ON_ERROR_STOP on' "$OP_SQL"                       || fail "operation must set ON_ERROR_STOP"
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;'                      || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;'                     || fail "operation must COMMIT (this one persists — it is the activation)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -q "20260618000199"                  || fail "operation must precondition on the 0199 NO-HOME migration"

  # writes: ONLY the owned set_game_config writer, exactly ONE key, to true; NEVER another table/DDL.
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('launch_from_dock_enabled', 'true'::jsonb)" || fail "missing launch_from_dock_enabled -> true"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+public\.|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                                   || fail "missing final PASS line"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                            || fail "missing the marked manual ROLLBACK section"

  echo "NO-HOME ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the 1 approved key; 0199-gated timed BEGIN..COMMIT; no false-flip; rollback commented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "NO-HOME ACTIVATION: OVERALL_PASS — launch-from-dock live. Next: scripts/team-command-proof.sh against the lit env (TEAMCMD_PASS_NOHOME)."
