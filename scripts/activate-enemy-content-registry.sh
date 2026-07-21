#!/usr/bin/env bash
# ENEMY-CONTENT-REGISTRY ACTIVATION runner (E0) — wraps scripts/activate-enemy-content-registry.sql, the
# flag flip that lights the enemy_archetypes/reward_profiles owner RPCs (migration 0257). STEP 1 of 4 in
# the E0->E1->E2->E3 combat-content chain (docs/COMBAT_CONTENT_PROGRAM.md).
# ██ HUMAN TOOL ██ — never wired into CI; nothing flips at build time; each `run` is the owner's recorded
# go decision. Modes mirror the activate-unified-movement.sh pattern:
#   selftest — DB-free static safety on the .sql (no network).
#   run      — execute against PROD via the Management API and assert the final PASS row. Requires the
#              typed confirm token as the 2nd arg + SUPABASE_ACCESS_TOKEN/SUPABASE_PROJECT_ID (.env.local).
#   bash scripts/activate-enemy-content-registry.sh selftest
#   bash scripts/activate-enemy-content-registry.sh run ACTIVATE_ENEMY_CONTENT_REGISTRY
# The node equivalent (this machine has no psql/jq for the curl path): node scripts/run-activation.mjs
# scripts/activate-enemy-content-registry.sql. Rollback: the commented section at the bottom of the .sql.
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_ENEMY_CONTENT_REGISTRY]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-enemy-content-registry.sql"
CONFIRM_TOKEN="ACTIVATE_ENEMY_CONTENT_REGISTRY"
FLAG="enemy_content_registry_enabled"
MIGRATION="20260618000257"
MARKERS="ACTE0_PASS_PRECONDITIONS ACTE0_PASS_WRITE ACTE0_PASS_SMOKE"
PASS_LINE="ENEMY-CONTENT-REGISTRY ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;'  || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"

  # preconditions: the E0 migration head + the object asserts.
  printf '%s' "$CLEAN" | grep -qF "$MIGRATION" || fail "operation must precondition on the E0 migration head ($MIGRATION)"
  for obj in reward_profiles enemy_archetypes reward_profile_create enemy_archetype_create; do
    printf '%s' "$CLEAN" | grep -qF "$obj" || fail "operation must assert E0 object $obj is present"
  done

  # the write: exactly ONE set_game_config call site (the ROLLBACK's is stripped), the E0 flag -> true.
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('$FLAG', 'true'::jsonb)" || fail "missing $FLAG -> true"
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL (forbidden — an act is not a migration)" || true

  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"          || fail "missing final PASS line"
  grep -q "NOT A MIGRATION" "$OP_SQL"     || fail "operation must document that it is an act, never a migration"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL"    || fail "operation must document the re-run no-op semantics"
  grep -qi "ROLLBACK (manual" "$OP_SQL"   || fail "missing the marked manual ROLLBACK section"
  grep -qF "set_game_config('$FLAG', 'false'::jsonb)" "$OP_SQL" || fail "the commented ROLLBACK must carry the inverse write ($FLAG -> false)"

  echo "ENEMY-CONTENT-REGISTRY ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the single E0 flag -> true; head>=$MIGRATION + E0 tables/RPCs asserted; one timed BEGIN..COMMIT; no meta-command/DDL/table-DML; rollback commented with the inverse write)"
  exit 0
fi

# ── run: the human's activation execution (Management-API path) ────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
for t in curl jq; do command -v "$t" >/dev/null 2>&1 || fail "required tooling missing: $t (use: node scripts/run-activation.mjs $OP_SQL)"; done
if [ -f "$REPO_ROOT/.env.local" ]; then
  [ -z "${SUPABASE_ACCESS_TOKEN:-}" ] && SUPABASE_ACCESS_TOKEN="$(sed -nE 's/^[[:space:]]*SUPABASE_ACCESS_TOKEN[[:space:]]*=[[:space:]]*//p' "$REPO_ROOT/.env.local" | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
  [ -z "${SUPABASE_PROJECT_ID:-}" ]  && SUPABASE_PROJECT_ID="$(sed -nE 's/^[[:space:]]*SUPABASE_PROJECT_ID[[:space:]]*=[[:space:]]*//p' "$REPO_ROOT/.env.local" | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
fi
[ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || fail "SUPABASE_ACCESS_TOKEN not set and not found in .env.local"
[ -n "${SUPABASE_PROJECT_ID:-}" ]  || fail "SUPABASE_PROJECT_ID not set and not found in .env.local"

echo "[act] E0 ENEMY-CONTENT-REGISTRY flip against project $SUPABASE_PROJECT_ID (Management API; one all-or-nothing transaction)"
BODY="$(jq -Rs '{query: .}' < "$OP_SQL")" || fail "could not encode the operation SQL"
RESP="$(curl --silent --show-error --proto '=https' --max-redirs 0 --connect-timeout 10 --max-time 120 -w '\n%{http_code}' \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" \
  -X POST "https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_ID}/database/query" --data-binary "$BODY")" || fail "the Management API request failed to send"
HTTP_CODE="$(printf '%s' "$RESP" | tail -n 1)"; OUT="$(printf '%s' "$RESP" | sed '$d')"
if [ "${HTTP_CODE:0:1}" != "2" ]; then
  echo "── the act RAISED (HTTP $HTTP_CODE) — nothing committed (all-or-nothing txn) ──" >&2
  printf '%s\n' "$OUT" >&2
  fail "activation act FAILED — read the message above, remediate, re-run"
fi
printf '%s\n' "$OUT"
printf '%s' "$OUT" | grep -qF "$PASS_LINE" || fail "the act did not return the final PASS row (verify the flag before anything else)"
echo "E0 ENEMY-CONTENT-REGISTRY ACTIVATION: OVERALL_PASS — owner authoring RPCs live. NEXT: activate-encounter-authoring.sh (E1)."
