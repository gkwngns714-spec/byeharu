#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# MIGRATION 0272 — READ-ONLY POST-DEPLOYMENT VERIFIER runner
#
# ██ READ-ONLY. This runner drives scripts/verify-0272-postdeploy.sql, which opens
# ██ `begin transaction read only` and closes with `rollback` — PostgreSQL itself rejects any write.
# ██ It NEVER deploys, NEVER approves a deployment, NEVER flips a flag, NEVER activates a binding and
# ██ NEVER cleans up runtime state. It is SAFE to point at production.
#
# USAGE
#   # 1) BEFORE snapshot — take this while the deployment is still waiting at its gate:
#   DB_URL="postgres://…" ./scripts/verify-0272-postdeploy.sh before   > /tmp/pd0272.before.log
#   # 2) …the owner releases the deployment gate (a separate, human act this script never performs)…
#   # 3) AFTER snapshot:
#   DB_URL="postgres://…" ./scripts/verify-0272-postdeploy.sh after    > /tmp/pd0272.after.log
#   # 4) THE PROOF — only the expected_to_change.* lines may differ:
#   ./scripts/verify-0272-postdeploy.sh diff /tmp/pd0272.before.log /tmp/pd0272.after.log
#
# MODES
#   before                 assert the pre-deploy posture (head 0271, elite config ABSENT, 0261 body).
#   after   (default)      assert the post-deploy posture (head exactly 0272, elite config = 2, 0272 body).
#   diff A B               compare two captured logs. Fails if any must_not_change.* line moved, or if
#                          an expected_to_change.* line did NOT move. NO DB access; pure text.
#   --expect-blocked [ph]  SELFTEST mode: expect PD0272_BLOCKED (the fail-closed path). Used by CI
#                          against a DISPOSABLE database, proving the verifier fails closed rather than
#                          passing vacuously. Exits 1 if the verifier reports PASS instead.
#
# OVERRIDES (no file edit, no psql meta-commands — connection GUCs via PGOPTIONS)
#   PD0272_MIGRATION PD0272_PREV_MIGRATION PD0272_ELITE_MULTIPLIER
#   PD0272_CANARY_BINDING PD0272_OTHER_BINDING
#   PD0272_RUNTIME_LOCATION PD0272_RUNTIME_PROFILE PD0272_RUNTIME_LAST_SPAWN_AT PD0272_RUNTIME_ACTIVE_COUNT
#   PD0272_SKIP_RLS_READS=1   skip the combat_encounters checks (a role that cannot read them)
#   Any unset variable falls back to the SQL file's own default.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$SCRIPT_DIR/verify-0272-postdeploy.sql"

# ── diff mode: pure text, no database at all ───────────────────────────────────────────────────────
if [ "${1:-}" = "diff" ]; then
  A="${2:?diff needs two captured logs: diff <before.log> <after.log>}"
  B="${3:?diff needs two captured logs: diff <before.log> <after.log>}"
  [ -f "$A" ] || { echo "PD0272_DIFF_FAIL missing file: $A"; exit 1; }
  [ -f "$B" ] || { echo "PD0272_DIFF_FAIL missing file: $B"; exit 1; }
  snap() { grep -o 'PD0272_SNAPSHOT .*' "$1" | sed 's/^PD0272_SNAPSHOT //' | sort; }
  snap "$A" > /tmp/pd0272.snap.a || true
  snap "$B" > /tmp/pd0272.snap.b || true
  if [ ! -s /tmp/pd0272.snap.a ] || [ ! -s /tmp/pd0272.snap.b ]; then
    echo 'PD0272_DIFF_FAIL — one of the logs carries no PD0272_SNAPSHOT lines'; exit 1
  fi
  rc=0
  echo '── must_not_change.* — ANY difference here is a defect ─────────────────────────────'
  if diff <(grep '^must_not_change\.' /tmp/pd0272.snap.a) \
          <(grep '^must_not_change\.' /tmp/pd0272.snap.b); then
    echo 'ok: every must_not_change.* value is byte-identical across the deployment'
  else
    echo 'PD0272_DIFF_FAIL — a must_not_change.* value MOVED across the deployment (see above)'; rc=1
  fi
  echo
  echo '── expected_to_change.* — these SHOULD differ (and are the evidence 0272 landed) ────'
  diff <(grep '^expected_to_change\.' /tmp/pd0272.snap.a) \
       <(grep '^expected_to_change\.' /tmp/pd0272.snap.b) && {
    echo 'PD0272_DIFF_FAIL — NOTHING changed: the deployment did not land (or both logs are the same phase)'; rc=1; }
  echo
  [ $rc -eq 0 ] && echo 'PD0272_DIFF_PASS — only the intended values moved. Nothing was written.' \
                || echo 'PD0272_DIFF_FAIL — see above.'
  exit $rc
fi

[ -f "$SQL" ] || { echo "post-deploy sql not found: $SQL"; exit 1; }
: "${DB_URL:?DB_URL required (a read-only run is safe against prod, but you must name it explicitly)}"

MODE="${1:-after}"
PHASE="after"
case "$MODE" in
  before)           PHASE="before" ;;
  after)            PHASE="after" ;;
  --expect-blocked) PHASE="${2:-after}" ;;
  *) echo "unknown mode: $MODE (want: before | after | diff | --expect-blocked)"; exit 1 ;;
esac

opts="-c pd0272.phase=$PHASE"
add() { [ -n "${2:-}" ] && opts="$opts -c $1=$2"; return 0; }
add pd0272.migration            "${PD0272_MIGRATION:-}"
add pd0272.prev_migration       "${PD0272_PREV_MIGRATION:-}"
add pd0272.elite_multiplier     "${PD0272_ELITE_MULTIPLIER:-}"
add pd0272.canary_binding       "${PD0272_CANARY_BINDING:-}"
add pd0272.other_binding        "${PD0272_OTHER_BINDING:-}"
add pd0272.runtime_location     "${PD0272_RUNTIME_LOCATION:-}"
add pd0272.runtime_profile      "${PD0272_RUNTIME_PROFILE:-}"
add pd0272.runtime_last_spawn_at "${PD0272_RUNTIME_LAST_SPAWN_AT:-}"
add pd0272.runtime_active_count "${PD0272_RUNTIME_ACTIVE_COUNT:-}"
add pd0272.skip_rls_reads       "${PD0272_SKIP_RLS_READS:-}"

# capture without aborting so every PD0272_FINDING line is printed for diagnosis; the marker checks
# below are the pass/fail gate.
out="$(PGOPTIONS="$opts" psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$SQL" 2>&1)"
echo "$out"
echo '────────────────────────────────────────────────────────────────────────────'

blocks="$(echo "$out" | grep -c 'PD0272_FINDING \[BLOCK\]' || true)"
warns="$(echo "$out"  | grep -c 'PD0272_FINDING \[WARN\]'  || true)"

if [ "$MODE" = "--expect-blocked" ]; then
  if echo "$out" | grep -q 'PD0272_BLOCKED'; then
    echo "PD0272_SELFTEST_PASS — the verifier failed closed as required (blocking findings: $blocks)"
    exit 0
  fi
  echo 'PD0272_SELFTEST_FAIL — expected PD0272_BLOCKED but the verifier did not report it'
  exit 1
fi

if echo "$out" | grep -q 'PD0272_PASS'; then
  echo "PD0272_VERIFY_PASS phase=$PHASE — 0 blocking findings, $warns warning(s). Nothing was written."
  echo "Capture BOTH phases and run:  $0 diff <before.log> <after.log>  — a single PASS proves posture, not 'unchanged'."
  exit 0
fi
echo "PD0272_VERIFY_FAIL phase=$PHASE — $blocks blocking finding(s), $warns warning(s). Nothing was written."
exit 1
