#!/usr/bin/env bash
# COORDINATE-TRAVEL ACTIVATION runner — wraps the ONE free-coordinate-travel flip operation
# scripts/activate-coordinate-travel.sql (FULL_CAPACITY_PLAN §B ladder: the reachability
# prerequisite for the exploration/mining rungs; WORLD_RECON_F1.md §7). ██ HUMAN TOOL ██ — never
# wired into CI; nothing flips at build time; each `run` is the human's recorded go decision.
#
# The activate-captains.sh pattern, coordinate-travel domain. Modes:
#   selftest — DB-free static safety: the operation writes game_config ONLY, via the owned
#              set_game_config writer, on exactly ONE key (mainship_coordinate_travel_enabled →
#              true — the ONE write), never another flag and never a table/DDL; preconditions on
#              the COORD-GUARD migration 0178 AND pins the GUARDED prosrc of the move command via
#              the resolver-CALL token (assignment form) PAIRED with the unguarded-read-GONE
#              negative check (the pair is the real teeth) plus the old-3-arg-gone check; asserts
#              the readiness-capability + stop-guard + anchors-nonempty + reachability + envelope
#              smokes are present; is one timed BEGIN..COMMIT; contains NO psql meta-command
#              (management-API compatible); keeps its ROLLBACK section commented out (flag-only,
#              with the in-flight-settle citation); and documents the NO-client-PR fact (the
#              coordinate UI is server-readiness-driven via coordinate_travel_available).
#   run      — execute against $DB_URL (prod session-pooler conn string or a staging clone) and
#              assert every stage marker. Requires the typed confirm token as the 2nd arg.
#              No local psql on this machine? Paste the .sql into the Supabase Dashboard SQL
#              editor / management-API runner instead — it is self-contained, self-asserting,
#              and meta-command-free.
#
#   bash scripts/activate-coordinate-travel.sh selftest
#   bash scripts/activate-coordinate-travel.sh run ACTIVATE_COORD_TRAVEL     # DB_URL required
#
# AFTER a green run (NO client PR — the coordinate UI mounts off the server readiness projection;
# the ship-id passthrough already shipped WITH the COORD-GUARD slice):
#   1. Manual smoke: anchor a ship at a port → open the map → tap empty space → crosshair + Move
#      control mount → command departs → Stop works mid-flight; on a multi-ship account the tap
#      moves the SELECTED ship, and an id-less direct API call at N>1 gets the clean fail-closed
#      no_ship reject.
#   2. THEN the exploration/mining flips (activate-exploration / activate-mining) — their
#      reachability prerequisite is now satisfied.
# Rollback: the commented section at the bottom of the .sql (the ONE flag only; in-flight
# coordinate movements settle server-side regardless — the arrival processor reads no flag).
set -uo pipefail
set +x
MODE="${1:-}"
fail() { echo "FAIL: $1" >&2; exit 1; }
case "$MODE" in selftest|run) : ;; *) echo "usage: $0 <selftest|run [ACTIVATE_COORD_TRAVEL]>" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OP_SQL="$REPO_ROOT/scripts/activate-coordinate-travel.sql"
CONFIRM_TOKEN="ACTIVATE_COORD_TRAVEL"
MARKERS="ACTIVATE_COORD_TRAVEL_PASS_PRECONDITIONS ACTIVATE_COORD_TRAVEL_PASS_STAGE1 ACTIVATE_COORD_TRAVEL_PASS_SMOKE"
PASS_LINE="COORDINATE TRAVEL ACTIVATION PASS"

[ -f "$OP_SQL" ] || fail "operation SQL not found"

if [ "$MODE" = "selftest" ]; then
  CLEAN="$(sed -E 's/--.*//' "$OP_SQL")"   # strip comments: the ROLLBACK section must vanish here

  # management-API compatibility: NO psql meta-command anywhere (nothing for a runner to strip).
  grep -qE '^[[:space:]]*\\' "$OP_SQL" && fail "operation contains a psql meta-command (must be management-API compatible)" || true

  # one explicit, timed BEGIN..COMMIT; gated on the COORD-GUARD prep migration.
  printf '%s' "$CLEAN" | grep -qiE '\bbegin;' || fail "operation must open a transaction"
  printf '%s' "$CLEAN" | grep -qiE '\bcommit;' || fail "operation must COMMIT (this one persists — it is the activation)"
  n="$(printf '%s' "$CLEAN" | grep -ciE '^[[:space:]]*(begin|commit);' || true)"
  [ "$n" = "2" ] || fail "operation must be exactly ONE BEGIN..COMMIT (found $n txn verbs)"
  printf '%s' "$CLEAN" | grep -q 'lock_timeout' && printf '%s' "$CLEAN" | grep -q 'statement_timeout' || fail "operation must set timeouts"
  printf '%s' "$CLEAN" | grep -q "20260618000178" || fail "operation must precondition on the 0178 COORD-GUARD migration"

  # the prosrc pin PAIR — the real teeth: the resolver CALL (assignment form) asserted live in the
  # deployed move command BEFORE the flip, AND the old unguarded derivation asserted GONE.
  printf '%s' "$CLEAN" | grep -qF "v_ship := public.mainship_resolve_owned_ship(v_player, p_main_ship_id)" || fail "missing the resolver-call prosrc pin (assignment form) for the move command"
  printf '%s' "$CLEAN" | grep -qF "where player_id = v_player" || fail "missing the unguarded-read-is-GONE prosrc pin (the pair's negative half)"
  printf '%s' "$CLEAN" | grep -qF "command_main_ship_space_move(double precision, double precision, uuid, uuid)" || fail "missing the 4-arg guarded-move identity pin"
  printf '%s' "$CLEAN" | grep -qF "command_main_ship_space_move(double precision, double precision, uuid)') is not null" || fail "missing the old-3-arg-identity-gone precondition"
  printf '%s' "$CLEAN" | grep -qF "command_main_ship_space_stop(uuid, uuid)" || fail "missing the guarded-stop (0083) pin"
  printf '%s' "$CLEAN" | grep -qF "get_osn_movement_readiness(uuid)" || fail "missing the readiness-RPC existence pin"
  printf '%s' "$CLEAN" | grep -qF "coordinate_travel_available" || fail "missing the readiness coordinate-capability derivation pin"

  # writes: ONLY the owned set_game_config writer, exactly ONE call site, exactly the one key/value;
  # NEVER another flag, NEVER a table, NEVER DDL.
  n="$(printf '%s' "$CLEAN" | grep -c 'set_game_config(' || true)"
  [ "$n" = "1" ] || fail "operation must have exactly 1 set_game_config call site — the ONE write (found $n)"
  printf '%s' "$CLEAN" | grep -qF "set_game_config('mainship_coordinate_travel_enabled', 'true'::jsonb)" || fail "missing mainship_coordinate_travel_enabled -> true"
  printf '%s' "$CLEAN" | grep -qiE "set_game_config\('?[a-z_]*'?, *'false'" && fail "operation sets a flag to false (rollback must stay commented)" || true
  printf '%s' "$CLEAN" | grep -qE "set_game_config\('(exploration_enabled|mining_enabled|mainship_space_movement_enabled|trade_market_enabled|team_command_enabled|captain_assignment_enabled|captain_progression_enabled)'" \
    && fail "operation rewrites another rung's key (one observable change per window)" || true
  printf '%s' "$CLEAN" | grep -qiE '(insert[[:space:]]+into|update[[:space:]]+public\.|delete[[:space:]]+from)' && fail "operation writes a table directly (set_game_config only)" || true
  printf '%s' "$CLEAN" | grep -qiE '\b(create|alter|drop|truncate)[[:space:]]' && fail "operation contains DDL (forbidden)" || true
  printf '%s' "$CLEAN" | grep -qiE '^[[:space:]]*(grant|revoke)[[:space:]]' && fail "operation changes an ACL (forbidden — ACLs are migration 0178 territory)" || true

  # smoke + rationale are documented/asserted: markers, the reachability math, the envelope pin,
  # the no-client-PR note, and the flag-only rollback with the in-flight-settle citation.
  for m in $MARKERS; do grep -q "$m" "$OP_SQL" || fail "missing stage marker: $m"; done
  grep -q "$PASS_LINE" "$OP_SQL"                                   || fail "missing final PASS line"
  printf '%s' "$CLEAN" | grep -qF "public.exploration_sites"        || fail "smoke does not count exploration_sites (the reachability rationale)"
  printf '%s' "$CLEAN" | grep -qF "public.mining_fields"            || fail "smoke does not count mining_fields (the reachability rationale)"
  printf '%s' "$CLEAN" | grep -qF "exploration_scan_radius"         || fail "reachability rationale must reference the 750-unit interaction radius knobs"
  printf '%s' "$CLEAN" | grep -qF "space_anchors"                   || fail "reachability rationale must compute the live anchor->site distance"
  printf '%s' "$CLEAN" | grep -qF "no active dockable location anchors" || fail "missing the anchors-nonempty precondition (a NULL distance record must not pass as proof)"
  printf '%s' "$CLEAN" | grep -qE '\-10000|10000'                   || fail "missing the +-10000 movement-envelope sanity pin"
  grep -q "NO CLIENT PR IS NEEDED" "$OP_SQL"                        || fail "operation must document the no-client-PR verification (server-readiness-driven UI)"
  grep -q "isCoordinateTargetingActionable" "$OP_SQL"               || fail "the no-client-PR note must cite the client gate (osnReadiness/GalaxyMap)"
  grep -qi "ROLLBACK (manual" "$OP_SQL"                             || fail "missing the marked manual ROLLBACK section"
  grep -q "process_mainship_space_arrivals" "$OP_SQL"               || fail "rollback must cite the flag-independent in-flight settle path"

  echo "COORDINATE TRAVEL ACTIVATION SELFTEST: ALL PASSED (set_game_config-only on the ONE key; 0178-guard-gated single timed BEGIN..COMMIT with the resolver-call + unguarded-read-gone prosrc pin pair; no meta-commands; no other-rung rewrites; no table writes/DDL/ACL; anchors + reachability + envelope smokes present; rollback commented with the in-flight-settle citation; no-client-PR documented)"
  exit 0
fi

# ── run: the human's activation execution ─────────────────────────────────────────────────────────
[ "${2:-}" = "$CONFIRM_TOKEN" ] || fail "refusing to run: pass the exact confirm token $CONFIRM_TOKEN as the 2nd argument"
: "${DB_URL:?DB_URL (the target database conn string) required}"
out="$(psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$OP_SQL" 2>&1)" || { echo "$out" >&2; fail "activation operation FAILED — nothing was committed (all-or-nothing txn)"; }
printf '%s\n' "$out"
for m in $MARKERS; do printf '%s' "$out" | grep -q "$m" || fail "missing marker $m in the run output"; done
printf '%s' "$out" | grep -q "$PASS_LINE" || fail "operation did not report the final PASS line"
echo "COORDINATE TRAVEL ACTIVATION: OVERALL_PASS — free coordinate travel live (no client PR needed; the map's coordinate UI mounts off coordinate_travel_available). Next: manual smoke (tap empty space -> move -> stop), then the exploration/mining flips."
