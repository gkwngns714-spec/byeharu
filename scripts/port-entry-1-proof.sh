#!/usr/bin/env bash
# PORT-ENTRY-1 — disposable proof for first-ship commissioning + same-location dock normalization (migration 0072).
# Modes: selftest (DB-free static checks on the migration) / local (run the real-chain matrix against DB_URL).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local) : ;; *) echo "usage: $0 <selftest|local>" >&2; exit 2;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIG="$REPO_ROOT/supabase/migrations/20260618000072_port_entry_commission_normalize.sql"
SQL="$REPO_ROOT/scripts/port-entry-1-proof.sql"

if [ "$MODE" = "selftest" ]; then
  [ -f "$MIG" ] || fail "migration not found"; [ -f "$SQL" ] || fail "proof sql not found"
  # the three functions exist with the intended shapes
  grep -q "create or replace function public.port_entry_commission_writer(p_player uuid)" "$MIG" || fail "private writer missing"
  grep -q "create or replace function public.commission_first_main_ship()" "$MIG" || fail "commission RPC missing"
  grep -q "create or replace function public.normalize_main_ship_dock()" "$MIG" || fail "normalizer RPC missing"
  # commissioning writer inserts DIRECTLY into at_location shape, and NEVER uses ensure_main_ship_for_player
  # (the executable-code checks run on the COMMENT-STRIPPED SQL; the header legitimately NAMES these as excluded).
  CLEAN="$(sed -E 's/--.*//' "$MIG")"
  grep -q "'stationary', 'at_location'" "$MIG" || fail "writer does not insert canonical at_location shape"
  printf '%s' "$CLEAN" | grep -q "ensure_main_ship_for_player" && fail "writer must NOT use ensure_main_ship_for_player" || true
  grep -q "b1a00001-0066-4a00-8a00-000000000001" "$MIG" || fail "Haven spawn port not server-fixed"
  grep -q "auth.uid()" "$MIG" || fail "RPCs do not derive caller from auth.uid()"
  grep -c "security definer" "$MIG" | grep -q "3" || fail "expected all 3 functions SECURITY DEFINER"
  # both RPCs assert canonical at_location via validate_context; normalizer never calls resolve_origin
  grep -q "validate_context(v_ship)" "$MIG" || fail "missing post-write at_location assertion"
  printf '%s' "$CLEAN" | grep -q "resolve_origin" && fail "normalizer/writer must NOT call resolve_origin" || true
  # outcome reasons present
  for reason in needs_normalization needs_compat_route not_provisionable already_provisioned ineligible_port not_normalizable; do
    grep -q "$reason" "$MIG" || fail "missing outcome reason: $reason"
  done
  # ACL: authenticated RPCs; writer service_role-only
  grep -q "grant  execute on function public.commission_first_main_ship()  to authenticated" "$MIG" || fail "commission not authenticated-granted"
  grep -q "grant  execute on function public.port_entry_commission_writer(uuid) to service_role" "$MIG" || fail "writer not service_role-granted"
  grep -q "revoke execute on function public.port_entry_commission_writer(uuid) from public, anon, authenticated" "$MIG" || fail "writer not revoked from authenticated"
  # comment-stripped: NO out-of-scope writes / no flag change / no existing-object DDL
  CLEAN="$(sed -E 's/--.*//' "$MIG")"
  printf '%s' "$CLEAN" | grep -qiE "player_home_port|market_offers|trade_goods|player_wallet|ship_trade_cargo|world_sites" && fail "migration touches an out-of-scope (trading/home-port/world_sites) object" || true
  printf '%s' "$CLEAN" | grep -qiE "update .*game_config|insert into public.game_config|mainship_coordinate_travel_enabled|mainship_space_movement_enabled" && fail "migration touches a feature flag" || true
  printf '%s' "$CLEAN" | grep -qiE "drop function|drop table|alter table|drop trigger" && fail "migration alters/drops existing objects (must be additive)" || true
  # only at_location is set by the writer (no home-port / no coordinate write)
  printf '%s' "$CLEAN" | grep -q "space_x = null, space_y = null" >/dev/null 2>&1 || grep -q "null, null" "$MIG" || fail "writer does not null coordinates"
  # real external-concurrency proof exists and uses two independent sessions + a blocked-wait observation
  CONC="$REPO_ROOT/scripts/port-entry-1-concurrency.sh"
  [ -f "$CONC" ] || fail "real-concurrency proof script missing"
  grep -q "commission_first_main_ship" "$CONC" || fail "concurrency proof does not exercise the public commission RPC"
  grep -q "pg_blocking_pids" "$CONC" || fail "concurrency proof does not verify a real blocked-by-another-txn wait"
  grep -q "B_RESULT' before A commit\|COMPLETED before A committed" "$CONC" || fail "concurrency proof does not assert the loser is blocked until the winner commits"
  grep -q "mainship_space_validate_context" "$CONC" || fail "concurrency proof does not assert final at_location invariant"
  echo "PORT-ENTRY-1 SELFTEST: ALL PASSED (3 functions; direct at_location insert, no ensure_main_ship_for_player; Haven-fixed; auth.uid(); SECURITY DEFINER; at_location assertion; no resolve_origin; ACLs; no flag/home-port/trading/world_sites/DDL; real two-session concurrency proof present)"
  exit 0
fi

# ── local: run the real-chain matrix against a disposable DB_URL ──────────────────────────────────────────────
: "${DB_URL:?DB_URL (disposable stack) required}"
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$SQL" || fail "real-chain PORT-ENTRY-1 proof failed"
echo "PORT-ENTRY-1 LOCAL MATRIX: ALL PASSED"
