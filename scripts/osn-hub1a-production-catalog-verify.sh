#!/usr/bin/env bash
# OSN-HUB-1A / PORT-LAUNCH-1A — STRICTLY READ-ONLY production catalog / ACL / configuration verifier (head 0068).
#
# Answers ONLY: "Does production exactly match the approved dark state at migration head 0068 (PORT-LAUNCH-1A)?"
# It proves production is still dark, coherent, locked down, and world/player-unchanged — and that the seven
# functions 0067 materially changed/added PLUS the two functions 0068 added (reveal_starter_ports,
# get_osn_movement_readiness) are byte-identical (raw stored prosrc) + descriptor-identical to the
# disposable 0001..0068 reference chain. It NEVER enables OSN, mutates data, invokes a game command, creates a
# user/fixture, reveals a port, calls a write-capable RPC, uses a direct DB host, or prints rows/UUIDs/coords/
# player data/function bodies/secrets/connection strings. All production reads run inside ONE
# BEGIN ... ISOLATION LEVEL REPEATABLE READ READ ONLY snapshot (scripts/osn-hub1a-production-catalog-verify.sql)
# that ROLLBACKs. Connection = the established pinned-CA / verify-full / Management-API session-pooler route only.
#
# Modes:
#   selftest    DB-free static safety proof of THIS tooling (SQL allowlist, read-only gate, no-write, conn
#               template, pinned CA, pooler binding, override rejection, migration-literal binding). No secrets.
#   local       Disposable $DB_URL (chain 0001..0068): reconcile the dark-state matrix → OVERALL_PASS=true,
#               and prove the parity comparator (identical accepted; synthetic body/descriptor mismatch rejected).
#   production  Gated, read-only: reference (disposable $DB_URL) + LIVE (pooler) → reconcile production dark-state
#               + byte-identical 9-function parity; final OVERALL_PASS.
set -uo pipefail

MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|local|production) : ;; *) echo "usage: $0 <selftest|local|production>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CA_FILE="$REPO_ROOT/scripts/supabase-prod-ca.crt"
EXPECTED_CA_SHA256="807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa"  # Supabase Root 2021 CA
SQL_FILE="$REPO_ROOT/scripts/osn-hub1a-production-catalog-verify.sql"
MIG68="$REPO_ROOT/supabase/migrations/20260618000068_portlaunch1a_reveal_readiness.sql"
MIG67="$REPO_ROOT/supabase/migrations/20260618000067_osn_hub1a_canonical_location_targets.sql"
MIG66="$REPO_ROOT/supabase/migrations/20260618000066_worldhub1b_a_hidden_ports_eligibility.sql"
EXPECT_MIG="20260618000068"
EXPECT_AUTH_SURFACE="bootstrap_me,cancel_build_order,command_main_ship_space_move,command_main_ship_space_move_to_location,command_main_ship_space_stop,get_combat_reports,get_my_expedition_preview,get_osn_movement_readiness,get_world_map,move_main_ship_to_location,repair_main_ship,request_leave_location,request_main_ship_return,request_retreat,send_fleet_to_location,send_main_ship_expedition,train_units"
PARITY_TAGS="legal core begin resolve dock stop cmd reveal readiness"
INTERNAL_TAGS="lock validate resolve excl legal core begin proc settle dock stop elig assign"
DESC_FIELDS="LANG OWNER SECDEF SP ARGS SRVX ANONX AUTHX PUBX"
# Two public functions are granted only to a non-service role in their migration; their service_role EXECUTE is
# governed by Supabase hosted DEFAULT PRIVILEGES (allowed) which the disposable reference chain does not
# reproduce. So SRVX is EXEMPT from ref-vs-prod parity for these tags:
#   • cmd       (command_main_ship_space_move_to_location, 0067) — authenticated; SRVX asserted as an EXPLICIT,
#                testable hosted-production policy (= allowed) via check_wrapper_srvx (NOT parity, NOT suppressed).
#   • readiness (get_osn_movement_readiness, 0068)             — authenticated; per the established hosted-default
#                lesson its service_role EXECUTE is INTENTIONALLY NOT asserted (the parity would be unreliable);
#                its security is proven by exact-17 surface membership + authenticated=yes / anon=no / PUBLIC=no.
# Strict ref-vs-prod SRVX parity is preserved for every other (explicitly service_role-granted) function,
# INCLUDING reveal_starter_ports (0068), which is explicitly granted to service_role (SRVX=true on both sides).
WRAPPER_TAG="cmd"
WRAPPER_PROD_SRVX_EXPECTED="true"
SRVX_EXEMPT_TAGS="cmd readiness"   # tags whose SRVX is exempt from ref-vs-prod parity (hosted-default reliance)
is_srvx_exempt() { case " $SRVX_EXEMPT_TAGS " in *" $1 "*) return 0;; *) return 1;; esac; }

# ── proven connection/trust helpers (identical to the established WORLD-HUB / ANCHOR verifiers) ──────────────
is_hex64() { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{64}$'; }
validate_ref() { printf '%s' "${1:-}" | grep -qE '^[a-z0-9]{20}$' || fail "invalid/empty project ref"; }
OVERRIDE_VARS="DATABASE_URL PGHOST PGPORT PGUSER PGDATABASE PGHOSTADDR PGSERVICE PGURI PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY PGSSLCRL PGPASSWORD PGOPTIONS PSQLRC"
reject_target_overrides() { local v; for v in $OVERRIDE_VARS; do [ -z "${!v:-}" ] || fail "external target/trust override $v is set"; done; }
ca_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//; s/://g' | tr 'A-Z' 'a-z'; }
verify_ca() {
  local f="$1" n fp
  [ -f "$f" ] || fail "CA file not found: scripts/supabase-prod-ca.crt"
  [ -s "$f" ] || fail "CA file is empty"
  n="$(grep -c 'BEGIN CERTIFICATE' "$f" || true)"; [ "$n" = "1" ] || fail "CA must contain exactly one certificate (found $n)"
  openssl x509 -in "$f" -noout >/dev/null 2>&1 || fail "CA is not a valid PEM certificate"
  openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1 || fail "CA certificate is expired"
  fp="$(ca_fingerprint "$f")"; is_hex64 "$fp" || fail "CA fingerprint not 64 hex"; [ "$fp" = "$EXPECTED_CA_SHA256" ] || fail "CA fingerprint mismatch"
  echo "[ca] SHA-256 fingerprint = $fp"
}
parse_pooler_endpoint() {
  printf '%s' "${1:-}" | jq -er '
    ( if type=="array" then (if length==1 then .[0] else error("array length not exactly 1") end)
      elif type=="object" then . else error("unexpected top-level type") end ) as $e
    | ($e.db_host // error("missing db_host")) as $h | ($e.db_port // error("missing db_port")) as $p
    | (if ($h|type)=="string" and ($h|length)>0 then . else error("empty db_host") end) | "\($h)|\($p)"' 2>/dev/null
}
require_pooler_binding() {
  local h="${1:-}" pt="${2:-}" u="${3:-}" r="${4:-}"; validate_ref "$r"
  printf '%s' "$h" | grep -qE '^[a-z0-9][a-z0-9.-]*\.pooler\.supabase\.com$' || fail "host is not <label>.pooler.supabase.com"
  case "$pt" in 5432|6543) : ;; *) fail "pooler port '$pt' not in {5432,6543}";; esac
  [ "$u" = "postgres.${r}" ] || fail "pooler tenant not postgres.<ref>"
}
build_verifier_conn() { printf 'host=%s port=5432 user=postgres.%s dbname=postgres sslmode=verify-full sslrootcert=%s' "$1" "$2" "$3"; }
mval() { printf '%s\n' "${1:-}" | grep -m1 -E "^$2=" | cut -d= -f2- ; }
is_true()  { [ "${1:-}" = "true" ]  || [ "${1:-}" = "t" ]; }

# ── migration binding: the verifier's expected literals MUST be present verbatim in the checked-out migrations.
assert_migration() {
  [ -f "$MIG68" ] || fail "migration 0068 not found in checkout"
  [ -f "$MIG67" ] || fail "migration 0067 not found in checkout"
  [ -f "$MIG66" ] || fail "migration 0066 not found in checkout"
  local lit
  for lit in "reveal_starter_ports" "get_osn_movement_readiness"; do
    grep -qF "$lit" "$MIG68" || fail "expected literal absent from migration 0068: $lit"
  done
  grep -qE "grant execute on function public.get_osn_movement_readiness\(\) +to authenticated" "$MIG68" \
    || fail "0068 does not grant get_osn_movement_readiness to authenticated"
  grep -qE "grant execute on function public.reveal_starter_ports\(\) +to service_role" "$MIG68" \
    || fail "0068 does not grant reveal_starter_ports to service_role"
  for lit in "b1a00001-0066-4a00-8a00-000000000001" "Haven Reach" "b1a00002-0066-4a00-8a00-000000000002" "Slagworks Anchorage" \
             "b1a00003-0066-4a00-8a00-000000000003" "Driftmarch Waypost" "b1a0a001-0066-4a00-8a00-0000000000a1" \
             "b1a05001-0066-4a00-8a00-000000000051" "is_home_port_eligible" "assign_home_port"; do
    grep -qF "$lit" "$MIG66" || fail "expected literal absent from migration 0066: $lit"
  done
  for lit in "mainship_space_location_target_legal" "mainship_space_begin_move_core" "mainship_space_dock_at_location" \
             "mainship_space_stop" "command_main_ship_space_move_to_location" "clock_timestamp()" "activity <> 'none'"; do
    grep -qF "$lit" "$MIG67" || fail "expected literal absent from migration 0067: $lit"
  done
  grep -qE "grant execute on function public.command_main_ship_space_move_to_location\(uuid, uuid\) to authenticated" "$MIG67" \
    || fail "0067 does not grant the one new wrapper to authenticated"
}

run_sql() { PGCONNECT_TIMEOUT=20 psql "$1" -X -q -A -t -v ON_ERROR_STOP=1 -f "$SQL_FILE"; }

# ── reconcile the dark-state / surface / ACL / descriptor-invariant matrix (A,B,C,D + E invariants) ─────────
# Sets global PASS and ROWS (a markdown table body). Prints only labels/counts/booleans/hashes.
reconcile() {
  local OUT="$1" tag v
  PASS=1; ROWS=""
  chk() { if [ "$2" = "1" ]; then ROWS="${ROWS}| ${1} | PASS | ${3} |\n"; else ROWS="${ROWS}| ${1} | **FAIL** | ${3} |\n"; PASS=0; fi; }
  eq() { [ "$1" = "$2" ] && echo 1 || echo 0; }

  # A — deployment + dark state
  chk "A1 migration head 0068"  "$([ "$(mval "$OUT" HEAD)" = "$EXPECT_MIG" ] && [ "$(mval "$OUT" N_AFTER)" = "0" ] && echo 1 || echo 0)" "head=$(mval "$OUT" HEAD) after=$(mval "$OUT" N_AFTER)"
  chk "A2 send flag (true,1×,jsonb)"  "$([ "$(mval "$OUT" FLAG_SEND_N)" = "1" ] && [ "$(mval "$OUT" FLAG_SEND_TYPE)" = "jsonb" ] && [ "$(mval "$OUT" FLAG_SEND)" = "1" ] && echo 1 || echo 0)" "n=$(mval "$OUT" FLAG_SEND_N) type=$(mval "$OUT" FLAG_SEND_TYPE) val=$(mval "$OUT" FLAG_SEND)"
  chk "A3 space flag (false,1×,jsonb)" "$([ "$(mval "$OUT" FLAG_SPACE_N)" = "1" ] && [ "$(mval "$OUT" FLAG_SPACE_TYPE)" = "jsonb" ] && [ "$(mval "$OUT" FLAG_SPACE)" = "0" ] && echo 1 || echo 0)" "n=$(mval "$OUT" FLAG_SPACE_N) type=$(mval "$OUT" FLAG_SPACE_TYPE) val=$(mval "$OUT" FLAG_SPACE)"
  chk "A4 zero active coord movements" "$(eq "$(mval "$OUT" N_ACTIVE_MOVES)" 0)" "active=$(mval "$OUT" N_ACTIVE_MOVES)"
  chk "A5 no incoherent fleet pointer" "$([ "$(mval "$OUT" N_FLEET_SPACE_PTR)" = "0" ] && [ "$(mval "$OUT" N_PTR_INCOHERENT)" = "0" ] && [ "$(mval "$OUT" N_MOVE_UNPTR)" = "0" ] && echo 1 || echo 0)" "fleet_ptr=$(mval "$OUT" N_FLEET_SPACE_PTR) incoherent=$(mval "$OUT" N_PTR_INCOHERENT) unptr=$(mval "$OUT" N_MOVE_UNPTR)"
  chk "A6 player_home_port empty"  "$(eq "$(mval "$OUT" N_HOMEPORT)" 0)" "rows=$(mval "$OUT" N_HOMEPORT)"
  chk "A7 no base anchor"          "$(eq "$(mval "$OUT" N_BASE_ANCHOR)" 0)" "base_anchors=$(mval "$OUT" N_BASE_ANCHOR)"
  chk "A8 one 30s arrival cron"    "$([ "$(mval "$OUT" N_ARRIVAL_CRON)" = "1" ] && [ "$(mval "$OUT" ARRIVAL_CRON_SCHED)" = "30 seconds" ] && echo 1 || echo 0)" "n=$(mval "$OUT" N_ARRIVAL_CRON) sched=$(mval "$OUT" ARRIVAL_CRON_SCHED)"
  # A9 (PORT-LAUNCH-2B) — pre-reveal: NO current state references a fixed starter port (reveal/recovery-safe).
  chk "A9 no starter-port interaction state" "$([ "$(mval "$OUT" STP_PRESENCE)" = "0" ] && [ "$(mval "$OUT" STP_FLEET)" = "0" ] && [ "$(mval "$OUT" STP_LEGACY_MV)" = "0" ] && [ "$(mval "$OUT" STP_OSN_MV)" = "0" ] && [ "$(mval "$OUT" STP_HOMEPORT)" = "0" ] && echo 1 || echo 0)" "presence=$(mval "$OUT" STP_PRESENCE) fleet=$(mval "$OUT" STP_FLEET) legacy_mv=$(mval "$OUT" STP_LEGACY_MV) osn_mv=$(mval "$OUT" STP_OSN_MV) homeport=$(mval "$OUT" STP_HOMEPORT)"

  # B — hidden-port / world-state protection
  chk "B1 three hidden ports exact" "$([ "$(mval "$OUT" P1_OK)" = "1" ] && [ "$(mval "$OUT" P2_OK)" = "1" ] && [ "$(mval "$OUT" P3_OK)" = "1" ] && [ "$(mval "$OUT" N_ROLED)" = "3" ] && [ "$(mval "$OUT" N_ROLED_UNEXP)" = "0" ] && echo 1 || echo 0)" "p=$(mval "$OUT" P1_OK)$(mval "$OUT" P2_OK)$(mval "$OUT" P3_OK) roled=$(mval "$OUT" N_ROLED) unexp=$(mval "$OUT" N_ROLED_UNEXP)"
  chk "B2 one anchor/port, none extra" "$([ "$(mval "$OUT" A1_OK)" = "1" ] && [ "$(mval "$OUT" A2_OK)" = "1" ] && [ "$(mval "$OUT" A3_OK)" = "1" ] && [ "$(mval "$OUT" N_ANCHOR_LOC)" = "3" ] && [ "$(mval "$OUT" N_ANCHOR_UNEXP)" = "0" ] && echo 1 || echo 0)" "a=$(mval "$OUT" A1_OK)$(mval "$OUT" A2_OK)$(mval "$OUT" A3_OK) loc_anchors=$(mval "$OUT" N_ANCHOR_LOC) unexp=$(mval "$OUT" N_ANCHOR_UNEXP)"
  chk "B3 one docking svc/port, none extra" "$([ "$(mval "$OUT" S1_OK)" = "1" ] && [ "$(mval "$OUT" S2_OK)" = "1" ] && [ "$(mval "$OUT" S3_OK)" = "1" ] && [ "$(mval "$OUT" N_SVC_UNEXP)" = "0" ] && echo 1 || echo 0)" "s=$(mval "$OUT" S1_OK)$(mval "$OUT" S2_OK)$(mval "$OUT" S3_OK) unexp=$(mval "$OUT" N_SVC_UNEXP)"
  chk "B4 original five locations intact" "$(eq "$(mval "$OUT" N_ORIG)" 5)" "intact=$(mval "$OUT" N_ORIG)/5"
  chk "B5 ports hidden from get_world_map" "$([ "$(mval "$OUT" MAP_LEAK)" = "0" ] && [ "$(mval "$OUT" MAP_LEAK_ID)" = "0" ] && echo 1 || echo 0)" "name_leak=$(mval "$OUT" MAP_LEAK) id_leak=$(mval "$OUT" MAP_LEAK_ID)"
  chk "B6 ports home-port ineligible" "$([ "$(mval "$OUT" ELIG1)" = "0" ] && [ "$(mval "$OUT" ELIG2)" = "0" ] && [ "$(mval "$OUT" ELIG3)" = "0" ] && echo 1 || echo 0)" "elig=$(mval "$OUT" ELIG1)$(mval "$OUT" ELIG2)$(mval "$OUT" ELIG3)"

  # C — public authenticated RPC surface (exact 17, no overload, anon limited to get_world_map)
  chk "C1 authenticated surface == 17" "$([ "$(mval "$OUT" AUTH_SURFACE)" = "$EXPECT_AUTH_SURFACE" ] && [ "$(mval "$OUT" N_AUTH)" = "17" ] && [ "$(mval "$OUT" N_AUTH_DISTINCT)" = "17" ] && echo 1 || echo 0)" "n=$(mval "$OUT" N_AUTH) distinct=$(mval "$OUT" N_AUTH_DISTINCT) set_match=$([ "$(mval "$OUT" AUTH_SURFACE)" = "$EXPECT_AUTH_SURFACE" ] && echo 1 || echo 0)"
  chk "C1b new RPC is get_osn_movement_readiness only" "$([ "$(mval "$OUT" EXIST_readiness)" = "1" ] && [ "$(mval "$OUT" D_readiness_AUTHX)" = "true" ] && [ "$(mval "$OUT" D_readiness_ANONX)" = "false" ] && [ "$(mval "$OUT" D_readiness_PUBX)" = "false" ] && [ "$(mval "$OUT" D_readiness_ARGS)" = "" ] && echo 1 || echo 0)" "exist=$(mval "$OUT" EXIST_readiness) auth=$(mval "$OUT" D_readiness_AUTHX) anon=$(mval "$OUT" D_readiness_ANONX) pub=$(mval "$OUT" D_readiness_PUBX) args='$(mval "$OUT" D_readiness_ARGS)'"
  chk "C2 anon limited to get_world_map" "$([ "$(mval "$OUT" ANON_ON_17)" = "get_world_map" ] && [ "$(mval "$OUT" GWM_ANON)" = "1" ] && [ "$(mval "$OUT" GWM_AUTH)" = "1" ] && echo 1 || echo 0)" "anon_on_17='$(mval "$OUT" ANON_ON_17)' gwm_anon=$(mval "$OUT" GWM_ANON) gwm_auth=$(mval "$OUT" GWM_AUTH)"

  # D — internal ACL boundaries (every internal: exists, service_role-only, anon+auth denied)
  local dpass=1 detail=""
  for tag in $INTERNAL_TAGS; do
    if [ "$(mval "$OUT" "I_${tag}_EXIST")" = "1" ] && [ "$(mval "$OUT" "I_${tag}_SRVX")" = "1" ] && [ "$(mval "$OUT" "I_${tag}_ANONX")" = "0" ] && [ "$(mval "$OUT" "I_${tag}_AUTHX")" = "0" ]; then :; else dpass=0; detail="${detail}${tag}!"; fi
  done
  chk "D1 13 internals service_role-only" "$dpass" "${detail:-all 13 exist+service_role-only+anon/auth-denied}"
  chk "D2 catalog tables locked down" "$([ "$(mval "$OUT" SA_CLIENT)" = "0" ] && [ "$(mval "$OUT" LS_CLIENT)" = "0" ] && [ "$(mval "$OUT" PHP_AUTH_WRITE)" = "0" ] && [ "$(mval "$OUT" PHP_ANON)" = "0" ] && [ "$(mval "$OUT" PHP_AUTH_SELECT)" = "1" ] && [ "$(mval "$OUT" PHP_RLS)" = "1" ] && echo 1 || echo 0)" "sa_client=$(mval "$OUT" SA_CLIENT) ls_client=$(mval "$OUT" LS_CLIENT) php_write=$(mval "$OUT" PHP_AUTH_WRITE) php_anon=$(mval "$OUT" PHP_ANON) php_sel=$(mval "$OUT" PHP_AUTH_SELECT) php_rls=$(mval "$OUT" PHP_RLS)"

  # E invariants (per parity tag): exists, plpgsql, owner=postgres, SECDEF, search_path=public, anon/PUBLIC denied.
  # The two authenticated public functions (cmd wrapper 0067, readiness 0068) require AUTHX=true; every other tag
  # — including reveal_starter_ports (service_role-only) — requires AUTHX=false.
  local epass=1 edet=""
  for tag in $PARITY_TAGS; do
    local want_auth="false"; case "$tag" in cmd|readiness) want_auth="true";; esac
    if [ "$(mval "$OUT" "EXIST_${tag}")" = "1" ] \
       && [ "$(mval "$OUT" "D_${tag}_LANG")" = "plpgsql" ] && [ "$(mval "$OUT" "D_${tag}_OWNER")" = "postgres" ] \
       && is_true "$(mval "$OUT" "D_${tag}_SECDEF")" \
       && printf '%s' "$(mval "$OUT" "D_${tag}_SP")" | grep -q 'search_path=public' \
       && [ "$(mval "$OUT" "D_${tag}_ANONX")" = "false" ] && [ "$(mval "$OUT" "D_${tag}_PUBX")" = "false" ] \
       && [ "$(mval "$OUT" "D_${tag}_AUTHX")" = "$want_auth" ]; then :; else epass=0; edet="${edet}${tag}!"; fi
  done
  chk "E0 9 fns secure shape (7×0067 + reveal/readiness×0068)" "$epass" "${edet:-all 9 plpgsql/owner=postgres/SECDEF/search_path=public/anon+PUBLIC-denied; only cmd+readiness authenticated}"
}

# ── parity: raw stored-body hash + descriptor field-by-field, reference vs production (no body/raw printed) ──
hash_of() { local b="${1:-}" raw h; [ -n "$b" ] || return 1; raw="$(printf '%s' "$b" | base64 -d 2>/dev/null || true)"; [ -n "$raw" ] || return 1; h="$(printf '%s' "$raw" | sha256sum | awk '{print $1}')"; is_hex64 "$h" || return 1; printf '%s' "$h"; }
parity() {  # $1=reference OUT  $2=production OUT ; sets PPASS + PROWS
  local R="$1" P="$2" tag f rh ph rv pv
  PPASS=1; PROWS=""
  for tag in $PARITY_TAGS; do
    local ok=1 why="" note="body+descriptor byte-identical"
    rh="$(hash_of "$(mval "$R" "HB_${tag}")" || true)"; ph="$(hash_of "$(mval "$P" "HB_${tag}")" || true)"
    if [ -z "$rh" ] || [ -z "$ph" ]; then ok=0; why="missing-body"; elif [ "$rh" != "$ph" ]; then ok=0; why="body-hash-differs"; fi
    for f in $DESC_FIELDS; do
      # For SRVX-exempt tags (cmd 0067, readiness 0068) service_role EXECUTE is a hosted-platform default the
      # reference can't reproduce → it is NOT a ref-vs-prod parity field for them (cmd is asserted explicitly by
      # check_wrapper_srvx; readiness is intentionally not asserted per the hosted-default lesson). SRVX parity
      # stays STRICT for every other function (incl. reveal_starter_ports). anon/authenticated/PUBLIC + body +
      # all else stay strict for ALL tags.
      if is_srvx_exempt "$tag" && [ "$f" = "SRVX" ]; then note="body+descriptor byte-identical (service_role SRVX exempt: hosted default)"; continue; fi
      rv="$(mval "$R" "D_${tag}_${f}")"; pv="$(mval "$P" "D_${tag}_${f}")"; if [ "$rv" != "$pv" ]; then ok=0; why="${why} ${f}-differs"; fi
    done
    if [ "$ok" = "1" ]; then PROWS="${PROWS}| ${tag} | PASS | ${note} |\n"; else PROWS="${PROWS}| ${tag} | **FAIL** | ${why} |\n"; PPASS=0; fi
  done
}

# Explicit, testable hosted-production ACL CONTRACT for the public wrapper's service_role EXECUTE (NOT a
# tolerated mismatch, NOT ref-vs-prod parity): production MUST report service_role EXECUTE = allowed. Sets
# WSPASS + WROW. Applied ONLY against the genuine production output (the disposable reference lacks the
# platform default, so this is not asserted in local mode's healthy path).
check_wrapper_srvx() {  # $1 = the PRODUCTION output
  local v; v="$(mval "$1" "D_${WRAPPER_TAG}_SRVX")"
  if [ "$v" = "$WRAPPER_PROD_SRVX_EXPECTED" ]; then
    WSPASS=1; WROW="| cmd service_role execute | PASS | expected hosted production policy = allowed (=${v}) |\n"
  else
    WSPASS=0; WROW="| cmd service_role execute | **FAIL** | expected hosted production policy = allowed (true), got '${v:-<absent>}' |\n"
  fi
}

emit_report() {  # $1=title $2=table-header $3=rows $4=verdict
  { echo "## $1"; echo ""; echo "- commit: \`${GITHUB_SHA:-local}\`  run: \`${GITHUB_RUN_ID:-local}\`  expected head: \`${EXPECT_MIG}\`"; echo "";
    echo "$2"; printf "%b" "$3"; echo ""; echo "**OVERALL_PASS=$4**"; } \
  | tee "${VERIFY_SUMMARY_FILE:-/dev/stdout}" | { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && tee -a "$GITHUB_STEP_SUMMARY" >/dev/null || cat >/dev/null; }
}

# ══════════════════════════════ SELFTEST (DB-free) ══════════════════════════════
if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL_FILE" ] || fail "SQL snapshot not found"
  assert_migration
  echo "[selftest] OK: port literals present in 0066; 0067's 7 function names + clock_timestamp + wrapper grant present; reveal/readiness + their grants present in 0068"
  # Comment- and \meta-stripped SQL body for static scanning (statements may span multiple lines).
  CLEAN="$(sed -E 's/--.*//' "$SQL_FILE" | grep -vE '^[[:space:]]*\\')"
  # Allowlist: every ';'-terminated statement begins with an allowed keyword (no ';' appears inside our literals).
  bad="$(printf '%s' "$CLEAN" | tr '\n' ' ' | tr ';' '\n' | sed -E 's/^[[:space:]]+//' | grep -vE '^[[:space:]]*$' \
        | grep -ivE '^(BEGIN TRANSACTION|SET LOCAL|SELECT|WITH|ROLLBACK)\b' | head -1 || true)"
  [ -z "$bad" ] || fail "disallowed SQL statement form: ${bad:0:70}"
  echo "[selftest] OK: SQL statements are BEGIN/SET LOCAL/SELECT/WITH/ROLLBACK only"
  grep -q 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY' "$SQL_FILE" || fail "missing repeatable-read read-only BEGIN"
  grep -q 'SET LOCAL default_transaction_read_only = on' "$SQL_FILE" || fail "missing SET LOCAL read-only"
  grep -qE '^[[:space:]]*ROLLBACK;' "$SQL_FILE" || fail "missing ROLLBACK"
  # No COMMIT and no write/DDL keyword outside quoted string literals (privilege names / catalog refs are quoted).
  printf '%s' "$CLEAN" | grep -iqE '\bCOMMIT\b' && fail "COMMIT statement present (must ROLLBACK only)"
  printf '%s' "$CLEAN" | sed "s/'[^']*'//g" | grep -iqE '\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|COMMIT|CALL|COPY|MERGE)\b' \
    && fail "write/DDL keyword present outside string literals"
  echo "[selftest] OK: no write/DDL keyword outside literals; ROLLBACK present; no COMMIT statement"
  # Read-only gate precedes the first catalog query (scan the comment-stripped body, not the comments).
  gate_ln="$(printf '%s\n' "$CLEAN" | grep -nm1 'transaction_read_only' | cut -d: -f1)"
  q_ln="$(printf '%s\n' "$CLEAN" | grep -nm1 -E 'FROM public\.|has_function_privilege|has_table_privilege|to_regprocedure|get_world_map|is_home_port_eligible|cfg_bool' | cut -d: -f1)"
  [ -n "$gate_ln" ] && [ -n "$q_ln" ] && [ "$gate_ln" -lt "$q_ln" ] || fail "read-only gate ($gate_ln) not before first catalog query ($q_ln)"
  echo "[selftest] OK: read-only gate (line $gate_ln) precedes the first catalog query (line $q_ln)"
  # equality source is raw prosrc, never pg_get_functiondef (scan the comment-stripped body).
  printf '%s' "$CLEAN" | grep -q 'p.prosrc' || fail "parity source is not p.prosrc"
  printf '%s' "$CLEAN" | grep -q 'pg_get_functiondef' && fail "parity uses pg_get_functiondef"
  echo "[selftest] OK: parity source is raw p.prosrc, not pg_get_functiondef"
  # connection template + pinned CA + pooler binding + override rejection (proven helpers).
  c="$(build_verifier_conn aws-0-x.pooler.supabase.com aaaaaaaaaaaaaaaaaaaa "$CA_FILE")"
  printf '%s' "$c" | grep -q 'sslmode=verify-full' || fail "conn missing verify-full"
  printf '%s' "$c" | grep -q 'port=5432' || fail "conn not forced to session 5432"
  printf '%s' "$c" | grep -qF "sslrootcert=$CA_FILE" || fail "conn missing pinned CA"
  printf '%s' "$c" | grep -qE 'sslmode=(require|prefer|allow|disable)|port=6543|sslrootcert=system' && fail "conn uses weaker TLS/port"
  echo "[selftest] OK: conn = verify-full + pinned CA + session 5432 (no weaker TLS/6543)"
  require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa
  ( require_pooler_binding evil.example.com 5432 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad host not rejected" || true
  ( require_pooler_binding aws-0-x.pooler.supabase.com 9999 postgres.aaaaaaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "bad port not rejected" || true
  ( require_pooler_binding aws-0-x.pooler.supabase.com 5432 postgres.WRONG aaaaaaaaaaaaaaaaaaaa ) >/dev/null 2>&1 && fail "unbound tenant not rejected" || true
  echo "[selftest] OK: pooler binding fail-closed (host/port/tenant)"
  parse_pooler_endpoint '{"db_host":"aws-0-x.pooler.supabase.com","db_port":6543}' >/dev/null || fail "single object rejected"
  ( parse_pooler_endpoint '[]' ) >/dev/null 2>&1 && fail "empty array not rejected" || true
  ( parse_pooler_endpoint '[{"db_host":"a.pooler.supabase.com","db_port":1},{"db_host":"b.pooler.supabase.com","db_port":2}]' ) >/dev/null 2>&1 && fail "multi endpoint not rejected" || true
  echo "[selftest] OK: Management-API endpoint parse fail-closed"
  for v in $OVERRIDE_VARS; do if ( export "$v=x"; reject_target_overrides ) >/dev/null 2>&1; then fail "$v override not rejected"; fi; done
  echo "[selftest] OK: target/trust override vars rejected"
  grep -nE 'db\.\$\{|host=db\.' "$0" >/dev/null 2>&1 && fail "a direct per-project host construction is present"
  echo "[selftest] OK: no direct per-project host construction (pooler endpoint only)"
  verify_ca "$CA_FILE"
  echo "OSN-HUB-1A PRODUCTION CATALOG VERIFY SELFTEST: ALL PASSED"
  exit 0
fi

# ══════════════════════════════ LOCAL (disposable proof) ══════════════════════════════
if [ "$MODE" = "local" ]; then
  : "${DB_URL:?DB_URL (disposable 0001..0068 stack) required}"
  assert_migration
  verify_ca "$CA_FILE"
  OUT="$(run_sql "$DB_URL")" || fail "local catalog read failed"
  [ "$(mval "$OUT" RO)" = "on" ] || fail "local read-only transaction not active"
  reconcile "$OUT"
  emit_report "OSN-HUB-1A / PORT-LAUNCH-1A — LOCAL disposable dark-state proof (0001..0068)" "| group | result | detail |
| --- | --- | --- |" "$ROWS" "$([ "$PASS" = "1" ] && echo true || echo false)"
  [ "$PASS" = "1" ] || fail "local dark-state reconcile did not pass on the healthy disposable chain"
  # parity comparator: identical reference accepts (wrapper SRVX excluded from parity); synthetic mismatches reject.
  parity "$OUT" "$OUT"; [ "$PPASS" = "1" ] || fail "parity rejected an identical reference"
  bad(){ printf '%s\n' "$OUT" | sed "$1"; }
  parity "$OUT" "$(bad 's/^HB_legal=.*/HB_legal=Y29ycnVwdA==/')";  [ "$PPASS" = "0" ] || fail "parity ACCEPTED a synthetic body mismatch (internal)"
  parity "$OUT" "$(bad 's/^HB_cmd=.*/HB_cmd=Y29ycnVwdA==/')";      [ "$PPASS" = "0" ] || fail "parity ACCEPTED a synthetic wrapper-BODY mismatch"
  parity "$OUT" "$(bad 's/^D_core_SECDEF=.*/D_core_SECDEF=false/')"; [ "$PPASS" = "0" ] || fail "parity ACCEPTED a synthetic descriptor mismatch (internal)"
  # the WRAPPER keeps STRICT ref-vs-prod parity for anon / authenticated / PUBLIC / body / args — only SRVX is exempt.
  parity "$OUT" "$(bad 's/^D_cmd_ANONX=.*/D_cmd_ANONX=true/')";    [ "$PPASS" = "0" ] || fail "parity ACCEPTED a wrapper anon-grant change"
  parity "$OUT" "$(bad 's/^D_cmd_AUTHX=.*/D_cmd_AUTHX=false/')";   [ "$PPASS" = "0" ] || fail "parity ACCEPTED a wrapper authenticated-grant change"
  parity "$OUT" "$(bad 's/^D_cmd_PUBX=.*/D_cmd_PUBX=true/')";      [ "$PPASS" = "0" ] || fail "parity ACCEPTED a wrapper PUBLIC-grant change"
  # internal service_role parity stays STRICT: flipping an internal SRVX must fail closed.
  parity "$OUT" "$(bad 's/^D_stop_SRVX=.*/D_stop_SRVX=false/')";   [ "$PPASS" = "0" ] || fail "parity ACCEPTED an internal service_role-grant change"
  # the wrapper's SRVX is exempt from ref-vs-prod parity (the local reference value naturally differs from hosted).
  parity "$OUT" "$(bad 's/^D_cmd_SRVX=.*/D_cmd_SRVX=true/')";      [ "$PPASS" = "1" ] || fail "wrapper SRVX wrongly subjected to ref-vs-prod parity"
  # reveal_starter_ports (0068) is in the STRICT parity set: body + every descriptor INCLUDING SRVX must match.
  parity "$OUT" "$(bad 's/^HB_reveal=.*/HB_reveal=Y29ycnVwdA==/')";  [ "$PPASS" = "0" ] || fail "parity ACCEPTED a reveal body mismatch"
  parity "$OUT" "$(bad 's/^D_reveal_SRVX=.*/D_reveal_SRVX=false/')"; [ "$PPASS" = "0" ] || fail "parity ACCEPTED a reveal service_role-grant change (reveal SRVX must stay strict)"
  parity "$OUT" "$(bad 's/^D_reveal_AUTHX=.*/D_reveal_AUTHX=true/')"; [ "$PPASS" = "0" ] || fail "parity ACCEPTED a reveal authenticated-grant change"
  # readiness (0068) STRICT for body/anon/auth/PUBLIC; SRVX EXEMPT (hosted default differs ref-vs-prod).
  parity "$OUT" "$(bad 's/^HB_readiness=.*/HB_readiness=Y29ycnVwdA==/')"; [ "$PPASS" = "0" ] || fail "parity ACCEPTED a readiness body mismatch"
  parity "$OUT" "$(bad 's/^D_readiness_AUTHX=.*/D_readiness_AUTHX=false/')"; [ "$PPASS" = "0" ] || fail "parity ACCEPTED a readiness authenticated-grant change"
  parity "$OUT" "$(bad 's/^D_readiness_ANONX=.*/D_readiness_ANONX=true/')"; [ "$PPASS" = "0" ] || fail "parity ACCEPTED a readiness anon-grant change"
  parity "$OUT" "$(bad 's/^D_readiness_SRVX=.*/D_readiness_SRVX=true/')"; [ "$PPASS" = "1" ] || fail "readiness SRVX wrongly subjected to ref-vs-prod parity (must be hosted-default exempt)"
  echo "[local] OK: parity rejects internal+reveal body/descriptor/SRVX + wrapper/readiness body/anon/auth/PUBLIC mismatches; cmd+readiness SRVX exempt from ref-vs-prod parity"
  # explicit wrapper service_role PRODUCTION-policy contract: allowed(true) → PASS; denied(false) → FAIL CLOSED.
  check_wrapper_srvx "$(bad 's/^D_cmd_SRVX=.*/D_cmd_SRVX=true/')";  [ "$WSPASS" = "1" ] || fail "explicit wrapper service_role policy rejected the allowed (true) value"
  check_wrapper_srvx "$(bad 's/^D_cmd_SRVX=.*/D_cmd_SRVX=false/')"; [ "$WSPASS" = "0" ] || fail "explicit wrapper service_role policy ACCEPTED a denied (false) value"
  echo "[local] OK: explicit wrapper service_role production-policy contract PASSes on allowed(true) and FAILs CLOSED on denied(false)"
  echo "OSN-HUB-1A PRODUCTION CATALOG VERIFY (LOCAL DISPOSABLE PROOF): ALL PASSED"
  exit 0
fi

# ══════════════════════════════ PRODUCTION (gated, read-only) ══════════════════════════════
: "${DB_URL:?DB_URL (disposable reference stack) required}" "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_ID:?}" "${SUPABASE_DB_PASSWORD:?}"
REF="$SUPABASE_PROJECT_ID"; validate_ref "$REF"
reject_target_overrides
assert_migration
for t in curl jq psql openssl base64 sha256sum; do command -v "$t" >/dev/null 2>&1 || { echo "RESULT: BLOCKED — required read-only tooling missing ($t)"; exit 5; }; done
verify_ca "$CA_FILE"

# Reference: disposable 0001..0068 chain.
REFOUT="$(run_sql "$DB_URL")" || fail "reference catalog read failed"
[ "$(mval "$REFOUT" RO)" = "on" ] || fail "reference read-only transaction not active"

# Resolve EXACTLY ONE protected session-pooler endpoint from the Management API (host only; tenant ref-bound).
POOLER="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
  --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  "https://api.supabase.com/v1/projects/${REF}/config/database/pooler" 2>/dev/null)" \
  || { echo "RESULT: BLOCKED — approved production connection failed"; exit 4; }
ENDPOINT="$(parse_pooler_endpoint "$POOLER")" || { echo "RESULT: BLOCKED — Management API not exactly one endpoint"; exit 4; }
PHOST="${ENDPOINT%%|*}"; API_PORT="${ENDPOINT##*|}"
require_pooler_binding "$PHOST" "$API_PORT" "postgres.$REF" "$REF"
CONN="$(build_verifier_conn "$PHOST" "$REF" "$CA_FILE")"
echo "[diag] verifier=${PHOST}:5432 (session pooler); tenant=postgres.<ref>; tls=verify-full; sslrootcert=pinned CA"

# Live production read inside the same one read-only snapshot.
PRODOUT="$(env -i PATH="$PATH" HOME="${RUNNER_TEMP:-/tmp}" PGPASSWORD="$SUPABASE_DB_PASSWORD" PGCONNECT_TIMEOUT=20 \
  psql "$CONN" -X -q -A -t -v ON_ERROR_STOP=1 -f "$SQL_FILE" 2>"${RUNNER_TEMP:-/tmp}/psqlerr")" \
  || { echo "RESULT: BLOCKED — approved production read-only query failed"; exit 4; }
[ "$(mval "$PRODOUT" RO)" = "on" ] || fail "PRODUCTION read-only gate did not report on"
echo "[production] read-only gate passed before any catalog query"

reconcile "$PRODOUT"
parity "$REFOUT" "$PRODOUT"                  # ref↔prod body + descriptors (wrapper SRVX exempt, asserted below)
check_wrapper_srvx "$PRODOUT"                # explicit hosted-production policy: wrapper service_role EXECUTE = allowed
OVERALL="$([ "$PASS" = "1" ] && [ "$PPASS" = "1" ] && [ "$WSPASS" = "1" ] && echo true || echo false)"
emit_report "OSN-HUB-1A / PORT-LAUNCH-1A — production catalog / ACL / configuration verification (head 0068)" "| check | result | detail |
| --- | --- | --- |" "${ROWS}| PARITY (9 fns: 7×0067 + reveal/readiness×0068, ref↔prod; cmd+readiness SRVX exempt) | $([ "$PPASS" = "1" ] && echo PASS || echo '**FAIL**') | byte-identical prosrc + descriptors |\n${WROW}" "$OVERALL"
printf "%b" "$PROWS" >> "${VERIFY_SUMMARY_FILE:-/dev/null}" 2>/dev/null || true

if [ "$OVERALL" = "true" ]; then
  echo "RESULT: PASS — production exactly matches the approved OSN-HUB-1A / PORT-LAUNCH-1A dark state at head 0068"
  exit 0
else
  echo "RESULT: FAIL — production does not match the approved OSN-HUB-1A dark state (see summary)"
  exit 1
fi
