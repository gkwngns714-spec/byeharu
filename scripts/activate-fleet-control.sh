#!/usr/bin/env bash
# FLEET-CONTROL ACTIVATION runner — wraps the ONE flag flip scripts/activate-fleet-control.sql
# (docs/FULL_CAPACITY_PLAN.md §FLEET; migration 0204 — the command-ship model + the 8-ship cap, built
# dark). ██ HUMAN TOOL ██ — never wired into CI; nothing flips at build time; each `run` is the human's
# recorded go decision. The activate-haul.sh / activate-captains.sh pattern, FLEET-CONTROL domain.
# Modes:
#   selftest — DB-free static safety: the operation's only DIRECT write is game_config, via the owned
#              set_game_config writer, on exactly ONE approved key (fleet_control_enabled -> true), never
#              a knob rewrite and never another window's flag; it writes NO table directly and contains
#              NO DDL; it is one timed UTC BEGIN..COMMIT gated on migration 0204 recorded + the deployed
#              -body prosrc pins (the command-ship gate in the 3 movement RPCs, the fleet_full 8-cap in
#              assign, and the un-gated ship_not_in_fleet setter) + team_command_enabled committed true;
#              contains NO psql meta-command (management-API compatible); keeps its ROLLBACK section
#              commented out (flag-only); documents the BIG behavior change (every command-shipless
#              fleet goes inactive at flip time) and the server-lit (runtime-flag) client mount — no PR.
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and assert
#              every stage marker. Requires the typed confirm token as the 2nd arg.
#
#   bash scripts/activate-fleet-control.sh selftest
#   bash scripts/activate-fleet-control.sh run ACTIVATE_FLEETCTRL          # DB_URL required
#
# AFTER a green run: NO client PR — the FLEET-CONTROL surfaces are runtime-flag-gated
# (strictConfigFlag('fleet_control_enabled') / fetchFleetControlEnabled), no compile constant exists.
# Manual smoke: open Fleets -> a fleet reads "Fleet inactive — set a command ship" -> Set as command ship
# -> it reads Active and can send/move/hunt; the add-ship picker refuses a 9th member; a lone ship on the
# map shows "Add this ship to a fleet to move it" (the per-ship Move affordance is gone).
# Rollback: the commented section at the bottom of the .sql (ONE reverse config write — the gate + cap
# drop and the client falls back to today on its next poll; is_command_ship designations persist inert).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_FLEETCTRL]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-fleet-control.sql"
CONFIRM_TOKEN="ACTIVATE_FLEETCTRL"
MARKERS="ACTIVATE_FLEETCTRL_PASS_PRECONDITIONS ACTIVATE_FLEETCTRL_PASS_STAGE1 ACTIVATE_FLEETCTRL_PASS_SMOKE"
PASS_LINE="FLEET-CONTROL ACTIVATION PASS"

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
  printf '%s' "$CLEAN" | grep -q "20260618000204" || fail "operation must precondition on the 0204 migration head"

  # the deployed-body prosrc pins: the command-ship gate, the 8-cap, the un-gated ship_not_in_fleet setter.
  printf '%s' "$CLEAN" | grep -qF "position('fleet_inactive_no_command' in v_src)" || fail "operation must prosrc-pin the command-ship gate in the movement RPCs"
  printf '%s' "$CLEAN" | grep -qF "position('fleet_full' in v_src)" || fail "operation must prosrc-pin the 8-ship cap in assign_ship_to_group"
  printf '%s' "$CLEAN" | grep -qF "position('ship_not_in_fleet' in v_src)" || fail "operation must prosrc-pin the ship_not_in_fleet guard in set_fleet_command_ship"
  printf '%s' "$CLEAN" | grep -qF "position('fleet_control_enabled' in v_src) > 0" || fail "operation must pin that set_fleet_command_ship does NOT read the flag (the designation is always settable)"

  # the team_command precondition (fleet control reshapes the live fleet system).
  printf '%s' "$CLEAN" | grep -qF "key = 'team_command_enabled'" || fail "operation must precondition on the raw team_command_enabled value"
  printf '%s' "$CLEAN" | grep -qF "cfg_bool('team_command_enabled')" || fail "operation must precondition on team_command_enabled through cfg_bool"

  # writes: exactly 1 set_game_config on the ONE approved key -> true, never a false-flip / other window /
  # direct table DML / DDL.
  n="$(printf '%s' "$CLEAN" | grep -o "set_game_config('" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('fleet_control_enabled', 'true'::jsonb)" || fail "missing fleet_control_enabled -> true (the only flag write)"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden)" || true

  # markers + the documentation the human relies on.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                        || fail "missing final PASS line"
  grep -q "THE BIG BEHAVIOR CHANGE" "$OP_SQL"           || fail "operation must document the flip-time mass-inactivation of command-shipless fleets"
  grep -q "NO CLIENT PR IS NEEDED" "$OP_SQL"            || fail "operation must document that the surface is runtime-flag-gated (no compile constant)"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL"                  || fail "operation must document the re-run no-op semantics"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                 || fail "missing the marked manual ROLLBACK section"

  echo "FLEET-CONTROL ACTIVATION SELFTEST: ALL PASSED (set_game_config-only direct write on the 1 approved key -> true; single timed UTC BEGIN..COMMIT gated on 0204 recorded + the deployed-body prosrc pins (command-ship gate / 8-cap / un-gated ship_not_in_fleet setter) + team_command_enabled committed true; no meta-commands; no knob/other-window/direct-table/DDL writes; rollback commented; the flip-time mass-inactivation + server-lit-mount + re-run semantics documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "FLEET-CONTROL ACTIVATION: OVERALL_PASS — the fleet control-model is live (command-ship gate + 8-ship cap). NO client PR needed (runtime-flag-gated). Every command-shipless fleet is now inactive until its owner designates a command ship in the Fleets panel."
