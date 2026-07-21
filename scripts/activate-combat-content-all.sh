#!/usr/bin/env bash
# COMBAT-CONTENT FULL ACTIVATION runner (E0->E1->E2->E3, ALL FOUR) — wraps scripts/activate-combat-content-all.sql,
# the single-transaction convenience flip that lights all four combat-content flags in strict dependency
# order (migrations 0257-0260; docs/COMBAT_CONTENT_PROGRAM.md). ██ THIS FLIPS E3 TOO — COMBAT GOES LIVE. ██
# For a STAGED rollout run the four per-flag acts in order instead; this file is the one-shot go-live.
# ██ HUMAN TOOL ██ — never wired into CI. Modes mirror activate-unified-movement.sh:
#   bash scripts/activate-combat-content-all.sh selftest
#   bash scripts/activate-combat-content-all.sh run ACTIVATE_COMBAT_CONTENT_ALL
# node equivalent: node scripts/run-activation.mjs scripts/activate-combat-content-all.sql
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_COMBAT_CONTENT_ALL]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-combat-content-all.sql"
CONFIRM_TOKEN="ACTIVATE_COMBAT_CONTENT_ALL"
MIGRATION="20260618000260"
FLAGS="enemy_content_registry_enabled encounter_authoring_enabled encounter_binding_authoring_enabled encounter_resolver_enabled"
MARKERS="ACTALL_PASS_PRECONDITIONS ACTALL_PASS_WRITES ACTALL_PASS_SMOKE"
PASS_LINE="COMBAT-CONTENT FULL ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"

  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command" || true
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;'  || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"

  printf '%s' "$CLEAN" | grep -qF "$MIGRATION" || fail "operation must precondition on the full-chain migration head ($MIGRATION)"
  # every slice's key object must be asserted.
  for obj in reward_profiles enemy_archetypes enemy_fleet_templates encounter_profiles \
             location_encounter_bindings encounter_runtime_state resolve_location_encounter process_combat_ticks; do
    printf '%s' "$CLEAN" | grep -qF "$obj" || fail "operation must assert object $obj is present"
  done
  printf '%s' "$CLEAN" | grep -qF "v_resolver_engaged" || fail "operation must prosrc-pin the resolved branch"

  # the writes: exactly ONE set_game_config call site (the loop; the ROLLBACK's four are stripped), and
  # all four flag keys must appear in the ordered write list, ending with the E3 resolver flag.
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site — the ordered 4-key loop (found $n)"
  for f in $FLAGS; do
    printf '%s' "$CLEAN" | grep -qF "'$f'" || fail "operation must flip $f"
  done
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+(public\.)?[a-z_]+[[:space:]]+set|delete[[:space:]]+from)' && fail "operation writes a table directly" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)[[:space:]]' && fail "operation contains DDL" || true

  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                            || fail "missing final PASS line"
  grep -q "NOT A MIGRATION" "$OP_SQL"                       || fail "operation must document it is an act, not a migration"
  grep -q "RE-RUN SEMANTICS" "$OP_SQL"                      || fail "operation must document the re-run semantics"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                     || fail "missing the marked manual ROLLBACK section"
  grep -qiE "FLIPS ALL FOUR|COMBAT.*LIVE" "$OP_SQL"         || fail "operation must PROMINENTLY warn that it flips all four (combat goes live)"
  grep -qF "set_game_config('encounter_resolver_enabled',          'false'::jsonb)" "$OP_SQL" || fail "the commented ROLLBACK must set the E3 resolver flag false FIRST"

  echo "COMBAT-CONTENT FULL ACTIVATION SELFTEST: ALL PASSED (set_game_config-only over the ordered 4-key list E0->E1->E2->E3; head>=$MIGRATION + all E0-E3 objects + resolved-branch prosrc pin asserted; flips-all-four/combat-live warning present; one timed BEGIN..COMMIT; no meta-command/DDL/table-DML; rollback commented, E3-first)"
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

echo "[act] ██ COMBAT-CONTENT FULL flip (E0->E1->E2->E3) — THIS MAKES COMBAT LIVE ██ against project $SUPABASE_PROJECT_ID (Management API; one all-or-nothing transaction)"
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
printf '%s' "$OUT" | grep -qF "$PASS_LINE" || fail "the act did not return the final PASS row (verify the four flags before anything else)"
echo "██ COMBAT-CONTENT FULL ACTIVATION: OVERALL_PASS — all four flags live; COMBAT BEHAVIOR IS NOW LIVE. Rollback = set encounter_resolver_enabled false first (combat byte-identical again in one tick; see the .sql ROLLBACK section)."
