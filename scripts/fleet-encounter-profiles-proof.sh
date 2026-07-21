#!/usr/bin/env bash
# FLEET TEMPLATES + ENCOUNTER PROFILES — disposable proof runner (run against a THROWAWAY local Supabase).
#
# Drives scripts/fleet-encounter-profiles-proof.sql against a disposable DB_URL and asserts every PASS
# marker is present. The SQL is self-rolling-back (begin;…rollback;) — it flips BOTH gate flags
# (enemy_content_registry_enabled + encounter_authoring_enabled) ON only INSIDE the txn and leaves ZERO
# persisted state. NEVER point this at production. Packaged as a standalone script so it can run locally:
#   DB_URL="$(supabase status -o env | grep '^DB_URL=' | cut -d= -f2-)" ./scripts/fleet-encounter-profiles-proof.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$SCRIPT_DIR/fleet-encounter-profiles-proof.sql"
[ -f "$SQL" ] || { echo "proof sql not found: $SQL"; exit 1; }
: "${DB_URL:?DB_URL (disposable stack) required}"

out="$(psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$SQL" 2>&1)"
echo "$out"

for marker in \
  FLEET_ENCOUNTER_PASS_FLAG_OFF_DENIED \
  FLEET_ENCOUNTER_PASS_ANON_DENIED \
  FLEET_ENCOUNTER_PASS_NONOWNER_DENIED \
  FLEET_ENCOUNTER_PASS_OWNER_CREATE \
  FLEET_ENCOUNTER_PASS_OWNER_UPDATE \
  FLEET_ENCOUNTER_PASS_OWNER_SET_ACTIVE \
  FLEET_ENCOUNTER_PASS_IDEMPOTENT \
  FLEET_ENCOUNTER_PASS_STALE_REVISION_REJECTED \
  FLEET_ENCOUNTER_PASS_INVALID_REFERENCE_REJECTED \
  FLEET_ENCOUNTER_PASS_BOUNDED_NUMERIC_REJECTED \
  FLEET_ENCOUNTER_PASS_MEMBERS_REQUIRED \
  FLEET_ENCOUNTER_PASS_AUDIT_EXPOSURE_INTENTIONAL \
  FLEET_ENCOUNTER_PASS_DIRECT_WRITE_DENIED \
  FLEET_ENCOUNTER_PASS_AUDIT_FIELDS \
  FLEET_ENCOUNTER_PASS_DEACTIVATION_GUARD \
  FLEET_ENCOUNTER_PASS_DARK_GUARANTEE \
  FLEET_ENCOUNTER_PASS_NO_DELETE_RPC \
  'FLEET TEMPLATES + ENCOUNTER PROFILES PROOF PASSED'; do
  echo "$out" | grep -q "$marker" || { echo "MISSING PASS MARKER: $marker"; exit 1; }
done
echo 'ALL FLEET-ENCOUNTER-PROFILES PASS MARKERS PRESENT'
