#!/usr/bin/env bash
# OSN-3 S4 — DYNAMIC concurrency proof for public.process_mainship_space_arrivals() against the REAL
# migrated local Supabase DB. Real concurrent psql sessions (FIFO-driven) prove:
#   Scenario 1 (two concurrent processors, one due movement): one settles it, the other (with the ship
#     held by the first, uncommitted) skips via FOR UPDATE SKIP LOCKED → settled exactly once.
#   Scenario 2 (ship held by an unrelated lock): the processor skips it that tick, then settles it once
#     the lock is released.
# The arrival cron was already unscheduled by the fixtures step (deterministic). Cleans its fixtures.
# Requires $DB_URL. NEVER touches the shared/live DB.
set -uo pipefail
: "${DB_URL:?DB_URL required}"
q() { PGAPPNAME="${2:-mon}" psql "$DB_URL" -X -q -t -A -c "$1"; }

# create a coherent in_transit + DUE ship (own user → one ship per player); echo its main_ship_id
mkship() {
  local u b s f mv
  u=$(q "insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change) values ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated','osn3s4lock.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id")
  b=$(q "select id from bases where player_id='$u' and status='active' order by created_at limit 1")
  [ -n "$b" ] || { echo "FAIL: no auto-base for $u" >&2; exit 1; }
  s=$(q "insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id) values ('$u','starter_frigate','traveling','in_transit',500,500,50,10,2,3,gen_random_uuid()) returning main_ship_id")
  f=$(q "insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (gen_random_uuid(),'$u','$b','moving','movement','$s') returning id")
  mv=$(q "insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at) values (gen_random_uuid(),'$s','$f','$u','base',0,0,'space',100,50,1.0,now()-interval '1 hour',now()-interval '1 second') returning id")
  q "update fleets set active_space_movement_id='$mv' where id='$f'" >/dev/null
  echo "$s"
}

FIFOA=$(mktemp -u)
cleanup() {
  { echo "rollback;" >&3; } 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  kill "$PA" 2>/dev/null || true
  q "delete from auth.users where email like 'osn3s4lock.%@example.com';" >/dev/null 2>&1 || true
  rm -f "$FIFOA" 2>/dev/null || true
}
trap cleanup EXIT

# wait until session $1 is idle-in-transaction with its last query matching substring $2
wait_idletx() {
  for _ in $(seq 1 150); do
    [ "$(q "select (state='idle in transaction' and query ilike '%$2%') from pg_stat_activity where application_name='$1' order by query_start desc limit 1")" = "t" ] && return 0
    sleep 0.2
  done; echo "FAIL: $1 not idle-in-transaction (query ~ $2)"; cat /tmp/s4sessA.log 2>/dev/null; exit 1
}

mkfifo "$FIFOA"
PGAPPNAME=s4sessA psql "$DB_URL" -X -q < "$FIFOA" >/tmp/s4sessA.log 2>&1 & PA=$!
exec 3>"$FIFOA"

echo "=== Scenario 1: two concurrent processors, one due movement → settled exactly once ==="
S1=$(mkship)
echo "begin; select 'A='||public.process_mainship_space_arrivals();" >&3
wait_idletx s4sessA process_mainship_space_arrivals          # A ran the processor, holds the txn (ship locked, settle uncommitted)
B=$(q "select public.process_mainship_space_arrivals()")     # B: concurrent processor; A holds the ship → skip-locked
echo "commit;" >&3
sleep 0.5
grep -q "A=1" /tmp/s4sessA.log || { echo "FAIL: A did not settle exactly 1 (S1)"; cat /tmp/s4sessA.log; exit 1; }
[ "$B" = "0" ] || { echo "FAIL: concurrent processor B settled $B (expected 0 — ship was skip-locked)"; exit 1; }
ST=$(q "select status from main_ship_space_movements where main_ship_id='$S1'")
NM=$(q "select count(*) from main_ship_space_movements where main_ship_id='$S1' and status='arrived'")
[ "$ST" = "arrived" ] && [ "$NM" = "1" ] || { echo "FAIL: S1 not settled exactly once (status=$ST arrived_count=$NM)"; exit 1; }
echo "  ok: one due movement, two concurrent processors → settled exactly once (A=1, B=0)"

echo "=== Scenario 2: ship held by an unrelated lock → processor skips, then settles after release ==="
S2=$(mkship)
echo "begin; select public.mainship_space_lock_context('$S2', false);" >&3
wait_idletx s4sessA mainship_space_lock_context              # A holds the S2 ship lock (uncommitted)
B2=$(q "select public.process_mainship_space_arrivals()")    # processor: S2 skip-locked → not settled this tick
ST2=$(q "select status from main_ship_space_movements where main_ship_id='$S2'")
[ "$ST2" = "moving" ] || { echo "FAIL: S2 was settled while skip-locked (status=$ST2)"; exit 1; }
echo "  ok: skip-locked ship S2 left moving this tick (processor returned $B2 for it)"
echo "rollback;" >&3                                          # release the lock
sleep 0.5
C=$(q "select public.process_mainship_space_arrivals()")     # later tick settles it
ST2b=$(q "select status from main_ship_space_movements where main_ship_id='$S2'")
SS=$(q "select status||'/'||coalesce(spatial_state,'null') from main_ship_instances where main_ship_id='$S2'")
[ "$ST2b" = "arrived" ] || { echo "FAIL: S2 did not settle after release (status=$ST2b)"; exit 1; }
[ "$SS" = "stationary/in_space" ] || { echo "FAIL: S2 ship not stationary/in_space after settle ($SS)"; exit 1; }
echo "  ok: after lock release, a later processor call settled S2 (ship now stationary/in_space)"

echo "OSN-3 S4 DYNAMIC CONCURRENCY PROOF: ALL PASSED"
