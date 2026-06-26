#!/usr/bin/env bash
# OSN-HUB-1A — REAL concurrent-session race: mainship_space_stop(...) vs process_mainship_space_arrivals()
# on a DUE location-target route, against the REAL migrated local Supabase DB (FIFO-driven two sessions).
# Proves: when both try to settle the same due location route, the shared ship lock serializes them and the
# route settles EXACTLY ONCE — never a duplicate dock/presence, never a left-behind active coordinate pointer.
# Here Stop holds the ship lock (uncommitted dock) while a concurrent processor tick observes the still-moving
# committed row, tries the canonical skip-locked claim, finds the ship held, and skips (settles 0). After Stop
# commits, the route is the single docked settlement; a later processor tick is a no-op. NEVER the live DB.
set -uo pipefail
: "${DB_URL:?DB_URL required}"
q() { PGAPPNAME="${2:-mon}" psql "$DB_URL" -X -q -t -A -c "$1"; }

# Deterministic timing: ensure the arrival cron cannot fire during the race.
q "do \$\$ begin perform cron.unschedule(jobid) from cron.job where jobname='process-mainship-space-arrivals'; exception when undefined_table then null; end \$\$;" >/dev/null 2>&1 || true

# An eligible, VISIBLE public port (active zone/sector reused) + active docking service + one active anchor at (140,55).
mkport() {
  local z l
  z=$(q "select id from zones where status='active' order by id limit 1")
  l=$(q "insert into locations (zone_id,name,location_type,x,y,activity_type,status,physical_role) values ('$z','hub1a-race-'||replace(gen_random_uuid()::text,'-',''),'trade_outpost',140,55,'none','active','port') returning id")
  q "insert into location_services (location_id,service,status) values ('$l','docking','active')" >/dev/null
  q "insert into space_anchors (kind,location_id,space_x,space_y,status) values ('location','$l',140,55,'active')" >/dev/null
  echo "$l"
}

# A coherent in_transit + DUE location-target route to port $1. Echoes "<player_id> <main_ship_id>".
mkship_loc() {
  local u s f mv
  u=$(q "insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change) values ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated','osn3hub1arace.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id")
  s=$(q "insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id) values ('$u','starter_frigate','traveling','in_transit',500,500,50,10,2,3,gen_random_uuid()) returning main_ship_id")
  f=$(q "insert into fleets (id,player_id,status,location_mode,main_ship_id) values (gen_random_uuid(),'$u','moving','movement','$s') returning id")
  mv=$(q "insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,target_location_id,speed_used,depart_at,arrive_at) values (gen_random_uuid(),'$s','$f','$u','space',0,0,'location',140,55,'$1',1.0,now()-interval '1 hour',now()-interval '1 second') returning id")
  q "update fleets set active_space_movement_id='$mv' where id='$f'" >/dev/null
  echo "$u $s"
}

FIFOA=$(mktemp -u)
cleanup() {
  { echo "rollback;" >&3; } 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  kill "$PA" 2>/dev/null || true
  q "delete from auth.users where email like 'osn3hub1arace.%@example.com';" >/dev/null 2>&1 || true
  q "delete from space_anchors a using locations l where a.location_id=l.id and l.name like 'hub1a-race-%';" >/dev/null 2>&1 || true
  q "delete from location_services s using locations l where s.location_id=l.id and l.name like 'hub1a-race-%';" >/dev/null 2>&1 || true
  q "delete from locations where name like 'hub1a-race-%';" >/dev/null 2>&1 || true
  rm -f "$FIFOA" 2>/dev/null || true
}
trap cleanup EXIT

wait_idletx() {  # wait until session $1 is idle-in-transaction with last query matching substring $2
  for _ in $(seq 1 150); do
    [ "$(q "select (state='idle in transaction' and query ilike '%$2%') from pg_stat_activity where application_name='$1' order by query_start desc limit 1")" = "t" ] && return 0
    sleep 0.2
  done; echo "FAIL: $1 not idle-in-transaction (query ~ $2)"; cat /tmp/raceSessA.log 2>/dev/null; exit 1
}

mkfifo "$FIFOA"
PGAPPNAME=raceSessA psql "$DB_URL" -X -q < "$FIFOA" >/tmp/raceSessA.log 2>&1 & PA=$!
exec 3>"$FIFOA"

echo "=== Stop vs arrival-processor on one DUE location route → settled exactly once (no duplicate dock/presence) ==="
PORT=$(mkport)
read -r U S < <(mkship_loc "$PORT")
REQ=$(q "select gen_random_uuid()")

# Session A: Stop docks the due location route, holds the txn open (ship row locked, dock uncommitted).
echo "begin; select 'A='||(public.mainship_space_stop('$U','$S','$REQ')->>'outcome');" >&3
wait_idletx raceSessA mainship_space_stop

# Concurrent processor tick: sees the still-moving committed row, claims the ship skip-locked → held by A → skips.
B=$(q "select public.process_mainship_space_arrivals()")
[ "$B" = "0" ] || { echo "FAIL: concurrent processor settled $B (expected 0 — ship skip-locked by Stop)"; exit 1; }

echo "commit;" >&3
sleep 0.5
grep -q "A=arrived" /tmp/raceSessA.log || { echo "FAIL: Stop did not settle the due location route as 'arrived'"; cat /tmp/raceSessA.log; exit 1; }

ST=$(q "select status from main_ship_space_movements where main_ship_id='$S'")
SS=$(q "select status||'/'||coalesce(spatial_state,'null') from main_ship_instances where main_ship_id='$S'")
NP=$(q "select count(*) from location_presence lp join fleets f on f.id=lp.fleet_id where f.main_ship_id='$S' and lp.status='active'")
PTR=$(q "select count(*) from fleets where main_ship_id='$S' and (active_space_movement_id is not null or active_movement_id is not null)")
[ "$ST" = "arrived" ] || { echo "FAIL: movement status=$ST (expected arrived — exactly one settlement)"; exit 1; }
[ "$SS" = "stationary/at_location" ] || { echo "FAIL: ship=$SS (expected stationary/at_location)"; exit 1; }
[ "$NP" = "1" ] || { echo "FAIL: active presence count=$NP (expected exactly 1 — no duplicate dock)"; exit 1; }
[ "$PTR" = "0" ] || { echo "FAIL: an active coordinate pointer remains ($PTR)"; exit 1; }
echo "  ok: Stop settled once (A=arrived), concurrent processor skip-locked (B=0); one presence; no active pointer"

# A later processor tick must be a no-op (movement no longer moving) — never a duplicate settlement/presence.
C=$(q "select public.process_mainship_space_arrivals()")
NP2=$(q "select count(*) from location_presence lp join fleets f on f.id=lp.fleet_id where f.main_ship_id='$S' and lp.status='active'")
[ "$NP2" = "1" ] || { echo "FAIL: a later processor tick changed presence count to $NP2"; exit 1; }
echo "  ok: later processor tick is a no-op (returned $C); presence still exactly 1"

echo "OSN-HUB-1A STOP-vs-PROCESSOR RACE: PASSED"
