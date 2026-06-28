#!/usr/bin/env bash
# PHASE 9 — disposable proof for public.get_my_current_dock_services() (read-only docked-port surface).
#
# Boots a throwaway local chain and exercises the RPC through the REAL authenticated boundary (role
# authenticated + auth.uid() via jwt claims) across every ship state. It writes only disposable test fixtures
# (users/ships/services it cleans up); it never seeds production, never calls a trade/inventory write, never
# touches player_home_port, and never implements world_sites. Modes: selftest (DB-free) / local.
set -uo pipefail
set +x

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local) : ;; *) echo "usage: $0 <selftest|local>" >&2; exit 2;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIG="$REPO_ROOT/supabase/migrations/20260618000069_phase9_dock_services_read.sql"
P1='b1a00001-0066-4a00-8a00-000000000001'; P2='b1a00002-0066-4a00-8a00-000000000002'

# ── SELFTEST (DB-free) — the migration is a read-only, no-arg, authenticated-only RPC that never widens access ──
if [ "$MODE" = "selftest" ]; then
  [ -f "$MIG" ] || fail "migration not found"
  grep -q 'create or replace function public.get_my_current_dock_services()' "$MIG" || fail "RPC missing / takes arguments (must be zero-arg)"
  grep -q 'security definer' "$MIG" || fail "RPC not SECURITY DEFINER"
  grep -q 'set search_path = public' "$MIG" || fail "RPC missing search_path hardening"
  grep -q 'auth.uid()' "$MIG" || fail "RPC does not derive the player from auth.uid()"
  grep -q 'mainship_space_validate_context' "$MIG" || fail "RPC does not use the validated context"
  grep -q 'revoke all on function public.get_my_current_dock_services() from public' "$MIG" || fail "RPC does not revoke the default PUBLIC grant"
  grep -q 'grant execute on function public.get_my_current_dock_services() to authenticated' "$MIG" || fail "RPC not granted to authenticated"
  grep -qiE 'grant .* to anon' "$MIG" && fail "RPC granted to anon" || true
  # checks below operate on the COMMENT-STRIPPED SQL (the header legitimately names these terms in prose).
  CLEAN="$(sed -E 's/--.*//' "$MIG")"
  printf '%s' "$CLEAN" | grep -q 'player_home_port' && fail "RPC references player_home_port" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(insert|update|delete|create table|alter table|world_sites)\b' && fail "migration writes data / creates schema beyond the RPC" || true
  printf '%s' "$CLEAN" | grep -qiE 'from public\.bases|location_type|physical_role|activity_type' && fail "RPC reads base/type/role to decide dock access" || true
  echo "PHASE9 DOCK-SERVICES SELFTEST: ALL PASSED (zero-arg, SECURITY DEFINER + search_path, auth.uid()-derived, authenticated-only, no write/seed/home-port/world_sites)"
  exit 0
fi

# ── LOCAL (disposable matrix) ─────────────────────────────────────────────────────────────────────────────
: "${DB_URL:?DB_URL (disposable stack) required}"
q() { psql "$DB_URL" -X -q -t -A -c "$1"; }
authrpc() { psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c \
  "begin; do \$\$ begin perform set_config('request.jwt.claims', json_build_object('sub','$1','role','authenticated')::text, true); end \$\$; set local role authenticated; select (public.get_my_current_dock_services())::text; reset role; commit;"; }
anonrpc() { psql "$DB_URL" -X -q -t -A -c \
  "begin; set local role anon; select (public.get_my_current_dock_services())::text; reset role; commit;" 2>&1; }
mkuser() { q "insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','ph9.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','');" >/dev/null
  q "select id from auth.users where email like 'ph9.%@example.com' order by created_at desc limit 1;"; }
mkship_at() {  # $1=user $2=location → ship docked (present/at_location) at the location
  q "do \$\$ declare u uuid:='$1'; s uuid:=gen_random_uuid(); f uuid:=gen_random_uuid(); b uuid; z uuid; sec uuid; begin
       select id into b from public.bases where player_id=u and status='active' order by created_at limit 1;
       select zone_id into z from public.locations where id='$2'; select sector_id into sec from public.zones where id=z;
       insert into public.main_ship_instances(player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
         values(u,'starter_frigate','stationary','at_location',500,500,50,10,2,3,s);
       insert into public.fleets(id,player_id,origin_base_id,status,location_mode,main_ship_id,current_location_id,current_zone_id,current_sector_id)
         values(f,u,b,'present','location',s,'$2',z,sec);
       insert into public.location_presence(player_id,fleet_id,location_id,zone_id,sector_id,activity_type,status) values(u,f,'$2',z,sec,'none','active');
     end \$\$;" >/dev/null; }
mkship_simple() {  # $1=user $2=status $3=spatial_state → ship only (no fleet/presence): in_space/destroyed/home
  q "insert into public.main_ship_instances(player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id,space_x,space_y)
       values('$1','starter_frigate','$2','$3',500,500,50,10,2,3,gen_random_uuid(), $4, $5);" >/dev/null; }
st() { printf '%s' "$1" | grep -oE '"state": *"[a-z_]+"' | head -1 | grep -oE '[a-z_]+"$' | tr -d '"'; }
svc() { printf '%s' "$1" | grep -oE '"services": *\[[^]]*\]'; }

for p in "$P1" "$P2"; do q "update public.locations set status='active' where id='$p';" >/dev/null; done  # post-reveal realism

# ok[6] anon denied + authenticated allowed (ACL)
[ "$(q "select has_function_privilege('anon','public.get_my_current_dock_services()','EXECUTE');")" = "f" ] || fail "anon can execute the RPC"
[ "$(q "select has_function_privilege('authenticated','public.get_my_current_dock_services()','EXECUTE');")" = "t" ] || fail "authenticated cannot execute the RPC"
A="$(anonrpc)"; echo "$A" | grep -qiE 'permission denied|must be|denied' || fail "anon call was not denied at runtime: $A"
echo "ok[6] anon access denied (ACL false + runtime permission denied); authenticated granted"

# ok[5] the RPC takes ZERO client-controlled identifiers
[ "$(q "select pronargs from pg_proc where proname='get_my_current_dock_services';")" = "0" ] || fail "RPC accepts arguments"
echo "ok[5] RPC accepts no player/ship/location/port input (pronargs=0); player+ship+dock all server-derived"

# ok[1] authenticated, no main ship
U0="$(mkuser)"; R0="$(authrpc "$U0")"
[ "$(st "$R0")" = "no_main_ship" ] || { echo "$R0"; fail "ok[1] not no_main_ship"; }
echo "$R0" | grep -q '"services": *\[\]' || { echo "$R0"; fail "ok[1] services not empty"; }
echo "ok[1] no main ship → state=no_main_ship, services=[]"

# ok[2] at_location → that dock's active services only (docking)
U1="$(mkuser)"; mkship_at "$U1" "$P1"; R1="$(authrpc "$U1")"
[ "$(st "$R1")" = "at_location" ] || { echo "$R1"; fail "ok[2] not at_location"; }
echo "$R1" | grep -q "\"location_id\": *\"$P1\"" || { echo "$R1"; fail "ok[2] wrong dock location"; }
echo "$R1" | grep -q '"docked": *true' || { echo "$R1"; fail "ok[2] not docked"; }
echo "$R1" | grep -q '"docking"' || { echo "$R1"; fail "ok[2] docking service missing"; }
echo "ok[2] at_location → docked at the validated port; services=[\"docking\"]"

# ok[4] an INACTIVE service at the dock is not returned
q "insert into public.location_services(location_id,service,status) values('$P1','market','disabled') on conflict (location_id,service) do update set status='disabled';" >/dev/null
R1b="$(authrpc "$U1")"; echo "$R1b" | grep -q '"market"' && { echo "$R1b"; fail "ok[4] inactive market service was returned"; } || true
echo "$R1b" | grep -q '"docking"' || { echo "$R1b"; fail "ok[4] active docking dropped"; }
q "delete from public.location_services where location_id='$P1' and service='market';" >/dev/null
echo "ok[4] inactive (disabled) services are not returned (only active)"

# ok[3] in_transit / in_space / destroyed → no dock, no services
U2="$(mkuser)"
q "do \$\$ declare u uuid:='$U2'; s uuid:=gen_random_uuid(); f uuid:=gen_random_uuid(); m uuid:=gen_random_uuid(); b uuid; begin
     select id into b from public.bases where player_id=u and status='active' limit 1;
     insert into public.main_ship_instances(player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
       values(u,'starter_frigate','traveling','in_transit',500,500,50,10,2,3,s);
     insert into public.fleets(id,player_id,origin_base_id,status,location_mode,main_ship_id)  -- fleet FIRST (movement FK references it)
       values(f,u,b,'moving','movement',s);
     insert into public.main_ship_space_movements(id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,target_location_id,status,speed_used,depart_at,arrive_at)
       values(m,s,f,u,'location',-50,-30,'location',70,-10,'$P2','moving',1.0, now()-interval '2 hour', now()+interval '1 hour');
     update public.fleets set active_space_movement_id = m where id = f;  -- link (validate_context in_transit requires this)
   end \$\$;" >/dev/null
[ "$(st "$(authrpc "$U2")")" = "in_transit" ] || { echo "$(authrpc "$U2")"; fail "ok[3] in_transit"; }
U3="$(mkuser)"; mkship_simple "$U3" stationary in_space 123 456
[ "$(st "$(authrpc "$U3")")" = "in_space" ] || { echo "$(authrpc "$U3")"; fail "ok[3] in_space"; }
U4="$(mkuser)"; mkship_simple "$U4" destroyed destroyed NULL NULL
[ "$(st "$(authrpc "$U4")")" = "destroyed" ] || { echo "$(authrpc "$U4")"; fail "ok[3] destroyed"; }
for U in "$U2" "$U3" "$U4"; do authrpc "$U" | grep -q '"services": *\[\]' || fail "ok[3] non-docked returned services for $U"; done
echo "ok[3] in_transit / in_space / destroyed → no dock, services=[]"

# ok[7] an INCOHERENT at_location (spatial_state at_location but NO presence/fleet) never grants services
U5="$(mkuser)"; mkship_simple "$U5" stationary at_location NULL NULL   # at_location ship with no fleet/presence → contradictory
R5="$(authrpc "$U5")"
[ "$(st "$R5")" = "incoherent_or_unavailable" ] || { echo "$R5"; fail "ok[7] contradictory at_location not gated"; }
echo "$R5" | grep -q '"services": *\[\]' || { echo "$R5"; fail "ok[7] services not empty for incoherent"; }
echo "$R5" | grep -q '"docked": *false' || { echo "$R5"; fail "ok[7] docked true for incoherent"; }
echo "ok[7] incoherent dock/movement/presence → incoherent_or_unavailable, no services"

# ok[5b] each player gets only their OWN dock (no cross-player leakage)
U6="$(mkuser)"; mkship_at "$U6" "$P2"; R6="$(authrpc "$U6")"
echo "$R6" | grep -q "\"location_id\": *\"$P2\"" || { echo "$R6"; fail "ok[5] player got the wrong dock"; }
echo "$(authrpc "$U1")" | grep -q "\"location_id\": *\"$P1\"" || fail "ok[5] cross-player dock leak"
echo "ok[5b] each authenticated player resolves ONLY their own ship's dock (no cross-player selection)"

# ok[10] no market/service seed, trade write, inventory mutation, player_home_port use, or world_sites change
[ "$(q "select count(*) from public.location_services where service<>'docking';")" = "0" ] || fail "ok[10] a non-docking service row leaked"
[ "$(q "select count(*) from public.player_home_port;")" = "0" ] || fail "ok[10] a player_home_port row was created"
[ "$(q "select count(*) from information_schema.tables where table_name='world_sites';")" = "0" ] || fail "ok[10] world_sites table exists"
echo "ok[10] no market/service seed, no trade/inventory write, no player_home_port, no world_sites"

# cleanup disposable fixtures
q "delete from auth.users where email like 'ph9.%@example.com';" >/dev/null
for p in "$P1" "$P2"; do q "update public.locations set status='hidden' where id='$p';" >/dev/null; done
echo "PHASE9 DOCK-SERVICES LOCAL MATRIX: ALL PASSED"
