#!/usr/bin/env bash
# OSN-COORD-GATE-1 — disposable proof for the server-authoritative coordinate-travel gate (migration 0070).
# Boots a throwaway local chain and exercises public.command_main_ship_space_move through the REAL authenticated
# boundary. It writes only disposable fixtures; it never touches production, Trading, wallet, market, ports,
# player_home_port, or bases. Modes: selftest (DB-free) / local.
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local) : ;; *) echo "usage: $0 <selftest|local>" >&2; exit 2;; esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIG="$REPO_ROOT/supabase/migrations/20260618000070_osn_coord_gate_server_authoritative.sql"
P1='b1a00001-0066-4a00-8a00-000000000001'

if [ "$MODE" = "selftest" ]; then
  [ -f "$MIG" ] || fail "migration not found"
  grep -q "'mainship_coordinate_travel_enabled', 'false'" "$MIG" || fail "server gate key not seeded false"
  grep -q "cfg_bool('mainship_coordinate_travel_enabled')" "$MIG" || fail "raw command does not consult the server gate"
  grep -q "coordinate_travel_disabled" "$MIG" || fail "no deterministic coordinate_travel_disabled reject"
  grep -q "create or replace function public.command_main_ship_space_move(" "$MIG" || fail "raw command not re-created"
  grep -q "public.mainship_space_begin_move(v_player, v_ship, v_cx, v_cy, p_request_id)" "$MIG" || fail "delegation to the private writer not preserved"
  # the gate must reject BEFORE the ship read / writer delegation (no lock/side effect on denial)
  GATE_LN=$(grep -n "cfg_bool('mainship_coordinate_travel_enabled')" "$MIG" | head -1 | cut -d: -f1)
  SHIP_LN=$(grep -n "select main_ship_id into v_ship" "$MIG" | head -1 | cut -d: -f1)
  [ -n "$GATE_LN" ] && [ -n "$SHIP_LN" ] && [ "$GATE_LN" -lt "$SHIP_LN" ] || fail "gate is not before the ship read"
  # MUST NOT touch the location-target command, the other flags, or any out-of-scope system. Checks run on the
  # COMMENT-STRIPPED SQL (the header legitimately NAMES these as "not touched").
  CLEAN="$(sed -E 's/--.*//' "$MIG")"
  printf '%s' "$CLEAN" | grep -q "command_main_ship_space_move_to_location" && fail "migration touches the location-target command" || true
  printf '%s' "$CLEAN" | grep -qiE "mainship_space_movement_enabled', '|mainship_send_enabled" && fail "migration alters another feature flag's value" || true
  printf '%s' "$CLEAN" | grep -qiE "world_sites|player_home_port|player_wallet|market_offers|trade_|location_services|base_resources|insert into public.(locations|space_anchors|bases)" && fail "migration touches an out-of-scope system" || true
  echo "OSN-COORD-GATE SELFTEST: ALL PASSED (server gate seeded false; raw command gated before ship read; delegation preserved; location-target + other systems untouched)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
q() { psql "$DB_URL" -X -q -t -A -c "$1"; }
authcall() { psql "$DB_URL" -X -q -t -A -c \
  "begin; do \$\$ begin perform set_config('request.jwt.claims', json_build_object('sub','$1','role','authenticated')::text, true); end \$\$; set local role authenticated; select ($2)::text; reset role; commit;"; }
mkuser() { q "insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),'authenticated','authenticated','cg.'||replace(gen_random_uuid()::text,'-','')||'@example.com','',now(),now(),now(),'','','','');" >/dev/null
  q "select id from auth.users where email like 'cg.%@example.com' order by created_at desc limit 1;"; }
mkship_in_space() { q "insert into public.main_ship_instances(player_id,hull_type_id,status,spatial_state,hp,max_hp,cargo_capacity,support_capacity,captain_slots,module_slots,main_ship_id,space_x,space_y)
  values('$1','starter_frigate','stationary','in_space',500,500,50,10,2,3,gen_random_uuid(),0,0);" >/dev/null; }
code() { printf '%s' "$1" | grep -oE '"code" *: *"[a-z_]+"' | head -1 | grep -oE '[a-z_]+"$' | tr -d '"'; }

# ok[1] server gate defaults false on a fresh chain (boots through 0070)
[ "$(q "select value from public.game_config where key='mainship_coordinate_travel_enabled';")" = "false" ] || fail "ok[1] server gate not defaulted false"
echo "ok[1] server coordinate gate defaults false"

# ok[6] anon cannot execute the raw command
[ "$(q "select has_function_privilege('anon','public.command_main_ship_space_move(double precision, double precision, uuid)','EXECUTE');")" = "f" ] || fail "ok[6] anon can execute the raw command"
[ "$(q "select has_function_privilege('authenticated','public.command_main_ship_space_move(double precision, double precision, uuid)','EXECUTE');")" = "t" ] || fail "authenticated cannot execute the raw command"
echo "ok[6] anonymous access denied (authenticated retained)"

# Set up an OSN-eligible (in_space) ship so a denial can be checked for side effects.
U1="$(mkuser)"; mkship_in_space "$U1"

# ok[2] authenticated raw call rejected while the server gate is false
R="$(authcall "$U1" "public.command_main_ship_space_move(200::double precision, 100::double precision, gen_random_uuid())")"
[ "$(code "$R")" = "coordinate_travel_disabled" ] || { echo "$R"; fail "ok[2] raw call not rejected while gate false"; }
echo "$R" | grep -q '"ok": *false' || { echo "$R"; fail "ok[2] not ok:false"; }
echo "ok[2] authenticated raw coordinate command rejected while server gate false"

# ok[3] the denied call created NO movement / fleet / presence and did not mutate ship state
MV0=$(q "select count(*) from public.main_ship_space_movements;"); FL0=$(q "select count(*) from public.fleets;")
PR0=$(q "select count(*) from public.location_presence;"); SS0=$(q "select spatial_state from public.main_ship_instances where player_id='$U1';")
authcall "$U1" "public.command_main_ship_space_move(300::double precision, 150::double precision, gen_random_uuid())" >/dev/null
MV1=$(q "select count(*) from public.main_ship_space_movements;"); FL1=$(q "select count(*) from public.fleets;")
PR1=$(q "select count(*) from public.location_presence;"); SS1=$(q "select spatial_state from public.main_ship_instances where player_id='$U1';")
[ "$MV0" = "$MV1" ] && [ "$FL0" = "$FL1" ] && [ "$PR0" = "$PR1" ] && [ "$SS0" = "$SS1" ] || fail "ok[3] denied call had a side effect (mv $MV0->$MV1 fl $FL0->$FL1 pr $PR0->$PR1 ss $SS0->$SS1)"
echo "ok[3] denial creates no movement/fleet/presence and no ship-state mutation"

# ok[5] the location-target command is NOT rejected by the coordinate gate (governed by movement_enabled)
RL="$(authcall "$U1" "public.command_main_ship_space_move_to_location('$P1'::uuid, gen_random_uuid())")"
[ "$(code "$RL")" = "coordinate_travel_disabled" ] && { echo "$RL"; fail "ok[5] location-target wrongly blocked by coordinate gate"; } || true
[ "$(code "$RL")" = "feature_disabled" ] && { echo "$RL"; fail "ok[5] location-target reports movement disabled (flag should be true)"; } || true
echo "ok[5] location-target command unaffected by the coordinate gate (code=$(code "$RL"))"

# ok[4] with the gate ENABLED in the disposable stack only, a valid coordinate move works
q "update public.game_config set value='true' where key='mainship_coordinate_travel_enabled';" >/dev/null
RE="$(authcall "$U1" "public.command_main_ship_space_move(400::double precision, 250::double precision, gen_random_uuid())")"
echo "$RE" | grep -q '"ok": *true' || { echo "$RE"; fail "ok[4] enabled coordinate move did not succeed"; }
echo "$RE" | grep -q '"movement_id"' || { echo "$RE"; fail "ok[4] enabled move created no movement_id"; }
[ "$(q "select count(*) from public.main_ship_space_movements where status='moving';")" -ge 1 ] || fail "ok[4] no moving movement row created"
echo "ok[4] raw coordinate movement works only after the gate is enabled locally"

# ok[7] regression: idempotency holds on the enabled path (same request_id → same movement, no duplicate)
RID=$(q "select gen_random_uuid();")
# stop the active move first so a fresh one is admissible (use a second user to avoid in_transit conflict)
U2="$(mkuser)"; mkship_in_space "$U2"
RA="$(authcall "$U2" "public.command_main_ship_space_move(120::double precision, 90::double precision, '$RID'::uuid)")"
echo "$RA" | grep -q '"ok": *true' || { echo "$RA"; fail "ok[7] first enabled move failed"; }
MID1=$(printf '%s' "$RA" | grep -oE '"movement_id": *"[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
RB="$(authcall "$U2" "public.command_main_ship_space_move(120::double precision, 90::double precision, '$RID'::uuid)")"
MID2=$(printf '%s' "$RB" | grep -oE '"movement_id": *"[0-9a-f-]+"' | grep -oE '[0-9a-f-]{36}')
[ -n "$MID1" ] && [ "$MID1" = "$MID2" ] || fail "ok[7] idempotency broke (mid1=$MID1 mid2=$MID2)"
[ "$(q "select count(*) from public.main_ship_space_movements where player_id='$U2';")" = "1" ] || fail "ok[7] duplicate movement created on replay"
echo "ok[7] enabled-path idempotency + Dock-0/begin_move delegation intact"

q "update public.game_config set value='false' where key='mainship_coordinate_travel_enabled';" >/dev/null
q "delete from auth.users where email like 'cg.%@example.com';" >/dev/null
echo "OSN-COORD-GATE LOCAL MATRIX: ALL PASSED"
