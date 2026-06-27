#!/usr/bin/env bash
# PORT-LAUNCH-2C — controlled three-port reveal operation orchestrator.
#
# Runs ONE fixed operation (scripts/reveal-starter-ports-operation.sql) that reveals the three canonical
# starter ports exactly once, guarded by preconditions/postconditions. It accepts NO operator-supplied SQL,
# port list, flag name, environment, host, or ref. Connection uses ONLY the repository's already-proven
# production access pattern (Supabase Management-API session-pooler + pinned CA + sslmode=verify-full),
# identical to the read-only catalog verifier. Secrets are never printed; shell tracing is never enabled.
#
# Modes:
#   selftest    DB-free static safety proof of THIS tooling: the confirmation-token gate, the main-only ref
#               guard, the operation SQL's shape (one reveal call, fixed ids, no flag/DDL/home-port writes),
#               the conn template (verify-full + pinned CA + session pooler 5432), override rejection, CA pin.
#   local       Disposable $DB_URL: the operation matrix — happy path + every fail-closed negative.
#   production  GATED, human-approved. Confirm-token + main-ref guard → resolve pooler → run the operation
#               against production. Dispatched ONLY by the protected workflow; NEVER run in PORT-LAUNCH-2C.
set -uo pipefail
# Tracing is intentionally OFF for the whole script (connection details / password must never be traced).
set +x

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local|production) : ;; *) echo "usage: $0 <selftest|local|production>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/reveal-starter-ports-operation.sql"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"  # Supabase Root 2021 CA
CONFIRM_TOKEN="REVEAL_THREE_STARTER_PORTS"   # the only accepted confirmation value
P1='b1a00001-0066-4a00-8a00-000000000001'
P2='b1a00002-0066-4a00-8a00-000000000002'
P3='b1a00003-0066-4a00-8a00-000000000003'

# ── confirmation + ref gate (checked BEFORE any production database connection is attempted) ──────────────
assert_confirm() {  # $1 = the supplied confirmation value
  [ "${1:-}" = "$CONFIRM_TOKEN" ] || fail "confirmation mismatch — expected the exact typed token (refusing to proceed)"
}
assert_main_only() {  # $1 = the git ref (GITHUB_REF)
  [ "${1:-}" = "refs/heads/main" ] || fail "this operation may run ONLY from refs/heads/main (got '${1:-<none>}')"
}

# ── proven connection / trust helpers (identical to the read-only catalog verifier) ──────────────────────
is_hex64() { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{64}$'; }
validate_ref() { printf '%s' "${1:-}" | grep -qE '^[a-z0-9]{20}$' || fail "invalid/empty project ref"; }
OVERRIDE_VARS="DATABASE_URL PGHOST PGPORT PGUSER PGDATABASE PGHOSTADDR PGSERVICE PGURI PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY PGSSLCRL PGPASSWORD PGOPTIONS PSQLRC"
reject_target_overrides() { local v; for v in $OVERRIDE_VARS; do [ -z "${!v:-}" ] || fail "external target/trust override $v is set"; done; }
ca_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//; s/://g' | tr 'A-Z' 'a-z'; }
verify_ca() {
  local f="$1" n fp
  [ -f "$f" ] || fail "CA file not found: scripts/supabase-prod-ca.crt"
  [ -s "$f" ] || fail "CA file is empty"
  n="$(grep -c 'BEGIN CERTIFICATE' "$f" || true)"; [ "$n" = "1" ] || fail "CA must contain exactly one certificate (found $n)"
  openssl x509 -in "$f" -noout >/dev/null 2>&1 || fail "CA is not a valid PEM certificate"
  openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1 || fail "CA certificate is expired"
  fp="$(ca_fingerprint "$f")"; is_hex64 "$fp" || fail "CA fingerprint not 64 hex"; [ "$fp" = "$EXPECTED_CA_SHA256" ] || fail "CA fingerprint mismatch"
  echo "[ca] SHA-256 fingerprint = $fp"
}
parse_pooler_endpoint() {
  printf '%s' "${1:-}" | jq -er '
    ( if type=="array" then (if length==1 then .[0] else error("array length not exactly 1") end)
      elif type=="object" then . else error("unexpected top-level type") end ) as $e
    | ($e.db_host // error("missing db_host")) as $h | ($e.db_port // error("missing db_port")) as $p
    | (if ($h|type)=="string" and ($h|length)>0 then . else error("empty db_host") end) | "\($h)|\($p)"' 2>/dev/null
}
require_pooler_binding() {
  local h="${1:-}" pt="${2:-}" u="${3:-}" r="${4:-}"; validate_ref "$r"
  printf '%s' "$h" | grep -qE '^[a-z0-9][a-z0-9.-]*\.pooler\.supabase\.com$' || fail "host is not <label>.pooler.supabase.com"
  case "$pt" in 5432|6543) : ;; *) fail "pooler port '$pt' not in {5432,6543}";; esac
  [ "$u" = "postgres.${r}" ] || fail "pooler tenant not postgres.<ref>"
}
# Session-pooler, verify-full, pinned CA — identical to the proven read-only verifier conn (the operation
# SQL is what differs: a single guarded read-write reveal transaction instead of a read-only snapshot).
build_prod_conn() { printf 'host=%s port=5432 user=postgres.%s dbname=postgres sslmode=verify-full sslrootcert=%s' "$1" "$2" "$3"; }

# ══════════════════════════════ SELFTEST (DB-free) ══════════════════════════════
if [ "$MODE" = "selftest" ]; then
  [ -f "$OP_SQL" ] || fail "operation SQL not found"
  # 1) confirmation-token gate
  ( assert_confirm "$CONFIRM_TOKEN" ) || fail "valid confirmation token was rejected"
  ( assert_confirm "nope" ) 2>/dev/null && fail "a wrong confirmation token was accepted" || true
  ( assert_confirm "" )     2>/dev/null && fail "an empty confirmation token was accepted" || true
  echo "[selftest] OK: confirmation gate accepts only the exact token"
  # 2) main-only ref guard
  ( assert_main_only "refs/heads/main" ) || fail "refs/heads/main was rejected"
  ( assert_main_only "refs/heads/feature" ) 2>/dev/null && fail "a non-main ref was accepted" || true
  ( assert_main_only "" ) 2>/dev/null && fail "an empty ref was accepted" || true
  echo "[selftest] OK: operation is bound to refs/heads/main only"
  # 3) the operation SQL targets the canonical function exactly once, with the fixed ids, and writes nothing
  #    other than via reveal_starter_ports() (no flag write, no home-port, no DDL/migration).
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"
  [ "$(printf '%s' "$CLEAN" | grep -coE 'reveal_starter_ports\s*\(\s*\)')" = "1" ] || fail "operation must call reveal_starter_ports() exactly once"
  for id in "$P1" "$P2" "$P3"; do printf '%s' "$CLEAN" | grep -qF "$id" || fail "operation missing canonical port id $id"; done
  printf '%s' "$CLEAN" | grep -qiE 'update[[:space:]]+(public\.)?game_config' && fail "operation writes a feature flag (forbidden)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert|update|delete)[[:space:]]+(into[[:space:]]+)?(public\.)?player_home_port' && fail "operation touches player_home_port (forbidden)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate|grant|revoke)\b' && fail "operation contains DDL/migration-like statements (forbidden)" || true
  printf '%s' "$CLEAN" | grep -qiE '\bbegin\b' && printf '%s' "$CLEAN" | grep -qiE '\bcommit\b' || fail "operation must be one explicit BEGIN..COMMIT transaction"
  printf '%s' "$CLEAN" | grep -qE 'lock_timeout' && printf '%s' "$CLEAN" | grep -qE 'statement_timeout' || fail "operation must set conservative timeouts"
  # no operator-supplied placeholders / psql variable interpolation that could inject ports/flags/sql.
  # Excludes PostgreSQL ::type casts and := assignments (a colon NOT preceded by another colon, followed by
  # an identifier/quote, is a psql :var interpolation); also catches ${...} and %%token%% templates.
  printf '%s' "$CLEAN" | grep -qE "(^|[^:]):[A-Za-z_'\"]|%%[A-Za-z_]+%%|\\\$\\{" && fail "operation contains an interpolation placeholder (must be fully hard-coded)" || true
  echo "[selftest] OK: operation is hard-coded — one reveal call, fixed ids, no flag/home-port/DDL writes, one timed transaction, no placeholders"
  # 4) connection template: verify-full + pinned CA + session port 5432; no weaker TLS / 6543 / system CA
  c="$(build_prod_conn aws-0-x.pooler.supabase.com aaaaaaaaaaaaaaaaaaaa "$CA_FILE")"
  printf '%s' "$c" | grep -q 'sslmode=verify-full' || fail "conn missing verify-full"
  printf '%s' "$c" | grep -q 'port=5432' || fail "conn not forced to session 5432"
  printf '%s' "$c" | grep -qF "sslrootcert=$CA_FILE" || fail "conn missing pinned CA"
  printf '%s' "$c" | grep -qE 'sslmode=(require|prefer|allow|disable)|port=6543|sslrootcert=system' && fail "conn uses weaker TLS/port/CA" || true
  echo "[selftest] OK: conn = verify-full + pinned CA + session 5432 (no weaker TLS/6543/system CA)"
  # 5) pooler binding + endpoint parse + override rejection (proven helpers)
  require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa
  ( require_pooler_binding evil.example.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad host not rejected" || true
  ( require_pooler_binding aws-0-x.pooler.supabase.com 9999 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad port not rejected" || true
  ( require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.WRONG aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "unbound tenant not rejected" || true
  echo "[selftest] OK: pooler binding fail-closed (host/port/tenant)"
  if command -v jq >/dev/null 2>&1; then
    parse_pooler_endpoint '{"db_host":"aws-0-x.pooler.supabase.com","db_port":6543}' >/dev/null || fail "single object rejected"
    ( parse_pooler_endpoint '[]' ) >/dev/null 2>&1 && fail "empty array not rejected" || true
    ( parse_pooler_endpoint '[{"db_host":"a.pooler.supabase.com","db_port":1},{"db_host":"b.pooler.supabase.com","db_port":2}]' ) >/dev/null 2>&1 && fail "multi endpoint not rejected" || true
    echo "[selftest] OK: Management-API endpoint parse fail-closed"
  else echo "[selftest] note: jq absent locally — endpoint-parse check runs in CI"; fi
  for v in $OVERRIDE_VARS; do if ( export "$v=x"; reject_target_overrides ) >/dev/null 2>&1; then fail "$v override not rejected"; fi; done
  echo "[selftest] OK: target/trust override vars rejected"
  grep -nE 'db\.\$\{|host=db\.' "$0" >/dev/null 2>&1 && fail "a direct per-project host construction is present" || true
  echo "[selftest] OK: no direct per-project host construction (pooler endpoint only)"
  verify_ca "$CA_FILE"
  echo "REVEAL-STARTER-PORTS SELFTEST: ALL PASSED"
  exit 0
fi

# ══════════════════════════════ LOCAL (disposable operation matrix) ══════════════════════════════
if [ "$MODE" = "local" ]; then
  : "${DB_URL:?DB_URL (disposable stack) required}"
  q() { PGAPPNAME=mon psql "$DB_URL" -X -q -t -A -c "$1"; }
  run_op() { PGAPPNAME=reveal-op psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1; }
  set_status() { q "update public.locations set status='$2' where id='$1';" >/dev/null; }
  hidden_n() { q "select count(*) from public.locations where id in ('$P1','$P2','$P3') and status='hidden';"; }
  active_n() { q "select count(*) from public.locations where id in ('$P1','$P2','$P3') and status='active';"; }
  ensure_hidden() { for p in "$P1" "$P2" "$P3"; do set_status "$p" hidden; done; }
  # disposable stack mirrors the LIVE flags (send=true) so the real precondition path runs; OSN stays dark.
  q "update public.game_config set value='true'  where key='mainship_send_enabled';" >/dev/null
  q "update public.game_config set value='false' where key='mainship_space_movement_enabled';" >/dev/null

  # 1) HAPPY PATH
  ensure_hidden
  out="$(run_op)"; rc=$?
  [ "$rc" = "0" ] || { echo "$out"; fail "happy path did not succeed"; }
  for m in 'PRECONDITIONS_PASS=true' 'REVEAL_FUNCTION_CALLS=1' 'STARTER_PORTS_ACTIVE_AFTER=3' 'FLAGS_UNCHANGED=true' 'REVEAL_OPERATION_PASS=true'; do
    echo "$out" | grep -qF "$m" || { echo "$out"; fail "happy path missing marker: $m"; }
  done
  [ "$(active_n)" = "3" ] || fail "happy path did not leave 3 ports active"
  [ "$(q "select count(*) from public.game_config where key='mainship_space_movement_enabled' and value='false'::jsonb;")" = "1" ] || fail "OSN flag changed during happy path"
  echo "ok[1] happy path: 3 hidden -> reveal once -> 3 active, flags unchanged, all markers present"
  ensure_hidden

  # 2) WRONG PRE-STATE (only 2 hidden / one already active) -> fail closed, no reveal call, no change
  set_status "$P1" active
  out="$(run_op)"; rc=$?
  [ "$rc" != "0" ] || fail "wrong pre-state was accepted"
  echo "$out" | grep -qF 'PRECOND FAIL' || { echo "$out"; fail "wrong pre-state did not raise PRECOND FAIL"; }
  echo "$out" | grep -qF 'REVEAL_FUNCTION_CALLS=1' && fail "reveal was called despite a wrong pre-state" || true
  [ "$(q "select status from public.locations where id='$P1';")" = "active" ] && [ "$(q "select count(*) from public.locations where id in ('$P2','$P3') and status='hidden';")" = "2" ] || fail "wrong pre-state altered port state (should be no change)"
  echo "ok[2] wrong pre-state (2 hidden/1 active): fail-closed, reveal not called, no change"
  ensure_hidden

  # 3) RERUN AFTER SUCCESS -> the second run fails closed at the precondition and never calls reveal again
  run_op >/dev/null; [ "$(active_n)" = "3" ] || fail "rerun setup: first reveal did not activate 3"
  out="$(run_op)"; rc=$?
  [ "$rc" != "0" ] || fail "rerun after success was accepted (must fail closed)"
  echo "$out" | grep -qF 'PRECOND FAIL' || { echo "$out"; fail "rerun did not fail closed at the precondition"; }
  echo "$out" | grep -qiF 'already ACTIVE' || { echo "$out"; fail "rerun did not report already-active"; }
  echo "$out" | grep -qF 'REVEAL_FUNCTION_CALLS=1' && fail "reveal was called a second time on rerun" || true
  [ "$(active_n)" = "3" ] || fail "rerun changed the active count"
  echo "ok[3] rerun after success: fail-closed at precondition (already ACTIVE), reveal NOT called again, no change"
  ensure_hidden

  # 4) FLAG TAMPER -> fail closed before reveal; restore. assert_fail_closed checks: nonzero rc, a PRECOND
  #    FAIL message, and that reveal was NOT called.
  assert_fail_closed() {  # $1=output  $2=rc  $3=case label
    [ "$2" != "0" ] || { echo "$1"; fail "$3: pre-state was accepted (expected fail-closed)"; }
    echo "$1" | grep -qF 'PRECOND FAIL' || { echo "$1"; fail "$3: did not raise PRECOND FAIL"; }
    echo "$1" | grep -qF 'REVEAL_FUNCTION_CALLS=1' && fail "$3: reveal was called" || true
  }
  q "update public.game_config set value='true' where key='mainship_space_movement_enabled';" >/dev/null
  out="$(run_op)"; rc=$?; assert_fail_closed "$out" "$rc" "OSN flag on"
  [ "$(hidden_n)" = "3" ] || fail "flag-tamper (space=true) case revealed ports"
  q "update public.game_config set value='false' where key='mainship_space_movement_enabled';" >/dev/null
  q "update public.game_config set value='false' where key='mainship_send_enabled';" >/dev/null
  out="$(run_op)"; rc=$?; assert_fail_closed "$out" "$rc" "send flag off"
  [ "$(hidden_n)" = "3" ] || fail "send-flag (send=false) case revealed ports"
  q "update public.game_config set value='true' where key='mainship_send_enabled';" >/dev/null
  echo "ok[4] flag tamper (space=true / send=false): fail-closed before reveal, ports unchanged"
  ensure_hidden

  # 5) UNEXPECTED-MUTATION DETECTORS fail closed AND roll back (the operation's two safety nets)
  #   5a) flag-change detector: snapshot -> change flag -> the unchanged-assertion raises -> ROLLBACK restores it
  q "do \$\$ declare b jsonb; begin
       select value into b from public.game_config where key='mainship_space_movement_enabled';
       update public.game_config set value='true' where key='mainship_space_movement_enabled';
       if (select value from public.game_config where key='mainship_space_movement_enabled') is distinct from b then
         raise exception 'detector: a feature flag changed'; end if;
     end \$\$;" >/tmp/det_a 2>&1 && fail "5a flag-change detector did not raise"
  [ "$(q "select count(*) from public.game_config where key='mainship_space_movement_enabled' and value='false'::jsonb;")" = "1" ] || fail "5a flag-change was NOT rolled back"
  #   5b) unexpected extra-active detector: reveal +3 but also flip an extra non-canonical location -> net<>+3 -> raise -> ROLLBACK
  XLOC="$(q "select id from public.locations where id not in ('$P1','$P2','$P3') and status='active' limit 1;")"
  q "do \$\$ declare before int; after int; begin
       select count(*) into before from public.locations where status='active';
       perform public.reveal_starter_ports();
       update public.locations set status='hidden' where id='$XLOC';   -- an UNEXPECTED extra change
       select count(*) into after from public.locations where status='active';
       if after <> before + 3 then raise exception 'detector: net active change % (expected +3) — unexpected mutation', after-before; end if;
     end \$\$;" >/tmp/det_b 2>&1 && fail "5b extra-mutation detector did not raise"
  [ "$(hidden_n)" = "3" ] || fail "5b reveal was NOT rolled back"
  [ "$(q "select status from public.locations where id='$XLOC';")" = "active" ] || fail "5b unexpected change was NOT rolled back"
  echo "ok[5] unexpected-mutation detectors (flag-change, extra active): fail-closed and rolled back"
  ensure_hidden

  # restore the disposable stack to the dark baseline
  ensure_hidden
  [ "$(hidden_n)" = "3" ] || fail "cleanup: ports not all hidden"
  echo "REVEAL-STARTER-PORTS LOCAL OPERATION MATRIX: ALL PASSED"
  exit 0
fi

# ══════════════════════════════ PRODUCTION (gated, human-approved — NEVER run in PORT-LAUNCH-2C) ═════════
: "${REVEAL_CONFIRM:?confirmation token required}" "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}" "${SUPABASE_DB_PASSWORD:?}"
assert_confirm "$REVEAL_CONFIRM"               # exact typed token BEFORE any production connection
assert_main_only "${GITHUB_REF:-}"             # only from refs/heads/main
reject_target_overrides
REF="$SUPABASE_PROJECT_ID"; validate_ref "$REF"
for t in curl jq psql openssl; do command -v "$t" >/dev/null 2>&1 || { echo "RESULT: BLOCKED — required tooling missing ($t)"; exit 5; }; done
verify_ca "$CA_FILE"
# Resolve EXACTLY ONE protected session-pooler endpoint from the Management API (host only; tenant ref-bound).
POOLER="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
  --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/${REF}/config/database/pooler" 2>/dev/null)" \
  || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
ENDPOINT="$(parse_pooler_endpoint "$POOLER")" || { echo "RESULT: BLOCKED — Management API not exactly one endpoint"; exit 4; }
PHOST="${ENDPOINT%%|*}"; API_PORT="${ENDPOINT##*|}"
require_pooler_binding "$PHOST" "$API_PORT" "postgres.$REF" "$REF"
CONN="$(build_prod_conn "$PHOST" "$REF" "$CA_FILE")"
echo "[diag] operation=${PHOST}:5432 (session pooler); tenant=postgres.<ref>; tls=verify-full; sslrootcert=pinned CA"
# ONE psql invocation, ONE transaction. No retry: a failed/uncertain result fails closed; a human must then
# run a separate read-only post-reveal verification before any follow-up.
out="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 \
  psql "$CONN" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)"; rc=$?
echo "$out" | grep -aoE '(PRECONDITIONS_PASS|STARTER_PORTS_EXPECTED|STARTER_PORTS_HIDDEN_BEFORE|REVEAL_FUNCTION_CALLS|STARTER_PORTS_ACTIVE_AFTER|FLAGS_UNCHANGED|REVEAL_OPERATION_PASS)=[0-9a-z]+' || true
if [ "$rc" = "0" ] && echo "$out" | grep -qF 'REVEAL_OPERATION_PASS=true'; then
  echo "RESULT: PASS — the three canonical starter ports were revealed exactly once (flags unchanged)"
  exit 0
fi
echo "RESULT: FAIL/ABORTED — the reveal operation did not confirm success; transaction rolled back. Do NOT retry."
echo "Next step is a SEPARATE human-gated read-only post-reveal verification before any follow-up." >&2
exit 1
