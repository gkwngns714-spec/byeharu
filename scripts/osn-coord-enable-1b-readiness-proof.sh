#!/usr/bin/env bash
# OSN-COORD-ENABLE-1B — disposable proof for the additive coordinate-travel readiness capability (migration 0071).
# Two modes:
#   selftest — DB-free static checks on the migration (additive-only, derivation, ACL, no writes, no out-of-scope);
#   local    — run the real-chain fixture matrix (scripts/osn-coord-enable-1b-readiness-proof.sql) against a
#              throwaway DB_URL. Writes only disposable fixtures; restores flags; never touches production.
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local) : ;; *) echo "usage: $0 <selftest|local>" >&2; exit 2;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIG="$REPO_ROOT/supabase/migrations/20260618000071_osn_coord_enable_1b_readiness_capability.sql"
SQL="$REPO_ROOT/scripts/osn-coord-enable-1b-readiness-proof.sql"

if [ "$MODE" = "selftest" ]; then
  [ -f "$MIG" ] || fail "migration not found"
  [ -f "$SQL" ] || fail "proof fixture sql not found"
  grep -q "create or replace function public.get_osn_movement_readiness()" "$MIG" || fail "readiness function not re-created"
  grep -q "security definer" "$MIG" || fail "SECURITY DEFINER not preserved"
  grep -q "auth.uid()" "$MIG" || fail "auth.uid() caller derivation not preserved"
  grep -q "coordinate_travel_available" "$MIG" || fail "additive field not added"
  # derivation must be anchored-origin preserving: coord_avail = v_avail AND coordinate gate (NOT the loose
  # movement_enabled AND coordinate_enabled duplicate).
  grep -q "v_coord_avail := (v_avail and v_coord_flag)" "$MIG" || fail "derivation is not osn_available AND coordinate gate"
  grep -q "cfg_bool('mainship_coordinate_travel_enabled')" "$MIG" || fail "coordinate gate not consulted"
  grep -q "v_avail := (v_flag and v_cat = 'anchored')" "$MIG" || fail "existing osn_available semantics not preserved"
  # ACL re-asserted for THIS function only: authenticated execute, no public/anon.
  grep -q "revoke execute on function public.get_osn_movement_readiness() from public, anon" "$MIG" || fail "ACL not re-locked (public/anon)"
  grep -q "grant  execute on function public.get_osn_movement_readiness() to authenticated" "$MIG" || fail "authenticated execute not granted"

  # Comment-stripped body checks: NO write of any kind, and NO out-of-scope object/flag/command touched. The
  # header legitimately NAMES these as "not touched", so the assertions run on the comment-stripped SQL only.
  CLEAN="$(sed -E 's/--.*//' "$MIG")"
  printf '%s' "$CLEAN" | grep -qiE "insert into|update |delete from|alter table|drop |truncate " && fail "migration performs a write/DDL beyond the function replacement" || true
  printf '%s' "$CLEAN" | grep -q "game_config" && fail "migration references game_config in executable SQL (must not write/seed a flag)" || true
  printf '%s' "$CLEAN" | grep -q "command_main_ship_space_move" && fail "migration touches a movement command" || true
  printf '%s' "$CLEAN" | grep -qiE "reveal_starter_ports|location_services|space_anchors|player_home_port|main_ship_space_movements|mainship_space_dock|process_mainship_space_arrivals" && fail "migration touches an out-of-scope object" || true
  # The ONLY executable statements are: create-or-replace the function, and the two ACL lines.
  STMTS="$(printf '%s' "$CLEAN" | grep -cE '^\s*(create or replace function|revoke execute on function|grant  execute on function)' )"
  [ "$STMTS" = "3" ] || fail "unexpected executable statement count ($STMTS; want exactly create-or-replace + revoke + grant)"

  # Fixture sql sanity: it proves the full 2×2 table and the unanchored-with-both-flags-true security case.
  grep -q "coord flag=true" "$SQL" || fail "proof does not sweep the coordinate flag true"
  grep -q "UNANCHORED" "$SQL" || fail "proof does not assert the unanchored-cannot-go-true case"
  grep -q "has_function_privilege('anon'" "$SQL" || fail "proof does not assert anon cannot execute"
  grep -q "read-only ok" "$SQL" || fail "proof does not assert reads write nothing"
  echo "OSN-COORD-ENABLE-1B SELFTEST: ALL PASSED (additive field; osn_available∧gate derivation; SECURITY DEFINER + auth.uid() + ACL preserved; no writes/flags/out-of-scope objects; proof covers the 2×2 table, the unanchored security case, ACL, and read-only)"
  exit 0
fi

# ── local: run the real-chain fixture matrix against a disposable DB_URL ──────────────────────────────────────
: "${DB_URL:?DB_URL (disposable stack) required}"
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$SQL" || fail "real-chain readiness proof failed"
echo "OSN-COORD-ENABLE-1B LOCAL MATRIX: ALL PASSED"
