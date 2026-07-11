#!/usr/bin/env bash
# TEAM-COMMAND B-VERIFY — disposable proof orchestrator for the DARK team send/stop RPC surface
# (slices 0160..0164: ship_groups + upsert/assign/delete + group send/stop).
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends in
#              ROLLBACK), toggles the dark flags ONLY inside the txn, provisions via the real commission
#              RPCs, exercises all five team RPCs + every reject token, and asserts the all-or-nothing /
#              stop-aggregate / held-in-space / SET-NULL specifics.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the actual behavior proof),
#              then verify the COMMITTED team_command_enabled flag is still 'false'.
# The shared blocks (arg scaffold / self-rolling-back / flag-inside-txn / out-of-scope / local psql+markers)
# live in scripts/lib/trade-proof-lib.sh; only this proof's specifics live here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/team-command-proof.sql"

# the block PASS markers and the final PASS line this proof must exercise.
MARKERS="TEAMCMD_PASS_DARK TEAMCMD_PASS_WRITE TEAMCMD_PASS_SEND TEAMCMD_PASS_STOP TEAMCMD_PASS_DELETE"
PASS_LINE="TEAM-COMMAND B-VERIFY PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"
  tp_assert_flags_inside_txn "$SQL" team_command_enabled mainship_additional_commission_enabled mainship_send_enabled

  # ── provisions via the REAL commission RPCs (no direct ship inserts as the primary path). ─────────
  grep -q "public.commission_first_main_ship()"      "$SQL" || fail "harness does not provision via commission_first_main_ship"
  grep -q "public.commission_additional_main_ship()" "$SQL" || fail "harness does not exercise commission_additional_main_ship"

  # ── all FIVE team RPCs are exercised. ──────────────────────────────────────────────────────────────
  for fn in upsert_ship_group assign_ship_to_group delete_ship_group send_ship_group_expedition stop_ship_group_transit; do
    grep -q "public.$fn(" "$SQL" || fail "harness does not exercise the '$fn' RPC"
  done

  # ── every reject token is asserted (dark gate, validation, fail-closed resolves, send outcomes). Pin the
  #    ASSERT FORM (`is distinct from '<tok>'`), not a bare token match — a bare grep would also match the
  #    SQL header comments, so a gutted .sql that only mentions the tokens in prose could false-green. ────
  for tok in team_command_disabled invalid_group_index invalid_name ship_not_found group_not_found empty_group member_send_failed; do
    grep -q "is distinct from '$tok'" "$SQL" || fail "harness does not ASSERT the '$tok' reject (is distinct from form)"
  done

  # ── behavior specifics: all-or-nothing send rollback; the EXACT mixed + idempotent stop aggregates;
  #    the physical held-in-open-space shape; delete's SET-NULL member un-grouping. ───────────────────
  grep -qi "all-or-nothing" "$SQL"                                    || fail "harness does not assert the all-or-nothing send rollback"
  grep -q "status in ('moving','present','returning')" "$SQL"        || fail "all-or-nothing does not assert zero active fleets for the rolled-back member"
  grep -q "'stopped')::int is distinct from 2" "$SQL"                 || fail "harness does not assert the exact mixed stop aggregate (stopped=2)"
  grep -q "'skipped')::int is distinct from 3" "$SQL"                 || fail "harness does not assert the exact idempotent double-stop aggregate (skipped=3)"
  grep -q "spatial_state = 'in_space'" "$SQL"                         || fail "harness does not assert the held-in-open-space physical shape"
  grep -qi "on delete set null" "$SQL"                                || fail "harness does not assert the delete SET-NULL member un-grouping"
  grep -q "group_id is null" "$SQL"                                   || fail "harness does not assert members are un-grouped after delete"

  # ── all five block PASS markers present. ──────────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing block PASS marker: $m"
  done

  tp_assert_out_of_scope "$SQL"

  echo "TEAM-COMMAND B-VERIFY SELFTEST: ALL PASSED (self-rolling-back; 3 dark flags toggled only in-txn; real-RPC provisioning; 5 RPCs + all reject tokens; all-or-nothing/stop-aggregate/held/SET-NULL specifics)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "TEAM-COMMAND B-VERIFY" "$SQL" "$PASS_LINE" "$MARKERS"

# post-run honesty check: EVERY committed flag the proof flips must still be false (the flips were rolled
# back). Check all three the harness toggles in-txn, not just the team gate.
for flag in team_command_enabled mainship_additional_commission_enabled mainship_send_enabled; do
  committed="$(psql "$DB_URL" -X -t -A -c "select coalesce((select value #>> '{}' from public.game_config where key = '$flag'), 'false')")" \
    || fail "could not read the committed '$flag' value"
  [ "$committed" = "false" ] || fail "committed $flag is '$committed' — the proof leaked a flag flip (must stay false)"
done

echo "TEAM-COMMAND B-VERIFY LOCAL PROOF: OVERALL_PASS (committed team_command_enabled/mainship_additional_commission_enabled/mainship_send_enabled all still false)"
