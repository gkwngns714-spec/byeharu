#!/usr/bin/env bash
# ENCOUNTER RESOLVER — disposable proof runner (run against a THROWAWAY local Supabase).
#
# Drives scripts/encounter-resolver-proof.sql against a disposable DB_URL and asserts every PASS marker.
# The SQL is self-rolling-back (begin;…rollback;) — it flips every gate flag ON only INSIDE the txn and
# leaves ZERO persisted state. NEVER point this at production. Run locally:
#   DB_URL="$(supabase status -o env | grep '^DB_URL=' | cut -d= -f2-)" ./scripts/encounter-resolver-proof.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$SCRIPT_DIR/encounter-resolver-proof.sql"
[ -f "$SQL" ] || { echo "proof sql not found: $SQL"; exit 1; }
: "${DB_URL:?DB_URL (disposable stack) required}"

out="$(psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$SQL" 2>&1)"
echo "$out"

for marker in \
  ER_PASS_VERBATIM \
  ER_PASS_REWARD_UNTOUCHED \
  ER_PASS_DETERMINISM \
  ER_PASS_NULL_FLAGS \
  ER_PASS_NULL_BINDING \
  ER_PASS_NULL_INACTIVE_LOC \
  ER_PASS_COOLDOWN \
  ER_PASS_REWARD_SHARED \
  ER_PASS_UNIT_CLAMP \
  ER_PASS_SKIP_ZERO \
  ER_PASS_FLAGOFF_ROWS \
  ER_PASS_FLAGOFF_REWARD \
  ER_PASS_RESOLVED_PLAN \
  ER_PASS_MULTIWAVE \
  ER_PASS_CAP \
  ER_PASS_E5_VARIETY \
  ER_PASS_E5_SEED_STABLE \
  ER_PASS_ELITE_WIRED \
  'ENCOUNTER-RESOLVER PROOF PASSED'; do
  echo "$out" | grep -q "$marker" || { echo "MISSING PASS MARKER: $marker"; exit 1; }
done
echo 'ALL ENCOUNTER-RESOLVER PASS MARKERS PRESENT'
