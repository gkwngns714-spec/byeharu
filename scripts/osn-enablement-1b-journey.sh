#!/usr/bin/env bash
# OSN-ENABLEMENT-1B — one real authenticated port-to-port OSN journey on a DISPOSABLE chain.
#
# The journey is issued through the ACTUAL public command boundary
# (public.command_main_ship_space_move_to_location) called as ROLE authenticated with auth.uid() = the test
# user — never by inserting a movement row directly. It temporarily sets mainship_space_movement_enabled=true
# ON THE THROWAWAY STACK ONLY, runs ok[1]..ok[9], then restores the flag to false and deletes all fixtures.
# Never touches production. Modes: selftest (DB-free), local (the journey against $DB_URL).
set -uo pipefail
set +x

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local) : ;; *) echo "usage: $0 <selftest|local>" >&2; exit 2;; esac
SELF="${BASH_SOURCE[0]}"
P1='b1a00001-0066-4a00-8a00-000000000001'   # Haven Reach  (origin)
P2='b1a00002-0066-4a00-8a00-000000000002'   # Slagworks Anchorage (destination)
P3='b1a00003-0066-4a00-8a00-000000000003'   # Driftmarch Waypost  (conflicting payload)

# ── SELFTEST (DB-free) — prove this harness exercises the real boundary and is disposable/reversible ───────
if [ "$MODE" = "selftest" ]; then
  grep -q 'command_main_ship_space_move_to_location' "$SELF" || fail "journey does not call the real public command RPC"
  grep -q 'set local role authenticated' "$SELF"            || fail "journey does not assume the authenticated role"
  grep -q "request.jwt.claims" "$SELF"                      || fail "journey does not set auth.uid() via jwt claims"
  grep -qE 'insert into[[:space:]]+(public\.)?main_ship_space_movements' "$SELF" \
    && fail "journey inserts a movement row directly (must go through the RPC)" || true
  grep -q "mainship_space_movement_enabled='false'" "$SELF" || grep -q "flag mainship_space_movement_enabled false" "$SELF" \
    || fail "journey does not restore the OSN flag to false"
  grep -q "delete from auth.users where email like 'osn1bjourney" "$SELF" || fail "journey does not clean up its test user"
  echo "OSN-ENABLEMENT-1B JOURNEY SELFTEST: ALL PASSED (real RPC boundary; authenticated role; jwt auth.uid; flag-restore; cleanup present)"
  exit 0
fi

# ── LOCAL (disposable journey) ───────────────────────────────────────────────────────────────────────────
: "${DB_URL:?DB_URL (disposable stack) required}"
su()  { psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "$1"; }                     # privileged (setup/settle/assert)
flag(){ su "update public.game_config set value='$2'::jsonb where key='$1';" >/dev/null; }
# authrpc <user-uuid> <jsonb-returning-expr> → runs as ROLE authenticated with auth.uid()=<user>; echoes the JSON.
authrpc(){ psql "$DB_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c \
  "begin; do \$\$ begin perform set_config('request.jwt.claims', json_build_object('sub','$1','role','authenticated')::text, true); end \$\$; set local role authenticated; select ($2)::text; reset role; commit;"; }
mov_n(){ su "select count(*) from public.main_ship_space_movements where main_ship_id='$1';"; }
moving_id(){ su "select id from public.main_ship_space_movements where main_ship_id='$1' and status='moving' order by depart_at desc limit 1;"; }

echo "── setup: activate the three canonical ports (direct status update; reveal_starter_ports() NOT called) ──"
for p in "$P1" "$P2" "$P3"; do su "update public.locations set status='active' where id='$p';" >/dev/null; done
flag mainship_send_enabled true
flag mainship_space_movement_enabled false
# unschedule the arrival cron for deterministic settlement (mirrors the dock-0 proof)
su "select cron.unschedule(jobid) from cron.job where jobname='process-mainship-space-arrivals';" >/dev/null 2>&1 || true

echo "── setup: a disposable authenticated user + main ship ANCHORED (present/at_location) at Haven Reach ──"
su "insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','osn1bjourney.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','');" >/dev/null
U="$(su "select id from auth.users where email like 'osn1bjourney.%@example.com' order by created_at desc limit 1;")"
[ -n "$U" ] || fail "test user not created"
su "do \$\$ declare u uuid:='$U'; s uuid:=gen_random_uuid(); f uuid:=gen_random_uuid(); b uuid; z uuid; sec uuid;
begin
  select id into b from public.bases where player_id=u and status='active' order by created_at limit 1;
  select zone_id into z from public.locations where id='$P1'; select sector_id into sec from public.zones where id=z;
  insert into public.main_ship_instances(player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id)
    values(u,'starter_frigate','stationary','at_location',500,500,50,10,2,3,s);
  insert into public.fleets(id,player_id,origin_base_id,status,location_mode,main_ship_id,current_location_id,current_zone_id,current_sector_id)
    values(f,u,b,'present','location',s,'$P1',z,sec);
  insert into public.location_presence(player_id,fleet_id,location_id,zone_id,sector_id,activity_type,status)
    values(u,f,'$P1',z,sec,'none','active');
end \$\$;" >/dev/null
S="$(su "select main_ship_id from public.main_ship_instances where player_id='$U' limit 1;")"
[ -n "$S" ] || fail "main ship not created/anchored"
echo "   user=$U ship=$S anchored at Haven Reach ($P1)"

# ok[1] flag OFF rejects creation with NO write
flag mainship_space_movement_enabled false
R1="$(authrpc "$U" "public.command_main_ship_space_move_to_location('$P2','11111111-1111-1111-1111-111111111111')")"
echo "$R1" | grep -q '"feature_disabled"' || { echo "$R1"; fail "ok[1]: flag-off did not return feature_disabled"; }
[ "$(mov_n "$S")" = "0" ] || fail "ok[1]: a movement row was created while the flag was off"
echo "ok[1] flag-off rejects creation with no write (code=feature_disabled; 0 movement rows)"

# enable OSN on the DISPOSABLE stack only
flag mainship_space_movement_enabled true

# ok[2] flag-on accepts one authenticated port-to-port movement
R2="$(authrpc "$U" "public.command_main_ship_space_move_to_location('$P2','22222222-2222-2222-2222-222222222222')")"
echo "$R2" | grep -q '"ok": *true' || { echo "$R2"; fail "ok[2]: authenticated move was not accepted"; }
[ "$(mov_n "$S")" = "1" ] || fail "ok[2]: expected exactly one movement row"
MID="$(moving_id "$S")"; [ -n "$MID" ] || fail "ok[2]: no moving movement"
su "select 1 from public.main_ship_space_movements where id='$MID' and target_kind='location' and target_location_id='$P2';" | grep -q 1 || fail "ok[2]: movement does not target Slagworks Anchorage"
echo "ok[2] flag-on accepts one authenticated port-to-port movement (ok=true; 1 moving movement → $P2)"

# ok[3] duplicate same request id is idempotent
R3="$(authrpc "$U" "public.command_main_ship_space_move_to_location('$P2','22222222-2222-2222-2222-222222222222')")"
echo "$R3" | grep -q '"ok": *true' || { echo "$R3"; fail "ok[3]: idempotent replay not ok"; }
[ "$(mov_n "$S")" = "1" ] || fail "ok[3]: a second movement row was created on replay"
[ "$(moving_id "$S")" = "$MID" ] || fail "ok[3]: replay produced a different movement"
echo "ok[3] duplicate same request id is idempotent (same movement; still exactly 1 row)"

# ok[4] same request id with different payload is rejected (no new movement)
R4="$(authrpc "$U" "public.command_main_ship_space_move_to_location('$P3','22222222-2222-2222-2222-222222222222')")"
echo "$R4" | grep -q '"request_conflict"' || { echo "$R4"; fail "ok[4]: payload conflict not rejected as request_conflict"; }
[ "$(mov_n "$S")" = "1" ] || fail "ok[4]: a conflicting re-request created a new movement row"
echo "ok[4] same request id + different payload rejected (code=request_conflict; still 1 row)"

# ok[5] ship enters in_transit and settles correctly
su "select 1 from public.main_ship_instances where main_ship_id='$S' and spatial_state='in_transit';" | grep -q 1 || fail "ok[5]: ship not in_transit after the command"
su "select 1 from public.fleets where main_ship_id='$S' and status='moving' and active_space_movement_id='$MID' and active_movement_id is null;" | grep -q 1 || fail "ok[5]: fleet not coherently moving on the OSN movement"
su "update public.main_ship_space_movements set depart_at=now()-interval '2 hours', arrive_at=now()-interval '1 hour' where id='$MID';" >/dev/null   # advance simulated time: whole window in the past, keeps arrive_at>depart_at
N="$(su "select public.process_mainship_space_arrivals();")"; [ "${N:-0}" -ge 1 ] || fail "ok[5]: processor settled 0"
echo "ok[5] ship entered in_transit then the real arrival processor settled it"

# ok[6] arrival at the active canonical port docks / becomes present
su "select 1 from public.main_ship_space_movements where id='$MID' and status='arrived' and terminal_reason='auto_arrival' and target_location_id='$P2';" | grep -q 1 || fail "ok[6]: movement did not arrive at Slagworks"
su "select 1 from public.main_ship_instances where main_ship_id='$S' and status='stationary' and spatial_state='at_location' and space_x is null and space_y is null;" | grep -q 1 || fail "ok[6]: ship not docked/at_location"
su "select 1 from public.fleets where main_ship_id='$S' and status='present' and location_mode='location' and current_location_id='$P2' and active_space_movement_id is null and active_movement_id is null;" | grep -q 1 || fail "ok[6]: fleet not present at Slagworks"
[ "$(su "select count(*) from public.location_presence lp join public.fleets f on f.id=lp.fleet_id where f.main_ship_id='$S' and lp.status='active' and lp.location_id='$P2';")" = "1" ] || fail "ok[6]: not exactly one active presence at Slagworks"
echo "ok[6] arrival docks at Slagworks Anchorage / becomes present (one active presence; at_location)"

# ok[7] no overlapping legacy and OSN movement ownership
[ "$(su "select count(*) from public.fleet_movements fm join public.fleets f on f.id=fm.fleet_id where f.main_ship_id='$S';")" = "0" ] || fail "ok[7]: a legacy fleet_movements row exists for the ship"
[ "$(su "select count(*) from public.fleets where main_ship_id='$S' and active_movement_id is not null and active_space_movement_id is not null;")" = "0" ] || fail "ok[7]: fleet holds both legacy and OSN movement ownership"
echo "ok[7] no overlapping legacy/OSN movement ownership (0 fleet_movements; exclusivity holds)"

# ok[8] frontend/readiness state reflects server truth (authenticated readiness projection)
RD="$(authrpc "$U" "public.get_osn_movement_readiness()")"
echo "$RD" | grep -q '"origin_category": *"anchored"' || { echo "$RD"; fail "ok[8]: readiness not anchored after docking"; }
echo "$RD" | grep -q '"osn_available": *true' || { echo "$RD"; fail "ok[8]: osn_available not true while flag on + anchored"; }
echo "$RD" | grep -q "$P2" && fail "ok[8]: current port still listed as an eligible destination" || true
echo "$RD" | grep -q "$P1" || { echo "$RD"; fail "ok[8]: other active ports not offered as destinations"; }
echo "ok[8] readiness reflects server truth (anchored at Slagworks; osn_available=true; current port excluded; others eligible)"

# ok[9] cleanup restores disposable state and the flag
su "delete from auth.users where email like 'osn1bjourney.%@example.com';" >/dev/null   # cascades ship/fleet/movement/presence
flag mainship_space_movement_enabled false
for p in "$P1" "$P2" "$P3"; do su "update public.locations set status='hidden' where id='$p';" >/dev/null; done
[ "$(su "select count(*) from auth.users where email like 'osn1bjourney.%@example.com';")" = "0" ] || fail "ok[9]: fixture user remains"
[ "$(su "select count(*) from public.main_ship_instances where player_id not in (select id from auth.users);")" = "0" ] || fail "ok[9]: orphan ship remains"
[ "$(su "select (value)::text from public.game_config where key='mainship_space_movement_enabled';")" = "false" ] || fail "ok[9]: OSN flag not restored to false"
[ "$(su "select count(*) from public.locations where id in ('$P1','$P2','$P3') and status<>'hidden';")" = "0" ] || fail "ok[9]: starter ports not restored to hidden"
echo "ok[9] cleanup restores disposable state and mainship_space_movement_enabled=false (no fixtures; ports hidden again)"

echo "OSN-ENABLEMENT-1B JOURNEY: ALL PASSED"
