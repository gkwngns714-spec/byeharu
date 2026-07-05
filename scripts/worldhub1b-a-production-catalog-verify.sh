#!/usr/bin/env bash
# WORLD-HUB-1B-A — STRICTLY READ-ONLY production catalog verification of migration 0066.
#
# Confirms the already-deployed dark catalog matches the approved migration EXACTLY: three fixed-ID hidden
# starter ports + aligned active anchors + active docking services; the six-part eligibility predicate /
# privileged writer / validity trigger present; the ports invisible, ineligible, and player-state-free; the
# original five locations untouched; flags unchanged. Emits ONLY compact PASS/FAIL booleans and counts —
# never UUIDs of players, emails, hosts, ports, URIs, secrets, raw rows, or table dumps.
#
# Connection: reuses the established trusted pattern — committed pinned Supabase Root 2021 CA
# (scripts/supabase-prod-ca.crt, fingerprint-pinned), IPv4 session-pooler host from the protected Management
# API (keyed by SUPABASE_PROJECT_ID), ref-bound tenant postgres.<ref>, FORCED session pooler port 5432,
# sslmode=verify-full sslrootcert=<pinned CA>. All reads run inside ONE
# BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY snapshot; ROLLBACK on every path; never COMMIT.
# Both the token-bearing curl and psql run under a whitelisted `env -i` (no inherited proxy/trust/PG*/PSQL*).
#
# HARD READ-ONLY: never writes, never runs db push / migration apply / DDL / DML / fixtures / cleanup, never
# invokes assign_home_port or any write-capable function, never uses a direct DB host, never prints secrets
# or connection strings. is_home_port_eligible / cfg_bool / get_world_map are read-only (STABLE) reads.
#
# Modes:
#   selftest    — DB-FREE static safety proof of THIS script. Returns BEFORE any secret/API/curl/psql.
#   production  — the gated, read-only verification. Run ONLY inside the protected `production` Environment.
set -euo pipefail

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|production) : ;; *) echo "usage: $0 <selftest|production>" >&2; exit 2;; esac

# ── Repo root WITHOUT a git dependency (selftest must not need git) ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"  # Supabase Root 2021 CA
MIG_FILE="$REPO_ROOT/supabase/migrations/20260618000066_worldhub1b_a_hidden_ports_eligibility.sql"
MIG148_FILE="$REPO_ROOT/supabase/migrations/20260618000148_location_names_single_word.sql"
EXPECT_MIG="20260618000066"

# ── Expected fixed catalog values. BOUND to the catalog migrations: assert_migration() (below) fails closed
#    unless every literal appears verbatim in the checked-out migration that owns it, so this verifier can
#    never drift from the catalog it checks. (Derived-from-migration requirement.) Identity/structure
#    literals are owned by 0066; the DISPLAY NAMES were renamed 2026-07-05 by forward-only migration 0148
#    (UX cleanup item 4 — one-word names; UUIDs unchanged), so the name literals bind to 0148. ────────────
P1_ID="b1a00001-0066-4a00-8a00-000000000001"; P1_NAME="Haven";      P1_ROLE="city"; P1_SEC="Outer Haven";   P1_SIDX=1; P1_ZONE="Wreck Belt";      P1_X="-50"; P1_Y="-30"; A1_ID="b1a0a001-0066-4a00-8a00-0000000000a1"; S1_ID="b1a05001-0066-4a00-8a00-000000000051"
P2_ID="b1a00002-0066-4a00-8a00-000000000002"; P2_NAME="Slagworks";  P2_ROLE="port"; P2_SEC="Crimson Nebula"; P2_SIDX=2; P2_ZONE="Ion Storm Route"; P2_X="70";  P2_Y="-10"; A2_ID="b1a0a002-0066-4a00-8a00-0000000000a2"; S2_ID="b1a05002-0066-4a00-8a00-000000000052"
P3_ID="b1a00003-0066-4a00-8a00-000000000003"; P3_NAME="Driftmarch"; P3_ROLE="port"; P3_SEC="Crimson Nebula"; P3_SIDX=2; P3_ZONE="Ion Storm Route"; P3_X="10";  P3_Y="80";  A3_ID="b1a0a003-0066-4a00-8a00-0000000000a3"; S3_ID="b1a05003-0066-4a00-8a00-000000000053"

# ── Fail-closed validators / connection helpers (logic identical to the established ANCHOR spotchecks) ────
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
  fp="$(ca_fingerprint "$f")"; [ "$fp" = "$EXPECTED_CA_SHA256" ] || fail "CA fingerprint mismatch (pinned $EXPECTED_CA_SHA256, got $fp)"
  echo "[ca] SHA-256 fingerprint = $fp"
}
# Parse EXACTLY ONE pooler endpoint {db_host, db_port} from a Management API response; else fail closed.
parse_pooler_endpoint() {
  local body="$1" host port
  host="$(printf '%s' "$body" | jq -er 'if type=="array" then (if length==1 then .[0] else error("multi") end) else . end | .db_host' 2>/dev/null)" || return 1
  port="$(printf '%s' "$body" | jq -er 'if type=="array" then .[0] else . end | .db_port' 2>/dev/null)" || return 1
  printf '%s %s' "$host" "$port"
}
require_pooler_binding() {  # $1=host $2=port $3=user $4=ref
  printf '%s' "${1:-}" | grep -qE '\.pooler\.supabase\.com$' || fail "pooler host not *.pooler.supabase.com"
  case "${2:-}" in 5432|6543) : ;; *) fail "pooler port not in {5432,6543}";; esac
  [ "${3:-}" = "postgres.${4:-}" ] || fail "tenant must be postgres.<ref>"
}
build_verifier_conn() { printf 'host=%s port=5432 user=postgres.%s dbname=postgres sslmode=verify-full sslrootcert=%s' "$1" "$2" "$3"; }
mval() { printf '%s\n' "$1" | grep -E "^$2=" | head -1 | cut -d= -f2-; }

# ── Migration binding: every expected literal MUST be present verbatim in the checked-out migration that
#    owns it — identity/structure in 0066, the 0148-renamed display names in 0148. ────────────────────────
assert_migration() {
  [ -f "$MIG_FILE" ] || fail "migration 0066 not found in checkout"
  [ -f "$MIG148_FILE" ] || fail "migration 0148 not found in checkout"
  local lit
  for lit in "$P1_ID" "$P2_ID" "$P3_ID" \
             "$A1_ID" "$A2_ID" "$A3_ID" "$S1_ID" "$S2_ID" "$S3_ID" \
             "is_home_port_eligible" "assign_home_port" "player_home_port_eligibility"; do
    grep -qF "$lit" "$MIG_FILE" || fail "expected literal not present in migration 0066: $lit"
  done
  for lit in "'$P1_NAME'" "'$P2_NAME'" "'$P3_NAME'"; do
    grep -qF "$lit" "$MIG148_FILE" || fail "expected name literal not present in migration 0148: $lit"
  done
}

# ── Single read-only snapshot: emits KEY=value lines only; ROLLBACK on the controlled path; no \quit. ─────
verify_sql() {
cat <<SQL
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT 'HEAD='||coalesce(max(version),'none') FROM supabase_migrations.schema_migrations;
SELECT 'N_AFTER='||count(*) FROM supabase_migrations.schema_migrations WHERE version > '${EXPECT_MIG}';
SELECT 'P1_OK='||(EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='${P1_ID}' AND l.name='${P1_NAME}' AND l.physical_role='${P1_ROLE}' AND l.status='hidden' AND l.activity_type='none' AND l.x=${P1_X} AND l.y=${P1_Y} AND z.name='${P1_ZONE}' AND z.status='active' AND s.name='${P1_SEC}' AND s.sector_index=${P1_SIDX} AND s.status='active'))::int;
SELECT 'P2_OK='||(EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='${P2_ID}' AND l.name='${P2_NAME}' AND l.physical_role='${P2_ROLE}' AND l.status='hidden' AND l.activity_type='none' AND l.x=${P2_X} AND l.y=${P2_Y} AND z.name='${P2_ZONE}' AND z.status='active' AND s.name='${P2_SEC}' AND s.sector_index=${P2_SIDX} AND s.status='active'))::int;
SELECT 'P3_OK='||(EXISTS(SELECT 1 FROM public.locations l JOIN public.zones z ON z.id=l.zone_id JOIN public.sectors s ON s.id=z.sector_id WHERE l.id='${P3_ID}' AND l.name='${P3_NAME}' AND l.physical_role='${P3_ROLE}' AND l.status='hidden' AND l.activity_type='none' AND l.x=${P3_X} AND l.y=${P3_Y} AND z.name='${P3_ZONE}' AND z.status='active' AND s.name='${P3_SEC}' AND s.sector_index=${P3_SIDX} AND s.status='active'))::int;
SELECT 'N_ROLED='||count(*) FROM public.locations WHERE physical_role<>'unclassified';
SELECT 'N_ROLED_UNEXP='||count(*) FROM public.locations WHERE physical_role<>'unclassified' AND id NOT IN ('${P1_ID}','${P2_ID}','${P3_ID}');
SELECT 'A1_OK='||((EXISTS(SELECT 1 FROM public.space_anchors WHERE id='${A1_ID}' AND location_id='${P1_ID}' AND kind='location' AND status='active' AND space_x=${P1_X} AND space_y=${P1_Y})) AND (SELECT count(*) FROM public.space_anchors WHERE location_id='${P1_ID}' AND kind='location' AND status='active')=1)::int;
SELECT 'A2_OK='||((EXISTS(SELECT 1 FROM public.space_anchors WHERE id='${A2_ID}' AND location_id='${P2_ID}' AND kind='location' AND status='active' AND space_x=${P2_X} AND space_y=${P2_Y})) AND (SELECT count(*) FROM public.space_anchors WHERE location_id='${P2_ID}' AND kind='location' AND status='active')=1)::int;
SELECT 'A3_OK='||((EXISTS(SELECT 1 FROM public.space_anchors WHERE id='${A3_ID}' AND location_id='${P3_ID}' AND kind='location' AND status='active' AND space_x=${P3_X} AND space_y=${P3_Y})) AND (SELECT count(*) FROM public.space_anchors WHERE location_id='${P3_ID}' AND kind='location' AND status='active')=1)::int;
SELECT 'N_ANCHOR_UNEXP='||count(*) FROM public.space_anchors WHERE kind='location' AND status='active' AND id NOT IN ('${A1_ID}','${A2_ID}','${A3_ID}');
SELECT 'S1_OK='||((EXISTS(SELECT 1 FROM public.location_services WHERE id='${S1_ID}' AND location_id='${P1_ID}' AND service='docking' AND status='active')) AND (SELECT count(*) FROM public.location_services WHERE location_id='${P1_ID}' AND service='docking' AND status='active')=1)::int;
SELECT 'S2_OK='||((EXISTS(SELECT 1 FROM public.location_services WHERE id='${S2_ID}' AND location_id='${P2_ID}' AND service='docking' AND status='active')) AND (SELECT count(*) FROM public.location_services WHERE location_id='${P2_ID}' AND service='docking' AND status='active')=1)::int;
SELECT 'S3_OK='||((EXISTS(SELECT 1 FROM public.location_services WHERE id='${S3_ID}' AND location_id='${P3_ID}' AND service='docking' AND status='active')) AND (SELECT count(*) FROM public.location_services WHERE location_id='${P3_ID}' AND service='docking' AND status='active')=1)::int;
SELECT 'N_SVC_UNEXP='||count(*) FROM public.location_services WHERE id NOT IN ('${S1_ID}','${S2_ID}','${S3_ID}');
SELECT 'N_ORIG='||count(*) FROM public.locations WHERE name IN ('Refuge','Lull','Snare','Reaver','Blackden') AND physical_role='unclassified' AND status='active';
SELECT 'MAP_LEAK='||(public.get_world_map()::text ~ '"name" *: *"(Haven|Slagworks|Driftmarch)"')::int;
SELECT 'MAP_LEAK_ID='||(public.get_world_map()::text ~ 'b1a0000[123]-0066')::int;
SELECT 'ELIG1='||public.is_home_port_eligible('${P1_ID}')::int;
SELECT 'ELIG2='||public.is_home_port_eligible('${P2_ID}')::int;
SELECT 'ELIG3='||public.is_home_port_eligible('${P3_ID}')::int;
SELECT 'N_HOMEPORT='||count(*) FROM public.player_home_port;
SELECT 'FLAG_SPACE='||public.cfg_bool('mainship_space_movement_enabled')::int;
SELECT 'FLAG_SEND='||public.cfg_bool('mainship_send_enabled')::int;
SELECT 'PHP_W='||(has_table_privilege('authenticated','public.player_home_port','INSERT') OR has_table_privilege('authenticated','public.player_home_port','UPDATE') OR has_table_privilege('authenticated','public.player_home_port','DELETE') OR has_table_privilege('anon','public.player_home_port','INSERT'))::int;
SELECT 'SVC_READ='||(has_table_privilege('authenticated','public.location_services','SELECT') OR has_table_privilege('anon','public.location_services','SELECT'))::int;
SELECT 'ASSIGN_X='||(has_function_privilege('authenticated','public.assign_home_port(uuid,uuid)','EXECUTE') OR has_function_privilege('anon','public.assign_home_port(uuid,uuid)','EXECUTE'))::int;
SELECT 'ELIG_FN='||(to_regprocedure('public.is_home_port_eligible(uuid)') IS NOT NULL)::int;
SELECT 'ASSIGN_FN='||(to_regprocedure('public.assign_home_port(uuid,uuid)') IS NOT NULL)::int;
SELECT 'TRG='||(EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace nsp ON nsp.oid=c.relnamespace WHERE nsp.nspname='public' AND c.relname='player_home_port' AND t.tgname='player_home_port_eligibility' AND NOT t.tgisinternal))::int;
ROLLBACK;
SQL
}

# ── SELFTEST (DB-free; returns before any secret/API/curl/psql) ──────────────────────────────────────────
if [ "$MODE" = "selftest" ]; then
  assert_migration
  echo "[selftest] OK: every expected fixed literal is present verbatim in migration 0066"
  sql="$(verify_sql)"
  # SQL allowlist: every non-empty, non-comment statement begins BEGIN TRANSACTION / SELECT / WITH / ROLLBACK.
  printf '%s\n' "$sql" | grep -vE '^\s*$' | while IFS= read -r st; do
    printf '%s' "$st" | grep -iqE '^(BEGIN TRANSACTION|SELECT|WITH|ROLLBACK)\b' || fail "disallowed SQL statement form: ${st:0:48}"
  done
  echo "[selftest] OK: SQL allowlist (BEGIN TRANSACTION/SELECT/WITH/ROLLBACK only)"
  printf '%s' "$sql" | grep -q 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY' || fail "missing repeatable-read read-only BEGIN"
  printf '%s' "$sql" | grep -q 'ROLLBACK;' || fail "missing ROLLBACK"
  # No write/DDL keyword anywhere in the SQL OUTSIDE quoted string literals (privilege names like 'INSERT'
  # and catalog references like to_regprocedure('public.assign_home_port(...)') are read-only and live inside
  # single quotes — strip those first, then scan). Defense in depth; assign_home_port is never invoked.
  printf '%s' "$sql" | sed "s/'[^']*'//g" \
    | grep -iqE '\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|COMMIT|CALL|COPY|MERGE|assign_home_port)\b' \
    && fail "write/DDL keyword present in read-only SQL (outside string literals)"
  echo "[selftest] OK: no write/DDL keyword outside literals; assign_home_port only referenced in catalog reads; ROLLBACK present"
  # And assign_home_port must appear ONLY inside quoted literals (catalog refs), never as a bare call.
  printf '%s' "$sql" | sed "s/'[^']*'//g" | grep -q 'assign_home_port' && fail "assign_home_port referenced outside a quoted literal"
  c="$(build_verifier_conn aws-0-x.pooler.supabase.com aaaaaaaaaaaaaaaaaaaa "$CA_FILE")"
  printf '%s' "$c" | grep -q 'sslmode=verify-full' || fail "conn missing verify-full"
  printf '%s' "$c" | grep -q 'port=5432' || fail "conn not forced to session pooler 5432"
  printf '%s' "$c" | grep -q "sslrootcert=$CA_FILE" || fail "conn missing pinned CA"
  echo "[selftest] OK: verifier conn = verify-full + pinned CA + session 5432"
  require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa
  ( require_pooler_binding evil.example.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "non-pooler host not rejected" || true
  ( require_pooler_binding aws-0-x.pooler.supabase.com 9999 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad port not rejected" || true
  echo "[selftest] OK: pooler binding fail-closed"
  for v in $OVERRIDE_VARS; do if ( export "$v=x"; reject_target_overrides ) >/dev/null 2>&1; then fail "$v override not rejected"; fi; done
  echo "[selftest] OK: target/trust override vars rejected ($OVERRIDE_VARS)"
  verify_ca "$CA_FILE"
  echo "WORLD-HUB-1B-A PRODUCTION VERIFY SELFTEST: ALL PASSED"
  exit 0
fi

# ── PRODUCTION (gated, read-only verification) ───────────────────────────────────────────────────────────
: "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}" "${SUPABASE_DB_PASSWORD:?}"
REF="$SUPABASE_PROJECT_ID"; validate_ref "$REF"
reject_target_overrides
assert_migration
for t in curl jq psql openssl; do command -v "$t" >/dev/null 2>&1 || { echo "RESULT: BLOCKED — required read-only tooling missing ($t)"; exit 5; }; done
verify_ca "$CA_FILE"

# Management API (token-bearing) under whitelisted env so inherited proxy/trust cannot redirect it.
POOLER="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
  --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/${REF}/config/database/pooler" 2>/dev/null)" \
  || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
read -r PHOST PPORT <<EOF
$(parse_pooler_endpoint "$POOLER" || true)
EOF
[ -n "${PHOST:-}" ] || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
require_pooler_binding "$PHOST" "${PPORT:-5432}" "postgres.$REF" "$REF"
CONN="$(build_verifier_conn "$PHOST" "$REF" "$CA_FILE")"
echo "connected through approved production session pooler"

OUT="$(verify_sql | env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 \
  psql "$CONN" -X -q -A -t -v ON_ERROR_STOP=1 2>"${RUNNER_TEMP:-/tmp}/psqlerr")" \
  || { echo "RESULT: BLOCKED — approved production read-only query failed"; exit 4; }

# ── Reconcile each assertion (fail closed BEFORE the verdict) ────────────────────────────────────────────
HEAD="$(mval "$OUT" HEAD)"; NAFTER="$(mval "$OUT" N_AFTER)"
P1="$(mval "$OUT" P1_OK)"; P2="$(mval "$OUT" P2_OK)"; P3="$(mval "$OUT" P3_OK)"
NROLED="$(mval "$OUT" N_ROLED)"; NRUX="$(mval "$OUT" N_ROLED_UNEXP)"
A1="$(mval "$OUT" A1_OK)"; A2="$(mval "$OUT" A2_OK)"; A3="$(mval "$OUT" A3_OK)"; NAUX="$(mval "$OUT" N_ANCHOR_UNEXP)"
S1="$(mval "$OUT" S1_OK)"; S2="$(mval "$OUT" S2_OK)"; S3="$(mval "$OUT" S3_OK)"; NSUX="$(mval "$OUT" N_SVC_UNEXP)"
NORIG="$(mval "$OUT" N_ORIG)"
MLEAK="$(mval "$OUT" MAP_LEAK)"; MLEAKID="$(mval "$OUT" MAP_LEAK_ID)"
E1="$(mval "$OUT" ELIG1)"; E2="$(mval "$OUT" ELIG2)"; E3="$(mval "$OUT" ELIG3)"
NHP="$(mval "$OUT" N_HOMEPORT)"
FSPACE="$(mval "$OUT" FLAG_SPACE)"; FSEND="$(mval "$OUT" FLAG_SEND)"
PHPW="$(mval "$OUT" PHP_W)"; SVCR="$(mval "$OUT" SVC_READ)"; ASX="$(mval "$OUT" ASSIGN_X)"
EFN="$(mval "$OUT" ELIG_FN)"; AFN="$(mval "$OUT" ASSIGN_FN)"; TRG="$(mval "$OUT" TRG)"

PASS=1; rows=""
chk() { local name="$1" ok="$2" detail="$3"; if [ "$ok" = "1" ]; then rows="${rows}| ${name} | PASS | ${detail} |\n"; else rows="${rows}| ${name} | **FAIL** | ${detail} |\n"; PASS=0; fi; }
b() { [ "$1" = "$2" ] && echo 1 || echo 0; }

chk "1 migration head 0066"        "$([ "$HEAD" = "$EXPECT_MIG" ] && [ "$NAFTER" = "0" ] && echo 1 || echo 0)" "head=${HEAD}, after=${NAFTER}"
chk "2 three exact hidden ports"   "$([ "$P1" = "1" ] && [ "$P2" = "1" ] && [ "$P3" = "1" ] && [ "$NROLED" = "3" ] && [ "$NRUX" = "0" ] && echo 1 || echo 0)" "P1/P2/P3=${P1}${P2}${P3}, roled=${NROLED}, unexpected=${NRUX}"
chk "3 parents active+linked"      "$([ "$P1" = "1" ] && [ "$P2" = "1" ] && [ "$P3" = "1" ] && echo 1 || echo 0)" "verified within each port row"
chk "4 one aligned anchor/port"    "$([ "$A1" = "1" ] && [ "$A2" = "1" ] && [ "$A3" = "1" ] && [ "$NAUX" = "0" ] && echo 1 || echo 0)" "A1/A2/A3=${A1}${A2}${A3}, unexpected=${NAUX}"
chk "5 one docking service/port"   "$([ "$S1" = "1" ] && [ "$S2" = "1" ] && [ "$S3" = "1" ] && [ "$NSUX" = "0" ] && echo 1 || echo 0)" "S1/S2/S3=${S1}${S2}${S3}, unexpected=${NSUX}"
chk "6 original five unchanged"    "$(b "$NORIG" 5)" "intact=${NORIG}/5"
chk "7 hidden from get_world_map"  "$([ "$MLEAK" = "0" ] && [ "$MLEAKID" = "0" ] && echo 1 || echo 0)" "name_leak=${MLEAK}, id_leak=${MLEAKID}"
chk "8 ports ineligible"           "$([ "$E1" = "0" ] && [ "$E2" = "0" ] && [ "$E3" = "0" ] && echo 1 || echo 0)" "elig=${E1}${E2}${E3}"
chk "9 player_home_port empty"     "$(b "$NHP" 0)" "rows=${NHP}"
chk "10 flags unchanged"           "$([ "$FSPACE" = "0" ] && [ "$FSEND" = "1" ] && echo 1 || echo 0)" "space=${FSPACE}, send=${FSEND}"
chk "11 catalog/RLS shape"         "$([ "$PHPW" = "0" ] && [ "$SVCR" = "0" ] && [ "$ASX" = "0" ] && [ "$EFN" = "1" ] && [ "$AFN" = "1" ] && [ "$TRG" = "1" ] && echo 1 || echo 0)" "php_write=${PHPW}, svc_read=${SVCR}, assign_exec=${ASX}, elig_fn=${EFN}, assign_fn=${AFN}, trigger=${TRG}"

VERDICT="$([ "$PASS" = "1" ] && echo 'PASS' || echo 'FAIL')"
{
  echo "## WORLD-HUB-1B-A — production catalog verification"
  echo ""
  echo "- commit: \`${GITHUB_SHA:-unknown}\`"
  echo "- run id: \`${GITHUB_RUN_ID:-local}\`"
  echo "- expected migration head: \`${EXPECT_MIG}\`"
  echo ""
  echo "| # assertion | result | detail |"
  echo "| --- | --- | --- |"
  printf "%b" "$rows"
  echo ""
  echo "**OVERALL: ${VERDICT}**"
} | tee "${VERIFY_SUMMARY_FILE:-/dev/stdout}" | { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && tee -a "$GITHUB_STEP_SUMMARY" >/dev/null || cat >/dev/null; }

if [ "$PASS" = "1" ]; then
  echo "RESULT: PASS — WORLD-HUB-1B-A production catalog matches the approved migration 0066"
  exit 0
else
  echo "RESULT: FAIL — WORLD-HUB-1B-A production catalog mismatch (see summary)"
  exit 1
fi
