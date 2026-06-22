#!/usr/bin/env bash
# Legacy Main-Ship Verifier Safety Repair — DISPOSABLE-STACK integration proof.
#
# Runs the REPAIRED verifiers against a throwaway `supabase start` stack and proves the charter table:
#   * original send flag TRUE  → verifier completes → flag remains TRUE
#   * original send flag FALSE → verifier completes → flag remains FALSE
#   * normal run → all verifier-created users + cascaded game rows are gone
#   * intentional mid-run failure → cleanup + flag restore STILL happen
#   * preview → its created users + cascade removed
#   * existing verifier assertions still pass (exit 0 on the success runs)
#
# Needs (from `supabase status -o env`): DB_URL (psql), API_URL, ANON_KEY, SERVICE_ROLE_KEY.
# NEVER uses production credentials or production data — disposable local stack only.
set -uo pipefail
: "${DB_URL:?}" "${API_URL:?}" "${ANON_KEY:?}" "${SERVICE_ROLE_KEY:?}"
command -v psql >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client >/dev/null; }

FAILED=0
okay() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; FAILED=1; }

q()       { psql "$DB_URL" -tA -c "$1" 2>/dev/null | tr -d '[:space:]'; }
setflag() { psql "$DB_URL" -q -c "update game_config set value='$1' where key='mainship_send_enabled';" >/dev/null; }
flagval() { q "select value from game_config where key='mainship_send_enabled';"; }
vusers()  { q "select count(*) from auth.users where email ~ '^(mssendtest|msmovetest|msrepairtest|mspreviewtest)\\.';"; }

assert_clean() {
  local label="$1" bad=0 n
  for t in bases base_units main_ship_instances fleets fleet_units fleet_movements main_ship_space_movements location_presence; do
    n=$(q "select count(*) from $t;")
    [ "${n:-x}" = "0" ] || { fail "$label: $t has ${n:-?} residual row(s)"; bad=1; }
  done
  n=$(vusers); [ "${n:-x}" = "0" ] || { fail "$label: ${n:-?} residual verifier auth user(s)"; bad=1; }
  [ "$bad" = "0" ] && okay "$label: no residual verifier users or cascaded game rows (clean)"
}

run_verifier() {
  VITE_SUPABASE_URL="$API_URL" VITE_SUPABASE_ANON_KEY="$ANON_KEY" SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" \
    node "scripts/$1"
}

echo "=== precondition: fresh disposable stack is clean ==="
assert_clean "precondition"

echo "=== DIAGNOSTIC: environment + ensure_main_ship_for_player (direct DB) ==="
psql "$DB_URL" -c "select hull_type_id from main_ship_hull_types;" || true
psql "$DB_URL" -c "select key, value, pg_typeof(value) from game_config where key like 'mainship%' or key in ('travel_scale','min_travel_seconds') order by key;" || true
psql "$DB_URL" -v ON_ERROR_STOP=0 <<'SQL' || true
do $$
declare uid uuid := gen_random_uuid();
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated','diag.'||replace(uid::text,'-','')||'@example.com','',now(),now(),now(),'','','','');
  raise notice 'DIAG after-signup: bases=% ships=%', (select count(*) from bases where player_id=uid), (select count(*) from main_ship_instances where player_id=uid);
  perform ensure_main_ship_for_player(uid);
  raise notice 'DIAG after-ensure: ships=%', (select count(*) from main_ship_instances where player_id=uid);
  delete from auth.users where id=uid;
exception when others then raise notice 'DIAG EXCEPTION: % / %', sqlstate, sqlerrm;
end $$;
SQL

echo "=== CASE 1: send, original flag TRUE → remains TRUE; assertions pass; cleanup ==="
setflag true
run_verifier verify-mainship-send.mjs; rc=$?
[ "$rc" = "0" ] && okay "1. send verifier passed (exit 0)" || fail "1. send verifier exit=$rc"
[ "$(flagval)" = "true" ] && okay "1a. send flag restored to TRUE" || fail "1a. flag=$(flagval) (want true)"
assert_clean "1b"

echo "=== CASE 2: send, original flag FALSE → remains FALSE; cleanup ==="
setflag false
run_verifier verify-mainship-send.mjs; rc=$?
[ "$rc" = "0" ] && okay "2. send verifier passed (exit 0)" || fail "2. send verifier exit=$rc"
[ "$(flagval)" = "false" ] && okay "2a. send flag restored to FALSE" || fail "2a. flag=$(flagval) (want false)"
assert_clean "2b"

echo "=== CASE 3: move, original flag TRUE → remains TRUE; cleanup ==="
setflag true
run_verifier verify-mainship-move.mjs; rc=$?
[ "$rc" = "0" ] && okay "3. move verifier passed (exit 0)" || fail "3. move verifier exit=$rc"
[ "$(flagval)" = "true" ] && okay "3a. move flag restored to TRUE" || fail "3a. flag=$(flagval)"
assert_clean "3b"

echo "=== CASE 4: repair, original flag TRUE → remains TRUE; cleanup ==="
setflag true
run_verifier verify-mainship-repair.mjs; rc=$?
[ "$rc" = "0" ] && okay "4. repair verifier passed (exit 0)" || fail "4. repair verifier exit=$rc"
[ "$(flagval)" = "true" ] && okay "4a. repair flag restored to TRUE" || fail "4a. flag=$(flagval)"
assert_clean "4b"

echo "=== CASE 5: preview → cleanup of BOTH created users (no flag touched) ==="
run_verifier verify-mainship-preview.mjs; rc=$?
[ "$rc" = "0" ] && okay "5. preview verifier passed (exit 0)" || fail "5. preview verifier exit=$rc"
assert_clean "5a"

echo "=== CASE 6: intentional mid-run FAILURE (send) → still cleans up + restores flag ==="
setflag true
# Real fault: make the world have no safe_zone/pirate_hunt so send die()s AFTER creating its user+base+ship.
psql "$DB_URL" -q -c "update locations set location_type='event_site';" >/dev/null
run_verifier verify-mainship-send.mjs; rc=$?
[ "$rc" != "0" ] && okay "6. send verifier failed as intended (exit $rc)" || fail "6. send unexpectedly passed with no usable world"
[ "$(flagval)" = "true" ] && okay "6a. flag STILL restored to TRUE on the failure path" || fail "6a. flag=$(flagval) (want true)"
assert_clean "6b"

echo ""
if [ "$FAILED" = "0" ]; then
  echo "LEGACY VERIFIER SAFETY PROOF (disposable stack): ALL PASSED"; exit 0
else
  echo "LEGACY VERIFIER SAFETY PROOF (disposable stack): FAILURES ABOVE"; exit 1
fi
