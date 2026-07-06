#!/usr/bin/env bash
# OSN-ENABLEMENT-2E — STRICTLY READ-ONLY post-ENABLE production verifier orchestrator.
#
# Confirms the live production state matches the approved POST-ENABLE baseline (OSN port-to-port ON), separate
# from the enable operation's own transaction log and distinct from every pre-enable verifier (which assert
# the flag false and would now fail by design). NEVER writes, never issues a movement command, never enables/
# disables a flag, never creates a production player. Connection = proven pinned-CA + verify-full session
# pooler; all reads inside one REPEATABLE READ READ ONLY snapshot. Modes: selftest / local / production.
set -uo pipefail
set +x

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local|production) : ;; *) echo "usage: $0 <selftest|local|production>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL="$REPO_ROOT/scripts/osn-postenable-verify.sql"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
GATES_FILE="$REPO_ROOT/src/features/map/osnReleaseGates.ts"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"
P1='b1a00001-0066-4a00-8a00-000000000001'; P2='b1a00002-0066-4a00-8a00-000000000002'; P3='b1a00003-0066-4a00-8a00-000000000003'

# ── proven connection / trust helpers ────────────────────────────────────────────────────────────────────
is_hex64() { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{64}$'; }
validate_ref() { printf '%s' "${1:-}" | grep -qE '^[a-z0-9]{20}$' || fail "invalid/empty project ref"; }
OVERRIDE_VARS="DATABASE_URL PGHOST PGPORT PGUSER PGDATABASE PGHOSTADDR PGSERVICE PGURI PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY PGSSLCRL PGPASSWORD PGOPTIONS PSQLRC"
reject_target_overrides() { local v; for v in $OVERRIDE_VARS; do [ -z "${!v:-}" ] || fail "external target/trust override $v is set"; done; }
ca_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//; s/://g' | tr 'A-Z' 'a-z'; }
verify_ca() { local f="$1" n fp
  [ -f "$f" ] || fail "CA file not found"; [ -s "$f" ] || fail "CA empty"
  n="$(grep -c 'BEGIN CERTIFICATE' "$f" || true)"; [ "$n" = "1" ] || fail "CA must contain exactly one cert (found $n)"
  openssl x509 -in "$f" -noout >/dev/null 2>&1 || fail "CA not valid PEM"; openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1 || fail "CA expired"
  fp="$(ca_fingerprint "$f")"; is_hex64 "$fp" || fail "CA fp not 64 hex"; [ "$fp" = "$EXPECTED_CA_SHA256" ] || fail "CA fingerprint mismatch"; echo "[ca] SHA-256 fingerprint = $fp"; }
parse_pooler_endpoint() { printf '%s' "${1:-}" | jq -er '
  ( if type=="array" then (if length==1 then .[0] else error("array length not exactly 1") end) elif type=="object" then . else error("unexpected") end ) as $e
  | ($e.db_host // error("missing db_host")) as $h | ($e.db_port // error("missing db_port")) as $p
  | (if ($h|type)=="string" and ($h|length)>0 then . else error("empty db_host") end) | "\($h)|\($p)"' 2>/dev/null; }
require_pooler_binding() { local h="${1:-}" pt="${2:-}" u="${3:-}" r="${4:-}"; validate_ref "$r"
  printf '%s' "$h" | grep -qE '^[a-z0-9][a-z0-9.-]*\.pooler\.supabase\.com$' || fail "host not <label>.pooler.supabase.com"
  case "$pt" in 5432|6543) : ;; *) fail "pooler port '$pt' not in {5432,6543}";; esac
  [ "$u" = "postgres.${r}" ] || fail "pooler tenant not postgres.<ref>"; }
build_conn() { printf 'host=%s port=5432 user=postgres.%s dbname=postgres sslmode=verify-full sslrootcert=%s' "$1" "$2" "$3"; }
mval() { printf '%s\n' "${1:-}" | grep -m1 -E "^$2=" | cut -d= -f2- ; }
assert_coord_suppressed() { local f="$1"
  grep -qE 'OSN_COORDINATE_TRAVEL_ENABLED[[:space:]]*=[[:space:]]*true' "$f" && return 1
  grep -qE 'OSN_COORDINATE_TRAVEL_ENABLED[[:space:]]*=[[:space:]]*false' "$f" || return 1; return 0; }

# read-only safety scan of a verifier SQL file (0=safe, 1=unsafe). Strips comments + single-quoted strings,
# then rejects write/DDL keywords and the forbidden movement/reveal function names appearing as CODE.
sql_is_readonly_safe() { local f="$1" clean nostr
  clean="$(sed -E 's/--.*//' "$f")"; nostr="$(printf '%s' "$clean" | sed "s/'[^']*'//g")"
  printf '%s' "$nostr" | grep -iqE '\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|merge|call|copy)\b' && return 1
  printf '%s' "$nostr" | grep -qE 'reveal_starter_ports|mainship_space_begin_move|command_main_ship_space_move|mainship_space_stop' && return 1
  grep -q 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY' "$f" || return 1
  grep -q 'default_transaction_read_only = on' "$f" || return 1
  grep -qE '^[[:space:]]*ROLLBACK;' "$f" || return 1
  printf '%s' "$clean" | grep -iqE '\bcommit\b' && return 1
  return 0; }

# reconcile the verifier markers into a fail-closed OVERALL_PASS (post-enable expectations)
RECON_PASS=1
reconcile() { local OUT="$1"; RECON_PASS=1
  ck() { if [ "${1:-}" != "$2" ]; then echo "  CHECK FAIL: $3 (got '${1:-}', want '$2')"; RECON_PASS=0; fi; }
  ge() { if [ "$(( ${1:-0} ))" -lt "$2" ] 2>/dev/null; then echo "  CHECK FAIL: $3 (got '${1:-}', want >=$2)"; RECON_PASS=0; fi; }
  ck "$(mval "$OUT" RO)" on "read-only transaction active"
  ck "$(mval "$OUT" HEAD)" 20260618000071 "migration head 0071 (OSN-COORD-ENABLE-1B readiness capability)"
  ck "$(mval "$OUT" N_AFTER)" 0 "no migration after 0071"
  # fail-closed flag integrity: each tracked key present EXACTLY once and parseable as a JSON boolean
  ck "$(mval "$OUT" SEND_ROWS)" 1 "mainship_send_enabled present exactly once"
  ck "$(mval "$OUT" SPACE_ROWS)" 1 "mainship_space_movement_enabled present exactly once"
  ck "$(mval "$OUT" COORD_ROWS)" 1 "mainship_coordinate_travel_enabled present exactly once"
  ck "$(mval "$OUT" SEND_BOOL)" 1 "mainship_send_enabled parses as boolean"
  ck "$(mval "$OUT" SPACE_BOOL)" 1 "mainship_space_movement_enabled parses as boolean"
  ck "$(mval "$OUT" COORD_BOOL)" 1 "mainship_coordinate_travel_enabled parses as boolean"
  # actual stored live values vs the approved CURRENT dark baseline (send=true, space=true, coordinate=FALSE)
  ck "$(mval "$OUT" FLAG_SEND)" 1 "mainship_send_enabled true"
  ck "$(mval "$OUT" FLAG_SPACE)" 1 "mainship_space_movement_enabled TRUE (port-to-port enabled)"
  ck "$(mval "$OUT" FLAG_COORD)" 0 "mainship_coordinate_travel_enabled FALSE (free coordinate travel still gated off; observed raw='$(mval "$OUT" COORD_RAW)')"
  ck "$(mval "$OUT" CONFIG_DEVIATIONS)" 0 "no tracked-flag config deviation"
  # OSN-COORD-GATE-1 catalog: the arbitrary-coordinate command surface is authenticated-only and singular
  ck "$(mval "$OUT" COORD_CMD_RESOLVED)" 1 "coordinate command resolves (canonical procedure non-null)"
  ck "$(mval "$OUT" COORD_CMD_PROC_ROWS)" 1 "coordinate command is exactly one pg_proc row in schema public"
  ck "$(mval "$OUT" ACL_COORD_CMD_AUTH)" 1 "command_main_ship_space_move authenticated"
  ck "$(mval "$OUT" ACL_COORD_CMD_ANON_DENIED)" 1 "command_main_ship_space_move anon denied"
  ck "$(mval "$OUT" COORD_CMD_PUBLIC_DENIED)" 1 "command_main_ship_space_move PUBLIC denied (from proacl)"
  ck "$(mval "$OUT" ACL_COORD_WRITER_SVC_ONLY)" 1 "raw coordinate writer (begin_move) service-role-only"
  ck "$(mval "$OUT" ACL_COORD_CORE_SVC_ONLY)" 1 "raw coordinate writer (begin_move_core) service-role-only"
  ck "$(mval "$OUT" COORD_SURFACE_COUNT)" 1 "exactly one authenticated raw-coordinate (float8,float8,uuid) surface"
  ck "$(mval "$OUT" CANON_EXIST)" 3 "3 canonical ports exist"
  ck "$(mval "$OUT" CANON_ACTIVE)" 3 "3 canonical ports active"
  ck "$(mval "$OUT" CANON_HIDDEN)" 0 "0 canonical ports hidden"
  ck "$(mval "$OUT" P1_OK)" 1 "Haven active+identity"; ck "$(mval "$OUT" P2_OK)" 1 "Slagworks active+identity"; ck "$(mval "$OUT" P3_OK)" 1 "Driftmarch active+identity"
  ck "$(mval "$OUT" N_ROLED)" 3 "exactly 3 role-bearing locations"; ck "$(mval "$OUT" N_ROLED_UNEXP)" 0 "no unexpected role-bearing location"
  ck "$(mval "$OUT" MAP_CANON_VISIBLE)" 3 "3 canonical ports in get_world_map"
  ck "$(mval "$OUT" MAP_UNEXPECTED_STARTER)" 0 "no unexpected starter id in the map"
  ck "$(mval "$OUT" MAP_INACTIVE_LEAK)" 0 "no inactive location in the map"
  ck "$(mval "$OUT" ACL_MOVE_TO_LOC_AUTH)" 1 "move-to-location wrapper authenticated"
  ck "$(mval "$OUT" ACL_WRITER_SVC_ONLY)" 1 "OSN writer service-role-only (auth+anon denied)"
  ck "$(mval "$OUT" ACL_DOCK_SVC_ONLY)" 1 "dock primitive service-role-only"
  ck "$(mval "$OUT" ACL_ARRIVAL_SVC_ONLY)" 1 "arrival processor service-role-only"
  ck "$(mval "$OUT" ACL_READINESS_AUTH)" 1 "readiness authenticated"
  ck "$(mval "$OUT" ACL_READINESS_ANON_DENIED)" 1 "readiness anon-denied"
  # OSN-COORD-ENABLE-1B (head 0071): readiness response contract + function attributes (live, single RPC call)
  ck "$(mval "$OUT" RDN_RESOLVED)" 1 "readiness function resolves canonically"
  ck "$(mval "$OUT" RDN_RETTYPE_JSONB)" 1 "readiness return type is jsonb"
  ck "$(mval "$OUT" RDN_SECDEF)" 1 "readiness is SECURITY DEFINER"
  ck "$(mval "$OUT" RDN_SEARCHPATH)" 1 "readiness has hardened search_path=public"
  ck "$(mval "$OUT" RDN_PUBLIC_DENIED)" 1 "readiness PUBLIC execute denied (from proacl)"
  ck "$(mval "$OUT" RDN_HAS_COORD)" 1 "readiness response contains coordinate_travel_available"
  ck "$(mval "$OUT" RDN_COORD_TYPE)" boolean "coordinate_travel_available is a JSON boolean"
  ck "$(mval "$OUT" RDN_COORD_VALUE)" false "coordinate_travel_available is false on the no-auth path"
  ck "$(mval "$OUT" ACL_DOCK_AUTH)" 1 "dock-services read surface authenticated"
  ck "$(mval "$OUT" ACL_DOCK_ANON_DENIED)" 1 "dock-services read surface anon/PUBLIC denied"
  ge "$(mval "$OUT" STRUCT_EXCL)" 1 "fleet movement-owner exclusivity CHECK"
  ck "$(mval "$OUT" STRUCT_IDX_SHIP)" 1 "one-active-move-per-ship index"; ck "$(mval "$OUT" STRUCT_IDX_FLEET)" 1 "one-active-move-per-fleet index"
  ge "$(mval "$OUT" STRUCT_RECEIPT)" 1 "receipt idempotency unique"
  ck "$(mval "$OUT" LEGACY_OSN_OVERLAP)" 0 "no fleet holds both legacy and OSN movement"
  ge "$(mval "$OUT" ELIGIBLE_ACTIVE_PORTS)" 2 "an anchored player has >=1 eligible destination (>=2 active ports)"
}
emit_markers() { local OUT="$1"
  echo "MIGRATION_HEAD=$( [ "$(mval "$OUT" HEAD)" = 20260618000071 ] && echo 0071 || mval "$OUT" HEAD )"
  echo "CANONICAL_STARTER_PORTS_EXPECTED=3"
  echo "CANONICAL_STARTER_PORTS_ACTIVE=$(mval "$OUT" CANON_ACTIVE)"
  echo "CANONICAL_STARTER_PORTS_HIDDEN=$(mval "$OUT" CANON_HIDDEN)"
  echo "AUTHENTICATED_MAP_PORTS_EXPECTED=3"
  echo "AUTHENTICATED_MAP_PORTS_VISIBLE=$(mval "$OUT" MAP_CANON_VISIBLE)"
  echo "MAINSHIP_SEND_ENABLED=$( [ "$(mval "$OUT" FLAG_SEND)" = 1 ] && echo true || echo false )"
  echo "MAINSHIP_SPACE_MOVEMENT_ENABLED=$( [ "$(mval "$OUT" FLAG_SPACE)" = 1 ] && echo true || echo false )"
  # Server-side coordinate gate — the ACTUAL live game_config value read from the DB (1=true/0=false/x=unparseable).
  echo "MAINSHIP_COORDINATE_TRAVEL_ENABLED=$( case "$(mval "$OUT" FLAG_COORD)" in 1) echo true;; 0) echo false;; *) echo "UNPARSEABLE(raw=$(mval "$OUT" COORD_RAW))";; esac )"
  # Frontend compile-time gate (separately checked against osnReleaseGates.ts via assert_coord_suppressed).
  echo "OSN_COORDINATE_TRAVEL_ENABLED_FRONTEND=false"
  # Is the public arbitrary-coordinate command surface still exactly one, authenticated-only?
  echo "COORDINATE_COMMAND_PUBLIC_SURFACE=$( [ "$(mval "$OUT" COORD_CMD_RESOLVED)" = 1 ] && [ "$(mval "$OUT" COORD_CMD_PROC_ROWS)" = 1 ] && [ "$(mval "$OUT" ACL_COORD_CMD_AUTH)" = 1 ] && [ "$(mval "$OUT" ACL_COORD_CMD_ANON_DENIED)" = 1 ] && [ "$(mval "$OUT" COORD_CMD_PUBLIC_DENIED)" = 1 ] && [ "$(mval "$OUT" COORD_SURFACE_COUNT)" = 1 ] && echo authenticated_only || echo UNEXPECTED )"
  echo "COORDINATE_RAW_WRITERS_SERVICE_ROLE_ONLY=$( [ "$(mval "$OUT" ACL_COORD_WRITER_SVC_ONLY)" = 1 ] && [ "$(mval "$OUT" ACL_COORD_CORE_SVC_ONLY)" = 1 ] && echo true || echo false )"
  echo "UNEXPECTED_CONFIG_CHANGES=$(mval "$OUT" CONFIG_DEVIATIONS)"
  # Structural OSN markers — these are catalog/ACL/structure facts, NOT a live player's readiness result.
  echo "PRODUCTION_OSN_READINESS_BOUNDARY_AUTHENTICATED_ONLY=$( [ "$(mval "$OUT" ACL_READINESS_AUTH)" = 1 ] && [ "$(mval "$OUT" ACL_READINESS_ANON_DENIED)" = 1 ] && echo true || echo false )"
  echo "PRODUCTION_OSN_WRITER_SERVICE_ROLE_ONLY=$( [ "$(mval "$OUT" ACL_WRITER_SVC_ONLY)" = 1 ] && [ "$(mval "$OUT" ACL_ARRIVAL_SVC_ONLY)" = 1 ] && echo true || echo false )"
  echo "PRODUCTION_OSN_OWNER_EXCLUSIVITY=$( [ "$(( $(mval "$OUT" STRUCT_EXCL) ))" -ge 1 ] 2>/dev/null && [ "$(mval "$OUT" STRUCT_IDX_SHIP)" = 1 ] && [ "$(mval "$OUT" STRUCT_IDX_FLEET)" = 1 ] && echo true || echo false )"
  echo "PRODUCTION_OSN_RECEIPT_IDEMPOTENCY=$( [ "$(( $(mval "$OUT" STRUCT_RECEIPT) ))" -ge 1 ] 2>/dev/null && echo true || echo false )"
  echo "PRODUCTION_OSN_DOCK_ARRIVAL_CONTRACT=$( [ "$(mval "$OUT" ACL_DOCK_SVC_ONLY)" = 1 ] && [ "$(mval "$OUT" ACL_ARRIVAL_SVC_ONLY)" = 1 ] && echo true || echo false )"
  echo "PRODUCTION_OSN_NO_LEGACY_OVERLAP=$( [ "$(mval "$OUT" LEGACY_OSN_OVERLAP)" = 0 ] && echo true || echo false )"
  echo "PRODUCTION_OSN_PLAYER_READINESS_BEHAVIOR_PROVEN_BY_1B=true"
  # OSN-COORD-ENABLE-1B (head 0071): the readiness coordinate-capability CONTRACT, from the single live RPC call
  # + catalog. AUTHENTICATED_ONLY = auth allowed AND anon denied AND PUBLIC denied. FIELD_PRESENT/TYPE/NO_AUTH_VALUE
  # come from the one no-auth RPC return (no-ship path). DARK_BY_CONFIG is true ONLY when the server gate is false
  # AND the field exists AND is a JSON boolean AND the no-auth return is false — it asserts dark-by-configuration,
  # NOT a claim about an anchored player's runtime value.
  echo "READINESS_RPC_AUTHENTICATED_ONLY=$( [ "$(mval "$OUT" ACL_READINESS_AUTH)" = 1 ] && [ "$(mval "$OUT" ACL_READINESS_ANON_DENIED)" = 1 ] && [ "$(mval "$OUT" RDN_PUBLIC_DENIED)" = 1 ] && echo true || echo false )"
  echo "READINESS_COORDINATE_CAPABILITY_FIELD_PRESENT=$( [ "$(mval "$OUT" RDN_HAS_COORD)" = 1 ] && echo true || echo false )"
  echo "READINESS_COORDINATE_CAPABILITY_FIELD_TYPE=$(mval "$OUT" RDN_COORD_TYPE)"
  echo "READINESS_COORDINATE_CAPABILITY_NO_AUTH_VALUE=$(mval "$OUT" RDN_COORD_VALUE)"
  echo "READINESS_COORDINATE_CAPABILITY_DARK_BY_CONFIG=$( [ "$(mval "$OUT" FLAG_COORD)" = 0 ] && [ "$(mval "$OUT" RDN_HAS_COORD)" = 1 ] && [ "$(mval "$OUT" RDN_COORD_TYPE)" = boolean ] && [ "$(mval "$OUT" RDN_COORD_VALUE)" = false ] && echo true || echo false )"
  # PHASE 9 (head 0069) — the docked-port READ surface ACL, and the read-only guarantee of this verifier.
  echo "DOCK_SERVICES_READ_SURFACE_AUTHENTICATED_ONLY=$( [ "$(mval "$OUT" ACL_DOCK_AUTH)" = 1 ] && [ "$(mval "$OUT" ACL_DOCK_ANON_DENIED)" = 1 ] && echo true || echo false )"
  echo "DOCK_SERVICES_READ_SURFACE_PUBLIC_DENIED=$( [ "$(mval "$OUT" ACL_DOCK_ANON_DENIED)" = 1 ] && echo true || echo false )"
  echo "NO_PRODUCTION_WRITE_PERFORMED=true"
  echo "OVERALL_PASS=$( [ "$RECON_PASS" = 1 ] && echo true || echo false )"
}

# ══════════════════════════════ SELFTEST (DB-free) ══════════════════════════════
if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "verifier SQL not found"
  sql_is_readonly_safe "$SQL" || fail "verifier SQL is not read-only safe (write/DDL or an executable movement/reveal reference)"
  echo "[selftest] OK: verifier is read-only (REPEATABLE READ READ ONLY + ROLLBACK; no write/DDL); no reveal/movement function is callable (forbidden names appear only inside quoted catalog lookups)"
  grep -q "key='mainship_space_movement_enabled'" "$SQL" || fail "verifier does not read the OSN movement flag"
  grep -q "key='mainship_coordinate_travel_enabled'" "$SQL" || fail "verifier does not read the coordinate-travel server flag from the DB"
  grep -q "'FLAG_COORD='" "$SQL" || fail "verifier does not emit the live coordinate-gate value"
  grep -q "'COORD_ROWS='" "$SQL" || fail "verifier lacks the fail-closed coordinate-flag row-existence guard"
  grep -q "'COORD_BOOL='" "$SQL" || fail "verifier lacks the fail-closed coordinate-flag boolean-parse guard"
  grep -q "to_regprocedure('public.command_main_ship_space_move(double precision,double precision,uuid)')" "$SQL" || fail "verifier does not resolve the arbitrary-coordinate command canonically"
  grep -q "'COORD_CMD_PUBLIC_DENIED='" "$SQL" || fail "verifier does not assert PUBLIC-denied from proacl"
  grep -q 'aclexplode' "$SQL" || fail "verifier does not read PUBLIC grant from the catalog ACL"
  grep -q "'COORD_SURFACE_COUNT='" "$SQL" || fail "verifier does not assert a singular arbitrary-coordinate surface"
  grep -q "proargtypes\[0\] = 'double precision'::regtype::oid" "$SQL" || fail "coordinate-surface census must use arg-type OIDs, not a display string"
  grep -q "pg_get_function_identity_arguments" "$SQL" && fail "coordinate-surface census still uses a brittle identity-arguments display string" || true
  grep -q 'get_world_map' "$SQL" || fail "verifier does not test the authenticated map boundary"
  grep -q "to_regprocedure('public.get_osn_movement_readiness" "$SQL" || fail "verifier does not check the readiness ACL"
  # OSN-COORD-ENABLE-1B: readiness response-contract probe (single evaluation) + function attributes
  grep -q 'WITH r AS MATERIALIZED' "$SQL" || fail "verifier does not single-evaluate the readiness RPC probe (no MATERIALIZED CTE)"
  grep -q 'public.get_osn_movement_readiness() AS j' "$SQL" || fail "verifier does not call the readiness RPC once for the contract probe"
  [ "$(grep -cE 'get_osn_movement_readiness\(\)[^'\'']' "$SQL")" = 1 ] || fail "readiness RPC is executed other than exactly once (must be a single call)"
  grep -q "'RDN_HAS_COORD='"   "$SQL" || fail "verifier does not assert coordinate_travel_available presence"
  grep -q "'RDN_COORD_TYPE='"  "$SQL" || fail "verifier does not assert coordinate field type"
  grep -q "'RDN_COORD_VALUE='" "$SQL" || fail "verifier does not assert the no-auth coordinate value"
  grep -q "'RDN_RETTYPE_JSONB='" "$SQL" || fail "verifier does not assert jsonb return type"
  grep -q "'RDN_SECDEF='"      "$SQL" || fail "verifier does not assert SECURITY DEFINER"
  grep -q "'RDN_SEARCHPATH='"  "$SQL" || fail "verifier does not assert hardened search_path"
  grep -q "'RDN_PUBLIC_DENIED='" "$SQL" || fail "verifier does not assert readiness PUBLIC-denied from proacl"
  echo "[selftest] OK: asserts head 0071, the live DB flag values (send/space/coordinate) with fail-closed integrity, the map boundary, the OSN + arbitrary-coordinate command ACL, and the readiness coordinate-capability contract (single RPC probe + secdef/search_path/jsonb/ACL)"
  c="$(build_conn aws-0-x.pooler.supabase.com aaaaaaaaaaaaaaaaaaaa "$CA_FILE")"
  printf '%s' "$c" | grep -q 'sslmode=verify-full' || fail "conn missing verify-full"
  printf '%s' "$c" | grep -q 'port=5432' || fail "conn not session 5432"
  printf '%s' "$c" | grep -qE 'sslmode=(require|prefer|allow|disable)|port=6543|sslrootcert=system' && fail "conn weaker TLS/port/CA" || true
  echo "[selftest] OK: conn = verify-full + pinned CA + session 5432"
  require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa
  ( require_pooler_binding evil.example.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad host not rejected" || true
  for v in $OVERRIDE_VARS; do if ( export "$v=x"; reject_target_overrides ) >/dev/null 2>&1; then fail "$v override not rejected"; fi; done
  echo "[selftest] OK: pooler binding + override rejection"
  assert_coord_suppressed "$GATES_FILE" || fail "real OSN_COORDINATE_TRAVEL_ENABLED is not false"
  echo "[selftest] OK: OSN_COORDINATE_TRAVEL_ENABLED stays false"
  verify_ca "$CA_FILE"
  echo "OSN-POSTENABLE-VERIFY SELFTEST: ALL PASSED"
  exit 0
fi

# ══════════════════════════════ LOCAL (disposable matrix) ══════════════════════════════
if [ "$MODE" = "local" ]; then
  : "${DB_URL:?DB_URL (disposable stack) required}"
  q() { psql "$DB_URL" -X -q -t -A -c "$1"; }
  runv() { psql "$DB_URL" -X -q -A -t -v ON_ERROR_STOP=1 -f "$SQL"; }
  overall() { reconcile "$1"; [ "$RECON_PASS" = 1 ]; }
  flag() { q "update public.game_config set value='$2'::jsonb where key='$1';" >/dev/null; }
  set_active() { for p in "$P1" "$P2" "$P3"; do q "update public.locations set status='active' where id='$p';" >/dev/null; done; }
  set_hidden() { for p in "$P1" "$P2" "$P3"; do q "update public.locations set status='hidden' where id='$p';" >/dev/null; done; }

  # CURRENT baseline (head 0070): ports active, send=true, OSN port-to-port ENABLED (space=true), free
  # coordinate travel still gated OFF (coordinate=false). The disposable stack boots through 0070 so the
  # coordinate key already exists false; we set it explicitly for clarity.
  set_active; flag mainship_send_enabled true; flag mainship_space_movement_enabled true; flag mainship_coordinate_travel_enabled false

  # 1) expected post-enable STRUCTURAL/config state passes (no player, no movement, no behavioral claim — the
  #    live player-journey readiness behavior is proven by OSN-ENABLEMENT-1B, not here).
  OUT="$(runv)"; reconcile "$OUT"; MK="$(emit_markers "$OUT")"; printf '%s\n' "$MK"
  [ "$RECON_PASS" = 1 ] || fail "expected post-enable structural state did not pass"
  printf '%s\n' "$MK" | grep -qx 'MAINSHIP_SPACE_MOVEMENT_ENABLED=true' || fail "space flag not true in markers"
  printf '%s\n' "$MK" | grep -qx 'MAINSHIP_COORDINATE_TRAVEL_ENABLED=false' || fail "coordinate gate not false in markers"
  printf '%s\n' "$MK" | grep -qx 'COORDINATE_COMMAND_PUBLIC_SURFACE=authenticated_only' || fail "coordinate command surface not authenticated_only in markers"
  printf '%s\n' "$MK" | grep -qx 'COORDINATE_RAW_WRITERS_SERVICE_ROLE_ONLY=true' || fail "coordinate raw writers not service-role-only in markers"
  printf '%s\n' "$MK" | grep -qx 'MIGRATION_HEAD=0071' || fail "migration head not 0071 in markers"
  # OSN-COORD-ENABLE-1B readiness coordinate-capability contract markers must all reconcile in the baseline
  for m in READINESS_RPC_AUTHENTICATED_ONLY=true READINESS_COORDINATE_CAPABILITY_FIELD_PRESENT=true \
           READINESS_COORDINATE_CAPABILITY_FIELD_TYPE=boolean READINESS_COORDINATE_CAPABILITY_NO_AUTH_VALUE=false \
           READINESS_COORDINATE_CAPABILITY_DARK_BY_CONFIG=true; do
    printf '%s\n' "$MK" | grep -qx "$m" || fail "readiness contract marker missing/false: $m"
  done
  printf '%s\n' "$MK" | grep -q 'READINESS_COORDINATE_CAPABILITY_DARK=' && fail "emits the disallowed READINESS_COORDINATE_CAPABILITY_DARK marker" || true
  printf '%s\n' "$MK" | grep -qx 'OVERALL_PASS=true' || fail "OVERALL_PASS!=true"
  for m in PRODUCTION_OSN_READINESS_BOUNDARY_AUTHENTICATED_ONLY=true PRODUCTION_OSN_WRITER_SERVICE_ROLE_ONLY=true \
           PRODUCTION_OSN_OWNER_EXCLUSIVITY=true PRODUCTION_OSN_RECEIPT_IDEMPOTENCY=true \
           PRODUCTION_OSN_DOCK_ARRIVAL_CONTRACT=true PRODUCTION_OSN_NO_LEGACY_OVERLAP=true \
           PRODUCTION_OSN_PLAYER_READINESS_BEHAVIOR_PROVEN_BY_1B=true \
           DOCK_SERVICES_READ_SURFACE_AUTHENTICATED_ONLY=true DOCK_SERVICES_READ_SURFACE_PUBLIC_DENIED=true \
           NO_PRODUCTION_WRITE_PERFORMED=true; do
    printf '%s\n' "$MK" | grep -qx "$m" || fail "structural marker missing/false: $m"
  done
  printf '%s\n' "$MK" | grep -q 'AUTHENTICATED_OSN_AVAILABLE' && fail "verifier emits a misleading live-player availability marker" || true
  echo "ok[1] expected post-enable structural/config state passes (flag true; map=3; ACL authenticated-only; writers service-role-only; exclusivity/idempotency/dock-arrival intact; no legacy overlap; behavior attributed to 1B)"

  # 2) OSN flag false fails
  flag mainship_space_movement_enabled false; overall "$(runv)" && fail "OSN flag false still passed"; flag mainship_space_movement_enabled true
  echo "ok[2] OSN flag false: fail-closed"
  # 3) FRONTEND coordinate-travel gate true is detected (compile-time const exposure)
  tmp="$(mktemp)"; echo 'export const OSN_COORDINATE_TRAVEL_ENABLED = true as const' > "$tmp"
  assert_coord_suppressed "$tmp" && { rm -f "$tmp"; fail "coord-travel exposure not detected"; }; rm -f "$tmp"
  echo "ok[3] frontend coordinate-travel gate true: detected and fails"
  # 4) wrong active/hidden port state fails
  set_active; q "update public.locations set status='hidden' where id='$P1';" >/dev/null
  overall "$(runv)" && fail "a hidden canonical port still passed"; set_active
  echo "ok[4] wrong active/hidden port state: fail-closed"
  # 5) authenticated map mismatch fails (an unexpected active starter-family id surfaces in the map)
  ZONE="$(q "select zone_id from public.locations where id='$P1';")"; XID='b1a00009-0066-4a00-8a00-000000000009'
  q "insert into public.locations (id, zone_id, name, location_type, x, y, activity_type, status, physical_role)
     values ('$XID','$ZONE','Rogue Outpost','trade_outpost',5,5,'none','active','unclassified');" >/dev/null
  overall "$(runv)" && fail "unexpected starter-family map exposure still passed"
  q "delete from public.locations where id='$XID';" >/dev/null
  echo "ok[5] authenticated map mismatch (unexpected starter id exposed): fail-closed"
  # 6) unexpected configuration change fails (the OTHER tracked flag deviates)
  flag mainship_send_enabled false; overall "$(runv)" && fail "send-flag deviation still passed"; flag mainship_send_enabled true
  echo "ok[6] unexpected configuration change (send flag deviated): fail-closed"
  # 7) write-capable verifier content is rejected
  tmp="$(mktemp)"; cp "$SQL" "$tmp"; printf "\nupdate public.game_config set value='false'::jsonb where key='mainship_space_movement_enabled';\n" >> "$tmp"
  sql_is_readonly_safe "$tmp" && { rm -f "$tmp"; fail "a write-capable verifier was accepted"; }; rm -f "$tmp"
  echo "ok[7] write-capable verifier content: rejected by the read-only scan"
  # 8) SERVER coordinate-travel flag unexpectedly TRUE fails (the live gate must be false in the dark baseline)
  flag mainship_coordinate_travel_enabled true; overall "$(runv)" && fail "server coordinate flag true still passed"; flag mainship_coordinate_travel_enabled false
  echo "ok[8] server coordinate-travel flag true: fail-closed"
  # 9) coordinate-flag integrity: a MISSING row and a NON-boolean value each fail-closed (cfg_bool would mask
  #    the missing row as a silent false; the row-existence + boolean-parse guards prevent that).
  q "delete from public.game_config where key='mainship_coordinate_travel_enabled';" >/dev/null
  overall "$(runv)" && fail "missing coordinate flag row still passed"
  q "insert into public.game_config(key,value,description) values('mainship_coordinate_travel_enabled','false'::jsonb,'restore') on conflict (key) do update set value='false'::jsonb;" >/dev/null
  flag mainship_coordinate_travel_enabled '"nope"'; overall "$(runv)" && fail "non-boolean coordinate flag still passed"; flag mainship_coordinate_travel_enabled false
  echo "ok[9] coordinate-flag integrity (missing row + non-boolean value): fail-closed"

  # restore disposable dark baseline
  flag mainship_space_movement_enabled false; flag mainship_coordinate_travel_enabled false; set_hidden
  echo "OSN-POSTENABLE-VERIFY LOCAL MATRIX: ALL PASSED"
  exit 0
fi

# ══════════════════════════════ PRODUCTION (gated, read-only — NOT run during 2E build) ══════════════════
: "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}" "${SUPABASE_DB_PASSWORD:?}"
reject_target_overrides
REF="$SUPABASE_PROJECT_ID"; validate_ref "$REF"
for t in curl jq psql openssl; do command -v "$t" >/dev/null 2>&1 || { echo "RESULT: BLOCKED — required tooling missing ($t)"; exit 5; }; done
assert_coord_suppressed "$GATES_FILE" || { echo "RESULT: BLOCKED — OSN_COORDINATE_TRAVEL_ENABLED is not false"; exit 5; }
verify_ca "$CA_FILE"
POOLER="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
  --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/${REF}/config/database/pooler" 2>/dev/null)" || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
ENDPOINT="$(parse_pooler_endpoint "$POOLER")" || { echo "RESULT: BLOCKED — Management API not exactly one endpoint"; exit 4; }
PHOST="${ENDPOINT%%|*}"; API_PORT="${ENDPOINT##*|}"
require_pooler_binding "$PHOST" "$API_PORT" "postgres.$REF" "$REF"
CONN="$(build_conn "$PHOST" "$REF" "$CA_FILE")"
echo "[diag] verifier=${PHOST}:5432 (session pooler); tenant=postgres.<ref>; tls=verify-full; sslrootcert=pinned CA"
OUT="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 \
  psql "$CONN" -X -q -A -t -v ON_ERROR_STOP=1 -f "$SQL" 2>/dev/null)" || { echo "RESULT: BLOCKED — approved production read-only query failed"; exit 4; }
[ "$(mval "$OUT" RO)" = "on" ] || fail "PRODUCTION read-only gate not on"
reconcile "$OUT"; emit_markers "$OUT"
if [ "$RECON_PASS" = 1 ]; then
  echo "RESULT: PASS — production matches the approved POST-ENABLE state (OSN port-to-port ENABLED; ports active; ACL + structure intact)"; exit 0
fi
echo "RESULT: FAIL — production does not match the approved post-enable state (see CHECK FAIL lines)"; exit 1
