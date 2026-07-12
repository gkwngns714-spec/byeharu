#!/usr/bin/env bash
# SHIPYARD — disposable proof orchestrator for SHIPYARD-1 (migration 0188: the hull-build ORDER
# command start_hull_build on the reused M4.5 build_orders queue + hull_build_receipts).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends
#              in ROLLBACK), enables shipyard_enabled ONLY inside the txn via the raw-update idiom
#              (and NEVER via set_game_config — the mutation-evasion catch, the 0185-era hardened
#              pattern), provisions via the REAL pipeline leaves (reward_grant / captains_mint_instance,
#              never direct player_inventory / captain_instances / hull_build_receipts writes), and
#              asserts the exact 0185 recipe economics, every reject envelope, the no-existence-oracle
#              pin, the replay pin, the self-prereq pin, and the 0038 engine-seam pin.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks (arg scaffold / self-rolling-back / flags-inside-txn / out-of-scope / local
# psql+markers) live in scripts/lib/trade-proof-lib.sh (REUSED per the standing law); only this
# proof's specifics live here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/shipyard-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="SHIPYARD_PASS_DARK_GATE SHIPYARD_PASS_ORDER SHIPYARD_PASS_REPLAY SHIPYARD_PASS_SHORTFALL SHIPYARD_PASS_GATES SHIPYARD_PASS_SELF_PREREQ SHIPYARD_PASS_QUEUE_SEAM SHIPYARD_PASS_RETENTION"
PASS_LINE="SHIPYARD-1 PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── the ONE dark flag is enabled ONLY strictly inside the begin;..rollback; scope. ────────────────
  tp_assert_flags_inside_txn "$SQL" shipyard_enabled

  # ── NEVER-FLIP evasion catch (the 0185-era hardened pattern): the raw-update-inside-txn idiom is
  #    the ONLY sanctioned toggle; a set_game_config('shipyard_enabled', …) call would evade the
  #    inside-txn line check above, so its mere presence (outside comments) fails the selftest. ──────
  sed -E 's/--.*//' "$SQL" \
    | grep -q "set_game_config('shipyard_enabled'" \
    && fail "harness flips shipyard_enabled via set_game_config (only the raw-update-in-txn idiom is sanctioned)" || true

  # ── provisioning rides the REAL pipeline leaves only (sole-writer laws, in assert form). ──────────
  grep -q "public.reward_grant(" "$SQL" || fail "harness does not provision items via public.reward_grant (the real pipeline)"
  grep -q "public.captains_mint_instance(" "$SQL" || fail "harness does not mint the gate captain via the sole Captain leaf"
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.player_inventory' "$SQL" \
    && fail "harness inserts player_inventory directly (must go through reward_grant)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.captain_instances' "$SQL" \
    && fail "harness inserts captain_instances directly (must go through captains_mint_instance)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.hull_build_receipts' "$SQL" \
    && fail "harness inserts hull_build_receipts directly (Production is sole writer)" || true
  grep -qiE 'update[[:space:]]+public\.player_wallet|update[[:space:]]+public\.player_inventory' "$SQL" \
    && fail "harness updates wallet/inventory directly (sole-writer breach)" || true

  # ── the exact 0185 recipe economics are pinned in assert form. ────────────────────────────────────
  grep -q "want exactly 100 = 500 - 400" "$SQL" || fail "harness does not pin the exact 400-credit debit"
  for it in ore crystal engine_parts scrap blueprint_fragment weapon_parts pirate_alloy; do
    grep -q "\"$it\"" "$SQL" || fail "harness does not provision/assert recipe ingredient '$it'"
  done
  grep -q "jsonb_array_length(ingredients_json)=5" "$SQL" || fail "harness does not pin the 5-ingredient receipt"

  # ── every reject envelope + the anti-oracle + replay + seam pins are exercised (assert form). ─────
  for tok in feature_disabled unknown_hull no_recipe hull_prerequisite_not_met captain_level_too_low \
             queue_full insufficient_items insufficient_credits idempotent_replay; do
    grep -q "'$tok'" "$SQL" || fail "harness does not exercise reject/replay envelope '$tok'"
  done
  grep -q "existence oracle" "$SQL"              || fail "harness does not pin the dark no-existence-oracle property"
  grep -q "replay order_id differs" "$SQL"       || fail "harness does not pin same-request_id -> same order/receipt"
  grep -q "hull_recipe_no_self_prereq" "$SQL"    || fail "harness does not pin the self-prereq impossibility"
  grep -q "promoted/completed by the 0038 engine" "$SQL" || fail "harness does not pin the 0038 engine-invisibility seam"
  grep -q "public.process_build_queue()" "$SQL"  || fail "harness does not invoke the real queue processor"
  grep -q "public.production_start_next(" "$SQL" || fail "harness does not invoke the real queue promoter"
  grep -q "all-or-nothing" "$SQL"                || fail "harness does not pin the all-or-nothing spend ordering"

  # ── the RETENTION property (review H1): the REAL 0047 reaper is run and the receipt's survival +
  #    the no-second-order stale retry are pinned in assert form. ────────────────────────────────────
  grep -q "public.maintenance_cleanup_runtime_data(false" "$SQL" \
    || fail "harness does not run the REAL 0047 reaper (maintenance_cleanup_runtime_data, wet run)"
  grep -q "survive the reap with order_id NULL" "$SQL" \
    || fail "harness does not pin receipt survival (order_id -> NULL) past the 0047 reap"
  grep -q "placed a SECOND order" "$SQL" \
    || fail "harness does not pin the no-second-order stale-retry property"

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "SHIPYARD SELFTEST: ALL PASSED (self-rolling-back; flag inside txn only + set_game_config evasion catch; real-pipeline provisioning + sole-writer pins; exact 0185 economics; full reject-envelope + oracle/replay/self-prereq/engine-seam + 0047-retention coverage)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "SHIPYARD" "$SQL" "$PASS_LINE" "$MARKERS"
echo "SHIPYARD LOCAL PROOF: OVERALL_PASS"
