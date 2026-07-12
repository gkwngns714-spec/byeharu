#!/usr/bin/env bash
# TRADE-ECON-SEED-1 — disposable proof orchestrator for the multiport economy seed (migration 0173).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in
#              ROLLBACK), READ-ONLY (touches no game_config flag), and asserts E1..E4 over the exact
#              approved 3-port × 6-good price table.
#   local    — run the read-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks (arg scaffold / self-rolling-back / out-of-scope / local psql+markers) live in
# scripts/lib/trade-proof-lib.sh; only this proof's specifics live here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/trade-econ-seed-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="ES1_PASS_MULTIPORT ES1_PASS_ROUTES ES1_PASS_ANTIPUMP ES1_PASS_ROLES"
PASS_LINE="TRADE-ECON-SEED PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── READ-ONLY over Reference/Config: no flag toggle, no fixture provisioning, no writes. ──────────
  grep -q "game_config" "$SQL" && fail "catalog proof must not touch game_config (no flag toggles)" || true
  grep -qiE '^[[:space:]]*(insert|update|delete)[[:space:]]' "$SQL" && fail "catalog proof must be read-only" || true

  # ── all three starter-port identities (fixed 0066 UUIDs) and all six 0073 goods are asserted. ─────
  for pid in b1a00001-0066-4a00-8a00-000000000001 \
             b1a00002-0066-4a00-8a00-000000000002 \
             b1a00003-0066-4a00-8a00-000000000003; do
    grep -q "$pid" "$SQL" || fail "harness does not assert port $pid"
  done
  for g in textiles ore provisions reagents machinery luxury_goods; do
    grep -q "'$g'" "$SQL" || fail "harness does not assert good '$g'"
  done

  # ── the route-profit recomputation + the invariant tokens are exercised. ──────────────────────────
  for tok in route_profit anti_pump "dest.buy" "origin.sell"; do
    grep -q "$tok" "$SQL" || fail "harness does not assert '$tok'"
  done

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "TRADE-ECON-SEED SELFTEST: ALL PASSED (self-rolling-back; read-only/no flag toggle; 3-port x 6-good exact-table, route-profit, anti-pump, role markers)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "TRADE-ECON-SEED" "$SQL" "$PASS_LINE" "$MARKERS"
echo "TRADE-ECON-SEED LOCAL PROOF: OVERALL_PASS"
