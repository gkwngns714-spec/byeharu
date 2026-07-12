#!/usr/bin/env bash
# HAUL — disposable proof orchestrator for HAUL-0/1 (migration 0176: haul_contract_templates seed +
# haul_contracts + haul_contracts_enabled flag + the deterministic offer generator + hourly cron),
# HAUL-2 (migration 0179: haul_accept_contract / haul_deliver_contract + haul_receipts + deliver_by +
# the generator's (a2) accepted-past-deliver_by cancel pass), and the HAUL-3 read surface (migration
# 0181: get_port_contracts — dark gate-first reject-before-read + the lit board reflection).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in
#              ROLLBACK), enables haul_contracts_enabled ONLY inside the txn, mints contracts ONLY via
#              the real generator + transitions them ONLY via the real HAUL-2 RPCs (direct inserts are
#              categorically banned — haul_contracts, haul_receipts, AND ship_cargo_lots: delivery
#              cargo must ride the REAL trade_cargo_add_lot leaf), and binds every pin: the dark
#              feature_disabled no-op + the dark RPC haul_contracts_disabled rejects, the exact N×ports
#              count, the live-market reward recompute, the worth-taking self-trade comparison, the
#              raw-hash determinism re-derivation, the offered-only expiry (accepted rows spared), the
#              RLS/ACL shape asserts (incl. haul_receipts + the RPC ACLs), the origin-port accept with
#              the deliver_by = accepted_at + duration anchor + guards (already_accepted/_other,
#              too_many_active with replay-at-cap) + replay, the deliver path (wrong_port / foreign /
#              insufficient_cargo guards, the EXACT wallet + cargo deltas, replay), the deadline
#              (deadline_passed reject + the (a2) cancel freeing the cap slot), and the 0181 read
#              surface (dark gate-first reject + the lit mine/offered board reflection).
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
# The shared blocks (arg scaffold / self-rolling-back / flags-inside-txn / out-of-scope / local psql+markers)
# live in scripts/lib/trade-proof-lib.sh (haul is trade-family); only this proof's specifics live here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/haul-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="HAUL_PASS_DARK_GATE HAUL_PASS_GENERATE HAUL_PASS_WORTH_TAKING HAUL_PASS_DETERMINISM HAUL_PASS_EXPIRY HAUL_PASS_RLS_SHAPE HAUL_PASS_ACCEPT HAUL_PASS_ACCEPT_GUARDS HAUL_PASS_DELIVER_GUARDS HAUL_PASS_DELIVER HAUL_PASS_DEADLINE_CANCEL"
PASS_LINE="HAUL PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── the ONE dark flag is enabled ONLY strictly inside the begin;..rollback; scope. ────────────────
  tp_assert_flags_inside_txn "$SQL" haul_contracts_enabled

  # ── all three starter-port identities (fixed 0066 UUIDs) are asserted. ────────────────────────────
  for pid in b1a00001-0066-4a00-8a00-000000000001 \
             b1a00002-0066-4a00-8a00-000000000002 \
             b1a00003-0066-4a00-8a00-000000000003; do
    grep -q "$pid" "$SQL" || fail "harness does not assert port $pid"
  done

  # ── the dark run is pinned as a cron-safe NO-OP envelope (never a raise) with zero rows; the two
  #    HAUL-2 RPCs are pinned dark-rejecting (haul_contracts_disabled) with zero receipts. ───────────
  grep -q "'feature_disabled'" "$SQL" || fail "harness does not pin the dark feature_disabled envelope"
  grep -q "dark generator created" "$SQL" || fail "harness does not pin zero rows on the dark run"
  grep -q "'haul_contracts_disabled'" "$SQL" || fail "harness does not pin the dark RPC rejects"

  # ── contracts are minted ONLY by the real generator and transitioned ONLY by the real RPCs; the
  #    harness never INSERTs the haul tables or ship_cargo_lots (its marked time-travel/stand-in
  #    FIXTURE updates aside — inserts are categorically banned; delivery cargo must ride the REAL
  #    trade_cargo_add_lot leaf). ──────────────────────────────────────────────────────────────────
  grep -q "public.haul_generate_offers()" "$SQL" || fail "harness does not invoke the real generator"
  grep -q "public.haul_accept_contract(" "$SQL" || fail "harness does not invoke the real accept RPC"
  grep -q "public.haul_deliver_contract(" "$SQL" || fail "harness does not invoke the real deliver RPC"
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.haul_contracts' "$SQL" \
    && fail "harness inserts haul_contracts directly (rows must come from the generator)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.haul_contract_templates' "$SQL" \
    && fail "harness writes haul_contract_templates (Reference/Config — migration-seeded only)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.haul_receipts' "$SQL" \
    && fail "harness inserts haul_receipts directly (sole writers are the two RPCs)" || true
  grep -qiE '(insert[[:space:]]+into|update|delete[[:space:]]+from)[[:space:]]+public\.ship_cargo_lots' "$SQL" \
    && fail "harness writes ship_cargo_lots directly (cargo moves only through Trade-Cargo functions)" || true
  grep -q "public.trade_cargo_add_lot(" "$SQL" || fail "harness does not grant delivery cargo via the REAL trade_cargo_add_lot leaf"

  # ── the exact-count and reward-math pins. ─────────────────────────────────────────────────────────
  grep -q "N x ports" "$SQL" || fail "harness does not pin the exact N x ports offer count"
  grep -q "od.buy_price + t.reward_premium_per_unit" "$SQL" \
    || fail "harness does not recompute the reward off the LIVE dest market row"

  # ── the worth-taking economics pin (self-trade recompute from market_offers). ─────────────────────
  grep -q "self-trade" "$SQL" || fail "harness does not pin the worth-taking self-trade comparison"
  grep -q "od.buy_price - oo.sell_price" "$SQL" || fail "harness does not recompute the self-trade profit"

  # ── the determinism pins: idempotent re-run + the RAW hash technique re-derivation. ───────────────
  grep -q "idempotent within the day" "$SQL" || fail "harness does not pin the same-day idempotent re-run"
  grep -q "hashtextextended" "$SQL" || fail "harness does not re-derive an offer from the raw hash technique"
  grep -q "'haulqty:%s:%s:%s'" "$SQL" || fail "harness does not re-derive the quantity salt"
  grep -q "to_char(v_day, 'YYYY-MM-DD')" "$SQL" || fail "harness does not pin the GUC-stable to_char day rendering"
  grep -q "at time zone 'utc'" "$SQL" || fail "harness does not pin the UTC day boundary"
  grep -q "signature changed" "$SQL" || fail "harness does not pin the offer-set signature across re-runs"

  # ── the expiry pins: offered-only flip; accepted rows NEVER touched while within deliver_by. ──────
  grep -q "status = 'expired'" "$SQL" || fail "harness does not assert the offered->expired flip"
  grep -q "ACCEPTED row" "$SQL" || fail "harness does not pin that within-deadline accepted rows are never touched"

  # ── the RLS/ACL shape asserts (incl. the 0179 receipts + RPC ACLs). ───────────────────────────────
  grep -q "pg_policies" "$SQL" || fail "harness does not assert policy shape via pg_policies"
  grep -q "haul_contracts_offered_public_read" "$SQL" || fail "harness does not pin the bulletin policy"
  grep -q "haul_contracts_accepted_owner_read" "$SQL" || fail "harness does not pin the owner policy"
  grep -q "haul_receipts_select_own" "$SQL" || fail "harness does not pin the receipts owner policy"
  grep -q "has_function_privilege" "$SQL" || fail "harness does not assert the generator ACL"
  grep -q "haul-generate-offers" "$SQL" || fail "harness does not assert the cron job"

  # ── the HAUL-2 accept pins: the deliver_by anchor, the claim's zero movement, guards, replay. ─────
  grep -q "make_interval(secs => t.duration_seconds)" "$SQL" \
    || fail "harness does not recompute the deliver_by = accepted_at + duration anchor"
  grep -q "a claim moves NO credits" "$SQL" || fail "harness does not pin that accept moves no credits"
  grep -q "a claim moves NO cargo" "$SQL" || fail "harness does not pin that accept moves no cargo"
  grep -q "'already_accepted'" "$SQL" || fail "harness does not pin the self double-accept guard"
  grep -q "'already_accepted_other'" "$SQL" || fail "harness does not pin the foreign-accept guard"
  grep -q "'too_many_active'" "$SQL" || fail "harness does not pin the active-cap guard"
  grep -q "replay-at-cap" "$SQL" || fail "harness does not pin that a replayed accept works at the cap"
  grep -q "'contract_not_found'" "$SQL" || fail "harness does not pin the contract_not_found folds"
  grep -q "idempotent_replay" "$SQL" || fail "harness does not pin the idempotent replays"

  # ── the HAUL-2 deliver pins: guards, EXACT wallet/cargo deltas via the real leaves, deadline. ─────
  # ── the HAUL-3 read-surface pins (0181): dark gate-first reject + the lit board reflection. ──────
  grep -q "public.get_port_contracts(" "$SQL" || fail "harness does not invoke the HAUL-3 read RPC"
  grep -q "P0 FAIL dark read" "$SQL" || fail "harness does not pin the dark read reject"
  grep -q "P0 FAIL unauthenticated read" "$SQL" || fail "harness does not pin the unauthenticated read reject"
  grep -q "mine does not carry the accepted contract" "$SQL" || fail "harness does not pin the lit mine reflection"
  grep -q "fresh offered rows" "$SQL" || fail "harness does not pin the lit offered-tab reflection"

  grep -q "'wrong_port'" "$SQL" || fail "harness does not pin the wrong_port deliver guard"
  grep -q "'insufficient_cargo'" "$SQL" || fail "harness does not pin the insufficient_cargo guard"
  grep -q "100 + c.reward_credits" "$SQL" || fail "harness does not pin the EXACT wallet +reward delta"
  grep -q "cost_basis_consumed" "$SQL" || fail "harness does not pin the FIFO cost-basis consumption"
  grep -q "'deadline_passed'" "$SQL" || fail "harness does not pin the past-deadline deliver reject"
  grep -q "accepted_cancelled" "$SQL" || fail "harness does not pin the generator (a2) cancel envelope"
  grep -q "free the active slot" "$SQL" || fail "harness does not pin that the cancel frees the cap slot"

  # ── every property PASS marker is present. ────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "HAUL SELFTEST: ALL PASSED (self-rolling-back; flag inside txn only; generator-minted + RPC-transitioned rows only; dark no-op + dark RPC/read rejects + N x ports + live reward math + worth-taking + hash determinism + offered-only expiry + RLS shape incl. receipts/RPC ACLs + accept anchor/guards/replay + lit board reflection + deliver exact deltas/guards/replay + deadline cancel all pinned)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "HAUL" "$SQL" "$PASS_LINE" "$MARKERS"
echo "HAUL LOCAL PROOF: OVERALL_PASS"
