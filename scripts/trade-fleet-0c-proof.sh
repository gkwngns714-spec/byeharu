#!/usr/bin/env bash
# TRADE-FLEET-0C — disposable proof orchestrator for the multi-ship + per-ship-command core (migrations 0073..0084).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in ROLLBACK),
#              toggles the dark flag ONLY inside the txn, provisions via the real RPCs, and asserts properties 1/2/7.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks (arg scaffold / self-rolling-back / flag-inside-txn / out-of-scope / local psql+markers)
# live in scripts/lib/trade-proof-lib.sh; only this proof's specifics live here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/trade-fleet-0c-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="TF0C_PASS_PROVISIONING TF0C_PASS_PROP1 TF0C_PASS_PROP2 TF0C_PASS_PROP7"
PASS_LINE="TRADE-FLEET-0C PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"
  tp_assert_flags_inside_txn "$SQL" mainship_additional_commission_enabled

  # ── provisions via the REAL RPCs (no direct ship inserts as the primary path). ────────────────────
  grep -q "public.commission_first_main_ship()"      "$SQL" || fail "harness does not provision via commission_first_main_ship"
  grep -q "public.commission_additional_main_ship()" "$SQL" || fail "harness does not exercise commission_additional_main_ship"

  # ── the dark/cap/flag gate is asserted (reject-off, no_first_ship, cap block). ─────────────────────
  for tok in additional_commission_disabled no_first_ship ship_cap_reached; do
    grep -q "$tok" "$SQL" || fail "harness does not assert the '$tok' gate"
  done

  # ── the three 0C properties are asserted with explicit PASS markers. ──────────────────────────────
  for m in $MARKERS; do
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

  tp_assert_out_of_scope "$SQL"

  echo "TRADE-FLEET-0C SELFTEST: ALL PASSED (self-rolling-back; dark flag toggled only in-txn; real-RPC provisioning; dark/cap gate; properties 1/2/7; trade-enforcement deferred)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "TRADE-FLEET-0C" "$SQL" "$PASS_LINE" "$MARKERS"
echo "TRADE-FLEET-0C LOCAL PROOF: OVERALL_PASS"
