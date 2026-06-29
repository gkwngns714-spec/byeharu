#!/usr/bin/env bash
# OSN-COORD-ENABLE-1B — disposable proof for the additive coordinate-travel capability on the OSN readiness
# read-model (migration 0071: get_osn_movement_readiness().coordinate_travel_available). It NEVER touches
# production; it boots a throwaway local chain and exercises the REAL authenticated boundary
# (get_osn_movement_readiness via role=authenticated + auth.uid()). Modes: selftest (DB-free) / local.
#
# It writes only disposable fixtures (a docked test user, a home test user) and resets them; it issues NO
# movement command, performs NO production access, and changes NO production flag. The new field is a UX
# capability hint; the security boundary remains the unchanged server gate in command_main_ship_space_move.
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local) : ;; *) echo "usage: $0 <selftest|local>" >&2; exit 2;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIG="$REPO_ROOT/supabase/migrations/20260618000071_osn_coord_readiness_capability.sql"
# canonical 0066 starter ports (P1 = Haven Reach city; P2/P3 ports)
P1='b1a00001-0066-4a00-8a00-000000000001'
P2='b1a00002-0066-4a00-8a00-000000000002'
P3='b1a00003-0066-4a00-8a00-000000000003'

# ══════════════════════════════ SELFTEST (DB-free) ══════════════════════════════
if [ "$MODE" = "selftest" ]; then
  [ -f "$MIG" ] || fail "migration 0071 not found"
  # additive field present in the readiness result
  grep -q "'coordinate_travel_available'" "$MIG" || fail "migration does not add coordinate_travel_available"
  # derivation is the strict refinement of osn_available, NOT a loose two-flag formula
  grep -q "v_coord := (v_avail and coalesce(public.cfg_bool('mainship_coordinate_travel_enabled'), false))" "$MIG" \
    || fail "coordinate_travel_available is not derived as (osn_available AND coordinate gate)"
  # existing fields preserved on the main return
  for f in "'origin_category'" "'osn_available'" "'reason'" "'eligible_destination_ids'"; do
    grep -q "$f" "$MIG" || fail "migration drops existing readiness field $f"
  done
  # SECURITY DEFINER + authenticated-only ACL re-assert
  grep -q "security definer" "$MIG" || fail "function is not SECURITY DEFINER"
  grep -q "revoke execute on function public.get_osn_movement_readiness() from public, anon" "$MIG" || fail "ACL not re-asserted (public/anon revoke)"
  grep -q "grant  *execute on function public.get_osn_movement_readiness() to authenticated" "$MIG" || fail "authenticated execute not granted"
  # MUST NOT touch the command surfaces / other systems / any flag value. Check comment-stripped SQL (the
  # header legitimately NAMES the untouched functions).
  CLEAN="$(sed -E 's/--.*//' "$MIG")"
  printf '%s' "$CLEAN" | grep -qE "create or replace function public.command_main_ship_space_move" && fail "migration alters a coordinate/location command" || true
  printf '%s' "$CLEAN" | grep -qiE "insert into|update public|delete from|truncate" && fail "migration performs a write (DML)" || true
  printf '%s' "$CLEAN" | grep -qiE "mainship_coordinate_travel_enabled', '|mainship_space_movement_enabled', '|mainship_send_enabled', '" && fail "migration sets a feature flag value" || true
  # the proof harness itself cleans up
  grep -q "delete from auth.users where email like 'cr\." "$0" || fail "proof lacks disposable-user cleanup"
  echo "OSN-COORD-READINESS SELFTEST: ALL PASSED (additive field; strict osn_available∧coord-gate derivation; existing fields + SECURITY DEFINER + authenticated-only ACL preserved; no command change, no write, no flag set; cleanup present)"
  exit 0
fi

# ══════════════════════════════ LOCAL (disposable matrix) ══════════════════════════════
: "${DB_URL:?DB_URL (disposable stack) required}"
su()  { psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "$1"; }                       # privileged setup/assert
flag(){ su "update public.game_config set value='$2'::jsonb where key='$1';" >/dev/null; }
# authrpc <user-uuid> <jsonb-expr> → run as ROLE authenticated with auth.uid()=<user>; echo JSON text.
authrpc(){ psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c \
  "begin; do \$\$ begin perform set_config('request.jwt.claims', json_build_object('sub','$1','role','authenticated')::text, true); end \$\$; set local role authenticated; select ($2)::text; reset role; commit;"; }
fld(){ printf '%s' "$1" | jq -r ".$2"; }            # extract a field from a readiness JSON
ftype(){ printf '%s' "$1" | jq -r ".$2 | type"; }   # extract a field's JSON type

mkuser(){ # <slug> → echo new auth.users uuid
  su "insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','cr.$1.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','');" >/dev/null
  su "select id from auth.users where email like 'cr.$1.%@example.com' order by created_at desc limit 1;"; }

echo "── setup: activate the 3 canonical ports (direct status update; reveal_starter_ports() NOT called) ──"
for p in "$P1" "$P2" "$P3"; do su "update public.locations set status='active' where id='$p';" >/dev/null; done
[ "$(su "select count(*) from public.locations where id in ('$P1','$P2','$P3') and status='active';")" = "3" ] || fail "setup: 3 canonical ports not active"

echo "── setup: U1 = ship ANCHORED (at_location) at Haven Reach; U2 = ship HOME (unanchored) ──"
U1="$(mkuser anchored)"; [ -n "$U1" ] || fail "U1 not created"
su "do \$\$ declare u uuid:='$U1'; s uuid:=gen_random_uuid(); f uuid:=gen_random_uuid(); b uuid; z uuid; sec uuid;
begin
  select id into b from public.bases where player_id=u and status='active' order by created_at limit 1;
  select zone_id into z from public.locations where id='$P1'; select sector_id into sec from public.zones where id=z;
  insert into public.main_ship_instances(player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values(u,'starter_frigate','stationary','at_location',500,500,50,10,2,3,s);
  insert into public.fleets(id,player_id,origin_base_id,status,location_mode,main_ship_id,current_location_id,current_zone_id,current_sector_id)
    values(f,u,b,'present','location',s,'$P1',z,sec);
  insert into public.location_presence(player_id,fleet_id,location_id,zone_id,sector_id,activity_type,status)
    values(u,f,'$P1',z,sec,'none','active');
end \$\$;" >/dev/null
S1="$(su "select main_ship_id from public.main_ship_instances where player_id='$U1' limit 1;")"; [ -n "$S1" ] || fail "U1 ship not anchored"

U2="$(mkuser home)"; [ -n "$U2" ] || fail "U2 not created"
su "insert into public.main_ship_instances(player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values('$U2','starter_frigate','home','home',500,500,50,10,2,3,gen_random_uuid());" >/dev/null
echo "   U1=$U1 (anchored @ $P1)   U2=$U2 (home/unanchored)"

# ── The required 4-case truth table (base OSN readiness × coordinate flag) on the ANCHORED ship U1 ──────────
# osn_available is toggled via the movement flag (anchored origin held constant); coordinate flag toggled too.
# row 1: osn_available=false, coord=false → false
flag mainship_space_movement_enabled false; flag mainship_coordinate_travel_enabled false
R="$(authrpc "$U1" "public.get_osn_movement_readiness()")"
[ "$(fld "$R" osn_available)" = "false" ] && [ "$(fld "$R" coordinate_travel_available)" = "false" ] || { echo "$R"; fail "ok[1] osn=false,coord=false expected coord_avail=false"; }
echo "ok[1] osn_available=false, coord_gate=false → coordinate_travel_available=false"
# row 2: osn_available=false, coord=true → false (flags-true must NOT bypass a non-actionable osn_available)
flag mainship_coordinate_travel_enabled true
R="$(authrpc "$U1" "public.get_osn_movement_readiness()")"
[ "$(fld "$R" osn_available)" = "false" ] && [ "$(fld "$R" coordinate_travel_available)" = "false" ] || { echo "$R"; fail "ok[2] osn=false,coord=true expected coord_avail=false"; }
echo "ok[2] osn_available=false, coord_gate=true → coordinate_travel_available=false"
# row 3: osn_available=true, coord=false → false
flag mainship_space_movement_enabled true; flag mainship_coordinate_travel_enabled false
R="$(authrpc "$U1" "public.get_osn_movement_readiness()")"
[ "$(fld "$R" osn_available)" = "true" ] && [ "$(fld "$R" coordinate_travel_available)" = "false" ] || { echo "$R"; fail "ok[3] osn=true,coord=false expected coord_avail=false"; }
echo "ok[3] osn_available=true, coord_gate=false → coordinate_travel_available=false"
# row 4: osn_available=true, coord=true → true
flag mainship_coordinate_travel_enabled true
R="$(authrpc "$U1" "public.get_osn_movement_readiness()")"
[ "$(fld "$R" osn_available)" = "true" ] && [ "$(fld "$R" coordinate_travel_available)" = "true" ] || { echo "$R"; fail "ok[4] osn=true,coord=true expected coord_avail=true"; }
echo "ok[4] osn_available=true, coord_gate=true → coordinate_travel_available=true"

# ── anti-spoof: an UNANCHORED / non-actionable origin (home) gets false even with BOTH flags true ──────────
flag mainship_space_movement_enabled true; flag mainship_coordinate_travel_enabled true
R2="$(authrpc "$U2" "public.get_osn_movement_readiness()")"
[ "$(fld "$R2" origin_category)" = "not_anchored" ] || { echo "$R2"; fail "ok[5] home ship origin_category not 'not_anchored'"; }
[ "$(fld "$R2" osn_available)" = "false" ] || { echo "$R2"; fail "ok[5] home ship osn_available not false"; }
[ "$(fld "$R2" coordinate_travel_available)" = "false" ] || { echo "$R2"; fail "ok[5] UNANCHORED origin got coordinate_travel_available=true on flags alone"; }
echo "ok[5] unanchored (home) origin with BOTH flags true → coordinate_travel_available=false"

# ── existing fields + location/port readiness intact (U1 anchored, both flags true) ───────────────────────
R="$(authrpc "$U1" "public.get_osn_movement_readiness()")"
[ "$(fld "$R" origin_category)" = "anchored" ] || { echo "$R"; fail "ok[6] origin_category not anchored"; }
[ "$(fld "$R" reason)" = "none" ] || { echo "$R"; fail "ok[6] reason not 'none'"; }
NDEST="$(printf '%s' "$R" | jq -r '.eligible_destination_ids | length')"
[ "$NDEST" = "2" ] || { echo "$R"; fail "ok[6] expected exactly 2 eligible destinations (the non-docked active ports), got $NDEST"; }
printf '%s' "$R" | jq -e --arg p1 "$P1" '.eligible_destination_ids | index($p1) | not' >/dev/null || { echo "$R"; fail "ok[6] docked port $P1 leaked into destinations"; }
printf '%s' "$R" | jq -e --arg p2 "$P2" '.eligible_destination_ids | index($p2)' >/dev/null || { echo "$R"; fail "ok[6] $P2 missing from destinations"; }
printf '%s' "$R" | jq -e --arg p3 "$P3" '.eligible_destination_ids | index($p3)' >/dev/null || { echo "$R"; fail "ok[6] $P3 missing from destinations"; }
echo "ok[6] existing fields preserved + location/port readiness intact (origin=anchored, reason=none, dests=P2,P3 excl. docked P1)"

# ── the new field is a STRICT boolean (jsonb) ──────────────────────────────────────────────────────────────
[ "$(ftype "$R" coordinate_travel_available)" = "boolean" ] || { echo "$R"; fail "ok[7] coordinate_travel_available is not a JSON boolean"; }
[ "$(su "select jsonb_typeof((public.get_osn_movement_readiness())->'coordinate_travel_available');" 2>/dev/null || echo x)" != "" ] || true
echo "ok[7] coordinate_travel_available is a strict boolean"

# ── ACL: authenticated execute; anon + PUBLIC denied ─────────────────────────────────────────────────────
[ "$(su "select has_function_privilege('authenticated','public.get_osn_movement_readiness()','EXECUTE');")" = "t" ] || fail "ok[8] authenticated cannot execute readiness"
[ "$(su "select has_function_privilege('anon','public.get_osn_movement_readiness()','EXECUTE');")" = "f" ] || fail "ok[8] anon can execute readiness"
# PUBLIC denied via proacl (grantee oid 0). NULL proacl would mean PUBLIC default-EXECUTE → fail.
[ "$(su "select (not (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee=0 and a.privilege_type='EXECUTE')))::text from pg_proc p where p.oid='public.get_osn_movement_readiness()'::regprocedure;")" = "true" ] || fail "ok[8] PUBLIC can execute readiness"
echo "ok[8] readiness RPC ACL: authenticated execute; anon + PUBLIC denied"

# ── reading readiness performs NO write (no movement/dock/port/player/config/ship/fleet/presence change) ───
BEFORE="$(su "select (select count(*) from public.main_ship_space_movements)||'|'||(select count(*) from public.fleets)||'|'||(select count(*) from public.location_presence)||'|'||(select count(*) from public.main_ship_instances)||'|'||(select count(*) from public.locations)||'|'||(select md5(string_agg(key||'='||value::text,',' order by key)) from public.game_config);")"
authrpc "$U1" "public.get_osn_movement_readiness()" >/dev/null
authrpc "$U2" "public.get_osn_movement_readiness()" >/dev/null
AFTER="$(su "select (select count(*) from public.main_ship_space_movements)||'|'||(select count(*) from public.fleets)||'|'||(select count(*) from public.location_presence)||'|'||(select count(*) from public.main_ship_instances)||'|'||(select count(*) from public.locations)||'|'||(select md5(string_agg(key||'='||value::text,',' order by key)) from public.game_config);")"
[ "$BEFORE" = "$AFTER" ] || fail "ok[9] reading readiness mutated state ($BEFORE -> $AFTER)"
echo "ok[9] reading readiness performs no movement/dock/port/player/config/ship/fleet/presence write"

# ── cleanup: remove disposable users (cascade), restore dark baseline, assert no orphan ships ─────────────
su "delete from auth.users where email like 'cr.%@example.com';" >/dev/null
flag mainship_space_movement_enabled false; flag mainship_coordinate_travel_enabled false
for p in "$P1" "$P2" "$P3"; do su "update public.locations set status='hidden' where id='$p';" >/dev/null; done
[ "$(su "select count(*) from public.main_ship_instances where player_id not in (select id from auth.users);")" = "0" ] || fail "cleanup: orphan ship remains"
[ "$(su "select count(*) from auth.users where email like 'cr.%@example.com';")" = "0" ] || fail "cleanup: disposable users remain"
echo "ok[cleanup] disposable users removed; dark baseline restored (both flags false; ports hidden); no orphan ships"

echo "OSN-COORD-READINESS LOCAL MATRIX: ALL PASSED"
exit 0
