#!/usr/bin/env bash
# PORT-ENTRY-1-VERIFY-1 — STRICTLY READ-ONLY production verifier orchestrator for the deployed PORT-ENTRY-1
# surface (migration 0072). Connection discipline mirrors scripts/osn-postenable-verify.sh: proven pinned-CA +
# sslmode=verify-full session pooler, one REPEATABLE READ READ ONLY snapshot, no writes. Modes:
#   selftest   — DB-free static checks (read-only safety; expected markers; prosrc derivation present);
#   local      — run the SQL against a disposable DB_URL (proof harness validates pass + fail-closed cases);
#   production — gated, read-only, pinned-CA verify-full session pooler (NOT run during build; dispatch-only).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local|production) : ;; *) echo "usage: $0 <selftest|local|production>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL="$REPO_ROOT/scripts/port-entry-1-production-verify.sql"
MIG="$REPO_ROOT/supabase/migrations/20260618000072_port_entry_commission_normalize.sql"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
GATES_FILE="$REPO_ROOT/src/features/map/osnReleaseGates.ts"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"

# ── deterministic prosrc md5 derivation from the migration chain (version-stable repository reference) ───────
# Extracts a function's raw body (the exact dollar-quoted text Postgres stores as pg_proc.prosrc) between its
# `create or replace function <start>` line and the matching `$$;`, and md5s it. The disposable proof asserts
# this equals the catalog md5(prosrc) on the real chain, validating the extraction byte-for-byte.
# Extract a function's raw body to a temp file (CRLF-normalized), FAIL CLOSED if empty/malformed (start not
# matched or no captured body), then md5 the exact bytes (file md5 == stdin md5; trailing newline preserved).
extract_prosrc_md5() { local f="$1" start="$2" tmp; tmp="$(mktemp)"
  awk -v start="$start" '
    { sub(/\r$/, "") }
    index($0,start)==1 {inf=1}
    inf && $0=="as $$" {cap=1; printf "\n"; next}
    inf && cap && $0=="$$;" {exit}
    inf && cap {print}
  ' "$f" > "$tmp"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi      # empty body → malformed/ambiguous extraction → fail closed
  md5sum "$tmp" | cut -d" " -f1; rm -f "$tmp"; }
derive_hashes() {
  EXP_W="$(extract_prosrc_md5 "$MIG" 'create or replace function public.port_entry_commission_writer(p_player uuid)')" || fail "writer body extraction empty/malformed"
  EXP_C="$(extract_prosrc_md5 "$MIG" 'create or replace function public.commission_first_main_ship()')" || fail "commission body extraction empty/malformed"
  EXP_N="$(extract_prosrc_md5 "$MIG" 'create or replace function public.normalize_main_ship_dock()')" || fail "normalize body extraction empty/malformed"
  printf '%s' "$EXP_W" | grep -qE '^[0-9a-f]{32}$' || fail "writer prosrc md5 malformed"
  printf '%s' "$EXP_C" | grep -qE '^[0-9a-f]{32}$' || fail "commission prosrc md5 malformed"
  printf '%s' "$EXP_N" | grep -qE '^[0-9a-f]{32}$' || fail "normalize prosrc md5 malformed"
}

# ── proven connection / trust helpers (same pattern as osn-postenable-verify.sh) ─────────────────────────────
is_hex64() { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{64}$'; }
validate_ref() { printf '%s' "${1:-}" | grep -qE '^[a-z0-9]{20}$' || fail "invalid/empty project ref"; }
OVERRIDE_VARS="DATABASE_URL PGHOST PGPORT PGUSER PGDATABASE PGHOSTADDR PGSERVICE PGURI PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY PGSSLCRL PGPASSWORD PGOPTIONS PSQLRC"
reject_target_overrides() { local v; for v in $OVERRIDE_VARS; do [ -z "${!v:-}" ] || fail "external target/trust override $v is set"; done; }
ca_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//; s/://g' | tr 'A-Z' 'a-z'; }
verify_ca() { local f="$1" n fp
  [ -f "$f" ] || fail "CA file not found"; [ -s "$f" ] || fail "CA empty"
  n="$(grep -c 'BEGIN CERTIFICATE' "$f" || true)"; [ "$n" = "1" ] || fail "CA must contain exactly one cert (found $n)"
  openssl x509 -in "$f" -noout >/dev/null 2>&1 || fail "CA not valid PEM"; openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1 || fail "CA expired"
  fp="$(ca_fingerprint "$f")"; is_hex64 "$fp" || fail "CA fp not 64 hex"; [ "$fp" = "$EXPECTED_CA_SHA256" ] || fail "CA fingerprint mismatch"; echo "[ca] SHA-256 = $fp"; }
parse_pooler_endpoint() { printf '%s' "${1:-}" | jq -er '
  ( if type=="array" then (if length==1 then .[0] else error("array length not exactly 1") end) elif type=="object" then . else error("unexpected") end ) as $e
  | ($e.db_host // error("missing db_host")) as $h | ($e.db_port // error("missing db_port")) as $p
  | (if ($h|type)=="string" and ($h|length)>0 then . else error("empty db_host") end) | "\($h)|\($p)"' 2>/dev/null; }
require_pooler_binding() { local h="${1:-}" pt="${2:-}" u="${3:-}" r="${4:-}"; validate_ref "$r"
  printf '%s' "$h" | grep -qE '^[a-z0-9][a-z0-9.-]*\.pooler\.supabase\.com$' || fail "host not <label>.pooler.supabase.com"
  case "$pt" in 5432|6543) : ;; *) fail "pooler port '$pt' not in {5432,6543}";; esac
  [ "$u" = "postgres.${r}" ] || fail "pooler tenant not postgres.<ref>"; }
build_conn() { printf 'host=%s port=5432 user=postgres.%s dbname=postgres sslmode=verify-full sslrootcert=%s' "$1" "$2" "$3"; }
mval() { printf '%s\n' "${1:-}" | grep -m1 -E "^$2=" | cut -d= -f2- ; }
assert_coord_suppressed() { local f="$1"
  grep -qE 'OSN_COORDINATE_TRAVEL_ENABLED[[:space:]]*=[[:space:]]*true' "$f" && return 1
  grep -qE 'OSN_COORDINATE_TRAVEL_ENABLED[[:space:]]*=[[:space:]]*false' "$f" || return 1; return 0; }

# read-only safety scan of the verifier SQL (0=safe). No write/DDL; no executable PORT-ENTRY mutation RPC.
sql_is_readonly_safe() { local f="$1" clean nostr
  clean="$(sed -E 's/--.*//' "$f")"; nostr="$(printf '%s' "$clean" | sed "s/'[^']*'//g")"
  printf '%s' "$nostr" | grep -iqE '\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|merge|call|copy)\b' && return 1
  # the PORT-ENTRY mutation RPCs / private writer must NEVER appear as executable code (only inside quoted lookups)
  printf '%s' "$nostr" | grep -qE 'commission_first_main_ship|normalize_main_ship_dock|port_entry_commission_writer' && return 1
  grep -q 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY' "$f" || return 1
  grep -q 'default_transaction_read_only = on' "$f" || return 1
  grep -qE '^[[:space:]]*ROLLBACK;' "$f" || return 1
  printf '%s' "$clean" | grep -iqE '\bcommit\b' && return 1
  return 0; }

# ── reconcile markers → fail-closed OVERALL_PASS ─────────────────────────────────────────────────────────────
RECON_PASS=1
reconcile() { local OUT="$1"; RECON_PASS=1
  ck() { if [ "${1:-}" != "$2" ]; then echo "  CHECK FAIL: $3 (got '${1:-}', want '$2')"; RECON_PASS=0; fi; }
  ck "$(mval "$OUT" RO)" on "read-only transaction active"
  ck "$(mval "$OUT" HEAD)" 20260618000072 "migration head 0072"
  ck "$(mval "$OUT" N_AFTER)" 0 "no migration after 0072"
  ck "$(mval "$OUT" HAS_0072)" 1 "0072 present in history"
  local f
  for f in W C N; do
    ck "$(mval "$OUT" ${f}_RESOLVED)" 1 "$f function resolves"
    ck "$(mval "$OUT" ${f}_RET_JSONB)" 1 "$f returns jsonb"
    ck "$(mval "$OUT" ${f}_PLPGSQL)" 1 "$f language plpgsql"
    ck "$(mval "$OUT" ${f}_SECDEF)" 1 "$f SECURITY DEFINER"
    ck "$(mval "$OUT" ${f}_SEARCHPATH)" 1 "$f search_path=public"
    ck "$(mval "$OUT" ${f}_OWNER)" postgres "$f owner=postgres"
    ck "$(mval "$OUT" ${f}_PROSRC_OK)" 1 "$f prosrc matches migration-derived hash"
  done
  # ACLs: writer service_role-only; both public RPCs authenticated-only (service_role descriptive, not gated)
  ck "$(mval "$OUT" ACL_W_PUBLIC_DENIED)" 1 "writer PUBLIC denied"
  ck "$(mval "$OUT" ACL_W_ANON_DENIED)" 1 "writer anon denied"
  ck "$(mval "$OUT" ACL_W_AUTH_DENIED)" 1 "writer authenticated denied"
  ck "$(mval "$OUT" ACL_W_SVC_ALLOWED)" 1 "writer service_role allowed"
  ck "$(mval "$OUT" ACL_C_PUBLIC_DENIED)" 1 "commission PUBLIC denied"
  ck "$(mval "$OUT" ACL_C_ANON_DENIED)" 1 "commission anon denied"
  ck "$(mval "$OUT" ACL_C_AUTH_ALLOWED)" 1 "commission authenticated allowed"
  ck "$(mval "$OUT" ACL_N_PUBLIC_DENIED)" 1 "normalize PUBLIC denied"
  ck "$(mval "$OUT" ACL_N_ANON_DENIED)" 1 "normalize anon denied"
  ck "$(mval "$OUT" ACL_N_AUTH_ALLOWED)" 1 "normalize authenticated allowed"
  ck "$(mval "$OUT" PE_FN_COUNT)" 3 "exactly 3 PORT-ENTRY functions"
  ck "$(mval "$OUT" PE_FN_UNEXPECTED)" 0 "no unexpected PORT-ENTRY-prefixed function"
  ck "$(mval "$OUT" PE_AUTH_EXEC_COUNT)" 2 "exactly 2 authenticated-executable PORT-ENTRY RPCs"
  # FULL canonical authenticated client-RPC inventory must match EXACTLY (missing / lost-grant / any unexpected)
  ck "$(mval "$OUT" INV_UNRESOLVED)" 0 "every expected client RPC resolves"
  ck "$(mval "$OUT" INV_MISSING)" 0 "no expected authenticated client RPC missing (got missing='$(mval "$OUT" INV_MISSING_LIST)')"
  ck "$(mval "$OUT" INV_EXTRA)" 0 "no unexpected authenticated-executable public function (got extra='$(mval "$OUT" INV_EXTRA_LIST)')"
  ck "$(mval "$OUT" PE_TABLE_COUNT)" 0 "no PORT-ENTRY-specific table"
  ck "$(mval "$OUT" SEND_ROWS)" 1 "send flag present once"
  ck "$(mval "$OUT" SPACE_ROWS)" 1 "space flag present once"
  ck "$(mval "$OUT" COORD_ROWS)" 1 "coord flag present once"
  ck "$(mval "$OUT" FLAG_SEND)" 1 "mainship_send_enabled true"
  ck "$(mval "$OUT" FLAG_SPACE)" 1 "mainship_space_movement_enabled true"
  ck "$(mval "$OUT" FLAG_COORD)" 0 "mainship_coordinate_travel_enabled FALSE"
  ck "$(mval "$OUT" COORD_CMD_PRESENT)" 1 "raw coordinate command present (catalog)"
  ck "$(mval "$OUT" RDN_HAS_COORD_FIELD)" 1 "readiness exposes coordinate_travel_available"
  ck "$(mval "$OUT" RDN_COORD_NOAUTH)" false "readiness no-auth coordinate_travel_available=false"
}
emit_markers() { local OUT="$1"
  echo "MIGRATION_HEAD=$( [ "$(mval "$OUT" HEAD)" = 20260618000072 ] && echo 0072 || mval "$OUT" HEAD )"
  echo "NO_MIGRATION_AFTER_0072=$( [ "$(mval "$OUT" N_AFTER)" = 0 ] && echo true || echo false )"
  echo "PORT_ENTRY_FUNCTIONS_PRESENT=$( [ "$(mval "$OUT" PE_FN_COUNT)" = 3 ] && echo true || echo false )"
  echo "PORT_ENTRY_FUNCTION_BODIES_MATCH_SOURCE=$( [ "$(mval "$OUT" W_PROSRC_OK)" = 1 ] && [ "$(mval "$OUT" C_PROSRC_OK)" = 1 ] && [ "$(mval "$OUT" N_PROSRC_OK)" = 1 ] && echo true || echo false )"
  echo "WRITER_SERVICE_ROLE_ONLY=$( [ "$(mval "$OUT" ACL_W_PUBLIC_DENIED)" = 1 ] && [ "$(mval "$OUT" ACL_W_ANON_DENIED)" = 1 ] && [ "$(mval "$OUT" ACL_W_AUTH_DENIED)" = 1 ] && [ "$(mval "$OUT" ACL_W_SVC_ALLOWED)" = 1 ] && echo true || echo false )"
  echo "PUBLIC_RPCS_AUTHENTICATED_ONLY=$( [ "$(mval "$OUT" ACL_C_PUBLIC_DENIED)" = 1 ] && [ "$(mval "$OUT" ACL_C_ANON_DENIED)" = 1 ] && [ "$(mval "$OUT" ACL_C_AUTH_ALLOWED)" = 1 ] && [ "$(mval "$OUT" ACL_N_PUBLIC_DENIED)" = 1 ] && [ "$(mval "$OUT" ACL_N_ANON_DENIED)" = 1 ] && [ "$(mval "$OUT" ACL_N_AUTH_ALLOWED)" = 1 ] && echo true || echo false )"
  echo "PUBLIC_RPC_SERVICE_ROLE_EXEC=commission=$(mval "$OUT" ACL_C_SVC),normalize=$(mval "$OUT" ACL_N_SVC) (descriptive — hosted policy, not gated)"
  echo "NO_UNEXPECTED_PORT_ENTRY_SURFACE=$( [ "$(mval "$OUT" PE_FN_UNEXPECTED)" = 0 ] && [ "$(mval "$OUT" PE_AUTH_EXEC_COUNT)" = 2 ] && echo true || echo false )"
  echo "AUTHENTICATED_CLIENT_RPC_INVENTORY_EXACT=$( [ "$(mval "$OUT" INV_UNRESOLVED)" = 0 ] && [ "$(mval "$OUT" INV_MISSING)" = 0 ] && [ "$(mval "$OUT" INV_EXTRA)" = 0 ] && echo true || echo false )"
  echo "AUTHENTICATED_CLIENT_RPC_EXPECTED_N=$(mval "$OUT" INV_EXPECTED_N)"
  echo "AUTHENTICATED_CLIENT_RPC_OBSERVED_N=$(mval "$OUT" INV_OBSERVED_N)"
  echo "AUTHENTICATED_CLIENT_RPC_MISSING=$(mval "$OUT" INV_MISSING_LIST)"
  echo "AUTHENTICATED_CLIENT_RPC_EXTRA=$(mval "$OUT" INV_EXTRA_LIST)"
  echo "AUTHENTICATED_CLIENT_RPC_OBSERVED=$(mval "$OUT" INV_OBSERVED_LIST)"
  echo "NO_PORT_ENTRY_TABLE=$( [ "$(mval "$OUT" PE_TABLE_COUNT)" = 0 ] && echo true || echo false )"
  echo "MAINSHIP_SEND_ENABLED=$( [ "$(mval "$OUT" FLAG_SEND)" = 1 ] && echo true || echo false )"
  echo "MAINSHIP_SPACE_MOVEMENT_ENABLED=$( [ "$(mval "$OUT" FLAG_SPACE)" = 1 ] && echo true || echo false )"
  echo "MAINSHIP_COORDINATE_TRAVEL_ENABLED=$( case "$(mval "$OUT" FLAG_COORD)" in 1) echo true;; 0) echo false;; *) echo "UNPARSEABLE";; esac )"
  echo "COORDINATE_TRAVEL_AVAILABLE_NOAUTH=$(mval "$OUT" RDN_COORD_NOAUTH)"
  echo "COORDINATE_COMMAND_GATE_PRESENT=$( [ "$(mval "$OUT" COORD_CMD_PRESENT)" = 1 ] && echo true || echo false )"
  echo "OSN_COORDINATE_TRAVEL_ENABLED_FRONTEND=false"
  echo "NO_PRODUCTION_WRITE_PERFORMED=true"
  echo "OVERALL_PASS=$( [ "$RECON_PASS" = 1 ] && echo true || echo false )"
}

# ══════════════════════════ SELFTEST (DB-free) ══════════════════════════
if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "verifier SQL not found"; [ -f "$MIG" ] || fail "migration 0072 not found"
  sql_is_readonly_safe "$SQL" || fail "verifier SQL is not read-only safe (write/DDL or an executable PORT-ENTRY mutation RPC)"
  echo "[selftest] OK: SQL is read-only (REPEATABLE READ READ ONLY + ROLLBACK; no write/DDL; no executable commission/normalize/writer call)"
  grep -q "md5(p.prosrc)=:'exp_writer'" "$SQL" || fail "SQL does not compare writer prosrc md5"
  grep -q "md5(p.prosrc)=:'exp_commission'" "$SQL" || fail "SQL does not compare commission prosrc md5"
  grep -q "md5(p.prosrc)=:'exp_normalize'" "$SQL" || fail "SQL does not compare normalize prosrc md5"
  grep -q "pg_get_functiondef" "$SQL" && fail "must NOT use pg_get_functiondef for body identity" || true
  # FULL authenticated client-RPC inventory assertion present, includes the two public PORT-ENTRY RPCs, EXCLUDES the writer
  grep -q "'INV_MISSING='" "$SQL" || fail "SQL missing INV_MISSING inventory marker"
  grep -q "'INV_EXTRA='" "$SQL" || fail "SQL missing INV_EXTRA inventory marker"
  grep -q "has_function_privilege('authenticated', p.oid, 'EXECUTE')" "$SQL" || fail "inventory does not enumerate authenticated-executable functions"
  grep -q "('public.commission_first_main_ship()')" "$SQL" || fail "inventory expected set omits commission RPC"
  grep -q "('public.normalize_main_ship_dock()')" "$SQL" || fail "inventory expected set omits normalize RPC"
  grep -qE "^  \('public\.port_entry_commission_writer" "$SQL" && fail "private writer must NOT be in the authenticated client-RPC inventory" || true
  for m in HEAD W_SECDEF C_SECDEF N_SECDEF ACL_W_SVC_ALLOWED ACL_C_AUTH_ALLOWED FLAG_COORD RDN_COORD_NOAUTH; do
    grep -q "'$m=" "$SQL" || fail "SQL missing marker $m"; done
  derive_hashes
  echo "[selftest] OK: derived migration prosrc md5 — writer=$EXP_W commission=$EXP_C normalize=$EXP_N"
  c="$(build_conn aws-0-x.pooler.supabase.com aaaaaaaaaaaaaaaaaaaa "$CA_FILE")"
  printf '%s' "$c" | grep -q 'sslmode=verify-full' || fail "conn missing verify-full"
  printf '%s' "$c" | grep -q 'port=5432' || fail "conn not session 5432"
  printf '%s' "$c" | grep -qE 'sslmode=(require|prefer|allow|disable)|port=6543|sslrootcert=system' && fail "conn weaker TLS/port/CA" || true
  require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa
  ( require_pooler_binding evil.example.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad host not rejected" || true
  for v in $OVERRIDE_VARS; do if ( export "$v=x"; reject_target_overrides ) >/dev/null 2>&1; then fail "$v override not rejected"; fi; done
  assert_coord_suppressed "$GATES_FILE" || fail "OSN_COORDINATE_TRAVEL_ENABLED not false"
  verify_ca "$CA_FILE"
  echo "PORT-ENTRY-1-VERIFY SELFTEST: ALL PASSED"
  exit 0
fi

# ══════════════════════════ LOCAL (disposable) ══════════════════════════
if [ "$MODE" = "local" ]; then
  : "${DB_URL:?DB_URL (disposable stack) required}"
  derive_hashes
  OUT="$(psql "$DB_URL" -X -q -A -t -v ON_ERROR_STOP=1 -v exp_writer="$EXP_W" -v exp_commission="$EXP_C" -v exp_normalize="$EXP_N" -f "$SQL")"
  reconcile "$OUT"; emit_markers "$OUT"
  [ "$RECON_PASS" = 1 ] || fail "verifier did not pass against the expected PORT-ENTRY-1 catalog"
  echo "PORT-ENTRY-1-VERIFY LOCAL: OVERALL_PASS=true"
  exit 0
fi

# ══════════════════════════ PRODUCTION (gated, read-only — dispatch-only) ══════════════════════════
: "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}" "${SUPABASE_DB_PASSWORD:?}"
reject_target_overrides
REF="$SUPABASE_PROJECT_ID"; validate_ref "$REF"
for t in curl jq psql openssl md5sum awk; do command -v "$t" >/dev/null 2>&1 || { echo "RESULT: BLOCKED — required tooling missing ($t)"; exit 5; }; done
assert_coord_suppressed "$GATES_FILE" || { echo "RESULT: BLOCKED — OSN_COORDINATE_TRAVEL_ENABLED is not false"; exit 5; }
verify_ca "$CA_FILE"
derive_hashes
POOLER="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
  --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/${REF}/config/database/pooler" 2>/dev/null)" || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
ENDPOINT="$(parse_pooler_endpoint "$POOLER")" || { echo "RESULT: BLOCKED — Management API not exactly one endpoint"; exit 4; }
PHOST="${ENDPOINT%%|*}"; API_PORT="${ENDPOINT##*|}"
require_pooler_binding "$PHOST" "$API_PORT" "postgres.$REF" "$REF"
CONN="$(build_conn "$PHOST" "$REF" "$CA_FILE")"
echo "[diag] verifier=${PHOST}:5432 (session pooler); tenant=postgres.<ref>; tls=verify-full; sslrootcert=pinned CA"
OUT="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 \
  psql "$CONN" -X -q -A -t -v ON_ERROR_STOP=1 -v exp_writer="$EXP_W" -v exp_commission="$EXP_C" -v exp_normalize="$EXP_N" -f "$SQL" 2>/dev/null)" || { echo "RESULT: BLOCKED — approved production read-only query failed"; exit 4; }
[ "$(mval "$OUT" RO)" = "on" ] || fail "PRODUCTION read-only gate not on"
reconcile "$OUT"; emit_markers "$OUT"
if [ "$RECON_PASS" = 1 ]; then echo "RESULT: PASS — production matches the approved PORT-ENTRY-1 deployed surface"; exit 0; fi
echo "RESULT: FAIL — production does not match the approved PORT-ENTRY-1 surface (see CHECK FAIL lines)"; exit 1
