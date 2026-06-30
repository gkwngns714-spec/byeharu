#!/usr/bin/env bash
# PORT-ENTRY-1-VERIFY-1 — disposable real-chain proof FOR THE VERIFIER. Boots nothing itself; runs against a
# disposable DB_URL (chain 0001..0072) provided by the workflow. Proves: (1) the verifier PASSES on the expected
# PORT-ENTRY-1 catalog; (2) it FAILS CLOSED for each intentionally-wrong descriptor. Uses NO production
# credentials/hosts. Mutations are applied to the throwaway DB only and reverted (functions restored by
# re-applying migration 0072; flags/head restored explicitly).
set -uo pipefail
: "${DB_URL:?DB_URL (disposable stack) required}"
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$SD/.." && pwd)"
MIG="$ROOT/supabase/migrations/20260618000072_port_entry_commission_normalize.sql"
VERIFY="$SD/port-entry-1-production-verify.sh"
fail() { echo "PROOF FAIL: $1" >&2; exit 1; }
q() { psql "$DB_URL" -X -q -t -A -c "$1" >/dev/null; }
revert_fns() { psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f "$MIG" >/dev/null; }

# Mirror PRODUCTION flags (a fresh disposable chain defaults send/space false; coord ships false).
q "update public.game_config set value='true'::jsonb  where key='mainship_send_enabled';"
q "update public.game_config set value='true'::jsonb  where key='mainship_space_movement_enabled';"
q "update public.game_config set value='false'::jsonb where key='mainship_coordinate_travel_enabled';"

# 1) baseline: verifier PASSES on the expected catalog.
bash "$VERIFY" local >/dev/null || fail "verifier did not PASS on the expected PORT-ENTRY-1 catalog"
echo "ok[1] verifier PASSES on the expected PORT-ENTRY-1 catalog"

expect_fail() { if bash "$VERIFY" local >/dev/null 2>&1; then fail "verifier PASSED under mutation: $1"; fi; echo "ok fail-closed: $1"; }
# run the verifier (which emits markers even on failure), require OVERALL_PASS=false + each named marker present.
assert_markers_fail() { local label="$1"; shift; local out m
  out="$(bash "$VERIFY" local 2>&1 || true)"
  echo "$out" | grep -q 'OVERALL_PASS=false' || { echo "$out"; fail "$label: OVERALL_PASS not false"; }
  for m in "$@"; do echo "$out" | grep -q "$m" || { echo "$out"; fail "$label: expected marker '$m' not observed"; }; done
  echo "ok fail-closed (markers): $label"; }

# A) wrong function body / prosrc hash
q "create or replace function public.commission_first_main_ship() returns jsonb language plpgsql security definer set search_path = public as \$x\$ begin return jsonb_build_object('tampered', true); end \$x\$;"
expect_fail "wrong function body (prosrc hash mismatch)"; revert_fns
# B) wrong ACL (writer wrongly executable by authenticated)
q "grant execute on function public.port_entry_commission_writer(uuid) to authenticated;"
expect_fail "wrong ACL: private writer granted to authenticated"; revert_fns
# C) missing SECURITY DEFINER
q "create or replace function public.normalize_main_ship_dock() returns jsonb language plpgsql set search_path = public as \$x\$ begin return jsonb_build_object('ok', true); end \$x\$;"
expect_fail "missing SECURITY DEFINER"; revert_fns
# D) wrong search_path
q "create or replace function public.commission_first_main_ship() returns jsonb language plpgsql security definer set search_path = public, pg_temp as \$x\$ begin return jsonb_build_object('ok', true); end \$x\$;"
expect_fail "wrong search_path"; revert_fns
# E) migration head beyond 0072
q "insert into supabase_migrations.schema_migrations(version,name) values ('20260618000073','fake_future') on conflict do nothing;"
expect_fail "migration head beyond 0072"; q "delete from supabase_migrations.schema_migrations where version='20260618000073';"
# F) coordinate flag unexpectedly enabled
q "update public.game_config set value='true'::jsonb where key='mainship_coordinate_travel_enabled';"
expect_fail "coordinate flag enabled"; q "update public.game_config set value='false'::jsonb where key='mainship_coordinate_travel_enabled';"

# G) FULL-INVENTORY: an unexpected authenticated-executable public function whose name does NOT begin port_entry_
q "create function public.zz_unexpected_auth_rpc() returns int language sql as 'select 1';"
q "grant execute on function public.zz_unexpected_auth_rpc() to authenticated;"
assert_markers_fail "unexpected non-prefixed authenticated RPC" 'AUTHENTICATED_CLIENT_RPC_INVENTORY_EXACT=false'
q "revoke execute on function public.zz_unexpected_auth_rpc() from authenticated;"
q "drop function public.zz_unexpected_auth_rpc();"
bash "$VERIFY" local >/dev/null || fail "no clean re-pass after removing the unexpected authenticated RPC"
echo "ok: clean re-pass after removing the unexpected authenticated RPC"

# H) FULL-INVENTORY: an EXPECTED public RPC loses its authenticated EXECUTE
q "revoke execute on function public.commission_first_main_ship() from authenticated;"
assert_markers_fail "expected RPC missing authenticated EXECUTE (commission)" 'AUTHENTICATED_CLIENT_RPC_INVENTORY_EXACT=false'
revert_fns   # re-applies migration 0072 → restores the exact authenticated grant
bash "$VERIFY" local >/dev/null || fail "no clean re-pass after restoring commission authenticated EXECUTE"
echo "ok: clean re-pass after restoring commission authenticated EXECUTE"

# restore + final re-pass
revert_fns
bash "$VERIFY" local >/dev/null || fail "verifier did not re-PASS after reverts"
echo "PORT-ENTRY-1-VERIFY PROOF: ALL PASSED (expected catalog + full RPC inventory passes; 8/8 fail-closed cases rejected; clean re-pass)"
