#!/usr/bin/env bash
# OSN ANCHOR-2 P0-A — STRICTLY READ-ONLY production home-base backfill ambiguity census (count-only).
#
# Decides whether the future per-ship home_base_id backfill (link a ship to its owner's base IFF the owner
# has exactly one active base) is safe, by emitting ONLY aggregate counts. No player UUIDs, emails, auth
# metadata, base/ship ids, hosts, ports, URIs, secrets, raw rows, or raw status values ever reach logs.
#
# Connection: reuses the established trusted pattern — committed pinned Supabase Root 2021 CA
# (scripts/supabase-prod-ca.crt, fingerprint-pinned), IPv4 pooler host from the protected Management API
# (keyed by SUPABASE_PROJECT_ID), ref-bound tenant postgres.<ref>, FORCED session pooler port 5432,
# sslmode=verify-full sslrootcert=<pinned CA>. One BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY
# snapshot covers the schema/data gate AND the census. ROLLBACK on every controlled path; never COMMIT.
# Both the token-bearing curl and psql run under a whitelisted `env -i` (no inherited proxy/trust/PG*/PSQL*).
#
# Modes:
#   selftest    — DB-FREE static safety proof of THIS script. Returns BEFORE any secret/API/curl/psql.
#   production  — the gated, read-only census. Run ONLY inside the protected `production` Environment.
set -euo pipefail

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|production) : ;; *) echo "usage: $0 <selftest|production>" >&2; exit 2;; esac

# ── Repo root WITHOUT a git dependency (selftest must not need git) ──────────────────────────────────────
REPO_ROOT="${GITHUB_WORKSPACE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"  # Supabase Root 2021 CA

# ── Fail-closed validators / connection helpers (logic identical to the ANCHOR-1A spotcheck) ────────────
is_hex64() { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{64}$'; }
validate_ref() { printf '%s' "${1:-}" | grep -qE '^[a-z0-9]{20}$' || fail "invalid/empty project ref"; }
# Connection/control overrides rejected (defense-in-depth) BEFORE connect. env -i (below) is the real boundary.
OVERRIDE_VARS="DATABASE_URL PGHOST PGPORT PGUSER PGDATABASE PGHOSTADDR PGSERVICE PGURI PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY PGSSLCRL PGPASSWORD PGOPTIONS PSQLRC"
reject_target_overrides() { local v; for v in $OVERRIDE_VARS; do [ -z "${!v:-}" ] || fail "external target/trust override $v is set"; done; }
ca_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//; s/://g' | tr 'A-Z' 'a-z'; }
verify_ca() {
  local f="$1" n fp
  [ -f "$f" ] || fail "CA file not found"
  [ -s "$f" ] || fail "CA file is empty"
  n="$(grep -c 'BEGIN CERTIFICATE' "$f" || true)"; [ "$n" = "1" ] || fail "CA must contain exactly one certificate"
  openssl x509 -in "$f" -noout >/dev/null 2>&1 || fail "CA is not a valid PEM certificate"
  openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1 || fail "CA certificate is expired"
  fp="$(ca_fingerprint "$f")"; is_hex64 "$fp" || fail "CA fingerprint not 64 hex"
  [ "$fp" = "$EXPECTED_CA_SHA256" ] || fail "CA fingerprint mismatch"
  echo "pinned CA verified"                                    # generic — no fingerprint/subject/body
}
parse_pooler_endpoint() {
  printf '%s' "${1:-}" | jq -er '
    ( if type=="array" then (if length==1 then .[0] else error("array length not 1") end)
      elif type=="object" then . else error("unexpected type") end ) as $e
    | ($e.db_host // error("missing db_host")) as $h
    | ($e.db_port // error("missing db_port")) as $p
    | (if ($h|type)=="string" and ($h|length)>0 then . else error("empty db_host") end)
    | "\($h)|\($p)"
  ' 2>/dev/null
}
require_pooler_binding() {
  local h="${1:-}" pt="${2:-}" u="${3:-}" r="${4:-}"
  validate_ref "$r"
  [ -n "$h" ] || fail "pooler host not resolved"
  printf '%s' "$h" | grep -qE '^[a-z0-9][a-z0-9.-]*\.pooler\.supabase\.com$' || fail "host is not <label>.pooler.supabase.com"
  case "$pt" in 5432|6543) : ;; *) fail "pooler port not in {5432,6543}";; esac
  [ "$u" = "postgres.${r}" ] || fail "pooler tenant user not bound to the protected project ref"
}
build_verifier_conn() { printf 'host=%s port=5432 user=postgres.%s dbname=postgres sslmode=verify-full sslrootcert=%s' "$1" "$2" "$3"; }

# ── Single-snapshot census SQL: schema+data gate then count-only census; ROLLBACK on every path; no \quit. ─
census_sql() {
  cat <<'SQL'
\set ON_ERROR_STOP on
\pset pager off
\pset tuples_only on
\pset format unaligned
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT (current_setting('transaction_read_only') = 'on')
   AND (current_setting('transaction_isolation') = 'repeatable read')
   AND (to_regclass('public.main_ship_instances') IS NOT NULL)
   AND (to_regclass('public.bases') IS NOT NULL)
   AND (to_regclass('auth.users') IS NOT NULL)
   AND  EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='main_ship_instances' AND column_name='player_id')
   AND  EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='bases' AND column_name='id')
   AND  EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='bases' AND column_name='player_id')
   AND  EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='bases' AND column_name='status' AND data_type='text' AND is_nullable='NO')
   AND (NOT EXISTS(SELECT 1 FROM public.bases WHERE status IS NULL OR status NOT IN ('active','destroyed')))
   AND (NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='main_ship_instances' AND column_name='home_base_id'))
  AS ok \gset
\if :ok
WITH s AS (
  SELECT m.player_id,
         (m.player_id IS NOT NULL)                                AS has_owner,
         EXISTS(SELECT 1 FROM auth.users u WHERE u.id = m.player_id) AS auth_ok,
         (SELECT count(*) FROM public.bases b WHERE b.player_id = m.player_id)                         AS total_bases,
         (SELECT count(*) FROM public.bases b WHERE b.player_id = m.player_id AND b.status = 'active')  AS active_bases
  FROM public.main_ship_instances m
),
sc AS (
  SELECT *, CASE
    WHEN NOT has_owner    THEN 'null_owner'
    WHEN NOT auth_ok      THEN 'no_auth'
    WHEN total_bases = 0  THEN 'no_base'
    WHEN active_bases = 0 THEN 'bases_0_active'
    WHEN active_bases = 1 THEN 'one_active'
    ELSE                       'gt1_active'
  END AS klass FROM s
),
vo AS (SELECT player_id, max(active_bases) AS ab FROM sc WHERE has_owner AND auth_ok GROUP BY player_id),
oo AS (SELECT DISTINCT player_id FROM sc WHERE has_owner AND NOT auth_ok)
SELECT 'TOTAL_SHIPS=' || (SELECT count(*) FROM sc)
  || ' DISTINCT_NON_NULL_SHIP_OWNER_IDS=' || (SELECT count(DISTINCT player_id) FROM sc WHERE has_owner)
  || ' ORPHAN_SHIP_OWNER_IDS=' || (SELECT count(*) FROM oo)
  || ' VALID_OWNERS_0_ACTIVE=' || (SELECT count(*) FROM vo WHERE ab = 0)
  || ' VALID_OWNERS_1_ACTIVE=' || (SELECT count(*) FROM vo WHERE ab = 1)
  || ' VALID_OWNERS_GT1_ACTIVE=' || (SELECT count(*) FROM vo WHERE ab > 1)
  || ' OWNERS_BASES_BUT_0_ACTIVE=' || (SELECT count(*) FROM vo v WHERE v.ab = 0 AND EXISTS(SELECT 1 FROM public.bases b WHERE b.player_id = v.player_id))
  || ' SHIPS_NULL_OWNER=' || (SELECT count(*) FROM sc WHERE klass = 'null_owner')
  || ' SHIPS_WITHOUT_AUTH_USER=' || (SELECT count(*) FROM sc WHERE klass = 'no_auth')
  || ' SHIPS_OWNER_NO_BASE=' || (SELECT count(*) FROM sc WHERE klass = 'no_base')
  || ' SHIPS_OWNER_BASES_BUT_0_ACTIVE=' || (SELECT count(*) FROM sc WHERE klass = 'bases_0_active')
  || ' SHIPS_1_ACTIVE=' || (SELECT count(*) FROM sc WHERE klass = 'one_active')
  || ' SHIPS_GT1_ACTIVE=' || (SELECT count(*) FROM sc WHERE klass = 'gt1_active')
  || ' MAX_ACTIVE_BASES_VALID_OWNER=' || (SELECT coalesce(max(ab), 0) FROM vo)
  || ' ELIGIBLE=' || (SELECT count(*) FROM sc WHERE klass = 'one_active')
  || ' UNRESOLVED=' || (SELECT count(*) FROM sc WHERE klass <> 'one_active')
  AS census;
ROLLBACK;
\else
\echo 'CENSUS_BLOCKED_ASSUMPTION'
ROLLBACK;
\endif
SQL
}

mval() { printf '%s' "${1:-}" | tr ' ' '\n' | grep -E "^$2=" | head -1 | cut -d= -f2; }

# ── SELFTEST (DB-free; returns before any secret/API/curl/psql) ──────────────────────────────────────────
if [ "$MODE" = "selftest" ]; then
  sql="$(census_sql)"
  # (5) Allowlist psql meta-commands.
  while IFS= read -r ln; do
    case "$ln" in
      \\*) cmd="$(printf '%s' "$ln" | sed -E 's/^\\([a-zA-Z]+).*/\1/')"
           case "$cmd" in set|pset|gset|if|else|endif|echo) : ;; *) fail "disallowed psql meta-command: \\$cmd";; esac ;;
    esac
  done <<< "$sql"
  # (5) Allowlist SQL statement forms (strip meta + comment lines, split on ';').
  stmts="$(printf '%s\n' "$sql" | sed -E 's/^\\.*$//; s/^--.*$//' | tr '\n' ' ' | tr ';' '\n')"
  while IFS= read -r st; do
    st="$(printf '%s' "$st" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$st" ] || continue
    printf '%s' "$st" | grep -iqE '^(BEGIN TRANSACTION|SELECT|WITH|ROLLBACK)\b' || fail "disallowed SQL statement form: ${st:0:40}"
  done <<< "$stmts"
  echo "[selftest] OK: SQL allowlist (BEGIN TRANSACTION/SELECT/WITH/ROLLBACK + \\set/\\pset/\\gset/\\if/\\else/\\endif/\\echo)"
  # Secondary forbidden-token defense.
  if printf '%s' "$sql" | grep -iqE '\b(commit|insert|update|delete|create|alter|drop|grant|revoke|truncate|merge|do|copy)\b'; then fail "forbidden token in SQL"; fi
  if printf '%s' "$sql" | grep -iq 'for update'; then fail "FOR UPDATE present"; fi
  printf '%s' "$sql" | grep -q 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY' || fail "missing repeatable-read read-only BEGIN"
  printf '%s' "$sql" | grep -q "current_setting('transaction_isolation') = 'repeatable read'" || fail "missing isolation assertion"
  printf '%s' "$sql" | grep -q "status NOT IN ('active','destroyed')" || fail "missing status-domain data gate"
  [ "$(printf '%s' "$sql" | grep -c 'ROLLBACK')" -ge 2 ] || fail "ROLLBACK must appear on both controlled paths"
  if printf '%s' "$sql" | grep -q '\\quit'; then fail "\\quit must not be used (ROLLBACK must run first)"; fi
  if printf '%s' "$sql" | grep -iqE '\b(email|encrypted_password|auth\.users\.email|main_ship_id)\b'; then fail "identifier/PII/unused field in SQL"; fi
  echo "[selftest] OK: single repeatable-read snapshot; status-domain data gate; rollback both paths; no \\quit; count-only"
  # Connection template.
  c="$(build_verifier_conn aws-0-x.pooler.supabase.com aaaaaaaaaaaaaaaaaaaa "$CA_FILE")"
  printf '%s' "$c" | grep -q 'sslmode=verify-full' || fail "conn missing verify-full"
  printf '%s' "$c" | grep -q 'port=5432' || fail "conn not session port 5432"
  printf '%s' "$c" | grep -qF "sslrootcert=$CA_FILE" || fail "conn missing pinned CA path"
  if printf '%s' "$c" | grep -qE 'port=6543|sslmode=(require|prefer|allow|disable)|sslrootcert=system'; then fail "conn uses 6543/weaker TLS/system trust"; fi
  echo "[selftest] OK: verifier conn = verify-full + pinned CA + session 5432"
  if ( require_pooler_binding "evil.example.com" "5432" "postgres.aaaaaaaaaaaaaaaaaaaa" "aaaaaaaaaaaaaaaaaaaa" ) >/dev/null 2>&1; then fail "bad host not rejected"; fi
  if ( require_pooler_binding "aws-0-x.pooler.supabase.com" "9999" "postgres.aaaaaaaaaaaaaaaaaaaa" "aaaaaaaaaaaaaaaaaaaa" ) >/dev/null 2>&1; then fail "bad port not rejected"; fi
  if ( require_pooler_binding "aws-0-x.pooler.supabase.com" "5432" "postgres.WRONG" "aaaaaaaaaaaaaaaaaaaa" ) >/dev/null 2>&1; then fail "unbound tenant not rejected"; fi
  require_pooler_binding "aws-0-x.pooler.supabase.com" "5432" "postgres.aaaaaaaaaaaaaaaaaaaa" "aaaaaaaaaaaaaaaaaaaa" || fail "valid binding rejected"
  echo "[selftest] OK: pooler binding fail-closed"
  case " $OVERRIDE_VARS " in *" PGOPTIONS "*) : ;; *) fail "PGOPTIONS missing from override list";; esac
  case " $OVERRIDE_VARS " in *" PSQLRC "*) : ;; *) fail "PSQLRC missing from override list";; esac
  for v in $OVERRIDE_VARS; do if ( export "$v=x"; reject_target_overrides ) >/dev/null 2>&1; then fail "$v override not rejected"; fi; done
  echo "[selftest] OK: target/trust override vars rejected ($OVERRIDE_VARS)"
  verify_ca "$CA_FILE"
  echo "OSN-ANCHOR-2 P0-A CENSUS SELFTEST: ALL PASSED"
  exit 0
fi

# ── PRODUCTION (gated, read-only census) ────────────────────────────────────────────────────────────────
: "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}" "${SUPABASE_DB_PASSWORD:?}"
: "${RUNNER_TEMP:?}"
REF="$SUPABASE_PROJECT_ID"
reject_target_overrides
validate_ref "$REF"
# Fail closed if required read-only tooling is absent (no runtime package installation).
for t in curl jq psql openssl; do command -v "$t" >/dev/null 2>&1 || { echo "RESULT: BLOCKED — required read-only tooling missing"; exit 5; }; done
verify_ca "$CA_FILE"

# Management API (token-bearing): whitelisted env so inherited proxy/trust cannot redirect it; stderr private.
POOLER="$(env -i PATH="$PATH" HOME="$RUNNER_TEMP" \
  curl --fail --silent --proto '=https' --max-redirs 0 --connect-timeout 10 --max-time 30 \
       -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
       "https://api.supabase.com/v1/projects/${REF}/config/database/pooler" 2>/dev/null)" \
  || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
ENDPOINT="$(parse_pooler_endpoint "$POOLER")" || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
PHOST="${ENDPOINT%%|*}"; API_PORT="${ENDPOINT##*|}"; PUSER="postgres.${REF}"
require_pooler_binding "$PHOST" "$API_PORT" "$PUSER" "$REF"
CONN="$(build_verifier_conn "$PHOST" "$REF" "$CA_FILE")"
echo "connected through approved production session pooler"

# Census (whitelisted env; stderr private; generic blocked on failure).
OUT="$(census_sql | env -i PATH="$PATH" HOME="$RUNNER_TEMP" PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 \
  psql "$CONN" -X -q -A -t -v ON_ERROR_STOP=1 2>"$RUNNER_TEMP/psqlerr")" \
  || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
if printf '%s\n' "$OUT" | grep -q 'CENSUS_BLOCKED_ASSUMPTION'; then
  echo "RESULT: BLOCKED — read-only/repeatable-read/schema/data assumption unmet"; exit 3
fi
LINE="$(printf '%s\n' "$OUT" | grep -E 'TOTAL_SHIPS=' | head -1 || true)"
[ -n "$LINE" ] || { echo "RESULT: BLOCKED — no census row returned"; exit 3; }
echo "[census] $LINE"

# ── Reconciliation (fail closed BEFORE any percentage/verdict) ───────────────────────────────────────────
LABELS="TOTAL_SHIPS DISTINCT_NON_NULL_SHIP_OWNER_IDS ORPHAN_SHIP_OWNER_IDS VALID_OWNERS_0_ACTIVE VALID_OWNERS_1_ACTIVE VALID_OWNERS_GT1_ACTIVE OWNERS_BASES_BUT_0_ACTIVE SHIPS_NULL_OWNER SHIPS_WITHOUT_AUTH_USER SHIPS_OWNER_NO_BASE SHIPS_OWNER_BASES_BUT_0_ACTIVE SHIPS_1_ACTIVE SHIPS_GT1_ACTIVE MAX_ACTIVE_BASES_VALID_OWNER ELIGIBLE UNRESOLVED"
for L in $LABELS; do
  v="$(mval "$LINE" "$L")"
  [ "$(printf '%s' "$LINE" | grep -oE "(^| )$L=" | wc -l | tr -d ' ')" = "1" ] || { echo "RESULT: BLOCKED — label $L not present exactly once"; exit 3; }
  printf '%s' "$v" | grep -qE '^[0-9]+$' || { echo "RESULT: BLOCKED — label $L not a non-negative integer"; exit 3; }
  eval "N_$L=$v"
done
ck() { [ "$1" -eq "$2" ] || { echo "RESULT: BLOCKED — census arithmetic did not reconcile ($3)"; exit 3; }; }
ck "$N_TOTAL_SHIPS" "$(( N_ELIGIBLE + N_UNRESOLVED ))" "total=eligible+unresolved"
ck "$N_UNRESOLVED" "$(( N_SHIPS_NULL_OWNER + N_SHIPS_WITHOUT_AUTH_USER + N_SHIPS_OWNER_NO_BASE + N_SHIPS_OWNER_BASES_BUT_0_ACTIVE + N_SHIPS_GT1_ACTIVE ))" "unresolved breakdown"
ck "$N_ELIGIBLE" "$N_SHIPS_1_ACTIVE" "eligible=ships_1_active"
ck "$N_DISTINCT_NON_NULL_SHIP_OWNER_IDS" "$(( N_ORPHAN_SHIP_OWNER_IDS + N_VALID_OWNERS_0_ACTIVE + N_VALID_OWNERS_1_ACTIVE + N_VALID_OWNERS_GT1_ACTIVE ))" "owner breakdown"
[ "$N_OWNERS_BASES_BUT_0_ACTIVE" -le "$N_VALID_OWNERS_0_ACTIVE" ] || { echo "RESULT: BLOCKED — owners-bases-but-0-active exceeds valid-owners-0-active"; exit 3; }
# Current live invariant: exactly one ship per owner, no null owners.
if [ "$N_TOTAL_SHIPS" -ne "$N_DISTINCT_NON_NULL_SHIP_OWNER_IDS" ]; then
  echo "RESULT: BACKFILL BLOCKED BY DATA ANOMALY"; echo "INVARIANT_ONE_SHIP_PER_OWNER=ANOMALY"; exit 3
fi

if [ "$N_TOTAL_SHIPS" = "0" ]; then PE="0.0"; PU="0.0"; else
  PE="$(awk -v e="$N_ELIGIBLE" -v t="$N_TOTAL_SHIPS" 'BEGIN{printf "%.1f",(e*100.0)/t}')"
  PU="$(awk -v u="$N_UNRESOLVED" -v t="$N_TOTAL_SHIPS" 'BEGIN{printf "%.1f",(u*100.0)/t}')"
fi
echo "[census] ELIGIBLE_PCT=${PE}% UNRESOLVED_PCT=${PU}%"
if [ "$N_UNRESOLVED" = "0" ]; then
  echo "RESULT: BACKFILL SAFE FOR ALL CURRENT MAIN SHIPS"
else
  echo "RESULT: BACKFILL SAFE FOR DETERMINISTIC SUBSET ONLY (eligible=$N_ELIGIBLE, unresolved=$N_UNRESOLVED)"
fi
echo "OSN-ANCHOR-2 P0-A PRODUCTION CENSUS: COMPLETE (read-only)"
