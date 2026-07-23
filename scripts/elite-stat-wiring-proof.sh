#!/usr/bin/env bash
# ELITE STAT WIRING (0272) — disposable proof runner (run against a THROWAWAY local Supabase).
#
# Drives scripts/elite-stat-wiring-proof.sql against a disposable DB_URL and asserts every PASS marker.
# The SQL is self-rolling-back (begin;…rollback;) — it flips every gate flag ON only INSIDE the txn and
# leaves ZERO persisted state. NEVER point this at production. Run locally:
#   DB_URL="$(supabase status -o env | grep '^DB_URL=' | cut -d= -f2-)" ./scripts/elite-stat-wiring-proof.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$SCRIPT_DIR/elite-stat-wiring-proof.sql"
[ -f "$SQL" ] || { echo "proof sql not found: $SQL"; exit 1; }
: "${DB_URL:?DB_URL (disposable stack) required}"

out="$(psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$SQL" 2>&1)"
echo "$out"

for marker in \
  ELITE_PASS_SOURCE \
  ELITE_PASS_LEGACY_PARITY \
  ELITE_PASS_DETERMINISM \
  ELITE_PASS_SPLIT_PLAN \
  ELITE_PASS_FLAGOFF_SYNTHETIC \
  ELITE_PASS_SPAWN_STATS \
  ELITE_PASS_WEAPONS_DAMAGE \
  'ELITE STAT WIRING PROOF PASSED'; do
  echo "$out" | grep -q "$marker" || { echo "MISSING PASS MARKER: $marker"; exit 1; }
done
echo 'ALL ELITE-STAT-WIRING PASS MARKERS PRESENT'
