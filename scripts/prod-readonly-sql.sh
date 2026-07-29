#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# PROD READ-ONLY SQL RUNNER — the ONE gated path for running a read-only .sql against production.
#
# ██ Runs a named SQL file against production over the established pinned-CA / sslmode=verify-full /
# ██ Management-API session-pooler route (helpers identical to scripts/osn-hub1a-production-catalog-
# ██ verify.sh). It REFUSES to run any SQL file that is not provably read-only.
#
# WHY GENERIC: rather than fork the connection/trust logic once per diagnostic question, this is the
# single reusable read-only-prod entrypoint. Each question is just a .sql file; this runner enforces
# the read-only contract and supplies the connection. Compose, don't fork.
#
# ██ READ-ONLY, ENFORCED THREE WAYS:
# ██   1. The target .sql MUST open `begin transaction read only` and end in `rollback` — Postgres
# ██      itself then rejects any write.
# ██   2. selftest greps the target .sql for write verbs OUTSIDE string literals and refuses if any
# ██      are present; it also requires the read-only-txn + rollback bookends.
# ██   3. No activation vocabulary (set_game_config / activate-*) may appear in the target .sql.
#
# USAGE
#   scripts/prod-readonly-sql.sh selftest <sql-file>
#   scripts/prod-readonly-sql.sh production <sql-file>     # gated by the `production` Environment
#
# EXIT: 0 ok · 1 selftest/contract fail · 2 usage · 4 could not establish approved prod connection
# ════════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail

MODE="${1:-}"
SQL_ARG="${2:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|production) : ;; *) echo "usage: $0 <selftest|production> <sql-file>" >&2; exit 2;; esac
[ -n "$SQL_ARG" ] || { echo "usage: $0 <selftest|production> <sql-file>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"  # Supabase Root 2021 CA

# Resolve the SQL file relative to repo root; refuse a path that escapes it.
case "$SQL_ARG" in
  /*) SQL_FILE="$SQL_ARG" ;;
  *)  SQL_FILE="$REPO_ROOT/$SQL_ARG" ;;
esac
[ -f "$SQL_FILE" ] || fail "sql file not found: $SQL_ARG"
REAL="$(cd "$(dirname "$SQL_FILE")" && pwd)/$(basename "$SQL_FILE")"
case "$REAL" in "$REPO_ROOT"/*) : ;; *) fail "sql file must live inside the repo: $SQL_ARG" ;; esac

# ── proven connection/trust helpers (identical to osn-hub1a-production-catalog-verify.sh) ──────────
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
build_verifier_conn() { printf 'host=%s port=5432 user=postgres.%s dbname=postgres sslmode=verify-full sslrootcert=%s' "$1" "$2" "$3"; }

# ── the read-only CONTRACT the target SQL must satisfy ─────────────────────────────────────────────
assert_sql_readonly() {
  local f="$1"
  grep -qiE '^[[:space:]]*begin transaction read only[[:space:]]*;' "$f" \
    || fail "target SQL does not open 'begin transaction read only;'"
  grep -qiE '^[[:space:]]*rollback[[:space:]]*;' "$f" \
    || fail "target SQL does not end in 'rollback;'"
  # strip line comments and single-quoted string literals, then look for any write verb.
  local clean
  clean="$(sed "s/--.*$//" "$f" | sed "s/'[^']*'//g")"
  printf '%s' "$clean" | grep -iqE '\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|COMMIT|CALL|COPY|MERGE)\b' \
    && fail "target SQL contains a write verb outside string literals" || true
  printf '%s' "$clean" | grep -iqE 'set_game_config|activate[-_]encounter|activate[-_]canary' \
    && fail "target SQL contains activation vocabulary" || true
}

# ─────────────────────────────────────────── SELFTEST ───────────────────────────────────────────────
if [ "$MODE" = "selftest" ]; then
  bash -n "$0" || fail "runner is not valid bash"
  assert_sql_readonly "$SQL_FILE"
  echo "[selftest] OK: target SQL is read-only (READ ONLY txn + rollback, no write verb, no activation): $SQL_ARG"
  c="$(build_verifier_conn aws-0-x.pooler.supabase.com aaaaaaaaaaaaaaaaaaaa "$CA_FILE")"
  printf '%s' "$c" | grep -q 'sslmode=verify-full' || fail "conn missing verify-full"
  printf '%s' "$c" | grep -qF "sslrootcert=$CA_FILE" || fail "conn missing pinned CA"
  printf '%s' "$c" | grep -qE 'sslmode=(require|prefer|allow|disable)|port=6543|sslrootcert=system' && fail "conn uses weaker TLS/port" || true
  echo "[selftest] OK: conn = verify-full + pinned CA + session 5432"
  require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa
  ( require_pooler_binding evil.example.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad host not rejected" || true
  ( require_pooler_binding aws-0-x.pooler.supabase.com 9999 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad port not rejected" || true
  ( require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.WRONG aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "unbound tenant not rejected" || true
  echo "[selftest] OK: pooler binding fail-closed (host/port/tenant)"
  parse_pooler_endpoint '{"db_host":"aws-0-x.pooler.supabase.com","db_port":6543}' >/dev/null || fail "single object rejected"
  ( parse_pooler_endpoint '[]' ) >/dev/null 2>&1 && fail "empty array not rejected" || true
  ( parse_pooler_endpoint '[{"db_host":"a.pooler.supabase.com","db_port":1},{"db_host":"b.pooler.supabase.com","db_port":2}]' ) >/dev/null 2>&1 && fail "multi endpoint not rejected" || true
  echo "[selftest] OK: exactly-one pooler endpoint enforced"
  verify_ca "$CA_FILE"
  echo "PROD_READONLY_SQL_SELFTEST_PASS"
  exit 0
fi

# ────────────────────────────────────────── PRODUCTION ──────────────────────────────────────────────
reject_target_overrides
assert_sql_readonly "$SQL_FILE"       # re-assert against the checked-out file before we connect
: "${SUPABASE_ACCESS_TOKEN:?SUPABASE_ACCESS_TOKEN required}"
: "${SUPABASE_PROJECT_ID:?SUPABASE_PROJECT_ID required}"
: "${SUPABASE_DB_PASSWORD:?SUPABASE_DB_PASSWORD required}"
REF="$SUPABASE_PROJECT_ID"; validate_ref "$REF"
verify_ca "$CA_FILE"

POOLER="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
  --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/${REF}/config/database/pooler" 2>/dev/null)" \
  || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
ENDPOINT="$(parse_pooler_endpoint "$POOLER")" || { echo "RESULT: BLOCKED — Management API not exactly one endpoint"; exit 4; }
PHOST="${ENDPOINT%%|*}"; API_PORT="${ENDPOINT##*|}"
require_pooler_binding "$PHOST" "$API_PORT" "postgres.$REF" "$REF"
CONN="$(build_verifier_conn "$PHOST" "$REF" "$CA_FILE")"
echo "[diag] target=${PHOST}:5432 (session pooler); tenant=postgres.<ref>; tls=verify-full; sslrootcert=pinned CA"
echo "[diag] running read-only SQL: $SQL_ARG"
echo "────────────────────────────────────────────────────────────────────────────"

env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 \
  psql "$CONN" -X -v ON_ERROR_STOP=1 -f "$SQL_FILE"
rc=$?
echo "────────────────────────────────────────────────────────────────────────────"
echo "NO_PRODUCTION_WRITE_PERFORMED=true"
exit $rc
