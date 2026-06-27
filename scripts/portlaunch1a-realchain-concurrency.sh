#!/usr/bin/env bash
# PORT-LAUNCH-1A — DYNAMIC concurrency proof for reveal_starter_ports()' lock ordering against the REAL
# migrated local Supabase DB. Real concurrent psql sessions (FIFO-driven) prove that while session A is inside
# reveal_starter_ports() (holding its sector→zone→location→anchor→docking-service locks in an open txn), a
# concurrent privileged session B that tries to mutate a VALIDATED dependency BLOCKS on a row lock until A
# ends — so no anchor / docking-service / hierarchy row can change between A's validation and its reveal write
# (TOCTOU-closed). Both A and B roll back → no net world change. Requires $DB_URL. Touches only seeded rows.
set -uo pipefail
: "${DB_URL:?DB_URL required}"
q() { PGAPPNAME="${2:-mon}" psql "$DB_URL" -X -q -t -A -c "$1"; }

P1='b1a00001-0066-4a00-8a00-000000000001'
P2='b1a00002-0066-4a00-8a00-000000000002'
P3='b1a00003-0066-4a00-8a00-000000000003'
A1='b1a0a001-0066-4a00-8a00-0000000000a1'   # Haven Reach canonical anchor
S1='b1a05001-0066-4a00-8a00-000000000051'   # Haven Reach docking service
ZONE1=$(q "select zone_id from locations where id='$P1'")
[ -n "$ZONE1" ] || { echo "FAIL: could not resolve Haven Reach zone"; exit 1; }

FIFOA=$(mktemp -u); FIFOB=$(mktemp -u)
cleanup() {
  { echo "rollback;" >&3; echo "rollback;" >&4; } 2>/dev/null || true
  exec 3>&- 4>&- 2>/dev/null || true
  kill "$PA" "$PB" 2>/dev/null || true
  rm -f "$FIFOA" "$FIFOB" 2>/dev/null || true
}
trap cleanup EXIT
wait_idletx() { for _ in $(seq 1 150); do [ "$(q "select (state='idle in transaction' and query ilike '%$2%') from pg_stat_activity where application_name='$1' order by query_start desc limit 1")" = "t" ] && return 0; sleep 0.2; done; echo "FAIL: $1 not idle-in-tx (~$2)"; cat /tmp/plA.log /tmp/plB.log 2>/dev/null; exit 1; }
wait_blocked() { for _ in $(seq 1 150); do [ "$(q "select coalesce(wait_event_type,'') from pg_stat_activity where application_name='$1' and state='active' order by query_start desc limit 1")" = "Lock" ] && return 0; sleep 0.2; done; echo "FAIL: $1 not Lock-blocked"; cat /tmp/plB.log 2>/dev/null; exit 1; }

mkfifo "$FIFOA"; mkfifo "$FIFOB"
PGAPPNAME=plA psql "$DB_URL" -X -q < "$FIFOA" >/tmp/plA.log 2>&1 & PA=$!
PGAPPNAME=plB psql "$DB_URL" -X -q < "$FIFOB" >/tmp/plB.log 2>&1 & PB=$!
exec 3>"$FIFOA" 4>"$FIFOB"

# precondition: the three ports must be HIDDEN so reveal_starter_ports() succeeds (acquires locks + reveals).
[ "$(q "select count(*) from locations where id in ('$P1','$P2','$P3') and status='hidden'")" = "3" ] || { echo "FAIL: ports not all hidden at start"; exit 1; }

# run one scenario: A enters reveal (holds locks); B mutates $1 (desc $2) → must BLOCK; A rollback; B proceeds; B rollback.
race() {
  local stmt="$1" desc="$2"
  echo "=== A holds reveal_starter_ports() locks; B '$desc' must block ==="
  echo "begin; select public.reveal_starter_ports();" >&3
  wait_idletx plA reveal_starter_ports                       # A inside reveal txn, holding all dependency locks
  echo "begin; $stmt" >&4                                    # B's privileged mutation of a validated row
  wait_blocked plB                                           # PROVEN: B blocks on A's held row lock
  echo "  ok: B blocked (wait_event_type=Lock) while A holds reveal_starter_ports() locks"
  echo "rollback;" >&3                                       # A ends → releases locks (reveal undone)
  wait_idletx plB "$desc"                                    # B unblocks and completes its statement (txn held)
  echo "  ok: B proceeded only AFTER A ended"
  echo "rollback;" >&4                                       # undo B → no net change
  sleep 0.3
}

race "update space_anchors    set status='retired'  where id='$A1';"      "update"
race "update location_services set status='disabled' where id='$S1';"      "update"
race "update zones            set status='locked'   where id='$ZONE1';"    "update"

# verify NO net change: ports hidden; the canonical anchor/service/zone untouched.
do_check=$(q "select (select count(*) from locations where id in ('$P1','$P2','$P3') and status<>'hidden')
            + (select count(*) from space_anchors where id='$A1' and status<>'active')
            + (select count(*) from location_services where id='$S1' and status<>'active')
            + (select count(*) from zones where id='$ZONE1' and status<>'active')")
[ "$do_check" = "0" ] || { echo "FAIL: net change detected after concurrency scenarios ($do_check)"; exit 1; }
echo "  ok: no net world change (ports hidden; anchor/service/zone unchanged)"

echo "PORT-LAUNCH-1A DYNAMIC CONCURRENCY PROOF: ALL PASSED"
