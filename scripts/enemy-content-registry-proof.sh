#!/usr/bin/env bash
# ENEMY CONTENT REGISTRY — disposable proof runner (run against a THROWAWAY local Supabase ONLY).
#
# Drives scripts/enemy-content-registry-proof.sql against a disposable DB_URL and asserts every PASS
# marker is present. The SQL is self-rolling-back (begin;…rollback;) — it flips the
# enemy_content_registry_enabled flag ON only INSIDE the txn and leaves ZERO persisted state. NEVER
# point this at production. Mirrors the worldeditor-publish-*-proof workflow's inline psql+markers
# step (the World Editor proof family has no shared runner lib), packaged as a standalone script so it
# can run locally too:  DB_URL="$(supabase status -o env | grep '^DB_URL=' | cut -d= -f2-)" ./scripts/enemy-content-registry-proof.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$SCRIPT_DIR/enemy-content-registry-proof.sql"
[ -f "$SQL" ] || { echo "proof sql not found: $SQL"; exit 1; }
: "${DB_URL:?DB_URL (disposable stack) required}"

out="$(psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$SQL" 2>&1)"
echo "$out"

for marker in \
  ENEMY_REGISTRY_PASS_FLAG_OFF_DENIED \
  ENEMY_REGISTRY_PASS_ANON_DENIED \
  ENEMY_REGISTRY_PASS_NONOWNER_DENIED \
  ENEMY_REGISTRY_PASS_OWNER_CREATE \
  ENEMY_REGISTRY_PASS_OWNER_UPDATE \
  ENEMY_REGISTRY_PASS_OWNER_SET_ACTIVE \
  ENEMY_REGISTRY_PASS_IDEMPOTENT \
  ENEMY_REGISTRY_PASS_STALE_REVISION_REJECTED \
  ENEMY_REGISTRY_PASS_INVALID_REFERENCE_REJECTED \
  ENEMY_REGISTRY_PASS_RESOURCE_GRANTS_STRICT \
  ENEMY_REGISTRY_PASS_BASE_DIFFICULTY_BOUNDED \
  ENEMY_REGISTRY_PASS_UNIT_TYPE_RESTRICTED \
  ENEMY_REGISTRY_PASS_AUDIT_EXPOSURE_INTENTIONAL \
  ENEMY_REGISTRY_PASS_DIRECT_WRITE_DENIED \
  ENEMY_REGISTRY_PASS_AUDIT_FIELDS \
  ENEMY_REGISTRY_PASS_COMBAT_UNCHANGED \
  'ENEMY CONTENT REGISTRY PROOF PASSED'; do
  echo "$out" | grep -q "$marker" || { echo "MISSING PASS MARKER: $marker"; exit 1; }
done
echo 'ALL ENEMY-CONTENT-REGISTRY PASS MARKERS PRESENT'
