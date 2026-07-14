#!/usr/bin/env bash
# REPAIR-ECON — disposable proof orchestrator for REPAIR-ECON (migration 0201: repair_economy_enabled flag +
# repair_credits_per_hp knob + repair_receipts + repair_ship_hull_at_port), and the destroyed-safelock seam.
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in
#              ROLLBACK), enables repair_economy_enabled ONLY inside the txn, provisions via the REAL RPCs
#              (commission_first_main_ship; damage via a fixture hp write, never a direct receipt insert),
#              asserts the 0.5 knob, every reject envelope, the exact-cost economics, and the safelock seam
#              (a destroyed ship rejected by the paid path + recovered FREE by repair_main_ship).
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks (arg scaffold / self-rolling-back / flags-inside-txn / out-of-scope / local psql+markers)
# live in scripts/lib/trade-proof-lib.sh (repair is a docked-port economy in the trade family); only this
# proof's specifics live here. Standalone (NOT team-command-proof: a parallel MOD2-2 slice owns that block).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/repair-econ-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="REPAIR_PASS_DARK_GATE REPAIR_PASS_SEED REPAIR_PASS_HAPPY REPAIR_PASS_PARTIAL REPAIR_PASS_IDEMPOTENT REPAIR_PASS_GUARDS REPAIR_PASS_SAFELOCK"
PASS_LINE="REPAIR-ECON PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── the ONE dark flag is enabled ONLY strictly inside the begin;..rollback; scope. ────────────────
  tp_assert_flags_inside_txn "$SQL" repair_economy_enabled

  # ── all three starter-port identities (fixed 0066 UUIDs) are referenced (Haven repair site + move target). ──
  for pid in b1a00001-0066-4a00-8a00-000000000001 \
             b1a00002-0066-4a00-8a00-000000000002 \
             b1a00003-0066-4a00-8a00-000000000003; do
    grep -q "$pid" "$SQL" || fail "harness does not reference port $pid"
  done

  # ── the seed knob is pinned to the approved 0.5 [D]. ──────────────────────────────────────────────
  grep -q "repair_credits_per_hp" "$SQL" || fail "harness does not read the cost knob repair_credits_per_hp"
  grep -q "want the seeded 0.5" "$SQL"    || fail "harness does not pin the 0.5 knob seed"

  # ── every reject envelope of the charter order is exercised (incl. the safelock seam ship_destroyed). ──
  for tok in repair_economy_disabled invalid_amount ship_not_found ship_destroyed not_docked nothing_to_repair insufficient_credits idempotent_replay; do
    grep -q "'$tok'" "$SQL" || fail "harness does not exercise reject/replay envelope '$tok'"
  done

  # ── the exact-delta economics are pinned: 120hp→60cr full mend, 40hp→20cr partial, no double-charge. ──
  grep -q "want exactly -60" "$SQL"      || fail "harness does not pin the exact -60 full-mend wallet delta"
  grep -q "restore 40, debit 20" "$SQL"  || fail "harness does not pin the exact partial-mend economics"
  grep -q "hp_restored=120" "$SQL"       || fail "harness does not pin the clamped 120-hp restore + receipt fields"

  # ── THE SAFELOCK SEAM: the destroyed ship is destroyed via the REAL primitive and recovered by the
  #    FREE repair_main_ship — and the harness proves the free path is UNGATED (runs with the flag LIT). ──
  grep -q "public.dev_set_main_ship_destroyed" "$SQL" || fail "harness does not destroy via the real primitive"
  grep -q "public.repair_main_ship()" "$SQL"          || fail "harness does not exercise the FREE safelock recovery"
  grep -q "free safelock charged the wallet" "$SQL"    || fail "harness does not assert the free recovery is zero-cost"

  # ── provisioning is via the REAL RPC, never a direct repair_receipts insert (the RPC is the sole writer). ──
  grep -q "public.commission_first_main_ship()" "$SQL" || fail "harness does not commission ships via the real RPC"
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.repair_receipts' "$SQL" \
    && fail "harness inserts repair_receipts directly (must be minted by repair_ship_hull_at_port only)" || true

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "REPAIR-ECON SELFTEST: ALL PASSED (self-rolling-back; flag inside txn only; real-RPC provisioning; 0.5 knob + exact-cost economics; full reject-envelope coverage; destroyed-safelock seam preserved free + intact)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "REPAIR-ECON" "$SQL" "$PASS_LINE" "$MARKERS"
echo "REPAIR-ECON LOCAL PROOF: OVERALL_PASS"
