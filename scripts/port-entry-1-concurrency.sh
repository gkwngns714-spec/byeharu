#!/usr/bin/env bash
# PORT-ENTRY-1 — REAL external-concurrency proof (proof-only; no migration/logic change).
#
# Two genuinely independent psql sessions race the AUTHENTICATED public boundary
# commission_first_main_ship() for the SAME newly-created player (same auth.uid()). Session A opens a
# transaction, calls commission (creating the ship under the player_id UNIQUE) and is HELD OPEN; session B
# then calls commission and MUST BLOCK on the unique-conflict insert until A commits. A third observer session
# deterministically confirms B is waiting on a Lock (and is blocked_by A) BEFORE A commits — not timing luck.
# Then A commits, B unblocks, and the post-race invariants are asserted: exactly one ship / fleet / active
# presence, canonical at_location, no orphan/movement. Runs ONLY against the disposable DB_URL.
set -uo pipefail
: "${DB_URL:?DB_URL (disposable stack) required}"
P1='b1a00001-0066-4a00-8a00-000000000001'; P2='b1a00002-0066-4a00-8a00-000000000002'; P3='b1a00003-0066-4a00-8a00-000000000003'
q(){ psql "$DB_URL" -X -q -t -A -c "$1"; }
WORK="$(mktemp -d)"; A_IN="$WORK/a_in"; A_OUT="$WORK/a_out"; B_OUT="$WORK/b_out"
SUB=""; A_PID=""; B_PID=""
cleanup(){
  { exec 3>&-; } 2>/dev/null || true
  [ -n "$A_PID" ] && kill "$A_PID" 2>/dev/null || true
  [ -n "$B_PID" ] && kill "$B_PID" 2>/dev/null || true
  [ -n "$SUB" ] && q "delete from auth.users where id='$SUB';" >/dev/null 2>&1 || true
  q "delete from auth.users where email like 'pe1conc.%@example.com';" >/dev/null 2>&1 || true
  q "update public.locations set status='hidden' where id in ('$P1','$P2','$P3');" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
}
fail(){ echo "CONC FAIL: $1" >&2; echo "--- a_out ---"; cat "$A_OUT" 2>/dev/null; echo "--- b_out ---"; cat "$B_OUT" 2>/dev/null; cleanup; exit 1; }
trap cleanup EXIT

# 0) Mirror production (Haven active) + create ONE fresh player (auth trigger → base; NO main ship).
q "select public.reveal_starter_ports();" >/dev/null || fail "reveal_starter_ports failed"
SUB="$(q "insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','pe1conc.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','') returning id;")"
[ -n "$SUB" ] || fail "could not create fixture player"
[ "$(q "select count(*) from public.main_ship_instances where player_id='$SUB';")" = "0" ] || fail "fixture player already has a ship"
CLAIMS="{\"sub\":\"$SUB\",\"role\":\"authenticated\"}"

# 1) SESSION A: long-lived session over a FIFO. begin → set caller → commission → HELD OPEN (no commit yet).
mkfifo "$A_IN"
psql "$DB_URL" -X -q -A -t -f "$A_IN" > "$A_OUT" 2>&1 &
A_PID=$!
exec 3>"$A_IN"                                   # hold the write end open so A's session stays alive
printf '%s\n' \
  "begin;" \
  "select set_config('request.jwt.claims','$CLAIMS',true);" \
  "select 'A_RESULT='||public.commission_first_main_ship()::text;" >&3
for i in $(seq 1 75); do grep -q 'A_RESULT=' "$A_OUT" && break; sleep 0.2; done
grep -q 'A_RESULT=' "$A_OUT" || fail "session A never returned its commission result"
A_RES="$(sed -n 's/^A_RESULT=//p' "$A_OUT" | head -1)"
echo "$A_RES" | grep -q '"created": *true' || fail "session A is not created=true: $A_RES"
echo "[A] commission returned created=true; transaction HELD OPEN (uncommitted), holding the player_id key"

# 2) SESSION B: a SEPARATE authenticated session, SAME player → commission in the background; must BLOCK.
( psql "$DB_URL" -X -q -A -t -c \
    "select set_config('request.jwt.claims','$CLAIMS',true); select 'B_RESULT='||public.commission_first_main_ship()::text;" \
    > "$B_OUT" 2>&1 ) &
B_PID=$!

# 3) DETERMINISTIC overlap proof: observe B WAITING on a Lock, blocked_by A's backend, BEFORE A commits.
BLOCKED=0; EVID=""
for i in $(seq 1 100); do
  if grep -q 'B_RESULT=' "$B_OUT"; then fail "session B COMPLETED before A committed → no real serialization"; fi
  EVID="$(q "select b.pid||' wait='||b.wait_event_type||'/'||coalesce(b.wait_event,'?')||' blocked_by='||coalesce((select string_agg(x::text,',') from unnest(pg_blocking_pids(b.pid)) x),'none')
             from pg_stat_activity b
             where b.pid <> pg_backend_pid() and b.state='active' and b.wait_event_type='Lock'
               and b.query ilike '%commission_first_main_ship%'
               and array_length(pg_blocking_pids(b.pid),1) >= 1
             limit 1;")"
  if [ -n "$EVID" ]; then BLOCKED=1; break; fi
  sleep 0.2
done
[ "$BLOCKED" = "1" ] || fail "could not observe session B blocked on a lock (blocked_by another txn) before A committed"
grep -q 'B_RESULT=' "$B_OUT" && fail "session B finished before A commit (not truly blocked)"
echo "[evidence] session B is blocked while A is still uncommitted → $EVID"

# 4) Release A (commit) → B must unblock and resolve via the unique-conflict (do-nothing) path.
printf '%s\n' "commit;" >&3
exec 3>&-                                          # EOF → A's psql commits + exits
wait "$A_PID" 2>/dev/null || true
wait "$B_PID" 2>/dev/null || true
B_RES="$(sed -n 's/^B_RESULT=//p' "$B_OUT" | head -1)"
[ -n "$B_RES" ] || fail "session B produced no result"
echo "$B_RES" | grep -q '"ok": *true'      || fail "session B not ok=true (loser must succeed read-only): $B_RES"
echo "$B_RES" | grep -q '"created": *false' || fail "session B not created=false (loser must be NON-mutating): $B_RES"
echo "[B] after A commit: $B_RES"

# 5) Post-race invariants: exactly one ship / fleet / active presence; canonical at_location; no movement.
SHIP="$(q "select main_ship_id from public.main_ship_instances where player_id='$SUB';")"
[ -n "$SHIP" ] || fail "no ship after race"
[ "$(q "select count(*) from public.main_ship_instances where player_id='$SUB';")" = "1" ] || fail "not exactly one ship"
[ "$(q "select count(*) from public.fleets where main_ship_id='$SHIP';")" = "1" ] || fail "not exactly one main-ship fleet"
FLEET="$(q "select id from public.fleets where main_ship_id='$SHIP';")"
[ "$(q "select count(*) from public.location_presence where fleet_id='$FLEET' and status='active';")" = "1" ] || fail "not exactly one active presence"
[ "$(q "select public.mainship_space_validate_context('$SHIP')->>'state';")" = "at_location" ] || fail "final state not at_location"
[ "$(q "select count(*) from public.main_ship_space_movements where main_ship_id='$SHIP';")" = "0" ] || fail "unexpected coordinate movement row"
[ "$(q "select count(*) from public.fleets where player_id='$SUB';")" = "1" ] || fail "orphan/duplicate fleet for player"

echo "PORT-ENTRY-1 REAL-CONCURRENCY PROOF PASSED: A created=true (held open) · B blocked_by A on the player_id unique-conflict until A commit · B created=false · exactly one ship/fleet/active-presence · at_location · no movement/orphan"
cleanup; trap - EXIT
