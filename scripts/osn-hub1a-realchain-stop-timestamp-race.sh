#!/usr/bin/env bash
# OSN-HUB-1A — TIMESTAMP-BOUNDARY race: a Stop transaction that BEGINS before arrive_at, blocks on the S2 ship
# lock, crosses arrive_at while blocked, then takes the due-arrival path and settles a location route via Dock-0.
# Designed to FAIL under the old now()/transaction-start timestamp (resolved_at would be < arrive_at) and PASS
# with Dock-0's clock_timestamp() settlement timestamp. Two real FIFO sessions: A holds the ship lock; B runs
# the (blocked) Stop. Proves resolved_at >= arrive_at and that the Stop RESULT, the command RECEIPT, and the
# persisted MOVEMENT row all agree on one settlement time — for BOTH a successful dock and a terminal failure.
# Requires $DB_URL. NEVER the shared/live DB.
set -uo pipefail
: "${DB_URL:?DB_URL required}"
q() { PGAPPNAME="${2:-mon}" psql "$DB_URL" -X -q -t -A -c "$1"; }

q "do \$\$ begin perform cron.unschedule(jobid) from cron.job where jobname='process-mainship-space-arrivals'; exception when undefined_table then null; end \$\$;" >/dev/null 2>&1 || true

mkport() {  # eligible visible port at ($1,$2); echoes location id
  local z l
  z=$(q "select id from zones where status='active' order by id limit 1")
  l=$(q "insert into locations (zone_id,name,location_type,x,y,activity_type,status,physical_role) values ('$z','hub1a-tsrace-'||replace(gen_random_uuid()::text,'-',''),'trade_outpost',$1,$2,'none','active','port') returning id")
  q "insert into location_services (location_id,service,status) values ('$l','docking','active')" >/dev/null
  q "insert into space_anchors (kind,location_id,space_x,space_y,status) values ('location','$l',$1,$2,'active')" >/dev/null
  echo "$l"
}
# in_transit location route to port $1 at ($2,$3) whose arrive_at is now()+($4) seconds; echoes "<player> <ship>"
mkship() {
  local u s f
  u=$(q "insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change) values ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated','osn3hub1atsr.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id")
  s=$(q "insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id) values ('$u','starter_frigate','traveling','in_transit',500,500,50,10,2,3,gen_random_uuid()) returning main_ship_id")
  f=$(q "insert into fleets (id,player_id,status,location_mode,main_ship_id) values (gen_random_uuid(),'$u','moving','movement','$s') returning id")
  q "insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,target_location_id,speed_used,depart_at,arrive_at) values (gen_random_uuid(),'$s','$f','$u','space',0,0,'location',$2,$3,'$1',1.0,now()-interval '1 hour',now()+($4 || ' seconds')::interval)" >/dev/null
  q "update fleets set active_space_movement_id=(select id from main_ship_space_movements where main_ship_id='$s' and status='moving') where id='$f'" >/dev/null
  echo "$u $s"
}

FA=$(mktemp -u); FB=$(mktemp -u)
cleanup() {
  { echo "rollback;" >&3; } 2>/dev/null || true
  { echo "rollback;" >&4; } 2>/dev/null || true
  exec 3>&- 2>/dev/null || true; exec 4>&- 2>/dev/null || true
  kill "$PA" "$PB" 2>/dev/null || true
  q "delete from auth.users where email like 'osn3hub1atsr.%@example.com';" >/dev/null 2>&1 || true
  q "delete from space_anchors a using locations l where a.location_id=l.id and l.name like 'hub1a-tsrace-%';" >/dev/null 2>&1 || true
  q "delete from location_services s using locations l where s.location_id=l.id and l.name like 'hub1a-tsrace-%';" >/dev/null 2>&1 || true
  q "delete from locations where name like 'hub1a-tsrace-%';" >/dev/null 2>&1 || true
  rm -f "$FA" "$FB" 2>/dev/null || true
}
trap cleanup EXIT

wait_idletx() { for _ in $(seq 1 150); do [ "$(q "select (state='idle in transaction' and query ilike '%$2%') from pg_stat_activity where application_name='$1' order by query_start desc limit 1")" = "t" ] && return 0; sleep 0.2; done; echo "FAIL: $1 not idle-in-tx (~$2)"; exit 1; }
wait_blocked() { for _ in $(seq 1 200); do [ "$(q "select (state='active' and wait_event_type='Lock' and query ilike '%$2%') from pg_stat_activity where application_name='$1' order by query_start desc limit 1")" = "t" ] && return 0; sleep 0.2; done; echo "FAIL: $1 not blocked on a lock (~$2)"; exit 1; }
wait_log() { for _ in $(seq 1 200); do grep -q "$2" "$1" && return 0; sleep 0.2; done; echo "FAIL: log $1 missing $2"; cat "$1"; exit 1; }

mkfifo "$FA"; mkfifo "$FB"
PGAPPNAME=tsA psql "$DB_URL" -X -q < "$FA" >/tmp/tsA.log 2>&1 & PA=$!
PGAPPNAME=tsB psql "$DB_URL" -X -q < "$FB" >/tmp/tsB.log 2>&1 & PB=$!
exec 3>"$FA"; exec 4>"$FB"

# Common pattern: A locks the ship (tx open) → B BEGINs (tx-start < arrive_at) and the Stop blocks on the lock
# → cross arrive_at while B is blocked → break target (fail scenario only) → release A → B settles → commit B.
run() {  # $1=mode(dock|fail)  $2=port  $3=ship  $4=user  $5=req
  : >/tmp/tsB.log
  echo "begin; select public.mainship_space_lock_context('$3', false);" >&3
  wait_idletx tsA mainship_space_lock_context
  echo "begin; select 'BDONE='||(public.mainship_space_stop('$4','$3','$5')->>'outcome');" >&4
  wait_blocked tsB mainship_space_stop                      # B's tx has begun (before arrive_at) and is blocked
  sleep 11                                                  # cross arrive_at (routes use +8s) while B is blocked
  if [ "$1" = "fail" ]; then
    q "update space_anchors set status='retired' where location_id='$2' and kind='location' and status='active'" >/dev/null
  fi
  echo "rollback;" >&3                                      # release the ship lock → B proceeds on the due path
  wait_log /tmp/tsB.log "BDONE="
  echo "commit;" >&4
  sleep 0.4
}

echo "=== Scenario 1: tx-start-before-arrival, target stays legal → due dock; resolved_at >= arrive_at ==="
P1=$(mkport 140 55); read -r U1 S1 < <(mkship "$P1" 140 55 8); R1=$(q "select gen_random_uuid()")
run dock "$P1" "$S1" "$U1" "$R1"
chk() { [ "$(q "$1")" = "t" ] || { echo "FAIL: $2"; echo "  ($1)"; exit 1; }; }
chk "select status='arrived' from main_ship_space_movements where main_ship_id='$S1'" "movement not arrived"
chk "select resolved_at >= arrive_at from main_ship_space_movements where main_ship_id='$S1'" "resolved_at < arrive_at (the now() bug)"
chk "select status='stationary' and spatial_state='at_location' from main_ship_instances where main_ship_id='$S1'" "ship not docked at_location"
chk "select updated_at >= arrive_at from fleets f join main_ship_space_movements m on m.fleet_id=f.id where m.main_ship_id='$S1'" "fleet updated_at < arrive_at"
chk "select updated_at >= (select arrive_at from main_ship_space_movements where main_ship_id='$S1') from main_ship_instances where main_ship_id='$S1'" "ship updated_at < arrive_at"
chk "select (count(*)=1) from location_presence lp join fleets f on f.id=lp.fleet_id where f.main_ship_id='$S1' and lp.status='active'" "not exactly one presence"
chk "select (count(*)=0) from fleets where main_ship_id='$S1' and (active_space_movement_id is not null or active_movement_id is not null)" "an active coordinate pointer remains"
chk "select (c.result_json->>'outcome')='arrived' and (c.result_json->>'docked')='true' from main_ship_space_command_receipts c where c.main_ship_id='$S1'" "receipt result not arrived+docked"
chk "select (c.result_json->>'resolved_at')::timestamptz = m.resolved_at and c.completed_at = m.resolved_at from main_ship_space_command_receipts c join main_ship_space_movements m on m.id=c.movement_id where m.main_ship_id='$S1'" "result/receipt/movement timestamps disagree"
C=$(q "select public.process_mainship_space_arrivals()")        # later tick is a no-op
chk "select (count(*)=1) from location_presence lp join fleets f on f.id=lp.fleet_id where f.main_ship_id='$S1' and lp.status='active'" "processor created a duplicate presence"
RREPLAY=$(q "select (public.mainship_space_stop('$U1','$S1','$R1')->>'outcome')")  # idempotent replay
[ "$RREPLAY" = "arrived" ] || { echo "FAIL: replay not idempotent (got $RREPLAY)"; exit 1; }
chk "select (count(*)=1) from main_ship_space_command_receipts where main_ship_id='$S1'" "replay created a second receipt"
echo "  ok: due dock after a tx-start-before-arrival Stop; resolved_at >= arrive_at; result=receipt=movement timestamp; one presence; idempotent"

echo "=== Scenario 2: tx-start-before-arrival, target broken in transit → terminal failure; resolved_at >= arrive_at ==="
P2=$(mkport -140 55); read -r U2 S2 < <(mkship "$P2" -140 55 8); R2=$(q "select gen_random_uuid()")
run fail "$P2" "$S2" "$U2" "$R2"
chk "select status='failed' from main_ship_space_movements where main_ship_id='$S2'" "movement not failed"
chk "select resolved_at >= arrive_at from main_ship_space_movements where main_ship_id='$S2'" "failed resolved_at < arrive_at (the now() bug)"
chk "select status='stationary' and spatial_state='in_space' and space_x=-140 and space_y=55 from main_ship_instances where main_ship_id='$S2'" "ship not in_space at the stored snapshot"
chk "select (count(*)=0) from location_presence lp join fleets f on f.id=lp.fleet_id where f.main_ship_id='$S2'" "a presence exists on terminal failure"
chk "select (c.result_json->>'outcome')='arrived' and (c.result_json->>'docked')='false' from main_ship_space_command_receipts c where c.main_ship_id='$S2'" "receipt result not arrived+undocked"
chk "select (c.result_json->>'resolved_at')::timestamptz = m.resolved_at and c.completed_at = m.resolved_at from main_ship_space_command_receipts c join main_ship_space_movements m on m.id=c.movement_id where m.main_ship_id='$S2'" "fail result/receipt/movement timestamps disagree"
echo "  ok: terminal failure after a tx-start-before-arrival Stop; resolved_at >= arrive_at; in_space at snapshot; no presence; timestamps agree"

echo "OSN-HUB-1A STOP TIMESTAMP-BOUNDARY RACE: PASSED"
