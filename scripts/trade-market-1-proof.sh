#!/usr/bin/env bash
# TRADE-MARKET-1 — disposable proof orchestrator for the atomic trade surface + priced add-ship (migrations 0085..0091).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in ROLLBACK),
#              toggles the dark flags ONLY inside the txn, provisions via the real RPCs, and asserts P0..P8.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks (arg scaffold / self-rolling-back / flag-inside-txn / out-of-scope / local psql+markers)
# live in scripts/lib/trade-proof-lib.sh; only this proof's specifics live here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/trade-market-1-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="TM1_PASS_DARK_GATE TM1_PASS_OFFERS TM1_PASS_BUY TM1_PASS_BUY_IDEMPOTENT TM1_PASS_VOLUME \
         TM1_PASS_CREDITS TM1_PASS_SELL_FIFO TM1_PASS_SELL_GUARDS TM1_PASS_ADD_SHIP_PRICE"
PASS_LINE="TRADE-MARKET-1 PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"
  tp_assert_flags_inside_txn "$SQL" trade_market_enabled mainship_additional_commission_enabled

  # ── provisions via the REAL RPCs + funds wallet as the owner (rolled back). ───────────────────────
  grep -q "public.commission_first_main_ship()"      "$SQL" || fail "harness does not provision the first ship via the real RPC"
  grep -q "public.commission_additional_main_ship()" "$SQL" || fail "harness does not exercise the priced add-ship RPC"
  for rpc in get_market_offers market_buy market_sell; do
    grep -q "public.$rpc(" "$SQL" || fail "harness does not exercise public.$rpc"
  done
  grep -qE "insert into public\.player_wallet \(player_id, balance\)" "$SQL" || fail "harness does not fund the wallet (owner insert)"

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done

  # ── the reject paths assert NO writes; the key reasons are exercised. ─────────────────────────────
  for tok in trade_market_disabled not_docked idempotent_replay insufficient_volume insufficient_credits \
             insufficient_cargo cost_basis_consumed realized_margin; do
    grep -q "$tok" "$SQL" || fail "harness does not assert '$tok'"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "TRADE-MARKET-1 SELFTEST: ALL PASSED (self-rolling-back; dark flags toggled only in-txn; real-RPC provisioning; P0..P8 markers; reject-path no-write asserts)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "TRADE-MARKET-1" "$SQL" "$PASS_LINE" "$MARKERS"
echo "TRADE-MARKET-1 LOCAL PROOF: OVERALL_PASS"
