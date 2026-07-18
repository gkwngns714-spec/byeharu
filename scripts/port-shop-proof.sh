#!/usr/bin/env bash
# PORT-SHOP — disposable proof orchestrator for PORT-SHOP (migration 0235: port_shop_offers seed +
# port_shop_enabled flag + buy_shop_offer_at_port + get_port_shop + the autocannon_rounds/shield_generator
# catalog seeds).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in
#              ROLLBACK), enables port_shop_enabled ONLY inside the txn, provisions via the REAL RPCs
#              (commission_first_main_ship, never a direct module/inventory/receipt insert), and exercises
#              every reject envelope + the buy-module / buy-item / replay properties.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks live in scripts/lib/trade-proof-lib.sh (port-shop is trade-family: buy-list + gated
# RPC + receipts); only this proof's specifics live here (the salvage-market-proof.sh precedent).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/port-shop-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="SHOP_PASS_DARK_GATE SHOP_PASS_SEED SHOP_PASS_BUY_MODULE SHOP_PASS_BUY_ITEM SHOP_PASS_IDEMPOTENT SHOP_PASS_GUARDS"
PASS_LINE="PORT-SHOP PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── the ONE dark flag is enabled ONLY strictly inside the begin;..rollback; scope. ────────────────
  tp_assert_flags_inside_txn "$SQL" port_shop_enabled

  # ── all three starter-port identities (fixed 0066 UUIDs) are asserted. ────────────────────────────
  for pid in b1a00001-0066-4a00-8a00-000000000001 \
             b1a00002-0066-4a00-8a00-000000000002 \
             b1a00003-0066-4a00-8a00-000000000003; do
    grep -q "$pid" "$SQL" || fail "harness does not assert port $pid"
  done

  # ── every offered ref (the beginner outfit, incl. the two new catalog rows) is exercised. ─────────
  for ref in autocannon_battery shield_generator shield_lattice vector_thruster_kit \
             deep_scan_sensor_array expanded_cargo_lattice mining_rig_extension autocannon_rounds; do
    grep -q "'$ref'" "$SQL" || fail "harness does not reference offered ref '$ref'"
  done

  # ── the Mk-II progression tiers are asserted ABSENT from sale. ────────────────────────────────────
  for it in autocannon_battery_mk2 shield_lattice_mk2; do
    grep -q "'$it'" "$SQL" || fail "harness does not assert Mk-II '$it' is not sold"
  done

  # ── every reject/replay envelope the proof exercises live (not_docked shares the salvage/repair
  #    docked-resolver, proven there; the live movement command is mid-refactor at this chain head). ──
  for tok in port_shop_disabled invalid_quantity no_offer module_qty_must_be_one insufficient_credits idempotent_replay; do
    grep -q "'$tok'" "$SQL" || fail "harness does not exercise reject/replay envelope '$tok'"
  done

  # ── ships are provisioned via the REAL RPC, never a direct module/inventory/receipt/offer insert. ─
  grep -q "public.commission_first_main_ship()" "$SQL" || fail "harness does not provision via commission_first_main_ship (the real RPC)"
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.module_instances'  "$SQL" && fail "harness inserts module_instances directly (must go through the buy RPC → modules_mint_instance)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.player_inventory'  "$SQL" && fail "harness inserts player_inventory directly (must go through the buy RPC → inventory_deposit)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.port_shop_receipts' "$SQL" && fail "harness writes port_shop_receipts directly (the RPC is the sole writer)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.port_shop_offers'   "$SQL" && fail "harness writes port_shop_offers (Reference/Config — migration-seeded only)" || true

  # ── the exact-delta economics are pinned: the −120 module debit, the −20 ammo debit, the 3×8 table. ─
  grep -q "want -120" "$SQL"            || fail "harness does not pin the exact -120 module wallet delta"
  grep -q "want -20" "$SQL"             || fail "harness does not pin the exact -20 ammo wallet delta"
  grep -q "exactly 8 active offers" "$SQL" || fail "harness does not pin the 3x8 exact offer table"

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "PORT-SHOP SELFTEST: ALL PASSED (self-rolling-back; flag inside txn only; real-RPC provisioning; exact 3x8 offer table + wired ammo; buy-module/buy-item/replay properties; full reject-envelope coverage)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "PORT-SHOP" "$SQL" "$PASS_LINE" "$MARKERS"
echo "PORT-SHOP LOCAL PROOF: OVERALL_PASS"
