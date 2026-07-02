#!/usr/bin/env bash
# TRADE-FLEET-0C — disposable proof orchestrator for the multi-ship + per-ship-command core (migrations 0073..0084).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in ROLLBACK),
#              toggles the dark flag ONLY inside the txn, provisions via the real RPCs, and asserts properties 1/2/7.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local) : ;; *) echo "usage: $0 <selftest|local>" >&2; exit 2;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL="$REPO_ROOT/scripts/trade-fleet-0c-proof.sql"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  # ── self-rolling-back: opens a txn, ends in ROLLBACK, and NEVER commits. ──────────────────────────
  grep -qiE '^[[:space:]]*begin;' "$SQL"    || fail "harness does not open a transaction (begin;)"
  grep -qiE '^[[:space:]]*rollback;' "$SQL" || fail "harness does not end in ROLLBACK"
  # last SQL statement must be the ROLLBACK (nothing persists after it); strip any inline comment before matching.
  LAST_TXN_VERB="$(grep -iE '^[[:space:]]*(commit|rollback);' "$SQL" | tail -1 | sed -E 's/--.*//' | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
  [ "$LAST_TXN_VERB" = "rollback;" ] || fail "final transaction verb is not ROLLBACK (got '$LAST_TXN_VERB')"
  # NO COMMIT anywhere (a stray commit would persist test state / a flag flip).
  grep -qiE '^[[:space:]]*commit;' "$SQL" && fail "harness contains a COMMIT (must never persist state)" || true

  # ── dark capability toggled ONLY inside the txn (between begin; and rollback;), then rolled back. ──
  grep -qE "update public\.game_config set value='true'::jsonb where key='mainship_additional_commission_enabled';" "$SQL" \
    || fail "harness does not enable the dark add-ship flag inside the txn"
  BEGIN_LN="$(grep -niE '^[[:space:]]*begin;' "$SQL" | head -1 | cut -d: -f1)"
  ROLLBACK_LN="$(grep -niE '^[[:space:]]*rollback;' "$SQL" | tail -1 | cut -d: -f1)"
  FLAG_LN="$(grep -nE "key='mainship_additional_commission_enabled'" "$SQL" | head -1 | cut -d: -f1)"
  [ "$BEGIN_LN" -lt "$FLAG_LN" ] && [ "$FLAG_LN" -lt "$ROLLBACK_LN" ] || fail "dark-flag toggle is not strictly inside the begin;..rollback; scope"
  # the committed/production flag value is never written outside the txn (no COMMIT above guarantees revert).

  # ── provisions via the REAL RPCs (no direct ship inserts as the primary path). ────────────────────
  grep -q "public.commission_first_main_ship()"      "$SQL" || fail "harness does not provision via commission_first_main_ship"
  grep -q "public.commission_additional_main_ship()" "$SQL" || fail "harness does not exercise commission_additional_main_ship"

  # ── the dark/cap/flag gate is asserted (reject-off, no_first_ship, cap block). ─────────────────────
  for tok in additional_commission_disabled no_first_ship ship_cap_reached; do
    grep -q "$tok" "$SQL" || fail "harness does not assert the '$tok' gate"
  done

  # ── the three 0C properties are asserted with explicit PASS markers. ──────────────────────────────
  for m in TF0C_PASS_PROVISIONING TF0C_PASS_PROP1 TF0C_PASS_PROP2 TF0C_PASS_PROP7; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  # property specifics: coexistence reads cargo_capacity_m3; movement uses explicit p_main_ship_id + per-ship
  # receipt scoping; shim uses zero-arg calls + multi-ship ambiguity.
  grep -q "cargo_capacity_m3" "$SQL"                                        || fail "PROP1 does not check the volume capacity column"
  grep -q "command_main_ship_space_move_to_location(%L::uuid, gen_random_uuid(), %L::uuid)" "$SQL" || fail "PROP2 does not command a ship by explicit p_main_ship_id"
  grep -q "main_ship_space_movements" "$SQL"                                || fail "PROP2 does not assert per-ship receipt scoping"
  grep -q "no_main_ship" "$SQL"                                             || fail "PROP7 does not assert multi-ship shim ambiguity fails closed"

  # ── the two trade-enforcement properties are explicitly DEFERRED (no buy/sell RPC exists in 0C). ──
  grep -qi "deferred to TRADE-MARKET-1" "$SQL" || fail "harness does not record the deferred trade-enforcement properties"

  # ── does NOT touch src/, migrations, or committed flag state outside the txn. ─────────────────────
  grep -qiE '\.\./src|/src/|migrations/' "$SQL" && fail "proof references src/ or migrations (out of scope)" || true

  echo "TRADE-FLEET-0C SELFTEST: ALL PASSED (self-rolling-back; dark flag toggled only in-txn; real-RPC provisioning; dark/cap gate; properties 1/2/7; trade-enforcement deferred)"
  exit 0
fi

# ── local: run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof) ───────────
: "${DB_URL:?DB_URL (disposable stack) required}"
OUT="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$SQL" 2>&1)" || { echo "$OUT" >&2; fail "real-chain TRADE-FLEET-0C proof failed"; }
printf '%s\n' "$OUT"
printf '%s' "$OUT" | grep -q "TRADE-FLEET-0C PROOF PASSED" || fail "proof did not report PASS"
for m in TF0C_PASS_PROVISIONING TF0C_PASS_PROP1 TF0C_PASS_PROP2 TF0C_PASS_PROP7; do
  printf '%s' "$OUT" | grep -q "$m" || fail "proof missing marker $m"
done
echo "TRADE-FLEET-0C LOCAL PROOF: OVERALL_PASS"
