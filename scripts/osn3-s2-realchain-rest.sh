#!/usr/bin/env bash
# OSN-3 S2 — LOCAL REST/RPC permission proof against the disposable local Supabase PostgREST/GoTrue.
# Proves the public Data-API boundary: each S2 helper RPC is REJECTED for the anon key and for a real
# disposable AUTHENTICATED user JWT. The service-role key is used ONLY to administer the throwaway user
# (create/delete) — NEVER as a client-boundary substitute. Requires API_URL, ANON_KEY, SERVICE_ROLE_KEY.
set -uo pipefail
: "${API_URL:?}" "${ANON_KEY:?}" "${SERVICE_ROLE_KEY:?}"

HELPERS="mainship_space_lock_context mainship_space_validate_context mainship_space_resolve_origin mainship_space_assert_cross_domain_exclusion"
BODY='{"p_main_ship_id":"00000000-0000-0000-0000-000000000000","p_skip_locked":false}'
EMAIL="osn3s2rest.$(date +%s).$RANDOM@example.com"
PASS="Test123456!"

jrole() { python3 -c "import sys,json,base64; p=sys.argv[1].split('.')[1]; p+='='*(-len(p)%4); print(json.loads(base64.urlsafe_b64decode(p)).get('role',''))" "$1" 2>/dev/null || true; }
jget()  { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || true; }

echo "=== mint a disposable AUTHENTICATED user JWT (service key used for admin only) ==="
curl -s -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"email_confirm\":true}" >/dev/null
ACCESS=$(curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jget access_token)
[ -n "$ACCESS" ] || { echo "FAIL: could not mint authenticated JWT"; exit 1; }
ROLE=$(jrole "$ACCESS")
echo "  minted JWT role claim = $ROLE"
[ "$ROLE" = "authenticated" ] || { echo "FAIL: token role != authenticated ($ROLE)"; exit 1; }

probe() { # $1=helper $2=bearer $3=label
  local code body
  code=$(curl -s -o /tmp/rb -w "%{http_code}" -X POST "$API_URL/rest/v1/rpc/$1" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $2" -H "Content-Type: application/json" -d "$BODY")
  body=$(head -c 300 /tmp/rb)
  if [ "$code" = "200" ] || [ "$code" = "204" ]; then echo "FAIL [$3] $1: REST executed it (HTTP $code): $body"; cleanup; exit 1; fi
  case "$body" in
    *'"status"'*|*'"ok"'*'true'*|*'origin_kind'*) echo "FAIL [$3] $1: body looks like a helper result: $body"; cleanup; exit 1;; esac
  echo "  ok [$3] $1: REJECTED (HTTP $code)"
}

cleanup() {
  local uid
  uid=$(curl -s "$API_URL/auth/v1/admin/users?per_page=200" -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
        | python3 -c "import sys,json
d=json.load(sys.stdin)
for u in (d.get('users') or d if isinstance(d,list) else d.get('users',[])):
    if isinstance(u,dict) and u.get('email')=='$EMAIL': print(u['id'])" 2>/dev/null || true)
  [ -n "${uid:-}" ] && curl -s -X DELETE "$API_URL/auth/v1/admin/users/$uid" -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" >/dev/null || true
}
trap cleanup EXIT

echo "=== anon-key RPC probes (must all be rejected) ==="
for h in $HELPERS; do probe "$h" "$ANON_KEY" "anon"; done
echo "=== authenticated-JWT RPC probes (must all be rejected) ==="
for h in $HELPERS; do probe "$h" "$ACCESS" "authenticated"; done

echo "OSN-3 S2 LOCAL REST/RPC PERMISSION PROOF: ALL PASSED"
