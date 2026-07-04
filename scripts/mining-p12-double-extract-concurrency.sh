#!/usr/bin/env bash
# MINING-P12 — DYNAMIC concurrency proof for public.mining_extract against the REAL migrated local
# Supabase DB. Mirrors scripts/osn3-s3-realchain-concurrency.sh point-for-point (real concurrent
# FIFO-driven psql sessions, distinct application_name, pg_stat_activity wait-state, a trap that
# restores every flag/tunable it toggled and asserts, fixture cleanup, $DB_URL-gated, NEVER touches
# the shared/live DB).
#
# WHAT THIS PROVES — the REACHABLE invariant. `mining_extract` (0104 step 11) is a read-then-insert:
# it reads the latest mining_extractions.created_at for (player, field) and, if older than
# mining_extract_cooldown_seconds, inserts. The S2 canonical lock (mainship_space_lock_context,
# 20260618000056...:46 `SELECT ... FOR UPDATE` on main_ship_instances) serializes commands on the
# SAME ship. Since every player holds ≤ 1 main ship at runtime today, two concurrent extracts for a
# player's ship contend on that ONE ship row: the second waits, then reads the first's now-committed
# extraction and is cooldown-rejected — NEVER a second extraction. Scenario below proves exactly that.
#
# WHY THE "TWO SHIPS OF ONE PLAYER" VARIANT IS NOT CONSTRUCTIBLE HERE (honest reachability note):
#   * The original main_ship_instances.player_id UNIQUE (20260617000043...:47,
#     main_ship_instances_player_id_key) was DROPPED in 20260618000079..., so ≤ 1-ship is NOT a
#     schema constraint today.
#   * It is instead a DARK-GATE / runtime invariant: the ONLY additional-ship path,
#     commission_additional_main_ship() (20260618000080...), is server-rejected while
#     mainship_additional_commission_enabled='false' (its default), and the first-ship writer is
#     zero-ship-guarded. So no path creates a 2nd ship for a player while that flag is dark, and this
#     proof deliberately does NOT flip it (no flag may be flipped in a committed artifact).
#   Therefore the two-ship double-extract race is UNREACHABLE today; this script covers the reachable
#   surface (one ship, contention on the ship row). The per-(player, field) advisory lock added in
#   0143 is DEFENSE-IN-DEPTH that becomes load-bearing only if/when multi-ship-per-player is activated;
#   it is verified here STRUCTURALLY (present, and ordered immediately before the cooldown read in
#   0143), not dynamically — with ≤ 1 ship it is never the contention point, which is precisely the
#   reachability finding.
#
# RUN (human owner's activation checklist — DEFERRED; this environment has no local DB):
#   DB_URL=postgres://... bash scripts/mining-p12-double-extract-concurrency.sh
# NOT wired into the dark `verify:*` block in package.json: it needs a LIT DB (mining_enabled flipped
# true INSIDE this disposable stack only) and so cannot run in the flag-off verify sweep. Referenced
# only from this header and the DEV_LOG. Static-check any time with:
#   bash -n scripts/mining-p12-double-extract-concurrency.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIG="$ROOT/supabase/migrations/20260618000143_mining_p12_extract_double_extract_guard.sql"

# ── STRUCTURAL CHECK (no DB): the 0143 advisory lock is present and ordered immediately BEFORE the
#    cooldown read. Runs even without $DB_URL so the defense-in-depth guard is asserted unconditionally.
[ -f "$MIG" ] || { echo "FAIL: migration 0143 not found at $MIG"; exit 1; }
LOCK_LINE=$(grep -n "perform pg_advisory_xact_lock(hashtext('mining_extract')" "$MIG" | head -1 | cut -d: -f1)
COOL_LINE=$(grep -n 'select e.created_at into v_last' "$MIG" | head -1 | cut -d: -f1)
[ -n "$LOCK_LINE" ] || { echo "FAIL: 0143 missing the per-(player,field) advisory lock perform line"; exit 1; }
[ -n "$COOL_LINE" ] || { echo "FAIL: 0143 cooldown read (select e.created_at into v_last) not found"; exit 1; }
{ [ "$LOCK_LINE" -lt "$COOL_LINE" ] && [ $((COOL_LINE - LOCK_LINE)) -le 20 ]; } \
  || { echo "FAIL: advisory lock (L$LOCK_LINE) is not immediately before the cooldown read (L$COOL_LINE)"; exit 1; }
echo "  ok (structural): 0143 advisory lock at L$LOCK_LINE precedes the cooldown read at L$COOL_LINE (defense-in-depth)"

# ── DYNAMIC PROOF requires a disposable DB. ──
: "${DB_URL:?DB_URL required (dynamic proof; run only against a disposable local DB)}"

q() { PGAPPNAME="${2:-mon}" psql "$DB_URL" -X -q -t -A -c "$1"; }

# capture originals so the trap can restore them verbatim (never invent a fallback)
ORIG_ENABLED=$(q "select value from game_config where key='mining_enabled'")
ORIG_COOLDOWN=$(q "select value from game_config where key='mining_extract_cooldown_seconds'")
FIELD_NAME="p12-conc-test-$(q "select replace(gen_random_uuid()::text,'-','')")"

FIFOA=$(mktemp -u); FIFOB=$(mktemp -u)
cleanup() {
  { echo "rollback;" >&3; echo "rollback;" >&4; } 2>/dev/null || true
  exec 3>&- 4>&- 2>/dev/null || true
  kill "$PA" "$PB" 2>/dev/null || true
  # restore the flag/tunable this stack toggled, back to their captured originals (flag → false)
  q "update game_config set value='${ORIG_ENABLED:-false}' where key='mining_enabled';" >/dev/null 2>&1 || true
  q "update game_config set value='${ORIG_COOLDOWN:-300}' where key='mining_extract_cooldown_seconds';" >/dev/null 2>&1 || true
  # fixture cleanup: the test field + the throwaway users (users cascade their ships/extractions)
  q "delete from mining_fields where name='$FIELD_NAME';" >/dev/null 2>&1 || true
  q "delete from auth.users where email like 'p12conc.%@example.com';" >/dev/null 2>&1 || true
  # assert the master flag is dark again
  RESTORED=$(q "select value from game_config where key='mining_enabled'" 2>/dev/null || echo '?')
  [ "$RESTORED" = "false" ] || echo "WARN: mining_enabled not restored to false (is '$RESTORED') — investigate"
  rm -f "$FIFOA" "$FIFOB" 2>/dev/null || true
}
trap cleanup EXIT

# wait until session $1 (app name) is blocked in a Lock wait (row FOR UPDATE or advisory both show 'Lock')
wait_blocked() {
  for _ in $(seq 1 100); do
    [ "$(q "select coalesce(wait_event_type,'') from pg_stat_activity where application_name='$1' and state='active' order by query_start desc limit 1")" = "Lock" ] && return 0
    sleep 0.2
  done; echo "FAIL: $1 did not reach Lock wait"; cat /tmp/p12sessB.log 2>/dev/null; exit 1
}
# wait until session $1 is idle-in-transaction AFTER the mining_extract writer ran (not merely after BEGIN)
wait_idletx() {
  for _ in $(seq 1 150); do
    [ "$(q "select (state='idle in transaction' and query ilike '%mining_extract%') from pg_stat_activity where application_name='$1' order by query_start desc limit 1")" = "t" ] && return 0
    sleep 0.2
  done; echo "FAIL: $1 not idle-in-transaction after writer"; cat /tmp/p12sessA.log /tmp/p12sessB.log 2>/dev/null; exit 1
}

mkfifo "$FIFOA"; mkfifo "$FIFOB"
PGAPPNAME=p12sessA psql "$DB_URL" -X -q < "$FIFOA" >/tmp/p12sessA.log 2>&1 & PA=$!
PGAPPNAME=p12sessB psql "$DB_URL" -X -q < "$FIFOB" >/tmp/p12sessB.log 2>&1 & PB=$!
exec 3>"$FIFOA" 4>"$FIFOB"

# ── fixtures: enable mining + a large cooldown ONLY in this disposable stack; ONE user with ONE
#    settled in_space main ship + one active field within mining_extract_radius (default 750) of it. ──
q "update game_config set value='true'  where key='mining_enabled';" >/dev/null
q "update game_config set value='86400' where key='mining_extract_cooldown_seconds';" >/dev/null   # large ⇒ B is cooldown-rejected
# raw throwaway user (the on_auth_user_created_base trigger provisions a base; NO main ship — 0005
# initialize_new_player creates base+units+resources only), so the manual insert below is the SOLE ship.
U=$(q "
  with u as (
    insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated','authenticated','p12conc.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','')
    returning id)
  select id from u;")
[ -n "$U" ] || { echo "FAIL: could not create throwaway user"; exit 1; }
NSHIP=$(q "select count(*) from main_ship_instances where player_id='$U'")
[ "$NSHIP" = "0" ] || { echo "FAIL: user unexpectedly already has $NSHIP main ship(s) — fixture assumption (≤1) broken"; exit 1; }
S=$(q "insert into main_ship_instances (player_id,hull_type_id,status,spatial_state,space_x,space_y,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id) values ('$U','starter_frigate','stationary','in_space',10,10,500,500,50,10,2,3,gen_random_uuid()) returning main_ship_id;")
[ -n "$S" ] || { echo "FAIL: could not create in_space main ship"; exit 1; }
# one active field AT the ship's coordinates (distance 0 ⇒ nearest, well within the 750 radius)
F=$(q "insert into mining_fields (name,space_x,space_y,reward_bundle_json,is_active) values ('$FIELD_NAME',10,10,'{\"items\":[{\"item_id\":\"ore\",\"quantity\":2}]}'::jsonb,true) returning id;")
[ -n "$F" ] || { echo "FAIL: could not create test mining field"; exit 1; }
R1=$(q "select gen_random_uuid()"); R2=$(q "select gen_random_uuid()")

echo "=== Scenario: two DISTINCT extract commands for the SAME ship — B waits on the ship lock, then cooldown-rejects ==="
echo "begin; with r as (select public.mining_extract('$U','$S','$R1') j) select 'A_OK='||(j->>'ok')||' A_EXT='||coalesce(j->>'extraction_id','none') from r;" >&3
wait_idletx p12sessA                                 # A ran the writer, holds the txn (ship lock + uncommitted extraction)
echo "begin; with r as (select public.mining_extract('$U','$S','$R2') j) select 'B_OK='||(j->>'ok')||' B_REASON='||coalesce(j->>'reason','none') from r;" >&4
wait_blocked p12sessB                                # B blocks on the ship FOR UPDATE (step 3, before it can reach the 0143 advisory lock at step 10b)
echo "commit;" >&3                                   # A commits → releases the ship lock; A's extraction is now committed
wait_idletx p12sessB                                 # B proceeds and completes its statement
echo "commit;" >&4

grep -q "A_OK=true" /tmp/p12sessA.log || { echo "FAIL: A did not succeed"; cat /tmp/p12sessA.log; exit 1; }
grep -q "B_OK=false" /tmp/p12sessB.log && grep -q "B_REASON=cooldown" /tmp/p12sessB.log \
  || { echo "FAIL: B did not reject with reason=cooldown"; cat /tmp/p12sessB.log; exit 1; }
N=$(q "select count(*) from mining_extractions where player_id='$U' and field_id='$F'")
[ "$N" = "1" ] || { echo "FAIL: expected exactly 1 extraction for (player, field), got $N"; exit 1; }
echo "  ok: distinct concurrent extracts on one ship → exactly ONE extraction; the loser cooldown-rejected after the winner committed"

echo "MINING-P12 DYNAMIC CONCURRENCY PROOF: ALL PASSED (reachable one-ship invariant; 0143 advisory lock verified structurally as defense-in-depth)"
