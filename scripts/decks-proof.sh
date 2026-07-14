#!/usr/bin/env bash
# DECKS — disposable proof orchestrator for the 0189 deck-stations slice (six-station catalog +
# the station axis on ship_captain_assignments through the ONE writer path).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT;
#              ends in ROLLBACK), enables the ONE dark gate (captain_assignment_enabled) ONLY
#              inside the txn, keeps EVERY game_config write inside the txn, provisions ONLY via
#              the real writers (commission RPC / captains_mint_instance / the two client
#              wrappers), NEVER inserts into or deletes from ship_captain_assignments (sole-writer
#              law; the ONE quarantined surgery is the station-NULLing UPDATE the backfill block
#              needs), and exercises every property (dark posture with the no-oracle probe,
#              named-station happy path, occupied/unknown rejects, lowest-sort auto-fill with the
#              cap-first authority, unassign-frees, verbatim replay, deterministic monotonic
#              backfill).
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual property
#              proof).
# The shared blocks (arg scaffold / self-rolling-back / flags-inside-txn / out-of-scope / local
# psql+markers) live in scripts/lib/trade-proof-lib.sh — the lib is feature-agnostic orchestrator
# plumbing (the salvage/haul/ev1 precedent); DECKS is captain-family but rides the same harness
# idiom. HOST DECISION (recorded): the captain behavior proofs live in team-command-proof.{sql,sh}
# (CAPTAINS/CAPXP/CAPLEVEL blocks), but that pair is CONTENDED by two in-flight slices — so DECKS
# ships as its own family-pure standalone pair + workflow (the ev1/world-events precedent) instead
# of a new block there.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/decks-proof.sql"

# the property PASS markers and the final PASS line this proof must exercise.
MARKERS="DECKS_PASS_DARK ROOMS8_PASS_SLOTS DECKS_PASS_ASSIGN_STATION DECKS_PASS_OCCUPIED DECKS_PASS_UNKNOWN_STATION ROOMS8_PASS_ASSIGN_ROOM ROOMS8_PASS_CONFIG DECKS_PASS_AUTOFILL DECKS_PASS_UNASSIGN_FREES DECKS_PASS_REPLAY ROOMS8_PASS_AFFINITY DECKS_PASS_BACKFILL ROOMS8_PASS_SLOT_BACKFILL"
PASS_LINE="DECKS/ROOMS-8 PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # ── the ONE dark gate is enabled ONLY strictly inside the begin;..rollback; scope. ────────────────
  tp_assert_flags_inside_txn "$SQL" captain_assignment_enabled

  # ── EVERY game_config write is inside the txn (no committed flag/config can survive). ─────────────
  begin_ln="$(grep -niE '^[[:space:]]*begin;' "$SQL" | head -1 | cut -d: -f1)"
  rollback_ln="$(grep -niE '^[[:space:]]*rollback;' "$SQL" | tail -1 | cut -d: -f1)"
  while IFS= read -r cfg_ln; do
    { [ "$begin_ln" -lt "$cfg_ln" ] && [ "$cfg_ln" -lt "$rollback_ln" ]; } \
      || fail "a game_config write is not strictly inside begin;..rollback;"
  done < <(grep -niE 'update public\.game_config' "$SQL" | cut -d: -f1)

  # ── SOLE-WRITER LAW: NEVER an insert into / delete from ship_captain_assignments; provisioning
  #    goes through the real writers only. ───────────────────────────────────────────────────────────
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?ship_captain_assignments' "$SQL" \
    && fail "harness inserts ship_captain_assignments directly (sole-writer law)" || true
  grep -qiE 'delete[[:space:]]+from[[:space:]]+(public\.)?ship_captain_assignments' "$SQL" \
    && fail "harness deletes ship_captain_assignments directly (unassign is the writer's job)" || true
  grep -q "public.captains_mint_instance(" "$SQL"      || fail "harness does not mint via the real mint writer"
  grep -q "public.commission_first_main_ship()" "$SQL" || fail "harness does not commission via the real RPC"
  grep -q "public.assign_captain_to_ship(" "$SQL"      || fail "harness does not assign via the real client wrapper"
  grep -q "public.unassign_captain_from_ship(" "$SQL"  || fail "harness does not unassign via the real client wrapper"
  # ROOMS-8: rooms are configured/read ONLY via the real RPCs — the harness never row-writes
  # ship_room_slots except the ONE quarantined slot-backfill surgery.
  grep -q "public.configure_ship_room(" "$SQL"    || fail "harness does not configure rooms via the real client wrapper"
  grep -q "public.get_my_ship_room_slots(" "$SQL" || fail "harness does not read rooms via the real read RPC"
  grep -qiE 'update[[:space:]]+public\.ship_room_slots' "$SQL" \
    && fail "harness UPDATEs ship_room_slots directly (configure is the sole writer)" || true
  # the quarantined surgery is EXACTLY the backfill fixture (station NULLing) + the two verbatim
  # backfill runs — three UPDATE sites on the assignment table, no more, no fewer.
  n="$(grep -c 'update public\.ship_captain_assignments' "$SQL" || true)"
  [ "$n" = "3" ] || fail "expected exactly 3 quarantined ship_captain_assignments UPDATE sites (surgery + backfill + monotonic re-run), found $n"
  grep -q "set station = null" "$SQL" || fail "harness lacks the pre-0189 station-NULLing surgery the backfill block needs"
  # ROOMS-8 slot backfill: EXACTLY one DELETE surgery (strip a ship's slots) + two verbatim inserts
  # (backfill + monotonic re-run).
  n="$(grep -c 'delete from public\.ship_room_slots' "$SQL" || true)"
  [ "$n" = "1" ] || fail "expected exactly 1 quarantined ship_room_slots DELETE surgery, found $n"
  n="$(grep -c 'insert into public\.ship_room_slots' "$SQL" || true)"
  [ "$n" = "2" ] || fail "expected exactly 2 verbatim ship_room_slots backfill INSERT sites (backfill + monotonic re-run), found $n"

  # ── the backfill under test is the 0189 statement (extract-and-diff pins on its load-bearing
  #    clauses) and its determinism/monotonicity asserts are intact. ─────────────────────────────────
  grep -q "partition by a.main_ship_id" "$SQL"                       || fail "backfill lost the per-ship partition"
  grep -q "order by a.assigned_at, a.captain_instance_id" "$SQL"     || fail "backfill lost the deterministic (assigned_at, id) order"
  grep -q "row_number() over (order by sort)" "$SQL"                 || fail "backfill lost the station sort ranking"
  grep -q "off the deterministic (assigned_at -> sort) mapping" "$SQL" || fail "harness lacks the backfill mapping assert"
  grep -q "not monotonic" "$SQL"                                     || fail "harness lacks the backfill monotonicity (second-run no-op) assert"
  # ROOMS-8 slot backfill under test is the 0203 statement (its load-bearing clauses) + determinism.
  grep -q "order by sort) as rn" "$SQL"                              || fail "slot backfill lost the room sort ranking"
  grep -q "from public.ship_stations order by sort limit 8" "$SQL"   || fail "slot backfill lost the 8-lowest-sort walk"
  grep -q "not monotonic" "$SQL"                                     || fail "harness lacks the slot backfill monotonicity assert"

  # ── every reject/property is asserted in assert-form (gutting any one fails here). ────────────────
  grep -q "'station_occupied'" "$SQL"           || fail "harness lacks the station_occupied reject assert"
  grep -q "'unknown_station'" "$SQL"            || fail "harness lacks the unknown_station reject assert"
  grep -q "'captain_slots_full'" "$SQL"         || fail "harness lacks the cap-first authority assert"
  grep -q "no_free_station unreachable" "$SQL"  || fail "harness lacks the no_free_station-unreachable probe"
  grep -q "captain_assignment_disabled" "$SQL"  || fail "harness lacks the dark posture assert"
  grep -q "answers differently while dark" "$SQL" || fail "harness lacks the dark no-oracle (known vs unknown station) probe"
  grep -q "idempotent_replay" "$SQL"            || fail "harness lacks the verbatim replay assert"
  grep -q "'gunnery'" "$SQL"                    || fail "harness lacks the named-station happy path"
  # ROOMS-8 room-config rejects + slot-scoping + the affinity read-shape are asserted:
  grep -q "'room_duplicate'" "$SQL"             || fail "harness lacks the room_duplicate reject assert"
  grep -q "'unknown_room'" "$SQL"               || fail "harness lacks the unknown_room reject assert"
  grep -q "'invalid_slot'" "$SQL"               || fail "harness lacks the invalid_slot reject assert"
  grep -q "'room_occupied'" "$SQL"              || fail "harness lacks the room_occupied reject assert"
  grep -q "'cargo_hold'" "$SQL"                 || fail "harness lacks the configure happy-path (room swap) assert"
  grep -q "'observatory'" "$SQL"                || fail "harness lacks the slot-scoping (non-fitted catalog room) assert"
  grep -q "station_affinity_bonus" "$SQL"       || fail "harness lacks the DECKS-3 affinity read-shape assert"
  grep -q "did not raise combat_power" "$SQL"   || fail "harness lacks the affinity-fold-still-fires assert"
  # the auto-fill walk is pinned room by room (lowest-sort determinism across the 8 fitted slots):
  for st in bridge engineering logistics sensors medbay command_deck armory; do
    grep -q "expected $st" "$SQL" || fail "harness does not pin the auto-fill walk at $st"
  done
  # the receipt + roster projections of the station are asserted:
  grep -q "result_json->>'station'" "$SQL" || fail "harness lacks the receipt station assert"
  grep -q "e->>'station'" "$SQL"           || fail "harness lacks the roster projection assert"

  # ── determinism: the harness itself contains no randomness beyond fixture ids. ───────────────────
  grep -qE 'random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  # ── every property PASS marker is EMITTED (assert-form: the raise-notice line itself, not the
  #    header's documentation list — gutting a block's notice must fail here, mutation-resistant). ───
  for m in $MARKERS; do
    grep -qE "raise notice '$m " "$SQL" || fail "missing property PASS notice (raise-form): $m"
  done
  grep -q "$PASS_LINE" "$SQL" || fail "harness missing the final PASS marker"

  tp_assert_out_of_scope "$SQL"

  echo "DECKS/ROOMS-8 SELFTEST: ALL PASSED (self-rolling-back; the one gate + every config write inside txn only; sole-writer law with the quarantined station-backfill (3 UPDATEs) + slot-backfill (1 DELETE + 2 INSERTs) surgeries pinned; dark no-oracle incl. room config/read, 8-slot default seed, named/auto/non-fitted assign, occupied/unknown, room config rejects, cap-first, unassign-frees, replay, the DECKS-3 affinity read-shape, and both backfills' determinism all assert-form-present)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "DECKS" "$SQL" "$PASS_LINE" "$MARKERS"
echo "DECKS LOCAL PROOF: OVERALL_PASS"
