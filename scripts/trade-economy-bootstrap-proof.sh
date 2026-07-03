#!/usr/bin/env bash
# TRADE-ECONOMY-BOOTSTRAP — disposable proof orchestrator for seed capital + the no-softlock relief floor (0093..0095).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in ROLLBACK),
#              toggles the dark flags ONLY inside the txn, provisions via the real RPCs, and asserts every property.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local) : ;; *) echo "usage: $0 <selftest|local>" >&2; exit 2;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL="$REPO_ROOT/scripts/trade-economy-bootstrap-proof.sql"

# the property PASS markers and the key reject-reason tokens this proof must exercise.
MARKERS="SEED_PASS_DARK SEED_PASS_APPLIED SEED_PASS_ONCE \
         RELIEF_PASS_DARK RELIEF_PASS_NO_WALLET RELIEF_PASS_WALLET_NOT_EMPTY RELIEF_PASS_CARGO_NOT_EMPTY \
         RELIEF_PASS_GRANT RELIEF_PASS_IDEMPOTENT RELIEF_PASS_COOLDOWN RELIEF_PASS_CAP"
PASS_LINE="TRADE-ECONOMY-BOOTSTRAP PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  # ── self-rolling-back: opens a txn, ends in ROLLBACK, and NEVER commits. ──────────────────────────
  grep -qiE '^[[:space:]]*begin;' "$SQL"    || fail "harness does not open a transaction (begin;)"
  grep -qiE '^[[:space:]]*rollback;' "$SQL" || fail "harness does not end in ROLLBACK"
  # last SQL statement must be the ROLLBACK (strip any inline comment before matching).
  LAST_TXN_VERB="$(grep -iE '^[[:space:]]*(commit|rollback);' "$SQL" | tail -1 | sed -E 's/--.*//' | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
  [ "$LAST_TXN_VERB" = "rollback;" ] || fail "final transaction verb is not ROLLBACK (got '$LAST_TXN_VERB')"
  grep -qiE '^[[:space:]]*commit;' "$SQL" && fail "harness contains a COMMIT (must never persist state)" || true

  # ── the dark flags are toggled ONLY inside the txn (between begin; and rollback;). ────────────────
  BEGIN_LN="$(grep -niE '^[[:space:]]*begin;' "$SQL" | head -1 | cut -d: -f1)"
  ROLLBACK_LN="$(grep -niE '^[[:space:]]*rollback;' "$SQL" | tail -1 | cut -d: -f1)"
  for flag in trade_market_enabled trade_relief_enabled; do
    grep -qE "update public\.game_config set value='true'::jsonb where key='$flag';" "$SQL" \
      || fail "harness does not enable the dark flag '$flag' inside the txn"
    FLAG_LN="$(grep -nE "set value='true'::jsonb where key='$flag'" "$SQL" | head -1 | cut -d: -f1)"
    { [ "$BEGIN_LN" -lt "$FLAG_LN" ] && [ "$FLAG_LN" -lt "$ROLLBACK_LN" ]; } || fail "'$flag' toggle is not strictly inside begin;..rollback;"
  done
  # the committed/production flag values are never written outside the txn (no COMMIT above guarantees revert).

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

  # ── does NOT touch src/ or migrations. ───────────────────────────────────────────────────────────
  grep -qiE '\.\./src|/src/|migrations/' "$SQL" && fail "proof references src/ or migrations (out of scope)" || true

  echo "TRADE-ECONOMY-BOOTSTRAP SELFTEST: ALL PASSED (self-rolling-back; dark flags toggled only in-txn; real-RPC provisioning; seed + relief anti-farm markers; reject-path reason asserts)"
  exit 0
fi

# ── local: run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property proof) ───────────
: "${DB_URL:?DB_URL (disposable stack) required}"
OUT="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$SQL" 2>&1)" || { echo "$OUT" >&2; fail "real-chain TRADE-ECONOMY-BOOTSTRAP proof failed"; }
printf '%s\n' "$OUT"
printf '%s' "$OUT" | grep -q "$PASS_LINE" || fail "proof did not report PASS"
for m in $MARKERS; do
  printf '%s' "$OUT" | grep -q "$m" || fail "proof missing marker $m"
done
echo "TRADE-ECONOMY-BOOTSTRAP LOCAL PROOF: OVERALL_PASS"
