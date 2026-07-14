#!/usr/bin/env bash
# COMMAND-BUFFS ACTIVATION runner — wraps the ONE flag flip scripts/activate-command-buffs.sql
# (docs/FULL_CAPACITY_PLAN.md §FLEET; migration 0205 — the fleet-wide command-buff fold, built dark).
# ██ HUMAN TOOL ██ — never wired into CI; nothing flips at build time; each `run` is the human's
# recorded go decision. The activate-fleet-control.sh pattern, COMMAND-BUFFS domain.
# Modes:
#   selftest — DB-free static safety: the operation's only DIRECT write is game_config, via the owned
#              set_game_config writer, on exactly ONE approved key (command_buffs_enabled -> true), never
#              a knob rewrite and never another window's flag; it writes NO table directly and contains
#              NO DDL; it is one timed UTC BEGIN..COMMIT gated on migration 0205 recorded + the deployed
#              adapter-body prosrc pins (the command_buffs_enabled gate + the is_command_ship-scoped
#              command_buff fold) + the catalog-freeze + buff-slot coverage + team_command_enabled AND
#              fleet_control_enabled committed true; contains NO psql meta-command (management-API
#              compatible); keeps its ROLLBACK section commented out (flag-only); documents the behavior
#              change + the FLEET-CONTROL dependency + the server-lit (runtime-flag) client mount — no PR.
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and assert
#              every stage marker. Requires the typed confirm token as the 2nd arg.
#
#   bash scripts/activate-command-buffs.sh selftest
#   bash scripts/activate-command-buffs.sh run ACTIVATE_CMDBUFF          # DB_URL required
#
# AFTER a green run: NO client PR — the dossier Command buff line is runtime-flag-gated
# (strictConfigFlag('command_buffs_enabled') / fetchShipCommandBuff), no compile constant exists.
# Manual smoke: open a ship's dossier -> the Command buff line shows the rolled buff + "Applies to the
# whole fleet when this ship is the command ship"; set that ship as its fleet's command ship -> every
# fleet member's Ship stats gain the buff.
# Rollback: the commented section at the bottom of the .sql (ONE reverse config write — the fold drops
# and the dossier line hides on the next poll; the rolled buff + is_command_ship rows persist inert).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_CMDBUFF]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-command-buffs.sql"
CONFIRM_TOKEN="ACTIVATE_CMDBUFF"
MARKERS="ACTIVATE_CMDBUFF_PASS_PRECONDITIONS ACTIVATE_CMDBUFF_PASS_STAGE1 ACTIVATE_CMDBUFF_PASS_SMOKE"
PASS_LINE="COMMAND-BUFFS ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere.
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT under txn-local UTC.
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -q "20260618000205" || fail "operation must precondition on the 0205 migration head"

  # the deployed adapter-body prosrc pins: the gate + the is_command_ship-scoped command_buff fold.
  printf '%s' "$CLEAN" | grep -qF "position('command_buffs_enabled' in v_src)" || fail "operation must prosrc-pin the command_buffs_enabled gate in the adapter"
  printf '%s' "$CLEAN" | grep -qF "position('command_buff_types' in v_src)" || fail "operation must prosrc-pin the command_buff_types fold read in the adapter"
  printf '%s' "$CLEAN" | grep -qF "position('is_command_ship' in v_src)" || fail "operation must prosrc-pin the is_command_ship scoping of the fold"

  # the catalog-freeze + buff-slot coverage preconditions.
  printf '%s' "$CLEAN" | grep -qF "the catalog-freeze law" || fail "operation must precondition on the >=10/tier catalog freeze"
  printf '%s' "$CLEAN" | grep -qF "carry no rolled buff" || fail "operation must precondition on full buff-slot coverage"

  # the fleet-control DEPENDENCY precondition (command buffs need the command-ship surface).
  printf '%s' "$CLEAN" | grep -qF "key = 'team_command_enabled'" || fail "operation must precondition on the raw team_command_enabled value"
  printf '%s' "$CLEAN" | grep -qF "key = 'fleet_control_enabled'" || fail "operation must precondition on the raw fleet_control_enabled value (the dependency)"
  printf '%s' "$CLEAN" | grep -qF "cfg_bool('fleet_control_enabled')" || fail "operation must precondition on fleet_control_enabled through cfg_bool"

  # writes: exactly 1 set_game_config on the ONE approved key -> true, never a false-flip / other window /
  # direct table DML / DDL.
  n="$(printf '%s' "$CLEAN" | grep -o "set_game_config('" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('command_buffs_enabled', 'true'::jsonb)" || fail "missing command_buffs_enabled -> true (the only flag write)"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # markers + the documentation the human relies on.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                        || fail "missing final PASS line"
  grep -q "THE BEHAVIOR CHANGE" "$OP_SQL"               || fail "operation must document the fleet-wide fold behavior change"
  grep -q "NO CLIENT PR IS NEEDED" "$OP_SQL"            || fail "operation must document that the surface is runtime-flag-gated (no compile constant)"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL"                  || fail "operation must document the re-run no-op semantics"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                 || fail "missing the marked manual ROLLBACK section"

  echo "COMMAND-BUFFS ACTIVATION SELFTEST: ALL PASSED (set_game_config-only direct write on the 1 approved key -> true; single timed UTC BEGIN..COMMIT gated on 0205 recorded + the deployed adapter-body prosrc pins (command_buffs_enabled gate / command_buff_types fold / is_command_ship scoping) + the >=10/tier catalog freeze + full buff-slot coverage + team_command_enabled AND fleet_control_enabled committed true; no meta-commands; no knob/other-window/direct-table/DDL writes; rollback commented; the behavior change + FLEET-CONTROL dependency + server-lit-mount + re-run semantics documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "COMMAND-BUFFS ACTIVATION: OVERALL_PASS — the fleet-wide command-buff fold is live. NO client PR needed (runtime-flag-gated). Every fleet with a designated command ship now gains that ship's rolled buff fleet-wide."
