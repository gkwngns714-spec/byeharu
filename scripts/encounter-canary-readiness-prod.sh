#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════════════════════════
# ENCOUNTER CANARY — PRODUCTION READ-ONLY READINESS RUNNER
#
# ██ Runs the EXISTING scripts/encounter-canary-readiness.sql against PRODUCTION over the established
# ██ pinned-CA / sslmode=verify-full / Management-API session-pooler route. It adds NO new checks and
# ██ NO second verifier — it only supplies a production DB_URL to the already-proven readiness runner.
#
# WHY THIS EXISTS
#   docs/ENCOUNTER_CANARY_PACKET.md §3A had to be an owner-operated Supabase SQL Editor paste because
#   the authoring machine has no service-role key and no psql. CI does have the secrets. This runner
#   closes that gap so the cap question (CH23) is settled by the same verifier CI already selftests,
#   instead of by a hand-pasted SELECT.
#
# ██ READ-ONLY, THREE WAYS:
# ██   1. encounter-canary-readiness.sql opens `begin transaction read only` + `SET LOCAL
# ██      default_transaction_read_only = on` and ends in `rollback` — Postgres rejects any write.
# ██   2. selftest below re-asserts that textually before any production job is allowed to run.
# ██   3. Nothing here activates a binding, flips a flag, deploys, or approves anything.
#
# MODES
#   selftest     No database, no secrets. Static safety gate for the production job.
#   production   Gated by the protected `production` GitHub Environment. Read-only.
#
# EXIT
#   0  CANARY_READINESS_PASS   — chain is ready (0 blocking findings)
#   1  CANARY_READINESS_FAIL   — blocking finding(s); DO NOT activate. Findings are printed.
#   4  BLOCKED                 — could not establish the approved production connection at all.
# ════════════════════════════════════════════════════════════════════════════════════════════════════
set -uo pipefail

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|production) : ;; *) echo "usage: $0 <selftest|production>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"  # Supabase Root 2021 CA
READINESS_SH="$REPO_ROOT/scripts/encounter-canary-readiness.sh"
READINESS_SQL="$REPO_ROOT/scripts/encounter-canary-readiness.sql"

# ── proven connection/trust helpers (identical to the established OSN-HUB-1A / WORLD-HUB verifiers) ──
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

# ─────────────────────────────────────────── SELFTEST ───────────────────────────────────────────────
if [ "$MODE" = "selftest" ]; then
  [ -f "$READINESS_SH" ]  || fail "readiness runner not found: scripts/encounter-canary-readiness.sh"
  [ -f "$READINESS_SQL" ] || fail "readiness sql not found: scripts/encounter-canary-readiness.sql"
  bash -n "$READINESS_SH" || fail "readiness runner is not valid bash"
  bash -n "$0"            || fail "this runner is not valid bash"
  echo "[selftest] OK: both runners parse"

  # The delegated verifier must still be read-only at the DATABASE level. If either of these ever
  # disappears from the .sql, this production runner must refuse to exist.
  grep -qiE '^[[:space:]]*begin transaction read only[[:space:]]*;' "$READINESS_SQL" \
    || fail "readiness sql no longer opens a READ ONLY transaction"
  grep -qiE '^[[:space:]]*rollback[[:space:]]*;' "$READINESS_SQL" \
    || fail "readiness sql no longer ends in rollback"
  echo "[selftest] OK: delegated SQL is read-only at the database level (READ ONLY txn + rollback)"

  # No write verb outside string literals anywhere in the delegated SQL.
  CLEAN="$(sed "s/--.*$//" "$READINESS_SQL" | sed "s/'[^']*'//g")"
  printf '%s' "$CLEAN" | grep -iqE '\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|COMMIT|CALL|COPY|MERGE)\b' \
    && fail "write verb present in the delegated readiness SQL" || true
  echo "[selftest] OK: no write verb in the delegated readiness SQL"

  # Neither this runner nor the delegated one may carry an activation path.
  for f in "$0" "$READINESS_SH"; do
    sed "s/#.*$//" "$f" | grep -qiE 'set_game_config|activate-encounter|activate_encounter|activate-canary' \
      && fail "activation path present in $(basename "$f")" || true
  done
  echo "[selftest] OK: no activation path in either runner"

  # Connection template + pinned CA + pooler binding fail-closed (proven helpers).
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
  echo "CANARY_READINESS_PROD_SELFTEST_PASS"
  exit 0
fi

# ────────────────────────────────────────── PRODUCTION ──────────────────────────────────────────────
reject_target_overrides
: "${SUPABASE_ACCESS_TOKEN:?SUPABASE_ACCESS_TOKEN required}"
: "${SUPABASE_PROJECT_ID:?SUPABASE_PROJECT_ID required}"
: "${SUPABASE_DB_PASSWORD:?SUPABASE_DB_PASSWORD required}"
REF="$SUPABASE_PROJECT_ID"; validate_ref "$REF"
verify_ca "$CA_FILE"

# Resolve EXACTLY ONE protected session-pooler endpoint from the Management API (host only; tenant ref-bound).
POOLER="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
  --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/${REF}/config/database/pooler" 2>/dev/null)" \
  || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
ENDPOINT="$(parse_pooler_endpoint "$POOLER")" || { echo "RESULT: BLOCKED — Management API not exactly one endpoint"; exit 4; }
PHOST="${ENDPOINT%%|*}"; API_PORT="${ENDPOINT##*|}"
require_pooler_binding "$PHOST" "$API_PORT" "postgres.$REF" "$REF"
CONN="$(build_verifier_conn "$PHOST" "$REF" "$CA_FILE")"
echo "[diag] verifier=${PHOST}:5432 (session pooler); tenant=postgres.<ref>; tls=verify-full; sslrootcert=pinned CA"
echo "[diag] delegating to scripts/encounter-canary-readiness.sh — no checks are defined here"

# Delegate to the ALREADY-PROVEN readiness runner. Its own exit code is this script's exit code.
PGPASSWORD="$SUPABASE_DB_PASSWORD" DB_URL="$CONN" bash "$READINESS_SH"
rc=$?
echo "────────────────────────────────────────────────────────────────────────────"
echo "NO_PRODUCTION_WRITE_PERFORMED=true"
exit $rc
