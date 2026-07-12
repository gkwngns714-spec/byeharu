#!/usr/bin/env bash
# SALVAGE-MARKET — disposable proof orchestrator for SALVAGE-0/1 (migration 0174: port_item_demand seed +
# salvage_market_enabled flag + sell_item_at_port).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in
#              ROLLBACK), enables salvage_market_enabled ONLY inside the txn, provisions via the REAL
#              RPCs/pipeline (reward_grant, never a direct player_inventory insert), and asserts the exact
#              approved 3-port × 5-droppable price table, every reject envelope, and the never-sellable pin.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks (arg scaffold / self-rolling-back / flags-inside-txn / out-of-scope / local psql+markers)
# live in scripts/lib/trade-proof-lib.sh (salvage is trade-family); only this proof's specifics live here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/salvage-market-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="SV1_PASS_DARK_GATE SV1_PASS_SEED_TABLE SV1_PASS_SELL SV1_PASS_IDEMPOTENT SV1_PASS_GUARDS SV1_PASS_NEVER_SELLABLE"
PASS_LINE="SALVAGE-MARKET PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── the ONE dark flag is enabled ONLY strictly inside the begin;..rollback; scope. ────────────────
  tp_assert_flags_inside_txn "$SQL" salvage_market_enabled

  # ── all three starter-port identities (fixed 0066 UUIDs) are asserted. ────────────────────────────
  for pid in b1a00001-0066-4a00-8a00-000000000001 \
             b1a00002-0066-4a00-8a00-000000000002 \
             b1a00003-0066-4a00-8a00-000000000003; do
    grep -q "$pid" "$SQL" || fail "harness does not assert port $pid"
  done

  # ── every combat droppable (the 0041/0171 loot table) appears in the exact-table pin. ─────────────
  for it in scrap pirate_alloy weapon_parts engine_parts repair_parts; do
    grep -q "'$it'" "$SQL" || fail "harness does not assert droppable '$it'"
  done

  # ── the never-sellable progression trio is asserted ABSENT (by id and by category). ───────────────
  for it in captain_memory_shard blueprint_fragment artifact_core; do
    grep -q "'$it'" "$SQL" || fail "harness does not assert progression item '$it'"
  done
  grep -q "category = 'progression'" "$SQL" || fail "harness does not assert progression absence by 0039 category"

  # ── every reject envelope of the charter order is exercised. ──────────────────────────────────────
  for tok in salvage_market_disabled invalid_quantity not_docked no_demand insufficient_items idempotent_replay; do
    grep -q "'$tok'" "$SQL" || fail "harness does not exercise reject/replay envelope '$tok'"
  done

  # ── items are granted via the REAL reward pipeline leaf, never a direct inventory insert. ─────────
  grep -q "public.reward_grant(" "$SQL" || fail "harness does not provision via public.reward_grant (the real pipeline)"
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.player_inventory' "$SQL" \
    && fail "harness inserts player_inventory directly (must go through reward_grant)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.port_item_demand' "$SQL" \
    && fail "harness writes port_item_demand (Reference/Config — migration-seeded only)" || true

  # ── the exact-delta economics are pinned: qty×price 60, the 15-row table, the 30..80 band. ────────
  grep -q "expected exactly 15 demand rows" "$SQL" || fail "harness does not pin the 15-row exact table"
  grep -q "want exactly +60" "$SQL"               || fail "harness does not pin the exact wallet delta"
  grep -q "30..80" "$SQL"                          || fail "harness does not recompute the Snare-run 30..80 band"

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "SALVAGE-MARKET SELFTEST: ALL PASSED (self-rolling-back; flag inside txn only; real-pipeline provisioning; exact 15-row price table + never-sellable pin; full reject-envelope coverage)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "SALVAGE-MARKET" "$SQL" "$PASS_LINE" "$MARKERS"
echo "SALVAGE-MARKET LOCAL PROOF: OVERALL_PASS"
