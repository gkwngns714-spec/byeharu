#!/usr/bin/env bash
# OSN-ENABLEMENT-1A — disposable proof for the post-reveal OSN enablement preflight.
#
# Exercises the ACTUAL preflight logic (scripts/osn-enablement-preflight.sql) against a throwaway full chain
# (0001..0068), plus the frontend coordinate-travel suppression gate. It NEVER touches production, never
# enables OSN, never calls reveal_starter_ports() (the disposable post-reveal state is created by a DIRECT
# status update on the throwaway stack). Modes:
#   selftest  DB-free: the preflight SQL is read-only by construction + emits the required sentinels; and the
#             coordinate-travel suppression check works.
#   local     run the post-reveal preflight matrix ok[1]..ok[5] against $DB_URL.
set -uo pipefail
set +x

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local) : ;; *) echo "usage: $0 <selftest|local>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL="$REPO_ROOT/scripts/osn-enablement-preflight.sql"
GATES_FILE="$REPO_ROOT/src/features/map/osnReleaseGates.ts"
P1='b1a00001-0066-4a00-8a00-000000000001'
P2='b1a00002-0066-4a00-8a00-000000000002'
P3='b1a00003-0066-4a00-8a00-000000000003'

# Frontend free-coordinate-travel suppression gate: the compile-time const must be exactly false.
# Returns 0 (suppressed) / non-zero (EXPOSED) — used by ok[5] and mirrored by the production workflow.
assert_coord_travel_suppressed() {  # $1 = osnReleaseGates.ts path
  local f="$1"
  [ -f "$f" ] || { echo "coord-gate: file missing"; return 2; }
  grep -qE 'OSN_COORDINATE_TRAVEL_ENABLED[[:space:]]*=[[:space:]]*true' "$f" && { echo "coord-gate: EXPOSED (=true)"; return 1; }
  grep -qE 'OSN_COORDINATE_TRAVEL_ENABLED[[:space:]]*=[[:space:]]*false' "$f" || { echo "coord-gate: const not found as false"; return 1; }
  return 0
}

# ── SELFTEST (DB-free) ───────────────────────────────────────────────────────────────────────────────────
if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "preflight SQL not found"
  grep -q 'set default_transaction_read_only = on' "$SQL" || fail "missing read-only session setting"
  grep -q 'begin transaction read only' "$SQL"            || fail "missing read-only transaction"
  CLEAN="$(sed -E 's/--.*//' "$SQL")"
  printf '%s' "$CLEAN" | grep -iqE '\breveal_starter_ports\b' && fail "preflight references reveal_starter_ports" || true
  # no DDL/DML/flag-write outside string literals (the SQL must never mutate)
  printf '%s' "$CLEAN" | sed "s/'[^']*'//g" \
    | grep -iqE '\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|merge|call)\b' \
    && fail "write/DDL/grant keyword present outside string literals" || true
  printf '%s' "$CLEAN" | grep -iqE '\braise\b' && fail "preflight must not RAISE (gating lives in the caller)" || true
  for s in 'MIGRATION_HEAD=' 'CANONICAL_STARTER_PORTS_EXPECTED=3' 'CANONICAL_STARTER_PORTS_ACTIVE=' \
           'CANONICAL_STARTER_PORTS_HIDDEN=' 'AUTHENTICATED_MAP_PORTS_VISIBLE=' 'MAINSHIP_SEND_ENABLED=' \
           'MAINSHIP_SPACE_MOVEMENT_ENABLED=' 'STRUCTURAL_PASS=' 'OVERALL_PASS='; do
    grep -qF "$s" "$SQL" || fail "preflight does not emit sentinel: $s"
  done
  # the new current-state + OSN-safety checks are present
  for c in chk7_canonical_ports_active_3 chk7_canonical_ports_none_hidden chk7_map_ports_visible_3 \
           chk8_send_flag_true chk9_fleet_movement_exclusivity chk9_one_active_move_per_ship \
           chk9_receipt_idempotency_unique chk9_dock_fn_service_role_only chk9_readiness_authenticated; do
    grep -qF "$c" "$SQL" || fail "preflight missing check: $c"
  done
  echo "[selftest] OK: preflight is read-only, never RAISEs, emits all current-state sentinels, asserts post-reveal + OSN-safety"
  # coordinate-travel suppression gate: real file passes; a =true file is detected as exposed
  assert_coord_travel_suppressed "$GATES_FILE" || fail "real osnReleaseGates.ts is not suppressed (=false)"
  tmp="$(mktemp)"; echo 'export const OSN_COORDINATE_TRAVEL_ENABLED = true as const' > "$tmp"
  if assert_coord_travel_suppressed "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; fail "coord-gate failed to detect =true exposure"; fi
  rm -f "$tmp"
  echo "[selftest] OK: coordinate-travel suppression gate passes for the real const and catches a =true exposure"
  echo "OSN-ENABLEMENT-1A PREFLIGHT SELFTEST: ALL PASSED"
  exit 0
fi

# ── LOCAL (disposable post-reveal matrix) ────────────────────────────────────────────────────────────────
: "${DB_URL:?DB_URL (disposable stack) required}"
q()   { psql "$DB_URL" -X -q -t -A -c "$1"; }
runp(){ psql "$DB_URL" -X -q -A -t -v ON_ERROR_STOP=1 -f "$SQL"; }
sentinel(){ printf '%s\n' "$1" | grep -oE "$2=[^|]*" | head -1; }
overall(){ printf '%s\n' "$1" | grep -oE 'OVERALL_PASS=(true|false)' | head -1; }
set_active(){ for p in "$P1" "$P2" "$P3"; do q "update public.locations set status='active' where id='$p';" >/dev/null; done; }
set_hidden(){ for p in "$P1" "$P2" "$P3"; do q "update public.locations set status='hidden' where id='$p';" >/dev/null; done; }
flag(){ q "update public.game_config set value='$2'::jsonb where key='$1';" >/dev/null; }

# baseline = the live post-reveal shape (ports active; send true; space false) — created by DIRECT update,
# never via reveal_starter_ports().
set_active; flag mainship_send_enabled true; flag mainship_space_movement_enabled false

# ok[1] expected post-reveal baseline passes
OUT="$(runp)"
[ "$(overall "$OUT")" = "OVERALL_PASS=true" ] || { printf '%s\n' "$OUT" | tr '|' '\n' | grep -E 'chk|PASS='; fail "baseline did not pass"; }
for expect in "MIGRATION_HEAD=0068" "CANONICAL_STARTER_PORTS_EXPECTED=3" "CANONICAL_STARTER_PORTS_ACTIVE=3" \
              "CANONICAL_STARTER_PORTS_HIDDEN=0" "AUTHENTICATED_MAP_PORTS_VISIBLE=3" \
              "MAINSHIP_SEND_ENABLED=true" "MAINSHIP_SPACE_MOVEMENT_ENABLED=false"; do
  printf '%s\n' "$OUT" | grep -qF "$expect" || fail "baseline sentinel missing/wrong: $expect"
done
printf '%s\n' "$OUT" | grep -qF 'STRUCTURAL_PASS=true' || fail "baseline STRUCTURAL_PASS!=true"
echo "ok[1] expected post-reveal baseline passes (OVERALL_PASS=true; head 0068; 3 active; 0 hidden; map 3; send=true; space=false)"

# ok[2] hidden / wrong-count starter-port state fails
set_active; q "update public.locations set status='hidden' where id='$P1';" >/dev/null
[ "$(overall "$(runp)")" = "OVERALL_PASS=false" ] || fail "a hidden canonical port still passed"
set_active
echo "ok[2] hidden / wrong-count starter-port state: fail-closed"

# ok[3] either feature-flag deviation fails
flag mainship_space_movement_enabled true
[ "$(overall "$(runp)")" = "OVERALL_PASS=false" ] || fail "OSN flag=true still passed"
flag mainship_space_movement_enabled false
flag mainship_send_enabled false
[ "$(overall "$(runp)")" = "OVERALL_PASS=false" ] || fail "send flag=false still passed"
flag mainship_send_enabled true
echo "ok[3] feature-flag deviation (space=true / send=false): fail-closed"

# ok[4] OSN public boundary / ACL / ownership invariant failure fails
#   make the service-role-only writer authenticated-callable → boundary broken → preflight must fail.
q "grant execute on function public.mainship_space_stop(uuid,uuid,uuid) to authenticated;" >/dev/null
[ "$(overall "$(runp)")" = "OVERALL_PASS=false" ] || fail "writer exposed to authenticated still passed"
q "revoke execute on function public.mainship_space_stop(uuid,uuid,uuid) from authenticated;" >/dev/null
[ "$(overall "$(runp)")" = "OVERALL_PASS=true" ] || fail "boundary restore did not return to pass"
echo "ok[4] OSN boundary/ACL failure (writer granted to authenticated): fail-closed, then restores"

# ok[5] coordinate-travel exposure fails
tmp="$(mktemp)"; echo 'export const OSN_COORDINATE_TRAVEL_ENABLED = true as const' > "$tmp"
if assert_coord_travel_suppressed "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; fail "coord-travel exposure not detected"; fi
rm -f "$tmp"
assert_coord_travel_suppressed "$GATES_FILE" >/dev/null || fail "real coord-travel gate not suppressed"
echo "ok[5] coordinate-travel exposure: detected and fails (real const stays suppressed=false)"

# restore disposable baseline back to the seed dark state (ports hidden) for any downstream assertion
set_hidden
echo "OSN-ENABLEMENT-1A PREFLIGHT MATRIX: ALL PASSED"
