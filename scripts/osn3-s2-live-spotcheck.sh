#!/usr/bin/env bash
# OSN-3 S2 — READ-ONLY live spot check. Assumes `supabase link` already ran. Uses only read paths:
# migration list --linked, schema db dump --linked (DDL/ACL inspection), and REST table reads.
# NO fixtures, NO test users, NO mutation, NO client-role helper calls, NO flag change.
set -uo pipefail
: "${SUPABASE_DB_PASSWORD:?}" "${URL:?}" "${ANON:?}" "${SRV:?}"
fail() { echo "FAIL: $1"; exit 1; }

echo "=== 1) migration 0056 applied on live ==="
supabase migration list --linked --password "$SUPABASE_DB_PASSWORD" | tee /tmp/migs
awk -F'|' '/20260618000056/{r=$2; gsub(/ /,"",r); if (r=="20260618000056") print "REMOTE_OK"}' /tmp/migs | grep -q REMOTE_OK \
  && echo "ok: migration 0056 is applied on the live database" || fail "0056 not shown applied remotely"

echo "=== 2) schema dump → helper existence / SECURITY DEFINER / search_path / owner / live ACLs ==="
supabase db dump --linked --password "$SUPABASE_DB_PASSWORD" -f /tmp/live.sql
echo "[diag] dump lines=$(wc -l </tmp/live.sql); mainship_space occurrences=$(grep -c mainship_space_ /tmp/live.sql || true)"
FQ='(public\.|"public"\.)?"?'   # tolerant: optional public. qualification and optional quotes
for h in mainship_space_lock_context mainship_space_validate_context mainship_space_resolve_origin mainship_space_assert_cross_domain_exclusion; do
  blk=$(grep -iE -A10 "create (or replace )?function ${FQ}${h}\"?\(" /tmp/live.sql)
  if [ -z "$blk" ]; then echo "[diag] no CREATE FUNCTION match for $h; lines mentioning it:"; grep -iE "$h" /tmp/live.sql | head -6; fail "$h not present on live"; fi
  echo "$blk" | grep -qi "SECURITY DEFINER" || fail "$h not SECURITY DEFINER"
  echo "$blk" | grep -qiE "search_path" || fail "$h search_path not set"
  grep -qiE "ALTER FUNCTION ${FQ}${h}\"?\(.*OWNER TO postgres" /tmp/live.sql || fail "$h owner != postgres"
  grep -qiE "REVOKE ALL ON FUNCTION ${FQ}${h}\"?\(.*FROM PUBLIC" /tmp/live.sql || fail "$h not revoked from PUBLIC"
  grep -qiE "GRANT ALL ON FUNCTION ${FQ}${h}\"?\(.*TO service_role" /tmp/live.sql || fail "$h not granted to service_role"
  if grep -qiE "GRANT.*ON FUNCTION ${FQ}${h}\"?\(.*TO anon" /tmp/live.sql; then fail "$h granted to anon"; fi
  if grep -qiE "GRANT.*ON FUNCTION ${FQ}${h}\"?\(.*TO authenticated" /tmp/live.sql; then fail "$h granted to authenticated"; fi
  echo "ok: $h — present, SECURITY DEFINER, search_path set, owner=postgres, PUBLIC revoked, service_role only, anon/authenticated NOT granted"
done
# canonical client RPC sanity (not lost) + anon get_world_map
grep -qiE "GRANT ALL ON FUNCTION ${FQ}send_main_ship_expedition\"?\(.*TO authenticated" /tmp/live.sql || fail "send_main_ship_expedition lost authenticated grant"
grep -qiE "GRANT ALL ON FUNCTION ${FQ}get_world_map\"?\(\) TO anon" /tmp/live.sql || fail "get_world_map lost anon grant"
if grep -niE "GRANT.*mainship_space_.*TO (anon|authenticated)" /tmp/live.sql; then fail "an S2 helper is client-granted on live"; fi
echo "ok: no S2 helper is client-exposed (no anon/authenticated grant); canonical client RPCs intact"
if grep -qE "REVOKE (ALL|CREATE) ON SCHEMA public FROM PUBLIC;" /tmp/live.sql; then
  echo "ok: public-schema CREATE revoked from PUBLIC (dump-evidenced)"
else
  echo "note: no explicit public-schema CREATE grant to PUBLIC/anon/authenticated in dump (PG15+ default: no PUBLIC CREATE on public)"
fi

echo "=== 3) REST read-only: flags false + zero coordinate-movement rows ==="
flags=$(curl -s "$URL/rest/v1/game_config?key=in.(mainship_send_enabled,mainship_space_movement_enabled)&select=key,value" -H "apikey: $ANON" -H "Authorization: Bearer $ANON")
echo "flags: $flags"
echo "$flags" | grep -qiE 'mainship_send_enabled"?,?"?:?,?"?value"?:?false|mainship_send_enabled.*false' || fail "mainship_send_enabled not false"
echo "$flags" | grep -qiE 'mainship_space_movement_enabled.*false' || fail "mainship_space_movement_enabled not false"
echo "ok: both flags false on live"
cr=$(curl -s -I "$URL/rest/v1/main_ship_space_movements?select=id" -H "apikey: $SRV" -H "Authorization: Bearer $SRV" -H "Prefer: count=exact" -H "Range: 0-0" | tr -d '\r' | grep -i '^content-range:' | awk -F/ '{print $NF}')
echo "main_ship_space_movements count = ${cr:-?}"
[ "${cr:-x}" = "0" ] || fail "main_ship_space_movements row count != 0 (got ${cr:-?})"
echo "ok: main_ship_space_movements row count = 0 on live"

echo "OSN-3 S2 LIVE SPOT CHECK (READ-ONLY): ALL PASSED"
