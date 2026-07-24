#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# ENCOUNTER CANARY — READ-ONLY READINESS VERIFIER runner (§3.3)
#
# ██ READ-ONLY. This runner drives scripts/encounter-canary-readiness.sql, which opens
# ██ `begin transaction read only` and closes with `rollback` — PostgreSQL itself rejects any write.
# ██ It NEVER activates a binding and NEVER flips a flag. It is SAFE to point at production.
#
# USAGE
#   DB_URL="postgres://…" ./scripts/encounter-canary-readiness.sh
#   # against a disposable local stack:
#   DB_URL="$(supabase status -o env | grep '^DB_URL=' | cut -d= -f2-)" ./scripts/encounter-canary-readiness.sh
#
# MODES
#   (default)          expect CANARY_READY_PASS; exit 1 if the chain is blocked.
#   --expect-blocked   SELFTEST mode: expect CANARY_READY_BLOCKED (the fail-closed path). Exits 1 if the
#                      verifier instead reports PASS. Used by CI against a disposable DB that has NO
#                      canary content, proving the verifier really does fail closed rather than
#                      vacuously passing.
#
# OVERRIDES (no file edit, no psql meta-commands — connection GUCs via PGOPTIONS)
#   CANARY_BINDING_ID      default 2f7bcf88-d810-47b4-8e04-748655688b55 (prod binding B)
#   CANARY_PROFILE_KEY     default canary_encounter
#   CANARY_EXPECT_BINDING_REV / _PROFILE_REV / _TEMPLATE_REV / _ARCHETYPE_REV / _REWARD_REV
#   CANARY_MIN_COOLDOWN_SECONDS, CANARY_MAX_ACTIVE_CAP, CANARY_ELITE_MIGRATION
#   Any unset variable falls back to the SQL file's own default.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$SCRIPT_DIR/encounter-canary-readiness.sql"
[ -f "$SQL" ] || { echo "readiness sql not found: $SQL"; exit 1; }
: "${DB_URL:?DB_URL required (a read-only run is safe against prod, but you must name it explicitly)}"

MODE="${1:-}"

opts=""
add() { [ -n "${2:-}" ] && opts="$opts -c $1=$2"; return 0; }
add canary.binding_id           "${CANARY_BINDING_ID:-}"
add canary.profile_key          "${CANARY_PROFILE_KEY:-}"
add canary.expect_binding_rev   "${CANARY_EXPECT_BINDING_REV:-}"
add canary.expect_profile_rev   "${CANARY_EXPECT_PROFILE_REV:-}"
add canary.expect_template_rev  "${CANARY_EXPECT_TEMPLATE_REV:-}"
add canary.expect_archetype_rev "${CANARY_EXPECT_ARCHETYPE_REV:-}"
add canary.expect_reward_rev    "${CANARY_EXPECT_REWARD_REV:-}"
add canary.expect_active         "${CANARY_EXPECT_ACTIVE:-}"
add canary.min_cooldown_seconds "${CANARY_MIN_COOLDOWN_SECONDS:-}"
add canary.max_active_cap       "${CANARY_MAX_ACTIVE_CAP:-}"
add canary.elite_migration      "${CANARY_ELITE_MIGRATION:-}"

# capture without aborting so every CANARY_FINDING line is printed for diagnosis; the marker checks
# below are the pass/fail gate.
out="$(PGOPTIONS="$opts" psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$SQL" 2>&1)"
echo "$out"
echo '────────────────────────────────────────────────────────────────────────────'

blocks="$(echo "$out" | grep -c 'CANARY_FINDING \[BLOCK\]' || true)"
warns="$(echo "$out" | grep -c 'CANARY_FINDING \[WARN\]'  || true)"

if [ "$MODE" = "--expect-blocked" ]; then
  if echo "$out" | grep -q 'CANARY_READY_BLOCKED'; then
    echo "CANARY_READINESS_SELFTEST_PASS — the verifier failed closed as required (blocking findings: $blocks)"
    exit 0
  fi
  echo "CANARY_READINESS_SELFTEST_FAIL — expected CANARY_READY_BLOCKED but the verifier did not report it"
  exit 1
fi

if echo "$out" | grep -q 'CANARY_READY_PASS'; then
  echo "CANARY_READINESS_PASS — 0 blocking findings, $warns warning(s). Nothing was written."
  exit 0
fi
echo "CANARY_READINESS_FAIL — $blocks blocking finding(s), $warns warning(s). Nothing was written. DO NOT run Script A or Script B."
exit 1
