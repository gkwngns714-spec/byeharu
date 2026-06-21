#!/usr/bin/env bash
# OSN-3 S6A — LOCAL REST/RPC permission proof against the disposable local Supabase PostgREST/GoTrue.
# Proves the public Data-API boundary:
#   • the PRIVATE writer mainship_space_begin_move (and, defence-in-depth, the S4 processor, S5 destruction
#     primitive, and four S2 helpers) are REJECTED for the anon key AND for a real authenticated user JWT —
#     a normal client can never reach the writer directly;
#   • the PUBLIC wrapper command_main_ship_space_move is REJECTED for anon, but is REACHABLE for the
#     authenticated user and, with mainship_space_movement_enabled=false (production-shaped), returns a
#     clean {ok:false, code:"feature_disabled"} — NOT a real movement (dark by flag at the boundary too).
# The service-role key administers the throwaway user only (create/delete). Requires API_URL, ANON_KEY,
# SERVICE_ROLE_KEY. (The flag is left false by the fixtures step that runs before this.)
set -uo pipefail
: "${API_URL:?}" "${ANON_KEY:?}" "${SERVICE_ROLE_KEY:?}"

WRAPPER="command_main_ship_space_move"
WRITER="mainship_space_begin_move"
PROC="process_mainship_space_arrivals"
DESTROY="dev_set_main_ship_destroyed"
HELPERS="mainship_space_lock_context mainship_space_validate_context mainship_space_resolve_origin mainship_space_assert_cross_domain_exclusion"
CBODY='{"p_target_x":10,"p_target_y":10,"p_request_id":"00000000-0000-0000-0000-000000000002"}'
WBODY='{"p_player":"00000000-0000-0000-0000-000000000000","p_main_ship_id":"00000000-0000-0000-0000-000000000000","p_target_x":1,"p_target_y":1,"p_request_id":"00000000-0000-0000-0000-000000000001"}'
DBODY='{"p_player":"00000000-0000-0000-0000-000000000000"}'
EMPTY='{}'
HBODY='{"p_main_ship_id":"00000000-0000-0000-0000-000000000000","p_skip_locked":false}'
EMAIL="osn3s6rest.$(date +%s).$RANDOM@example.com"
PASS="Test123456!"

jrole() { python3 -c "import sys,json,base64; p=sys.argv[1].split('.')[1]; p+='='*(-len(p)%4); print(json.loads(base64.urlsafe_b64decode(p)).get('role',''))" "$1" 2>/dev/null || true; }
jget()  { python3 -c "import sys,json; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || true; }

echo "=== mint a disposable AUTHENTICATED user JWT (service key for admin only) ==="
curl -s -X POST "$API_URL/auth/v1/admin/users" -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"email_confirm\":true}" >/dev/null
ACCESS=$(curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | jget access_token)
[ -n "$ACCESS" ] || { echo "FAIL: could not mint authenticated JWT"; exit 1; }
ROLE=$(jrole "$ACCESS"); echo "  minted JWT role claim = $ROLE"
[ "$ROLE" = "authenticated" ] || { echo "FAIL: token role != authenticated ($ROLE)"; exit 1; }

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

reject() { # $1=fn $2=bearer $3=label $4=body  — must be rejected (non-2xx, not a real result)
  local code body
  code=$(curl -s -o /tmp/rb -w "%{http_code}" -X POST "$API_URL/rest/v1/rpc/$1" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $2" -H "Content-Type: application/json" -d "$4")
  body=$(head -c 300 /tmp/rb)
  if [ "$code" = "200" ] || [ "$code" = "204" ]; then echo "FAIL [$3] $1: REST executed it (HTTP $code): $body"; exit 1; fi
  case "$body" in
    *movement_id*|*'"ok"'*'true'*|*origin_kind*|*fleets_cleaned*) echo "FAIL [$3] $1: body looks like a real result: $body"; exit 1;; esac
  echo "  ok [$3] $1: REJECTED (HTTP $code)"
}

echo "=== anon-key probes (ALL rejected — incl. the public wrapper) ==="
reject "$WRAPPER" "$ANON_KEY" "anon" "$CBODY"
reject "$WRITER" "$ANON_KEY" "anon" "$WBODY"
reject "$PROC" "$ANON_KEY" "anon" "$EMPTY"
reject "$DESTROY" "$ANON_KEY" "anon" "$DBODY"
for h in $HELPERS; do reject "$h" "$ANON_KEY" "anon" "$HBODY"; done

echo "=== authenticated-JWT probes: PRIVATE engine rejected ==="
reject "$WRITER" "$ACCESS" "authenticated" "$WBODY"
reject "$PROC" "$ACCESS" "authenticated" "$EMPTY"
reject "$DESTROY" "$ACCESS" "authenticated" "$DBODY"
for h in $HELPERS; do reject "$h" "$ACCESS" "authenticated" "$HBODY"; done

echo "=== authenticated-JWT probe: PUBLIC wrapper reachable but DARK (feature_disabled, no movement) ==="
code=$(curl -s -o /tmp/cb -w "%{http_code}" -X POST "$API_URL/rest/v1/rpc/$WRAPPER" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ACCESS" -H "Content-Type: application/json" -d "$CBODY")
body=$(head -c 300 /tmp/cb)
[ "$code" = "200" ] || { echo "FAIL: authenticated wrapper call not HTTP 200 (got $code): $body"; exit 1; }
case "$body" in *movement_id*|*'"ok"'*'true'*) echo "FAIL: wrapper produced a real movement while dark: $body"; exit 1;; esac
echo "$body" | grep -q 'feature_disabled' || { echo "FAIL: wrapper did not return feature_disabled while dark: $body"; exit 1; }
echo "  ok [authenticated] $WRAPPER: reachable, returned feature_disabled, no movement (HTTP $code)"

echo "OSN-3 S6A LOCAL REST/RPC PERMISSION PROOF: ALL PASSED"
