#!/usr/bin/env bash
# PORT-LAUNCH-2E — STRICTLY READ-ONLY post-reveal production verifier.
#
# Independently proves the live POST-REVEAL state (the three canonical starter ports are ACTIVE/public),
# both at the server-side catalog AND through the authenticated/public get_world_map() boundary. It NEVER
# writes, never calls reveal_starter_ports(), never changes a flag. Connection = the proven Supabase
# Management-API session-pooler + pinned CA + sslmode=verify-full, read-only snapshot, fail-closed.
#
# Modes:
#   selftest    DB-free static safety proof of THIS tooling (read-only SQL allowlist, no reveal call, no
#               write/DDL, ROLLBACK present, conn template, override rejection, CA pin).
#   local       Disposable $DB_URL: the verification matrix — happy post-reveal pass + every fail-closed case.
#   production  GATED, human-approved, READ-ONLY: resolve pooler -> run the snapshot -> reconcile OVERALL_PASS.
set -uo pipefail
set +x   # connection details / password must never be traced

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local|production) : ;; *) echo "usage: $0 <selftest|local|production>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL_FILE="$REPO_ROOT/scripts/postreveal-verify.sql"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"  # Supabase Root 2021 CA
P1='b1a00001-0066-4a00-8a00-000000000001'
P2='b1a00002-0066-4a00-8a00-000000000002'
P3='b1a00003-0066-4a00-8a00-000000000003'

# ── proven connection / trust helpers (identical to the read-only catalog verifier) ──────────────────────
is_hex64() { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{64}$'; }
validate_ref() { printf '%s' "${1:-}" | grep -qE '^[a-z0-9]{20}$' || fail "invalid/empty project ref"; }
OVERRIDE_VARS="DATABASE_URL PGHOST PGPORT PGUSER PGDATABASE PGHOSTADDR PGSERVICE PGURI PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY PGSSLCRL PGPASSWORD PGOPTIONS PSQLRC"
reject_target_overrides() { local v; for v in $OVERRIDE_VARS; do [ -z "${!v:-}" ] || fail "external target/trust override $v is set"; done; }
ca_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//; s/://g' | tr 'A-Z' 'a-z'; }
verify_ca() {
  local f="$1" n fp
  [ -f "$f" ] || fail "CA file not found"; [ -s "$f" ] || fail "CA file is empty"
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
mval() { printf '%s\n' "${1:-}" | grep -m1 -E "^$2=" | cut -d= -f2- ; }

# ── reconcile the post-reveal markers into a fail-closed OVERALL_PASS + the required output markers ───────
RECON_PASS=1
reconcile() {  # $1 = OUT
  local OUT="$1"; RECON_PASS=1
  ck() { if [ "${1:-}" != "$2" ]; then echo "  CHECK FAIL: $3 (got '${1:-}', want '$2')"; RECON_PASS=0; fi; }
  ck "$(mval "$OUT" RO)" on "read-only transaction active before any query"
  ck "$(mval "$OUT" HEAD)" 20260618000068 "migration head = 0068"
  ck "$(mval "$OUT" N_AFTER)" 0 "no migration after 0068"
  ck "$(mval "$OUT" CANON_EXIST)" 3 "exactly 3 canonical starter ports exist"
  ck "$(mval "$OUT" CANON_ACTIVE)" 3 "exactly 3 canonical starter ports active"
  ck "$(mval "$OUT" CANON_HIDDEN)" 0 "0 canonical starter ports hidden"
  ck "$(mval "$OUT" P1_OK)" 1 "Haven active + identity"
  ck "$(mval "$OUT" P2_OK)" 1 "Slagworks active + identity"
  ck "$(mval "$OUT" P3_OK)" 1 "Driftmarch active + identity"
  ck "$(mval "$OUT" N_ROLED)" 3 "exactly 3 role-bearing locations"
  ck "$(mval "$OUT" N_ROLED_UNEXP)" 0 "no unexpected role-bearing location"
  ck "$(mval "$OUT" ANCHOR_OK)" 1 "the 3 canonical anchors intact (active, none extra)"
  ck "$(mval "$OUT" SVC_OK)" 1 "the 3 canonical docking services intact (active)"
  ck "$(mval "$OUT" SVC_UNEXP)" 0 "no unexpected docking service"
  ck "$(mval "$OUT" FLAG_SEND)" 1 "mainship_send_enabled = true"
  ck "$(mval "$OUT" FLAG_SPACE)" 0 "mainship_space_movement_enabled = false"
  ck "$(mval "$OUT" MAP_CANON_VISIBLE)" 3 "3 canonical ports returned by get_world_map()"
  ck "$(mval "$OUT" MAP_UNEXPECTED_STARTER)" 0 "no unexpected starter-port id exposed in the map"
  ck "$(mval "$OUT" MAP_PORT_NAMES)" 3 "3 canonical port names present in the map"
  ck "$(mval "$OUT" MAP_INACTIVE_LEAK)" 0 "no inactive location exposed in the map"
}
emit_markers() {  # $1 = OUT  — the concise required markers
  local OUT="$1" head unexp
  head="$( [ "$(mval "$OUT" HEAD)" = "20260618000068" ] && echo 0068 || mval "$OUT" HEAD )"
  unexp=$(( $(mval "$OUT" N_ROLED_UNEXP) + $(mval "$OUT" SVC_UNEXP) + $(mval "$OUT" MAP_UNEXPECTED_STARTER) \
            + (3 - $(mval "$OUT" P1_OK) - $(mval "$OUT" P2_OK) - $(mval "$OUT" P3_OK)) \
            + (1 - $(mval "$OUT" ANCHOR_OK)) + (1 - $(mval "$OUT" SVC_OK)) ))
  echo "MIGRATION_HEAD=$head"
  echo "CANONICAL_PORTS_EXPECTED=3"
  echo "CANONICAL_PORTS_ACTIVE=$(mval "$OUT" CANON_ACTIVE)"
  echo "CANONICAL_PORTS_HIDDEN=$(mval "$OUT" CANON_HIDDEN)"
  echo "UNEXPECTED_PORT_STATE_CHANGES=$unexp"
  echo "AUTHENTICATED_MAP_PORTS_EXPECTED=3"
  echo "AUTHENTICATED_MAP_PORTS_VISIBLE=$(mval "$OUT" MAP_CANON_VISIBLE)"
  echo "MAINSHIP_SEND_ENABLED=$( [ "$(mval "$OUT" FLAG_SEND)" = 1 ] && echo true || echo false )"
  echo "MAINSHIP_SPACE_MOVEMENT_ENABLED=$( [ "$(mval "$OUT" FLAG_SPACE)" = 0 ] && echo false || echo true )"
  echo "OVERALL_PASS=$( [ "$RECON_PASS" = 1 ] && echo true || echo false )"
}

# ══════════════════════════════ SELFTEST (DB-free) ══════════════════════════════
if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL_FILE" ] || fail "SQL snapshot not found"
  CLEAN="$(sed -E 's/--.*//' "$SQL_FILE" | grep -vE '^[[:space:]]*\\')"
  # never invokes the reveal primitive
  printf '%s' "$CLEAN" | grep -qi 'reveal_starter_ports' && fail "verifier references reveal_starter_ports (forbidden)" || true
  # read-only allowlist: every ';'-terminated statement begins with an allowed keyword
  bad="$(printf '%s' "$CLEAN" | tr '\n' ' ' | tr ';' '\n' | sed -E 's/^[[:space:]]+//' | grep -vE '^[[:space:]]*$' \
        | grep -ivE '^(BEGIN TRANSACTION|SET LOCAL|SELECT|WITH|ROLLBACK)\b' | head -1 || true)"
  [ -z "$bad" ] || fail "disallowed SQL statement form: ${bad:0:70}"
  grep -q 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY' "$SQL_FILE" || fail "missing repeatable-read read-only BEGIN"
  grep -q 'SET LOCAL default_transaction_read_only = on' "$SQL_FILE" || fail "missing SET LOCAL read-only"
  grep -qE '^[[:space:]]*ROLLBACK;' "$SQL_FILE" || fail "missing ROLLBACK"
  printf '%s' "$CLEAN" | grep -iqE '\bCOMMIT\b' && fail "COMMIT present (must ROLLBACK only)" || true
  printf '%s' "$CLEAN" | sed "s/'[^']*'//g" | grep -iqE '\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|CALL|COPY|MERGE)\b' \
    && fail "write/DDL keyword present outside string literals" || true
  echo "[selftest] OK: read-only SQL (BEGIN/SET LOCAL/SELECT/WITH/ROLLBACK only); no write/DDL; ROLLBACK present; no reveal call"
  gate_ln="$(printf '%s\n' "$CLEAN" | grep -nm1 'transaction_read_only' | cut -d: -f1)"
  q_ln="$(printf '%s\n' "$CLEAN" | grep -nm1 -E 'FROM public\.|get_world_map|cfg_bool|schema_migrations' | cut -d: -f1)"
  [ -n "$gate_ln" ] && [ -n "$q_ln" ] && [ "$gate_ln" -lt "$q_ln" ] || fail "read-only gate not before first catalog query"
  echo "[selftest] OK: read-only gate precedes the first catalog query"
  # asserts the POST-reveal state (active), NOT the dark state (hidden)
  printf '%s' "$CLEAN" | grep -q "status='active'" || fail "verifier does not assert the active post-reveal state"
  printf '%s' "$CLEAN" | grep -q 'get_world_map' || fail "verifier does not test the authenticated map boundary"
  echo "[selftest] OK: verifier asserts the ACTIVE post-reveal state and tests the get_world_map boundary"
  c="$(build_verifier_conn aws-0-x.pooler.supabase.com aaaaaaaaaaaaaaaaaaaa "$CA_FILE")"
  printf '%s' "$c" | grep -q 'sslmode=verify-full' || fail "conn missing verify-full"
  printf '%s' "$c" | grep -q 'port=5432' || fail "conn not forced to session 5432"
  printf '%s' "$c" | grep -qE 'sslmode=(require|prefer|allow|disable)|port=6543|sslrootcert=system' && fail "conn uses weaker TLS/port/CA" || true
  echo "[selftest] OK: conn = verify-full + pinned CA + session 5432"
  require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa
  ( require_pooler_binding evil.example.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad host not rejected" || true
  for v in $OVERRIDE_VARS; do if ( export "$v=x"; reject_target_overrides ) >/dev/null 2>&1; then fail "$v override not rejected"; fi; done
  echo "[selftest] OK: pooler binding + target/trust override rejection fail-closed"
  verify_ca "$CA_FILE"
  echo "POSTREVEAL-VERIFY SELFTEST: ALL PASSED"
  exit 0
fi

# ══════════════════════════════ LOCAL (disposable verification matrix) ══════════════════════════════
if [ "$MODE" = "local" ]; then
  : "${DB_URL:?DB_URL (disposable stack) required}"
  q() { PGAPPNAME=mon psql "$DB_URL" -X -q -t -A -c "$1"; }
  run_sql() { PGAPPNAME=prv psql "$DB_URL" -X -q -A -t -v ON_ERROR_STOP=1 -f "$SQL_FILE"; }
  set_status() { q "update public.locations set status='$2' where id='$1';" >/dev/null; }
  set_active() { for p in "$P1" "$P2" "$P3"; do set_status "$p" active; done; }   # simulate post-reveal WITHOUT calling reveal_starter_ports()
  set_hidden() { for p in "$P1" "$P2" "$P3"; do set_status "$p" hidden; done; }
  pass_now() { local OUT; OUT="$(run_sql)"; reconcile "$OUT"; [ "$RECON_PASS" = 1 ]; }
  # mirror the LIVE flags on the disposable stack (send=true; OSN dark)
  q "update public.game_config set value='true'  where key='mainship_send_enabled';" >/dev/null
  q "update public.game_config set value='false' where key='mainship_space_movement_enabled';" >/dev/null

  # 1) EXPECTED POST-REVEAL ACTIVE STATE passes
  set_active
  OUT="$(run_sql)"; reconcile "$OUT"
  MK="$(emit_markers "$OUT")"; printf '%s\n' "$MK"   # print the required markers for the log
  [ "$RECON_PASS" = 1 ] || fail "happy post-reveal state did not pass reconcile"
  printf '%s\n' "$MK" | grep -qx 'OVERALL_PASS=true' || fail "happy path OVERALL_PASS!=true"
  [ "$(mval "$OUT" CANON_ACTIVE)" = "3" ] || fail "happy path canonical active != 3"
  [ "$(mval "$OUT" MAP_CANON_VISIBLE)" = "3" ] || fail "happy path map-visible != 3"
  echo "ok[1] expected post-reveal active state passes (OVERALL_PASS=true; 3 active; map shows 3; flags off)"

  # 2) A HIDDEN canonical port fails (CANON_HIDDEN / identity)
  set_active; set_status "$P1" hidden
  pass_now && fail "a hidden canonical port was accepted"
  echo "ok[2] hidden canonical port: fail-closed"

  # 3) WRONG ACTIVE-PORT COUNT fails (a different canonical hidden -> active count = 2)
  set_active; set_status "$P2" hidden
  pass_now && fail "wrong active-port count was accepted"
  echo "ok[3] wrong active-port count (2 active): fail-closed"

  # 4) FEATURE-FLAG CHANGE fails (and the other direction)
  set_active
  q "update public.game_config set value='true' where key='mainship_space_movement_enabled';" >/dev/null
  pass_now && fail "OSN flag on was accepted"
  q "update public.game_config set value='false' where key='mainship_space_movement_enabled';" >/dev/null
  q "update public.game_config set value='false' where key='mainship_send_enabled';" >/dev/null
  pass_now && fail "send flag off was accepted"
  q "update public.game_config set value='true' where key='mainship_send_enabled';" >/dev/null
  echo "ok[4] feature-flag change (space=true / send=false): fail-closed"

  # 5) AUTHENTICATED/PUBLIC MAP omission OR unexpected exposure fails
  #   5a omission: a canonical port hidden -> not returned by get_world_map -> MAP_CANON_VISIBLE<3
  set_active; set_status "$P3" hidden
  pass_now && fail "map omission (a canonical port missing from the map) was accepted"
  set_active
  #   5b unexpected exposure: an ACTIVE non-canonical location with a starter-port-family id appears in the map
  ZONE="$(q "select zone_id from public.locations where id='$P1';")"
  XID='b1a00009-0066-4a00-8a00-000000000009'
  q "insert into public.locations (id, zone_id, name, location_type, x, y, activity_type, status, physical_role)
     values ('$XID','$ZONE','Rogue Outpost','trade_outpost',5,5,'none','active','unclassified');" >/dev/null
  pass_now && fail "unexpected starter-family port exposed in the map was accepted"
  q "delete from public.locations where id='$XID';" >/dev/null
  echo "ok[5] authenticated/public map omission AND unexpected exposure: fail-closed"

  # restore the disposable stack
  set_hidden
  [ "$(q "select count(*) from public.locations where id in ('$P1','$P2','$P3') and status='hidden';")" = "3" ] || fail "cleanup: ports not all hidden"
  echo "POSTREVEAL-VERIFY LOCAL MATRIX: ALL PASSED"
  exit 0
fi

# ══════════════════════════════ PRODUCTION (gated, read-only — NOT run during PORT-LAUNCH-2E) ════════════
: "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}" "${SUPABASE_DB_PASSWORD:?}"
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
CONN="$(build_verifier_conn "$PHOST" "$REF" "$CA_FILE")"
echo "[diag] verifier=${PHOST}:5432 (session pooler); tenant=postgres.<ref>; tls=verify-full; sslrootcert=pinned CA"
OUT="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 \
  psql "$CONN" -X -q -A -t -v ON_ERROR_STOP=1 -f "$SQL_FILE" 2>/dev/null)" \
  || { echo "RESULT: BLOCKED — approved production read-only query failed"; exit 4; }
[ "$(mval "$OUT" RO)" = "on" ] || fail "PRODUCTION read-only gate did not report on"
echo "[production] read-only gate passed before any catalog query"
reconcile "$OUT"
emit_markers "$OUT"
if [ "$RECON_PASS" = 1 ]; then
  echo "RESULT: PASS — production matches the approved POST-REVEAL state (3 starter ports active/public; flags unchanged)"
  exit 0
fi
echo "RESULT: FAIL — production does not match the approved post-reveal state (see CHECK FAIL lines)"
exit 1
