#!/usr/bin/env bash
# LOCATION → ENCOUNTER BINDINGS — disposable proof runner (run against a THROWAWAY local Supabase).
#
# Drives scripts/location-encounter-bindings-proof.sql against a disposable DB_URL and asserts every PASS
# marker is present. The SQL is self-rolling-back (begin;…rollback;) — it flips ALL THREE gate flags
# (enemy_content_registry_enabled + encounter_authoring_enabled + encounter_binding_authoring_enabled) ON
# only INSIDE the txn and leaves ZERO persisted state. NEVER point this at production. Packaged as a
# standalone script so it can run locally:
#   DB_URL="$(supabase status -o env | grep '^DB_URL=' | cut -d= -f2-)" ./scripts/location-encounter-bindings-proof.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$SCRIPT_DIR/location-encounter-bindings-proof.sql"
[ -f "$SQL" ] || { echo "proof sql not found: $SQL"; exit 1; }
: "${DB_URL:?DB_URL (disposable stack) required}"

out="$(psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$SQL" 2>&1)"
echo "$out"

for marker in \
  LEB_PASS_FLAG_OFF_DENIED \
  LEB_PASS_ANON_DENIED \
  LEB_PASS_NONOWNER_DENIED \
  LEB_PASS_OWNER_CREATE \
  LEB_PASS_OWNER_UPDATE \
  LEB_PASS_OWNER_SET_ACTIVE \
  LEB_PASS_IDEMPOTENT \
  LEB_PASS_STALE_REVISION_REJECTED \
  LEB_PASS_INVALID_REFERENCE_REJECTED \
  LEB_PASS_BOUNDED_NUMERIC_REJECTED \
  LEB_PASS_DUPLICATE_BINDING_REJECTED \
  LEB_PASS_DEACTIVATION_GUARD \
  LEB_PASS_AUDIT_EXPOSURE_INTENTIONAL \
  LEB_PASS_DIRECT_WRITE_DENIED \
  LEB_PASS_DARK_GUARANTEE \
  LEB_PASS_NO_DELETE_RPC \
  'LOCATION → ENCOUNTER BINDINGS PROOF PASSED'; do
  echo "$out" | grep -q "$marker" || { echo "MISSING PASS MARKER: $marker"; exit 1; }
done
echo 'ALL LOCATION-ENCOUNTER-BINDINGS PASS MARKERS PRESENT'
