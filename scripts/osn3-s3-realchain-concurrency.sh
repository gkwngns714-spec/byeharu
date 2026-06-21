#!/usr/bin/env bash
# OSN-3 S3 — DYNAMIC concurrency proof for public.mainship_space_begin_move against the REAL migrated
# local Supabase DB. Uses real concurrent psql sessions (FIFO-driven, distinct application_name) +
# pg_stat_activity wait-state to prove, with genuine contention on the per-ship lock:
#   Scenario 1 (two DISTINCT commands for one ship): the second waits on the ship lock, then — after
#     the first commits and the ship is in_transit — REJECTS on revalidation (no second movement).
#   Scenario 2 (two SAME-request retries for one ship): the second waits on the ship lock, then returns
#     the FIRST committed receipt result (same movement id), rather than rejecting as already-moving.
# Toggles mainship_space_movement_enabled true ONLY in this disposable stack; the trap restores it to
# false and asserts. Cleans its fixtures. Requires $DB_URL. NEVER touches the shared/live DB.
set -uo pipefail
: "${DB_URL:?DB_URL required}"

q() { PGAPPNAME="${2:-mon}" psql "$DB_URL" -X -q -t -A -c "$1"; }

FIFOA=$(mktemp -u); FIFOB=$(mktemp -u)
cleanup() {
  { echo "rollback;" >&3; echo "rollback;" >&4; } 2>/dev/null || true
  exec 3>&- 4>&- 2>/dev/null || true
  kill "$PA" "$PB" 2>/dev/null || true
  q "update game_config set value='false' where key='mainship_space_movement_enabled';" >/dev/null 2>&1 || true
  q "delete from auth.users where email like 'osn3s3lock.%@example.com';" >/dev/null 2>&1 || true
  rm -f "$FIFOA" "$FIFOB" 2>/dev/null || true
}
trap cleanup EXIT

# wait until session $1 (app name) is blocked in a Lock wait
wait_blocked() {
  for _ in $(seq 1 100); do
    [ "$(q "select coalesce(wait_event_type,'') from pg_stat_activity where application_name='$1' and state='active' order by query_start desc limit 1")" = "Lock" ] && return 0
    sleep 0.2
  done; echo "FAIL: $1 did not reach Lock wait"; cat /tmp/s3sessB.log 2>/dev/null; exit 1
}
# wait until session $1 is idle-in-transaction (its statement finished, txn open holding locks)
wait_idletx() {
  for _ in $(seq 1 100); do
    case "$(q "select state from pg_stat_activity where application_name='$1' order by query_start desc limit 1")" in
      "idle in transaction") return 0;; esac
    sleep 0.2
  done; echo "FAIL: $1 not idle-in-transaction"; cat /tmp/s3sessA.log /tmp/s3sessB.log 2>/dev/null; exit 1
}

mkfifo "$FIFOA"; mkfifo "$FIFOB"
PGAPPNAME=s3sessA psql "$DB_URL" -X -q < "$FIFOA" >/tmp/s3sessA.log 2>&1 & PA=$!
PGAPPNAME=s3sessB psql "$DB_URL" -X -q < "$FIFOB" >/tmp/s3sessB.log 2>&1 & PB=$!
exec 3>"$FIFOA" 4>"$FIFOB"

# ── fixtures: enable the writer + two legacy_home ships (one per scenario) ──
q "update game_config set value='true' where key='mainship_space_movement_enabled';" >/dev/null
U=$(q "
  with u as (
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated','authenticated','osn3s3lock.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id)
  select id from u;")
SEC=$(q "select id from sectors order by sector_index limit 1")
q "insert into bases (player_id,name,sector_id,x,y) values ('$U','s3lockbase','$SEC',1,2);" >/dev/null
S1=$(q "insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id) values ('$U','starter_frigate','home',null,500,500,50,10,2,3,gen_random_uuid()) returning main_ship_id;")
S2=$(q "insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id) values ('$U','starter_frigate','home',null,500,500,50,10,2,3,gen_random_uuid()) returning main_ship_id;")
R1=$(q "select gen_random_uuid()"); R2=$(q "select gen_random_uuid()"); R3=$(q "select gen_random_uuid()")

echo "=== Scenario 1: two DISTINCT commands for ship S1 — B waits on the lock, then rejects ==="
echo "begin; with r as (select public.mainship_space_begin_move('$U','$S1',100,50,'$R1') j) select 'A_OK='||(j->>'ok') from r;" >&3
wait_idletx s3sessA                                  # A ran the writer, holds the txn (locks + uncommitted move)
echo "begin; with r as (select public.mainship_space_begin_move('$U','$S1',200,60,'$R2') j) select 'B_OK='||(j->>'ok')||' B_REASON='||coalesce(j->>'reason','none') from r;" >&4
wait_blocked s3sessB                                 # B blocks on the ship FOR UPDATE
echo "commit;" >&3                                   # A commits → releases the lock; ship now in_transit
wait_idletx s3sessB                                  # B proceeds and completes its statement
echo "commit;" >&4
grep -q "A_OK=true" /tmp/s3sessA.log || { echo "FAIL: A did not succeed"; cat /tmp/s3sessA.log; exit 1; }
grep -q "B_OK=false" /tmp/s3sessB.log && grep -q "B_REASON=in_transit_must_stop" /tmp/s3sessB.log \
  || { echo "FAIL: B did not reject with in_transit_must_stop"; cat /tmp/s3sessB.log; exit 1; }
N=$(q "select count(*) from main_ship_space_movements where main_ship_id='$S1' and status='moving'")
[ "$N" = "1" ] || { echo "FAIL: expected exactly 1 moving movement for S1, got $N"; exit 1; }
echo "  ok: distinct concurrent commands → exactly one move; the loser rejected after revalidation"

echo "=== Scenario 2: two SAME-request retries for ship S2 — B waits, then replays A's receipt ==="
echo "begin; with r as (select public.mainship_space_begin_move('$U','$S2',77,77,'$R3') j) select 'A_OK='||(j->>'ok')||' A_MV='||(j->>'movement_id') from r;" >&3
wait_idletx s3sessA
echo "begin; with r as (select public.mainship_space_begin_move('$U','$S2',77,77,'$R3') j) select 'B_OK='||(j->>'ok')||' B_MV='||(j->>'movement_id') from r;" >&4
wait_blocked s3sessB
echo "commit;" >&3
wait_idletx s3sessB
echo "commit;" >&4
AMV=$(grep -o "A_MV=[0-9a-f-]*" /tmp/s3sessA.log | tail -1 | cut -d= -f2)
BMV=$(grep -o "B_MV=[0-9a-f-]*" /tmp/s3sessB.log | tail -1 | cut -d= -f2)
grep -q "A_OK=true" /tmp/s3sessA.log || { echo "FAIL: A(retry) did not succeed"; cat /tmp/s3sessA.log; exit 1; }
grep -q "B_OK=true" /tmp/s3sessB.log || { echo "FAIL: B(retry) did not return ok"; cat /tmp/s3sessB.log; exit 1; }
[ -n "$AMV" ] && [ "$AMV" = "$BMV" ] || { echo "FAIL: retry movement ids differ (A=$AMV B=$BMV)"; exit 1; }
N=$(q "select count(*) from main_ship_space_movements where main_ship_id='$S2'")
[ "$N" = "1" ] || { echo "FAIL: same-request retry created extra movement (n=$N)"; exit 1; }
NR=$(q "select count(*) from main_ship_space_command_receipts where main_ship_id='$S2' and request_id='$R3'")
[ "$NR" = "1" ] || { echo "FAIL: same-request retry created extra receipt (n=$NR)"; exit 1; }
echo "  ok: same-request retries → identical receipt result; one movement, one receipt"

echo "OSN-3 S3 DYNAMIC CONCURRENCY PROOF: ALL PASSED"
