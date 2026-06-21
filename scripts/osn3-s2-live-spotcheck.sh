#!/usr/bin/env bash
# OSN-3 S2 — READ-ONLY live spot check. Assumes `supabase link` already ran. Uses only read paths:
#   1) migration list --linked            (0056 applied remotely)
#   2) supabase db dump --linked           (corroborate helper presence / SECURITY DEFINER / search_path;
#                                           the dump is --no-owner and lossy for privileges, so it is NOT
#                                           used for owner/ACL — see step 3)
#   3) direct psql catalog query via pooler (AUTHORITATIVE owner/ACL/flags/row-count — pure SELECTs)
#   4) REST table reads                    (corroborate flags false + zero coordinate-movement rows)
# NO fixtures, NO test users, NO mutation, NO client-role helper calls, NO flag change.
set -uo pipefail
: "${SUPABASE_DB_PASSWORD:?}" "${URL:?}" "${ANON:?}" "${SRV:?}" "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}"
REF="$SUPABASE_PROJECT_ID"
fail() { echo "FAIL: $1"; exit 1; }

echo "=== 1) migration 0056 applied on live ==="
supabase migration list --linked --password "$SUPABASE_DB_PASSWORD" | tee /tmp/migs
awk -F'|' '/20260618000056/{r=$2; gsub(/ /,"",r); if (r=="20260618000056") print "REMOTE_OK"}' /tmp/migs | grep -q REMOTE_OK \
  && echo "ok: migration 0056 is applied on the live database" || fail "0056 not shown applied remotely"

echo "=== 2) schema dump → corroborate helper presence / SECURITY DEFINER / search_path (dump is --no-owner, lossy for ACL) ==="
supabase db dump --linked --password "$SUPABASE_DB_PASSWORD" -f /tmp/live.sql
echo "[diag] dump lines=$(wc -l </tmp/live.sql); mainship_space occurrences=$(grep -c mainship_space_ /tmp/live.sql || true)"
FQ='(public\.|"public"\.)?"?'
for h in mainship_space_lock_context mainship_space_validate_context mainship_space_resolve_origin mainship_space_assert_cross_domain_exclusion; do
  blk=$(grep -iE -A10 "create (or replace )?function ${FQ}${h}\"?\(" /tmp/live.sql)
  [ -n "$blk" ] || fail "$h not present in live dump"
  echo "$blk" | grep -qi "SECURITY DEFINER" || fail "$h not SECURITY DEFINER in live dump"
  echo "$blk" | grep -qiE "search_path" || fail "$h search_path not set in live dump"
  echo "ok (dump): $h — present, SECURITY DEFINER, search_path set"
done

echo "=== 3) AUTHORITATIVE direct catalog query via pooler (owner / ACL / flags / row-count) ==="
command -v psql >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client >/dev/null; }

# Discover a reachable connection. Prefer the Management API pooler config; fall back to region-derived
# pooler hosts; last resort the direct host. We never print the password.
POOLER=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" "https://api.supabase.com/v1/projects/$REF/config/database/pooler" || true)
PHOST=$(echo "$POOLER" | jq -r 'if type=="array" then .[0].db_host else .db_host end // empty' 2>/dev/null || true)
PPORT=$(echo "$POOLER" | jq -r 'if type=="array" then (.[0].db_port|tostring) else (.db_port|tostring) end // empty' 2>/dev/null || true)
PUSER=$(echo "$POOLER" | jq -r 'if type=="array" then .[0].db_user else .db_user end // empty' 2>/dev/null || true)
REGION=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" "https://api.supabase.com/v1/projects" \
         | jq -r --arg ref "$REF" '.[] | select(.id==$ref) | .region' 2>/dev/null || true)
echo "[diag] pooler_host=${PHOST:-<none>} pooler_port=${PPORT:-<none>} pooler_user=${PUSER:-<none>} region=${REGION:-<none>}"

# Build candidate (host|port|user) list, most-specific first.
CANDS=()
[ -n "${PHOST:-}" ] && CANDS+=("$PHOST|${PPORT:-6543}|${PUSER:-postgres.$REF}")
if [ -n "${REGION:-}" ]; then
  for pre in aws-0 aws-1; do for prt in 6543 5432; do
    CANDS+=("$pre-$REGION.pooler.supabase.com|$prt|postgres.$REF")
  done; done
fi
CANDS+=("db.$REF.supabase.co|5432|postgres")

CONN=""
for c in "${CANDS[@]}"; do
  IFS='|' read -r H P U <<<"$c"
  echo "[diag] trying $H:$P user=$U"
  if PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=12 psql \
       "host=$H port=$P user=$U dbname=postgres sslmode=require" -X -t -A -c "select 1" >/dev/null 2>/tmp/cerr; then
    CONN="host=$H port=$P user=$U dbname=postgres sslmode=require"; echo "[diag] connected via $H:$P"; break
  else
    echo "[diag] connect failed ($H:$P): $(tr -d '\n' </tmp/cerr | tail -c 200)"
  fi
done
[ -n "$CONN" ] || fail "could not establish a read-only connection to live for catalog inspection"

PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 psql "$CONN" -X -v ON_ERROR_STOP=1 -f scripts/osn3-s2-live-inspect.sql \
  || fail "live catalog inspection failed (see assertions above)"
echo "ok: authoritative live catalog inspection passed"

echo "=== 4) REST read-only corroboration: flags false + zero coordinate-movement rows ==="
flags=$(curl -s "$URL/rest/v1/game_config?key=in.(mainship_send_enabled,mainship_space_movement_enabled)&select=key,value" -H "apikey: $ANON" -H "Authorization: Bearer $ANON")
echo "flags: $flags"
echo "$flags" | grep -qiE 'mainship_send_enabled.*false' || fail "mainship_send_enabled not false (REST)"
echo "$flags" | grep -qiE 'mainship_space_movement_enabled.*false' || fail "mainship_space_movement_enabled not false (REST)"
echo "ok: both flags false on live (REST corroboration)"
cr=$(curl -s -I "$URL/rest/v1/main_ship_space_movements?select=id" -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H "Prefer: count=exact" -H "Range: 0-0" | tr -d '\r' | grep -i '^content-range:' | awk -F/ '{print $NF}')
echo "main_ship_space_movements count = ${cr:-?}"
[ "${cr:-x}" = "0" ] || fail "main_ship_space_movements row count != 0 (got ${cr:-?})"
echo "ok: main_ship_space_movements row count = 0 on live (REST corroboration)"

echo "OSN-3 S2 LIVE SPOT CHECK (READ-ONLY): ALL PASSED"
