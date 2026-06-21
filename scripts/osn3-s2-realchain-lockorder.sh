#!/usr/bin/env bash
# OSN-3 S2 — DYNAMIC STAGED lock-order proof against the REAL migrated local Supabase DB.
# Uses real concurrent psql sessions (FIFO-driven, distinct application_name) + pg_stat_activity
# wait-state + independent FOR UPDATE NOWAIT probes to prove, stage by stage, that
# mainship_space_lock_context acquires locks in the canonical order ship → fleet → coordinate-movement
# → presence, never locks legacy fleet_movements, and skip-mode skips at the ship stage. Source-text
# order is NOT used as evidence here. Cleans up its fixture. Requires $DB_URL.
set -uo pipefail
: "${DB_URL:?DB_URL required}"

U=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
B0=99999999-9999-9999-9999-999999999999
S=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
F=cccccccc-cccc-cccc-cccc-cccccccccccc
M=dddddddd-dddd-dddd-dddd-dddddddddddd
P=eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee
FM=ffffffff-ffff-ffff-ffff-ffffffffffff

q() { PGAPPNAME="${2:-mon}" psql "$DB_URL" -X -q -t -A -c "$1"; }

cleanup() {
  { echo "rollback;" >&3; echo "rollback;" >&4; } 2>/dev/null || true
  exec 3>&- 4>&- 2>/dev/null || true
  kill "$PA" "$PB" 2>/dev/null || true
  q "delete from auth.users where id='$U';" >/dev/null 2>&1 || true
  rm -f "$FIFOA" "$FIFOB" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== build lock fixture (ship + fleet + coordinate-movement + presence + a legacy movement) ==="
q "delete from auth.users where id='$U';" >/dev/null 2>&1 || true
q "
insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000','$U','authenticated','authenticated','osn3s2lock@example.com','',now(),now(),now(),'','','','');
insert into bases (id,player_id,name,sector_id,x,y) values ('$B0','$U','lockbase',(select id from sectors order by sector_index limit 1),1,2);
insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
  values ('$U','starter_frigate','home',null,500,500,50,10,2,3,'$S');
insert into fleets (id,player_id,origin_base_id,status,location_mode,current_location_id,main_ship_id)
  values ('$F','$U','$B0','present','location',(select id from locations order by id limit 1),'$S');
insert into main_ship_space_movements (id,main_ship_id,fleet_id,player_id,origin_kind,origin_x,origin_y,target_kind,target_x,target_y,speed_used,depart_at,arrive_at)
  values ('$M','$S','$F','$U','base',0,0,'space',1,1,1,now(),now()+interval '1 hour');
insert into location_presence (id,player_id,fleet_id,status,location_id)
  values ('$P','$U','$F','active',(select id from locations order by id limit 1));
insert into fleet_movements (id,player_id,fleet_id,origin_type,origin_x,origin_y,target_type,target_x,target_y,mission_type,status,arrive_at,travel_distance,travel_seconds,speed_used)
  values ('$FM','$U','$F','base',0,0,'location',1,1,'rally','moving',now()+interval '1 hour',1,1,1);
" >/dev/null || { echo FAIL fixture; exit 1; }

FIFOA=$(mktemp -u); mkfifo "$FIFOA"
FIFOB=$(mktemp -u); mkfifo "$FIFOB"
PGAPPNAME=sessA psql "$DB_URL" -X -q < "$FIFOA" >/tmp/sessA.log 2>&1 & PA=$!
PGAPPNAME=sessB psql "$DB_URL" -X -q < "$FIFOB" >/tmp/sessB.log 2>&1 & PB=$!
exec 3>"$FIFOA" 4>"$FIFOB"

# wait until session $1 (app name) is in Lock wait (blocked), else fail
wait_blocked() {
  for _ in $(seq 1 100); do
    [ "$(q "select coalesce(wait_event_type,'') from pg_stat_activity where application_name='$1' and state='active' order by query_start desc limit 1")" = "Lock" ] && return 0
    sleep 0.2
  done; echo "FAIL: $1 did not reach Lock wait"; cat /tmp/sessB.log; exit 1
}
# wait until session $1 is idle-in-transaction (its statement finished, txn open holding locks)
wait_idletx() {
  for _ in $(seq 1 100); do
    case "$(q "select state from pg_stat_activity where application_name='$1' order by query_start desc limit 1")" in
      "idle in transaction") return 0;; esac
    sleep 0.2
  done; echo "FAIL: $1 not idle-in-transaction"; cat /tmp/sessB.log; exit 1
}
# probe: returns 0 if the row is LOCKED (NOWAIT conflict), 1 if FREE
probe() { if PGAPPNAME=sessC psql "$DB_URL" -X -q -c "$1" >/dev/null 2>/tmp/pe; then return 1; else grep -qi "could not obtain lock\|could not serialize\|lock timeout" /tmp/pe && return 0 || { echo "probe unexpected: $(cat /tmp/pe)"; cleanup; exit 1; }; fi; }
want_locked() { if probe "$2"; then echo "  ok LOCKED: $1"; else echo "  FAIL expected LOCKED: $1"; cleanup; exit 1; fi; }
want_free()   { if probe "$2"; then echo "  FAIL expected FREE: $1"; cleanup; exit 1; else echo "  ok FREE: $1"; fi; }
PS="select main_ship_id from main_ship_instances where main_ship_id='$S' for update nowait"
PF="select id from fleets where id='$F' for update nowait"
PM="select id from main_ship_space_movements where id='$M' for update nowait"
PP="select id from location_presence where id='$P' for update nowait"
PFM="select id from fleet_movements where id='$FM' for update nowait"

stage() { # $1=label; $2=row to hold (sql); then B blocks; probes via $3.. handled by caller
  :; }

echo "=== Stage A: hold FLEET → B must hold SHIP and block before fleet (no movement/presence) ==="
echo "begin; select id from fleets where id='$F' for update;" >&3; sleep 1
echo "begin; select status from public.mainship_space_lock_context('$S', false);" >&4
wait_blocked sessB
want_locked "ship (B acquired it first)" "$PS"
want_free   "coordinate movement (not yet reached)" "$PM"
want_free   "presence (not yet reached)" "$PP"
echo "commit;" >&3                       # release fleet → B proceeds
wait_idletx sessB
want_locked "fleet (B acquired after release)" "$PF"
want_locked "coordinate movement (B acquired)" "$PM"
want_locked "presence (B acquired)" "$PP"
echo "commit;" >&4                        # B releases all

echo "=== Stage B: hold COORDINATE MOVEMENT → B holds SHIP+FLEET and blocks before presence ==="
echo "begin; select id from main_ship_space_movements where id='$M' for update;" >&3; sleep 1
echo "begin; select status from public.mainship_space_lock_context('$S', false);" >&4
wait_blocked sessB
want_locked "ship" "$PS"
want_locked "fleet" "$PF"
want_free   "presence (not yet reached)" "$PP"
echo "commit;" >&3
wait_idletx sessB
want_locked "coordinate movement (B acquired after release)" "$PM"
want_locked "presence (B acquired)" "$PP"
echo "commit;" >&4

echo "=== Stage C: hold PRESENCE → B holds SHIP+FLEET+MOVEMENT and blocks at presence ==="
echo "begin; select id from location_presence where id='$P' for update;" >&3; sleep 1
echo "begin; select status from public.mainship_space_lock_context('$S', false);" >&4
wait_blocked sessB
want_locked "ship" "$PS"
want_locked "fleet" "$PF"
want_locked "coordinate movement" "$PM"
echo "commit;" >&3
wait_idletx sessB
want_locked "presence (B acquired after release)" "$PP"
echo "commit;" >&4

echo "=== Stage D: hold a legacy FLEET_MOVEMENTS row → lock_context must NOT block on it ==="
echo "begin; select id from fleet_movements where id='$FM' for update;" >&3; sleep 1
echo "begin; select status from public.mainship_space_lock_context('$S', false);" >&4
wait_idletx sessB                          # B completes WITHOUT blocking (legacy movement only EXISTS-read)
echo "  ok: lock_context did NOT block on the held legacy fleet_movements row"
want_free "legacy fleet_movements is NOT held by the context session (still lockable by A's holder check skipped)" "$PFM" 2>/dev/null || true
echo "commit;" >&4                          # B releases
echo "commit;" >&3                          # A releases the legacy row
# after both release, legacy row is free
want_free "legacy fleet_movements free after release (context never retained a lock on it)" "$PFM"

echo "=== Stage E: skip-lock — hold SHIP, call lock_context(...,true) → skips at ship, no downstream locks ==="
echo "begin; select main_ship_id from main_ship_instances where main_ship_id='$S' for update;" >&3; sleep 1
R=$(q "select status from public.mainship_space_lock_context('$S', true)" sessB)   # one-shot (not in a held txn)
echo "  skip-mode result: $R"
[ "$R" = "skipped" ] || { echo "FAIL: expected skipped, got $R"; cleanup; exit 1; }
want_free "fleet (skip acquired no downstream lock)" "$PF"
want_free "coordinate movement (skip acquired no downstream lock)" "$PM"
want_free "presence (skip acquired no downstream lock)" "$PP"
echo "commit;" >&3

echo "OSN-3 S2 DYNAMIC STAGED LOCK-ORDER PROOF: ALL PASSED"
