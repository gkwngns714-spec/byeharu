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
MARKERS="SHOP_PASS_DARK_GATE SHOP_PASS_SEED SHOP_PASS_BUY_MODULE SHOP_PASS_BUY_ITEM SHOP_PASS_IDEMPOTENT SHOP_PASS_GUARDS SHOP_PASS_DEEP_SCAN_WITHDRAWN SHOP_PASS_MINING_RIG_ON_SALE"
PASS_LINE="PORT-SHOP PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── the ONE dark flag is enabled ONLY strictly inside the begin;..rollback; scope. ────────────────
  tp_assert_flags_inside_txn "$SQL" port_shop_enabled

  # -- THE DARK BLOCK MUST SET ITS OWN PRECONDITION. Migration 0300 LIT port_shop_enabled, so a P0 block
  #    that leans on the original seed is asserting a WORLD, not a property -- and it stayed
  #    invisible for weeks because this workflow fired on no branch carrying 0300. Refuse to pass
  #    unless the dark scenario forces the flag false itself, in-txn, before it probes.
  grep -qE "update public\.game_config set value='false'::jsonb where key='port_shop_enabled';" "$SQL" \
    || fail "the dark block does not FORCE port_shop_enabled false -- it is trusting a seed that 0300 already flipped"

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
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.(base_items|fleet_items)'  "$SQL" && fail "harness inserts a port/fleet item store directly (must go through the buy RPC → inventory_deposit)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.port_shop_receipts' "$SQL" && fail "harness writes port_shop_receipts directly (the RPC is the sole writer)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.port_shop_offers'   "$SQL" && fail "harness writes port_shop_offers (Reference/Config — migration-seeded only)" || true

  # ── the exact-delta economics are pinned: the −120 module debit, the −20 ammo debit, the 3×7 table. ─
  grep -q "want -120" "$SQL"            || fail "harness does not pin the exact -120 module wallet delta"
  grep -q "want -20" "$SQL"             || fail "harness does not pin the exact -20 ammo wallet delta"
  grep -q "exactly 7 active offers" "$SQL" || fail "harness does not pin the 3x7 exact offer table (0235's 8 minus the 0342 deep-scan withdrawal)"

  # ── 0342 — THE PURCHASE GATE, NOT A DISABLED BUTTON. ──────────────────────────────────────────────
  #    The verdict this closes: "A disabled React button is not purchase prevention." The proof must
  #    call the REAL buy RPC for the withdrawn ref at ALL THREE starter ports, and must MEASURE the
  #    non-mutation rather than infer it from the returned reason string.
  grep -q "want -110" "$SQL" || fail "harness does not pin the exact -110 mining-rig wallet delta (the not-withdrawn arm)"
  grep -qE "buy_shop_offer_at_port\(.*'deep_scan_sensor_array'" "$SQL" \
    || fail "harness never calls the REAL buy RPC for the withdrawn deep_scan_sensor_array"
  grep -qE "foreach sk in array array\['haven','slag','drift'\]" "$SQL" \
    || fail "harness does not probe the withdrawal at all three starter ports (one representative port is not the claim)"
  grep -q "n_probes <> 3" "$SQL" \
    || fail "harness does not assert that all three port probes actually ran (a skipped loop would pass vacuously)"
  grep -q "mainship_resolve_docked_location" "$SQL" \
    || fail "harness does not CONFIRM each relocation through the real docked resolver — the three probes could all be the same port"
  for w in "moved the wallet" "minted a module instance" "wrote a receipt" "moved a per-port item store"; do
    grep -q "$w" "$SQL" || fail "harness does not measure non-mutation: '$w'"
  done
  grep -qE "buy_shop_offer_at_port\(.*'mining_rig_extension'" "$SQL" \
    || fail "harness never calls the REAL buy RPC for mining_rig_extension (the did-not-overreach arm)"
  grep -q "0342 overreached" "$SQL" \
    || fail "harness does not fail when the mining rig is withdrawn along with the deep-scan array"

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "PORT-SHOP SELFTEST: ALL PASSED (self-rolling-back; flag inside txn only; real-RPC provisioning; exact 3x7 offer table + 3 withdrawn deep-scan rows + wired ammo; buy-module/buy-item/replay properties; full reject-envelope coverage; the 0342 withdrawal probed at all three ports with measured non-mutation, and the mining rig proven still sold)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "PORT-SHOP" "$SQL" "$PASS_LINE" "$MARKERS"
echo "PORT-SHOP LOCAL PROOF: OVERALL_PASS"
