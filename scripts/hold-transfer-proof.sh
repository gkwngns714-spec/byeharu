#!/usr/bin/env bash
# ITEMS-HAVE-A-PLACE — disposable proof orchestrator for migration 0333 (item_types.volume_m3 +
# base_items + base_items_add/take + hold_capacity_m3/hold_used_m3 + transfer_items + get_my_hold +
# the get_my_docked_store item projection).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends
#              in ROLLBACK), toggles every flag it needs ONLY inside the txn, provisions through the
#              REAL RPCs (commission_first_main_ship / reward_grant / base_items_add — never a direct
#              player_inventory, base_items or item_transfer_receipts insert), and exercises the four
#              design laws plus the full reject envelope.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the property proof).
# The shared blocks live in scripts/lib/trade-proof-lib.sh (this is a port-service proof, same family
# as salvage-market / port-shop); only this proof's specifics live here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/hold-transfer-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="HOLD_PASS_DARK_GATE HOLD_PASS_VOLUMES HOLD_PASS_ROUNDTRIP HOLD_PASS_CAPACITY HOLD_PASS_LAW3 HOLD_PASS_ISOLATION HOLD_PASS_ATOMIC HOLD_PASS_GUARDS HOLD_PASS_READS HOLD_PASS_ACL"
PASS_LINE="ITEMS-HAVE-A-PLACE PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── every flag this proof needs is toggled ONLY strictly inside the begin;..rollback; scope. ─────
  tp_assert_flags_inside_txn "$SQL" station_storage_enabled team_command_enabled \
                                    fleet_movement_unified_enabled fleet_control_enabled

  # ── the DARK block sets its own precondition rather than trusting the seed. Production has
  #    station_storage_enabled TRUE and a fresh chain has it false; asserting either would be
  #    asserting a WORLD, not a property (the 0300 lights-on lesson). ─────────────────────────────
  grep -qE "update public\.game_config set value='false'::jsonb where key='station_storage_enabled';" "$SQL" \
    || fail "the dark block does not FORCE station_storage_enabled false — it is trusting the seed"

  # ── all three starter-port identities (fixed 0066 UUIDs) are asserted; the proof needs a SECOND
  #    port to have anything to be remote FROM. ───────────────────────────────────────────────────
  for pid in b1a00001-0066-4a00-8a00-000000000001 \
             b1a00002-0066-4a00-8a00-000000000002 \
             b1a00003-0066-4a00-8a00-000000000003; do
    grep -q "$pid" "$SQL" || fail "harness does not assert port $pid"
  done

  # ── the four DESIGN LAWS are each exercised by name. ────────────────────────────────────────────
  grep -q "volume_m3" "$SQL"                 || fail "law 1: harness never mentions a volume"
  grep -q "hold_over_capacity" "$SQL"        || fail "law 1: harness does not exercise the capacity refusal"
  grep -q "stored_at" "$SQL"                 || fail "law 2: harness has no per-port stock oracle"
  grep -q "insufficient_stored" "$SQL"       || fail "law 3: harness does not exercise the remote-retrieval refusal"
  grep -q "not_docked" "$SQL"                || fail "law 3: harness does not exercise the undocked refusal"
  grep -q "to_storage" "$SQL"                || fail "law 4: harness never moves hold -> storage"
  grep -q "to_hold" "$SQL"                   || fail "law 4: harness never moves storage -> hold"

  # ── LAW 3 must be proven UNEXPRESSABLE, not merely checked: the verb takes no port argument. ────
  grep -q "law 3 must be unexpressable" "$SQL" \
    || fail "harness does not assert the transfer signature carries no port/store argument"

  # ── the crown jewel: an item is never duplicated and never lost. ────────────────────────────────
  grep -q "total_of" "$SQL"                  || fail "harness has no conservation oracle"
  grep -q "P6 FAIL CONSERVATION" "$SQL"      || fail "harness does not assert conservation across a replay"

  # ── REFUSE, never clamp. ────────────────────────────────────────────────────────────────────────
  grep -q "clamped!" "$SQL" || fail "harness does not assert that an over-capacity refusal moves NOTHING"

  # ── THE GRANT POSTURE must be checked on ALL EIGHT privileges, not just the write verbs. rev.1 of
  #    0333 checked three and aborted the real production deploy on the SELECT it never revoked,
  #    because the Supabase project default grants arwdDxtm on every new public table. A short verb
  #    list is precisely how that happened, so the harness now refuses to pass without the other
  #    four, without an execution-level anon probe, and without a positive control for it. ─────────
  for v in TRUNCATE REFERENCES TRIGGER MAINTAIN; do
    grep -q "$v" "$SQL" \
      || fail "harness does not check the '$v' privilege — the project default grants it, and a verb list that is short is exactly how rev.1 aborted on production"
  done
  grep -q "set local role anon" "$SQL" \
    || fail "harness never becomes the anon seat — has_table_privilege reports what the ACL says, not what the database DOES"
  grep -q "positive control" "$SQL" \
    || fail "harness has no positive control for the anon probe — a seat that can read nothing at all would pass it vacuously"
  grep -q "PUBLIC-READ item_types catalog" "$SQL" \
    || fail "harness does not assert the item_types anon read SURVIVES the revoke — overshooting is as broken as falling short"

  # ── the capacity check must be SERIALIZED per player, or two of one player's ships can each pass
  #    it and land the hold over capacity between them. A one-transaction proof cannot stage that
  #    race, so it asserts the lock that prevents it — and its order against the row lock. ─────────
  grep -q "pg_advisory_xact_lock" "$SQL" \
    || fail "harness does not assert the per-player advisory lock that makes the capacity check authoritative"
  grep -q "inverted lock order" "$SQL" \
    || fail "harness does not assert the advisory lock is taken BEFORE the row lock"

  # ── every reject/replay envelope the proof exercises live. ──────────────────────────────────────
  for tok in station_storage_disabled invalid_request invalid_direction invalid_item invalid_quantity \
             ship_not_found not_docked insufficient_items insufficient_stored hold_over_capacity \
             idempotent_replay; do
    grep -q "'$tok'" "$SQL" || fail "harness does not exercise reject/replay envelope '$tok'"
  done
  # port_has_no_storage is deliberately NOT exercised live: Dock-0 only ever docks a port that
  # passes is_home_port_eligible, so a docked-but-unstorable location is unreachable from a real
  # fixture. It is a defensive branch, asserted by the migration's own (e) self-check instead.

  # ── fixtures come from the REAL RPCs, never a direct insert into a table the RPC owns. ──────────
  grep -q "public.commission_first_main_ship()" "$SQL" || fail "harness does not provision ships via commission_first_main_ship"
  grep -q "public.reward_grant(" "$SQL"                || fail "harness does not grant items via the real reward pipeline"
  grep -q "public.base_items_add(" "$SQL"              || fail "harness does not place port stock via the base_items sole writer"
  grep -q "public.command_ship_group_go(" "$SQL"       || fail "harness does not undock through the REAL unified mover"
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.player_inventory'        "$SQL" && fail "harness inserts player_inventory directly (must go through inventory_deposit)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.base_items'              "$SQL" && fail "harness inserts base_items directly (base_items_add is the sole writer)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+public\.item_transfer_receipts'  "$SQL" && fail "harness writes item_transfer_receipts directly (transfer_items is the sole writer)" || true
  grep -qiE 'update[[:space:]]+public\.base_items'                              "$SQL" && fail "harness updates base_items directly" || true

  # ── the exact m3 arithmetic is pinned, so a silently-changed volume cannot pass. ────────────────
  grep -q "an 80 m3 hold in a 50 m3 hull" "$SQL" || fail "harness does not pin the over-capacity fixture"
  grep -q "expected 25" "$SQL"                   || fail "harness does not pin 25 ore per starter hull"
  grep -q "want 80" "$SQL"                       || fail "harness does not pin the exact 80 m3 moved volume"

  # ── every property PASS marker is present. ──────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "ITEMS-HAVE-A-PLACE SELFTEST: ALL PASSED (self-rolling-back; every flag toggled inside the txn only; dark block sets its OWN precondition; real-RPC provisioning; all four design laws exercised incl. law 3 proven unexpressable; conservation oracle; refuse-never-clamp; full reject-envelope coverage)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "ITEMS-HAVE-A-PLACE" "$SQL" "$PASS_LINE" "$MARKERS"
echo "ITEMS-HAVE-A-PLACE LOCAL PROOF: OVERALL_PASS"
