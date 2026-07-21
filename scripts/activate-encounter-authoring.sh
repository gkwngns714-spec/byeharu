#!/usr/bin/env bash
# ENCOUNTER-AUTHORING ACTIVATION runner (E1) — wraps scripts/activate-encounter-authoring.sql, the flag
# flip that lights the fleet-template/encounter-profile owner RPCs (migration 0258). STEP 2 of 4 in the
# E0->E1->E2->E3 combat-content chain (docs/COMBAT_CONTENT_PROGRAM.md). DUAL-GATED: refuses unless E0 is
# already live.
# ██ HUMAN TOOL ██ — never wired into CI. Modes mirror activate-unified-movement.sh:
#   bash scripts/activate-encounter-authoring.sh selftest
#   bash scripts/activate-encounter-authoring.sh run ACTIVATE_ENCOUNTER_AUTHORING
# node equivalent: node scripts/run-activation.mjs scripts/activate-encounter-authoring.sql
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_ENCOUNTER_AUTHORING]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-encounter-authoring.sql"
CONFIRM_TOKEN="ACTIVATE_ENCOUNTER_AUTHORING"
FLAG="encounter_authoring_enabled"
DEP_FLAG="enemy_content_registry_enabled"
MIGRATION="20260618000258"
MARKERS="ACTE1_PASS_PRECONDITIONS ACTE1_PASS_DEPENDENCY ACTE1_PASS_WRITE ACTE1_PASS_SMOKE"
PASS_LINE="ENCOUNTER-AUTHORING ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"

  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command" || true
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;'  || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"

  printf '%s' "$CLEAN" | grep -qF "$MIGRATION" || fail "operation must precondition on the E1 migration head ($MIGRATION)"
  for obj in enemy_fleet_templates encounter_profiles enemy_fleet_template_create encounter_profile_create; do
    printf '%s' "$CLEAN" | grep -qF "$obj" || fail "operation must assert E1 object $obj is present"
  done

  # DEPENDENCY GUARD: refuse unless E0 already true (E1 is dual-gated).
  printf '%s' "$CLEAN" | grep -qF "cfg_bool('$DEP_FLAG')" || fail "operation must guard on the E0 flag cfg_bool('$DEP_FLAG')"
  grep -qF "DEPENDENCY FAIL" "$OP_SQL" || fail "operation must RAISE a DEPENDENCY FAIL when E0 is not already true"

  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('$FLAG', 'true'::jsonb)" || fail "missing $FLAG -> true"
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL" || true

  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"        || fail "missing final PASS line"
  grep -q "NOT A MIGRATION" "$OP_SQL"   || fail "operation must document it is an act, not a migration"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL"  || fail "operation must document the re-run semantics"
  grep -qi "ROLLBACK (manual" "$OP_SQL" || fail "missing the marked manual ROLLBACK section"
  grep -qF "set_game_config('$FLAG', 'false'::jsonb)" "$OP_SQL" || fail "the commented ROLLBACK must carry the inverse write ($FLAG -> false)"

  echo "ENCOUNTER-AUTHORING ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the single E1 flag -> true; DUAL-GATE dependency guard on E0 present; head>=$MIGRATION + E1 tables/RPCs asserted; one timed BEGIN..COMMIT; no meta-command/DDL/table-DML; rollback commented)"
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

echo "[act] E1 ENCOUNTER-AUTHORING flip against project $SUPABASE_PROJECT_ID (Management API; one all-or-nothing transaction)"
BODY="$(jq -Rs '{query: .}' < "$OP_SQL")" || fail "could not encode the operation SQL"
RESP="$(curl --silent --show-error --proto '=https' --max-redirs 0 --connect-timeout 10 --max-time 120 -w '\n%{http_code}' \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" \
  -X POST "https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_ID}/database/query" --data-binary "$BODY")" || fail "the Management API request failed to send"
HTTP_CODE="$(printf '%s' "$RESP" | tail -n 1)"; OUT="$(printf '%s' "$RESP" | sed '$d')"
if [ "${HTTP_CODE:0:1}" != "2" ]; then
  echo "── the act RAISED (HTTP $HTTP_CODE) — nothing committed (all-or-nothing txn; a DEPENDENCY FAIL means E0 is not live yet) ──" >&2
  printf '%s\n' "$OUT" >&2
  fail "activation act FAILED — read the message above, remediate, re-run"
fi
printf '%s\n' "$OUT"
printf '%s' "$OUT" | grep -qF "$PASS_LINE" || fail "the act did not return the final PASS row (verify the flag before anything else)"
echo "E1 ENCOUNTER-AUTHORING ACTIVATION: OVERALL_PASS — fleet/encounter authoring RPCs live. NEXT: activate-encounter-binding.sh (E2)."
