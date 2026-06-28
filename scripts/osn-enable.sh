#!/usr/bin/env bash
# OSN-ENABLEMENT-2 — controlled OSN port-to-port ENABLE operation orchestrator.
#
# Runs ONE fixed operation (scripts/osn-enable-operation.sql) that flips
# game_config.mainship_space_movement_enabled false→true exactly once, guarded by preconditions/postconditions.
# Accepts NO operator-supplied SQL, flag name, value, environment, host, or ref. Connection uses ONLY the
# repository's proven production access pattern (Supabase Management-API session-pooler + pinned CA +
# sslmode=verify-full), identical to the reveal operation. Secrets are never printed; tracing is never on.
#
# Modes: selftest (DB-free static safety) / local (disposable matrix) / production (gated, human-approved).
set -uo pipefail
set +x

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local|production) : ;; *) echo "usage: $0 <selftest|local|production>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/osn-enable-operation.sql"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"
CONFIRM_TOKEN="ENABLE_OSN_PORT_TO_PORT"
GATES_FILE="$REPO_ROOT/src/features/map/osnReleaseGates.ts"
FLAG='mainship_space_movement_enabled'
P1='b1a00001-0066-4a00-8a00-000000000001'; P2='b1a00002-0066-4a00-8a00-000000000002'; P3='b1a00003-0066-4a00-8a00-000000000003'

assert_confirm()   { [ "${1:-}" = "$CONFIRM_TOKEN" ] || fail "confirmation mismatch — expected the exact typed token"; }
assert_main_only() { [ "${1:-}" = "refs/heads/main" ] || fail "this operation may run ONLY from refs/heads/main (got '${1:-<none>}')"; }
# the free-coordinate travel gate must stay false even after OSN port-to-port is enabled
assert_coord_suppressed() { local f="$1"
  grep -qE 'OSN_COORDINATE_TRAVEL_ENABLED[[:space:]]*=[[:space:]]*true' "$f" && fail "OSN_COORDINATE_TRAVEL_ENABLED is true (free-coordinate travel exposed)" || true
  grep -qE 'OSN_COORDINATE_TRAVEL_ENABLED[[:space:]]*=[[:space:]]*false' "$f" || fail "OSN_COORDINATE_TRAVEL_ENABLED const not found as false"; }

# ── proven connection / trust helpers (identical to the reveal operation / read-only verifier) ───────────
is_hex64() { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{64}$'; }
validate_ref() { printf '%s' "${1:-}" | grep -qE '^[a-z0-9]{20}$' || fail "invalid/empty project ref"; }
OVERRIDE_VARS="DATABASE_URL PGHOST PGPORT PGUSER PGDATABASE PGHOSTADDR PGSERVICE PGURI PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY PGSSLCRL PGPASSWORD PGOPTIONS PSQLRC"
reject_target_overrides() { local v; for v in $OVERRIDE_VARS; do [ -z "${!v:-}" ] || fail "external target/trust override $v is set"; done; }
ca_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//; s/://g' | tr 'A-Z' 'a-z'; }
verify_ca() { local f="$1" n fp
  [ -f "$f" ] || fail "CA file not found"; [ -s "$f" ] || fail "CA file empty"
  n="$(grep -c 'BEGIN CERTIFICATE' "$f" || true)"; [ "$n" = "1" ] || fail "CA must contain exactly one cert (found $n)"
  openssl x509 -in "$f" -noout >/dev/null 2>&1 || fail "CA not valid PEM"
  openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1 || fail "CA expired"
  fp="$(ca_fingerprint "$f")"; is_hex64 "$fp" || fail "CA fp not 64 hex"; [ "$fp" = "$EXPECTED_CA_SHA256" ] || fail "CA fingerprint mismatch"
  echo "[ca] SHA-256 fingerprint = $fp"; }
parse_pooler_endpoint() { printf '%s' "${1:-}" | jq -er '
  ( if type=="array" then (if length==1 then .[0] else error("array length not exactly 1") end)
    elif type=="object" then . else error("unexpected top-level type") end ) as $e
  | ($e.db_host // error("missing db_host")) as $h | ($e.db_port // error("missing db_port")) as $p
  | (if ($h|type)=="string" and ($h|length)>0 then . else error("empty db_host") end) | "\($h)|\($p)"' 2>/dev/null; }
require_pooler_binding() { local h="${1:-}" pt="${2:-}" u="${3:-}" r="${4:-}"; validate_ref "$r"
  printf '%s' "$h" | grep -qE '^[a-z0-9][a-z0-9.-]*\.pooler\.supabase\.com$' || fail "host not <label>.pooler.supabase.com"
  case "$pt" in 5432|6543) : ;; *) fail "pooler port '$pt' not in {5432,6543}";; esac
  [ "$u" = "postgres.${r}" ] || fail "pooler tenant not postgres.<ref>"; }
build_prod_conn() { printf 'host=%s port=5432 user=postgres.%s dbname=postgres sslmode=verify-full sslrootcert=%s' "$1" "$2" "$3"; }

# ══════════════════════════════ SELFTEST (DB-free) ══════════════════════════════
if [ "$MODE" = "selftest" ]; then
  [ -f "$OP_SQL" ] || fail "operation SQL not found"
  ( assert_confirm "$CONFIRM_TOKEN" ) || fail "valid confirmation token rejected"
  ( assert_confirm "nope" ) 2>/dev/null && fail "wrong confirmation accepted" || true
  ( assert_main_only "refs/heads/main" ) || fail "refs/heads/main rejected"
  ( assert_main_only "refs/heads/x" ) 2>/dev/null && fail "non-main ref accepted" || true
  echo "[selftest] OK: confirmation token + main-only ref gates"
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"
  # EXACTLY ONE game_config write, and it sets the OSN flag to true (the enable), nothing else
  [ "$(printf '%s' "$CLEAN" | grep -coE 'update[[:space:]]+public\.game_config')" = "1" ] || fail "operation must write game_config exactly once"
  printf '%s' "$CLEAN" | grep -qE "update public\.game_config set value = 'true'::jsonb where key = c_flag" || fail "the one write must set the OSN flag to true"
  printf '%s' "$CLEAN" | grep -qiE "update[^;]*game_config[^;]*'false'" && fail "operation must not set any flag to false" || true
  printf '%s' "$CLEAN" | grep -qE "c_flag constant text := '$FLAG'" || fail "operation must target only mainship_space_movement_enabled"
  printf '%s' "$CLEAN" | grep -qi 'reveal_starter_ports' && fail "operation calls reveal_starter_ports (forbidden)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert|update|delete)[[:space:]]+(into[[:space:]]+)?(public\.)?(locations|location_presence|fleets|main_ship_instances|player_home_port|bases)\b' && fail "operation writes a non-config table (forbidden)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)\b' && fail "operation contains DDL (forbidden)" || true
  printf '%s' "$CLEAN" | grep -qiE '\bbegin\b' && printf '%s' "$CLEAN" | grep -qiE '\bcommit\b' || fail "operation must be one explicit BEGIN..COMMIT"
  printf '%s' "$CLEAN" | grep -qE 'lock_timeout' && printf '%s' "$CLEAN" | grep -qE 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -qE 'v_other_before|v_other_after' || fail "operation must digest the OTHER game_config keys (only-this-key invariance)"
  for id in "$P1" "$P2" "$P3"; do printf '%s' "$CLEAN" | grep -qF "$id" || fail "operation missing canonical port id $id (precondition)"; done
  echo "[selftest] OK: one game_config write (OSN flag→true) only; no reveal/table/DDL writes; only-this-key digest; timed BEGIN..COMMIT"
  c="$(build_prod_conn aws-0-x.pooler.supabase.com aaaaaaaaaaaaaaaaaaaa "$CA_FILE")"
  printf '%s' "$c" | grep -q 'sslmode=verify-full' || fail "conn missing verify-full"
  printf '%s' "$c" | grep -q 'port=5432' || fail "conn not forced to session 5432"
  printf '%s' "$c" | grep -qE 'sslmode=(require|prefer|allow|disable)|port=6543|sslrootcert=system' && fail "conn uses weaker TLS/port/CA" || true
  echo "[selftest] OK: conn = verify-full + pinned CA + session 5432"
  require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa
  ( require_pooler_binding evil.example.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad host not rejected" || true
  for v in $OVERRIDE_VARS; do if ( export "$v=x"; reject_target_overrides ) >/dev/null 2>&1; then fail "$v override not rejected"; fi; done
  echo "[selftest] OK: pooler binding + override rejection fail-closed"
  assert_coord_suppressed "$GATES_FILE"
  echo "[selftest] OK: OSN_COORDINATE_TRAVEL_ENABLED stays false (free-coordinate travel suppressed)"
  verify_ca "$CA_FILE"
  echo "OSN-ENABLE SELFTEST: ALL PASSED"
  exit 0
fi

# ══════════════════════════════ LOCAL (disposable enable matrix) ══════════════════════════════
if [ "$MODE" = "local" ]; then
  : "${DB_URL:?DB_URL (disposable stack) required}"
  q() { PGAPPNAME=mon psql "$DB_URL" -X -q -t -A -c "$1"; }
  run_op() { PGAPPNAME=osn-enable-op psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1; }
  flag_is() { q "select (value)::text from public.game_config where key='$1';"; }
  set_flag() { q "update public.game_config set value='$2'::jsonb where key='$1';" >/dev/null; }
  set_ports_active() { for p in "$P1" "$P2" "$P3"; do q "update public.locations set status='active' where id='$p';" >/dev/null; done; }
  set_ports_hidden() { for p in "$P1" "$P2" "$P3"; do q "update public.locations set status='hidden' where id='$p';" >/dev/null; done; }
  assert_fail_closed() {  # $1=out $2=rc $3=label — nonzero rc + PRECOND FAIL + flip NOT performed
    [ "$2" != "0" ] || { echo "$1"; fail "$3: pre-state accepted (expected fail-closed)"; }
    echo "$1" | grep -qF 'PRECOND FAIL' || { echo "$1"; fail "$3: did not raise PRECOND FAIL"; }
    echo "$1" | grep -qF 'OSN_FLAG_WRITES=1' && fail "$3: the flag was written" || true
    [ "$(flag_is "$FLAG")" = "false" ] || fail "$3: OSN flag is not false after a fail-closed case"
  }
  # post-reveal production-like baseline: ports active, send=true, OSN false
  set_ports_active; set_flag mainship_send_enabled true; set_flag "$FLAG" false

  # 1) CLEAN ENABLE
  out="$(run_op)"; rc=$?
  [ "$rc" = "0" ] || { echo "$out"; fail "clean enable did not succeed"; }
  for m in 'PRECONDITIONS_PASS=true' 'OSN_FLAG_BEFORE=false' 'OSN_FLAG_WRITES=1' 'OSN_FLAG_AFTER=true' 'SEND_FLAG_UNCHANGED=true' 'OTHER_CONFIG_UNCHANGED=true' 'OSN_ENABLE_OPERATION_PASS=true'; do
    echo "$out" | grep -qF "$m" || { echo "$out"; fail "clean enable missing marker: $m"; }
  done
  [ "$(flag_is "$FLAG")" = "true" ] || fail "OSN flag not true after enable"
  [ "$(flag_is mainship_send_enabled)" = "true" ] || fail "send flag changed by enable"
  echo "ok[1] clean enable: false -> true once; send + other config unchanged; all markers present"
  set_flag "$FLAG" false

  # 2) WRONG CONFIRMATION / NON-MAIN reject before any DB access
  ( assert_confirm "WRONG" ) 2>/dev/null && fail "wrong confirmation accepted" || true
  ( assert_main_only "refs/heads/x" ) 2>/dev/null && fail "non-main ref accepted" || true
  [ "$(flag_is "$FLAG")" = "false" ] || fail "gate touched the flag"
  echo "ok[2] wrong confirmation / non-main ref: rejected before any DB access; flag untouched"

  # 3) INVALID PRE-STATE -> fail-closed, flip not performed
  set_flag "$FLAG" true   # already enabled
  out="$(run_op)"; rc=$?; assert_fail_closed "$out" "$rc" "already-enabled"; set_flag "$FLAG" false
  set_flag mainship_send_enabled false
  out="$(run_op)"; rc=$?; assert_fail_closed "$out" "$rc" "send flag off"; set_flag mainship_send_enabled true
  q "update public.locations set status='hidden' where id='$P1';" >/dev/null
  out="$(run_op)"; rc=$?; assert_fail_closed "$out" "$rc" "a canonical port not active"; set_ports_active
  echo "ok[3] invalid pre-state (already enabled / send off / port not active): fail-closed, flip not performed"

  # 4) RERUN AFTER SUCCESS -> refuses to re-enable
  run_op >/dev/null; [ "$(flag_is "$FLAG")" = "true" ] || fail "rerun setup: first enable did not set true"
  out="$(run_op)"; rc=$?
  [ "$rc" != "0" ] || { echo "$out"; fail "rerun after enable was accepted"; }
  echo "$out" | grep -qiF 'refusing to re-enable' || { echo "$out"; fail "rerun did not refuse"; }
  echo "$out" | grep -qF 'OSN_FLAG_WRITES=1' && fail "rerun wrote the flag again" || true
  echo "ok[4] rerun after success: fail-closed (refuses to re-enable an already-true flag)"
  set_flag "$FLAG" false

  # 5) ONLY-THIS-KEY invariance: an offsetting change to ANOTHER game_config key is caught by the digest
  K="$(q "select key from public.game_config where key not in ('$FLAG','mainship_send_enabled') order by key limit 1;")"
  if [ -n "$K" ]; then
    KV="$(q "select (value)::text from public.game_config where key='$K';")"
    out="$(q "do \$\$ declare dbefore text; dafter text; begin
         select md5(coalesce(string_agg(key||'='||value::text,',' order by key),'')) into dbefore from public.game_config where key<>'$FLAG';
         update public.game_config set value='true'::jsonb where key='$FLAG';            -- the intended enable
         update public.game_config set value='\"__tampered__\"'::jsonb where key='$K';   -- an UNEXPECTED other-key change
         select md5(coalesce(string_agg(key||'='||value::text,',' order by key),'')) into dafter from public.game_config where key<>'$FLAG';
         if dafter is distinct from dbefore then raise exception 'DIGEST detector: a non-OSN game_config key changed'; end if;
       end \$\$;" 2>&1)"
    echo "$out" | grep -qF 'DIGEST detector' || { echo "$out"; fail "5: other-key change not caught by the digest"; }
    [ "$(flag_is "$FLAG")" = "false" ] || fail "5: enable was NOT rolled back"
    [ "$(q "select (value)::text from public.game_config where key='$K';")" = "$KV" ] || fail "5: other key not rolled back"
    echo "ok[5] only-this-key invariance: an unexpected change to another game_config key is caught and rolled back"
  else
    echo "ok[5] only-this-key invariance: (no third game_config key on this chain to perturb — digest logic asserted by selftest)"
  fi

  # restore the disposable dark baseline
  set_flag "$FLAG" false; set_ports_hidden
  [ "$(flag_is "$FLAG")" = "false" ] || fail "cleanup: OSN flag not restored to false"
  echo "OSN-ENABLE LOCAL MATRIX: ALL PASSED"
  exit 0
fi

# ══════════════════════════════ PRODUCTION (gated, human-approved) ══════════════════════════════
: "${OSN_ENABLE_CONFIRM:?confirmation token required}" "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}" "${SUPABASE_DB_PASSWORD:?}"
assert_confirm "$OSN_ENABLE_CONFIRM"
assert_main_only "${GITHUB_REF:-}"
assert_coord_suppressed "$GATES_FILE"
reject_target_overrides
REF="$SUPABASE_PROJECT_ID"; validate_ref "$REF"
for t in curl jq psql openssl; do command -v "$t" >/dev/null 2>&1 || { echo "RESULT: BLOCKED — required tooling missing ($t)"; exit 5; }; done
verify_ca "$CA_FILE"
POOLER="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
  --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/${REF}/config/database/pooler" 2>/dev/null)" \
  || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
ENDPOINT="$(parse_pooler_endpoint "$POOLER")" || { echo "RESULT: BLOCKED — Management API not exactly one endpoint"; exit 4; }
PHOST="${ENDPOINT%%|*}"; API_PORT="${ENDPOINT##*|}"
require_pooler_binding "$PHOST" "$API_PORT" "postgres.$REF" "$REF"
CONN="$(build_prod_conn "$PHOST" "$REF" "$CA_FILE")"
echo "[diag] operation=${PHOST}:5432 (session pooler); tenant=postgres.<ref>; tls=verify-full; sslrootcert=pinned CA"
out="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 \
  psql "$CONN" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)"; rc=$?
echo "$out" | grep -aoE '(PRECONDITIONS_PASS|OSN_FLAG_BEFORE|OSN_FLAG_WRITES|OSN_FLAG_AFTER|SEND_FLAG_UNCHANGED|OTHER_CONFIG_UNCHANGED|OSN_ENABLE_OPERATION_PASS)=[A-Za-z0-9]+' || true
if [ "$rc" = "0" ] && echo "$out" | grep -qF 'OSN_ENABLE_OPERATION_PASS=true'; then
  echo "RESULT: PASS — OSN port-to-port movement is now ENABLED (mainship_space_movement_enabled=true); only that flag changed."
  exit 0
fi
echo "RESULT: FAIL/ABORTED — the enable operation did not confirm success; transaction rolled back. Do NOT retry."
echo "Next step is a SEPARATE read-only verification before any follow-up." >&2
exit 1
