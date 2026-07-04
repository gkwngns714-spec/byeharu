#!/usr/bin/env bash
# TRADE-ECONOMY-BOOTSTRAP — disposable proof orchestrator for seed capital + the no-softlock relief floor (0093..0095).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in ROLLBACK),
#              toggles the dark flags ONLY inside the txn, provisions via the real RPCs, and asserts every property.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks (arg scaffold / self-rolling-back / flag-inside-txn / out-of-scope / local psql+markers)
# live in scripts/lib/trade-proof-lib.sh; only this proof's specifics live here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/trade-economy-bootstrap-proof.sql"

# the property PASS markers and the key reject-reason tokens this proof must exercise.
MARKERS="SEED_PASS_DARK SEED_PASS_APPLIED SEED_PASS_ONCE \
         RELIEF_PASS_DARK RELIEF_PASS_NO_WALLET RELIEF_PASS_WALLET_NOT_EMPTY RELIEF_PASS_CARGO_NOT_EMPTY \
         RELIEF_PASS_GRANT RELIEF_PASS_IDEMPOTENT RELIEF_PASS_COOLDOWN RELIEF_PASS_CAP"
PASS_LINE="TRADE-ECONOMY-BOOTSTRAP PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"
  tp_assert_flags_inside_txn "$SQL" trade_market_enabled trade_relief_enabled

  # ── provisions via the REAL RPCs + sets up wallet as the owner (rolled back). ─────────────────────
  grep -q "public.commission_first_main_ship()" "$SQL" || fail "harness does not provision the first ship via the real RPC"
  grep -q "public.market_buy("          "$SQL" || fail "harness does not exercise public.market_buy (seed path)"
  grep -q "public.market_claim_relief(" "$SQL" || fail "harness does not exercise public.market_claim_relief"
  grep -qE "insert into public\.player_wallet \(player_id, balance\)" "$SQL" || fail "harness does not set up the wallet (owner insert)"

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done

  # ── the key reject/replay reason tokens are exercised. ────────────────────────────────────────────
  for tok in trade_market_disabled trade_relief_disabled no_wallet wallet_not_empty cargo_not_empty \
             idempotent_replay relief_cooldown_active relief_cap_reached; do
    grep -q "$tok" "$SQL" || fail "harness does not assert '$tok'"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "TRADE-ECONOMY-BOOTSTRAP SELFTEST: ALL PASSED (self-rolling-back; dark flags toggled only in-txn; real-RPC provisioning; seed + relief anti-farm markers; reject-path reason asserts)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "TRADE-ECONOMY-BOOTSTRAP" "$SQL" "$PASS_LINE" "$MARKERS"
echo "TRADE-ECONOMY-BOOTSTRAP LOCAL PROOF: OVERALL_PASS"
