#!/usr/bin/env bash
# OSN-3 S5 — DYNAMIC concurrency proof for the coordinate-complete destruction primitive against the
# REAL migrated local Supabase DB. Real concurrent psql sessions (FIFO-driven) prove:
#   Scenario 1 (arrival wins first): the S4 processor settles a due movement (→in_space); destruction,
#     blocked on the ship lock, then cleanly clears the parked in_space ship.
#   Scenario 2 (destruction wins first): destruction cancels the moving movement; the arrival processor
#     (ship skip-locked, then movement no longer 'moving') never settles it.
#   Scenario 3 (two destructions race): one terminal result, the second is idempotent, no constraint
#     violation / duplicate / contradiction.
# Both paths acquire mainship_space_lock_context first, so they serialize on the ship row. Requires
# $DB_URL. The S4 arrival cron was unscheduled by the fixtures step (deterministic). Cleans its fixtures.
set -uo pipefail
: "${DB_URL:?DB_URL required}"
q() { PGAPPNAME="${2:-mon}" psql "$DB_URL" -X -q -t -A -c "$1"; }

# create a coherent in_transit + DUE ship (own user → one ship/player); echo "ship player"
mkship() {
  local u b s f mv
  u=$(q "insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change) values ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated','osn3s5lock.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id")
  b=$(q "select id from bases where player_id='$u' and status='active' order by created_at limit 1")
  [ -n "$b" ] || { echo "FAIL: no auto-base for $u" >&2; exit 1; }
  s=$(q "insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id) values ('$u','starter_frigate','traveling','in_transit',500,500,50,10,2,3,gen_random_uuid()) returning main_ship_id")
  f=$(q "insert into fleets (id,player_id,origin_base_id,status,location_mode,main_ship_id) values (gen_random_uuid(),'$u','$b','moving','movement','$s') returning id")
  mv=$(q "insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at) values (gen_random_uuid(),'$s','$f','$u','base',0,0,'space',100,50,1.0,now()-interval '1 hour',now()-interval '1 second') returning id")
  q "update fleets set active_space_movement_id='$mv' where id='$f'" >/dev/null
  echo "$s $u"
}

FIFOA=$(mktemp -u); FIFOB=$(mktemp -u)
cleanup() {
  { echo "rollback;" >&3; echo "rollback;" >&4; } 2>/dev/null || true
  exec 3>&- 4>&- 2>/dev/null || true
  kill "$PA" "$PB" 2>/dev/null || true
  q "delete from auth.users where email like 'osn3s5lock.%@example.com';" >/dev/null 2>&1 || true
  rm -f "$FIFOA" "$FIFOB" 2>/dev/null || true
}
trap cleanup EXIT
wait_idletx() { for _ in $(seq 1 150); do [ "$(q "select (state='idle in transaction' and query ilike '%$2%') from pg_stat_activity where application_name='$1' order by query_start desc limit 1")" = "t" ] && return 0; sleep 0.2; done; echo "FAIL: $1 not idle-in-tx (~$2)"; cat /tmp/s5A.log /tmp/s5B.log 2>/dev/null; exit 1; }
wait_blocked() { for _ in $(seq 1 150); do [ "$(q "select coalesce(wait_event_type,'') from pg_stat_activity where application_name='$1' and state='active' order by query_start desc limit 1")" = "Lock" ] && return 0; sleep 0.2; done; echo "FAIL: $1 not Lock-blocked"; cat /tmp/s5B.log 2>/dev/null; exit 1; }

mkfifo "$FIFOA"; mkfifo "$FIFOB"
PGAPPNAME=s5A psql "$DB_URL" -X -q < "$FIFOA" >/tmp/s5A.log 2>&1 & PA=$!
PGAPPNAME=s5B psql "$DB_URL" -X -q < "$FIFOB" >/tmp/s5B.log 2>&1 & PB=$!
exec 3>"$FIFOA" 4>"$FIFOB"

echo "=== Scenario 1: arrival wins first → then destruction clears the parked in_space ship ==="
read -r S1 P1 < <(mkship)
echo "begin; select 'A='||public.process_mainship_space_arrivals();" >&3
wait_idletx s5A process_mainship_space_arrivals           # A settled S1 (→in_space), holds txn
echo "select public.dev_set_main_ship_destroyed('$P1');" >&4
wait_blocked s5B                                          # destruction blocks on the ship lock
echo "commit;" >&3                                        # A commits → movement arrived, ship in_space
wait_idletx s5B dev_set_main_ship_destroyed               # destruction proceeds and completes
echo "commit;" >&4
sleep 0.4
grep -q "A=1" /tmp/s5A.log || { echo "FAIL: arrival did not settle S1"; cat /tmp/s5A.log; exit 1; }
MST=$(q "select status from main_ship_space_movements where main_ship_id='$S1'")
SST=$(q "select status||'/'||coalesce(spatial_state,'null')||'/'||coalesce(space_x::text,'null') from main_ship_instances where main_ship_id='$S1'")
[ "$MST" = "arrived" ] || { echo "FAIL: S1 movement not arrived (got $MST)"; exit 1; }
[ "$SST" = "destroyed/null/null" ] || { echo "FAIL: S1 ship not destroyed/cleared (got $SST)"; exit 1; }
echo "  ok: movement arrived normally, then destruction cleared the parked in_space ship (destroyed/spatial NULL)"

echo "=== Scenario 2: destruction wins first → arrival never settles the cancelled movement ==="
read -r S2 P2 < <(mkship)
echo "begin; select 'A='||(public.dev_set_main_ship_destroyed('$P2')->>'coordinate_movements_cancelled');" >&3
wait_idletx s5A dev_set_main_ship_destroyed               # A cancelled the movement + destroyed ship, holds txn
B=$(q "select public.process_mainship_space_arrivals()")  # processor: S2 skip-locked → 0
echo "commit;" >&3
sleep 0.4
C=$(q "select public.process_mainship_space_arrivals()")  # later tick: movement now 'cancelled' → not a candidate
grep -q "A=1" /tmp/s5A.log || { echo "FAIL: destruction did not cancel S2's movement"; cat /tmp/s5A.log; exit 1; }
MST2=$(q "select status||'/'||coalesce(terminal_reason,'null') from main_ship_space_movements where main_ship_id='$S2'")
SST2=$(q "select status from main_ship_instances where main_ship_id='$S2'")
[ "$MST2" = "cancelled/ship_destroyed" ] || { echo "FAIL: S2 movement not cancelled/ship_destroyed (got $MST2)"; exit 1; }
[ "$SST2" = "destroyed" ] || { echo "FAIL: S2 ship not destroyed (got $SST2)"; exit 1; }
echo "  ok: destruction cancelled the movement (ship_destroyed); arrival processor settled it 0 times (B=$B, later=$C)"

echo "=== Scenario 3: two destructions race → one terminal result, second idempotent, no violation ==="
read -r S3 P3 < <(mkship)
echo "begin; select 'A='||(public.dev_set_main_ship_destroyed('$P3')->>'status');" >&3
wait_idletx s5A dev_set_main_ship_destroyed               # A destroyed, holds txn
echo "select 'B='||(public.dev_set_main_ship_destroyed('$P3')->>'status');" >&4
wait_blocked s5B                                          # second destruction blocks on the ship lock
echo "commit;" >&3                                        # A commits
wait_idletx s5B dev_set_main_ship_destroyed               # B proceeds idempotently
echo "commit;" >&4
sleep 0.4
grep -q "A=destroyed" /tmp/s5A.log || { echo "FAIL: first destruction did not return destroyed"; cat /tmp/s5A.log; exit 1; }
grep -q "B=destroyed" /tmp/s5B.log || { echo "FAIL: second destruction errored/contradicted"; cat /tmp/s5B.log; exit 1; }
NC=$(q "select count(*) from main_ship_space_movements where main_ship_id='$S3' and status='cancelled' and terminal_reason='ship_destroyed'")
SST3=$(q "select status||'/'||coalesce(spatial_state,'null') from main_ship_instances where main_ship_id='$S3'")
[ "$NC" = "1" ] || { echo "FAIL: S3 expected exactly one cancelled movement (got $NC — duplicate terminalization)"; exit 1; }
[ "$SST3" = "destroyed/null" ] || { echo "FAIL: S3 ship state wrong (got $SST3)"; exit 1; }
echo "  ok: two concurrent destructions → one terminal cancellation, second idempotent, no constraint violation"

echo "OSN-3 S5 DYNAMIC CONCURRENCY PROOF: ALL PASSED"
