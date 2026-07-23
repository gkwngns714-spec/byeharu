#!/usr/bin/env bash
# ENCOUNTER-RESOLVER ACTIVATION runner (E3) — wraps scripts/activate-encounter-resolver.sql, ██ THE ONE
# FLIP THAT CHANGES COMBAT BEHAVIOR ██ (completes the quad-flag; migration 0260). STEP 4 of 4 (final) in
# the E0->E1->E2->E3 combat-content chain (docs/COMBAT_CONTENT_PROGRAM.md). QUAD-GATED: refuses unless E0
# AND E1 AND E2 are already live. Rollback = set the flag false (combat byte-identical again in one tick).
# ██ HUMAN TOOL ██ — never wired into CI. Modes mirror activate-unified-movement.sh:
#   bash scripts/activate-encounter-resolver.sh selftest
#   bash scripts/activate-encounter-resolver.sh run ACTIVATE_ENCOUNTER_RESOLVER
# node equivalent: node scripts/run-activation.mjs scripts/activate-encounter-resolver.sql
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_ENCOUNTER_RESOLVER]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-encounter-resolver.sql"
CONFIRM_TOKEN="ACTIVATE_ENCOUNTER_RESOLVER"
FLAG="encounter_resolver_enabled"
MIGRATION="20260618000260"
MARKERS="ACTE3_PASS_PRECONDITIONS ACTE3_PASS_DEPENDENCY ACTE3_PASS_WRITE ACTE3_PASS_SMOKE"
PASS_LINE="ENCOUNTER-RESOLVER ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"

  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command" || true
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;'  || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"

  printf '%s' "$CLEAN" | grep -qF "$MIGRATION" || fail "operation must precondition on the E3 migration head ($MIGRATION)"
  # resolver functions + the resolved-branch prosrc pin (the version number alone is insufficient).
  for obj in resolve_location_encounter resolve_encounter_reward_inputs process_combat_ticks encounter_runtime_state; do
    printf '%s' "$CLEAN" | grep -qF "$obj" || fail "operation must assert E3 object $obj is present"
  done
  printf '%s' "$CLEAN" | grep -qF "v_resolver_engaged" || fail "operation must prosrc-pin the resolved branch (process_combat_ticks references v_resolver_engaged)"
  printf '%s' "$CLEAN" | grep -qF "resolve_location_encounter(e.location_id, e.id::text)" || fail "operation must prosrc-pin the seeded resolved spawn call (resolve_location_encounter(e.location_id, e.id::text))"

  # DEPENDENCY GUARD: refuse unless E0 AND E1 AND E2 already true (the quad chain).
  printf '%s' "$CLEAN" | grep -qF "cfg_bool('enemy_content_registry_enabled')"      || fail "operation must guard on the E0 flag"
  printf '%s' "$CLEAN" | grep -qF "cfg_bool('encounter_authoring_enabled')"         || fail "operation must guard on the E1 flag"
  printf '%s' "$CLEAN" | grep -qF "cfg_bool('encounter_binding_authoring_enabled')" || fail "operation must guard on the E2 flag"
  grep -qF "DEPENDENCY FAIL" "$OP_SQL" || fail "operation must RAISE a DEPENDENCY FAIL when E0/E1/E2 are not already true"

  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('$FLAG', 'true'::jsonb)" || fail "missing $FLAG -> true"
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL" || true

  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                    || fail "missing final PASS line"
  grep -q "NOT A MIGRATION" "$OP_SQL"               || fail "operation must document it is an act, not a migration"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL"              || fail "operation must document the re-run semantics"
  grep -qi "ROLLBACK (manual" "$OP_SQL"             || fail "missing the marked manual ROLLBACK section"
  grep -qiE "BEHAVIOR[- ]CHANGING|COMBAT BEHAVIOR" "$OP_SQL" || fail "operation must PROMINENTLY warn that this flip changes combat behavior"
  grep -qF "set_game_config('$FLAG', 'false'::jsonb)" "$OP_SQL" || fail "the commented ROLLBACK must carry the inverse write ($FLAG -> false)"

  echo "ENCOUNTER-RESOLVER ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the single E3 flag -> true; QUAD-GATE dependency guard on E0+E1+E2 present; head>=$MIGRATION + resolver fns + resolved-branch prosrc pin asserted; behavior-change warning present; one timed BEGIN..COMMIT; no meta-command/DDL/table-DML; rollback commented)"
  exit 0
fi

[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
for t in curl jq; do command -v "$t" >/dev/null 2>&1 || fail "required tooling missing: $t (use: node scripts/run-activation.mjs $OP_SQL)"; done
if [ -f "$REPO_ROOT/.env.local" ]; then
  [ -z "${SUPABASE_ACCESS_TOKEN:-}" ] && SUPABASE_ACCESS_TOKEN="$(sed -nE 's/^[[:space:]]*SUPABASE_ACCESS_TOKEN[[:space:]]*=[[:space:]]*//p' "$REPO_ROOT/.env.local" | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
  [ -z "${SUPABASE_PROJECT_ID:-}" ]  && SUPABASE_PROJECT_ID="$(sed -nE 's/^[[:space:]]*SUPABASE_PROJECT_ID[[:space:]]*=[[:space:]]*//p' "$REPO_ROOT/.env.local" | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
fi
[ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || fail "SUPABASE_ACCESS_TOKEN not set and not found in .env.local"
[ -n "${SUPABASE_PROJECT_ID:-}" ]  || fail "SUPABASE_PROJECT_ID not set and not found in .env.local"

echo "[act] ██ E3 ENCOUNTER-RESOLVER flip — THIS CHANGES COMBAT BEHAVIOR ██ against project $SUPABASE_PROJECT_ID (Management API; one all-or-nothing transaction)"
BODY="$(jq -Rs '{query: .}' < "$OP_SQL")" || fail "could not encode the operation SQL"
RESP="$(curl --silent --show-error --proto '=https' --max-redirs 0 --connect-timeout 10 --max-time 120 -w '\n%{http_code}' \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" \
  -X POST "https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_ID}/database/query" --data-binary "$BODY")" || fail "the Management API request failed to send"
HTTP_CODE="$(printf '%s' "$RESP" | tail -n 1)"; OUT="$(printf '%s' "$RESP" | sed '$d')"
if [ "${HTTP_CODE:0:1}" != "2" ]; then
  echo "── the act RAISED (HTTP $HTTP_CODE) — nothing committed (a DEPENDENCY FAIL means E0/E1/E2 are not all live yet) ──" >&2
  printf '%s\n' "$OUT" >&2
  fail "activation act FAILED — read the message above, remediate, re-run"
fi
printf '%s\n' "$OUT"
printf '%s' "$OUT" | grep -qF "$PASS_LINE" || fail "the act did not return the final PASS row (verify the flag before anything else)"
echo "██ E3 ENCOUNTER-RESOLVER ACTIVATION: OVERALL_PASS — COMBAT BEHAVIOR IS NOW LIVE. Rollback = set $FLAG false (combat byte-identical again in one tick; see the .sql ROLLBACK section)."
