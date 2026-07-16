#!/usr/bin/env bash
# FLEET-GO — disposable proof orchestrator for the unified fleet-level mover (migration 0207,
# charter §3 step 3a). Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back (no COMMIT; ends
#              in ROLLBACK), toggles the dark flags ONLY inside the txn, provisions via the real RPCs,
#              and actually asserts the charter §2 properties (above all: NO ship writes).
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL (the real property proof).
# The shared shell blocks live in scripts/lib/trade-proof-lib.sh (sourced, never re-copied).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/fleetgo-proof.sql"
MIGRATION="$REPO_ROOT/supabase/migrations/20260618000207_fleetgo_unified_group_mover.sql"

MARKERS="FLEETGO_PASS_DARK FLEETGO_PASS_ONEFLEET FLEETGO_PASS_NOSHIPWRITE FLEETGO_PASS_SPEEDMIN FLEETGO_PASS_REDIRECT FLEETGO_PASS_GUARDS FLEETGO_PASS_ISOLATION"
PASS_LINE="FLEET-GO PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"
  tp_assert_flags_inside_txn "$SQL" fleet_movement_unified_enabled team_command_enabled mainship_additional_commission_enabled

  # ── provisions via the REAL RPCs (no direct ship/group inserts as the primary path). ─────────────
  grep -q "public.commission_first_main_ship()"      "$SQL" || fail "harness does not provision via commission_first_main_ship"
  grep -q "public.commission_additional_main_ship()" "$SQL" || fail "harness does not provision via commission_additional_main_ship"
  grep -q "public.upsert_ship_group(1, ''Vanguard'')" "$SQL" || fail "harness does not create its group via the real RPC"
  grep -q "public.assign_ship_to_group" "$SQL"             || fail "harness does not assign members via the real RPC"

  # ── the dark gate is asserted with a NONEXISTENT group id (reject-before-read, no existence oracle) ──
  grep -q "unified_movement_disabled" "$SQL" || fail "harness does not assert the dark gate"
  grep -q "command_ship_group_go(gen_random_uuid(), gen_random_uuid())" "$SQL" \
    || fail "dark block does not probe with nonexistent ids (cannot prove reject-BEFORE-read)"

  # ── every property PASS marker is exercised. ─────────────────────────────────────────────────────
  for m in $MARKERS; do
    grep -q "$m" "$SQL" || fail "missing property PASS marker: $m"
  done

  # ── THE CROWN JEWEL: the §2 no-ship-write assertion must be real, not decorative. ────────────────
  # It must snapshot ships, diff BOTH directions (EXCEPT alone is asymmetric), guard against a vacuous
  # empty snapshot, and be applied after the go, after the redirect, AND after the rejected guards.
  grep -q "assert_ships_untouched" "$SQL" || fail "no ship-untouched assertion — the charter §2 property is unproven"
  grep -q "except" "$SQL"                 || fail "ship diff does not use EXCEPT"
  grep -q "before-snapshot is EMPTY"      "$SQL" || fail "ship diff does not guard against a vacuous (empty) snapshot"
  for ctx in "'first go'" "'redirect'" "'guards'"; do
    grep -q "assert_ships_untouched('before_.*', 'after_.*', $ctx)" "$SQL" \
      || fail "the §2 ship-untouched assertion is not applied to: $ctx"
  done
  # the snapshot must actually cover every column that could carry movement.
  for col in status spatial_state space_x space_y updated_at; do
    grep -q "$col" "$SQL" || fail "ship snapshot does not cover the '$col' column"
  done

  # ── the redirect proof must be non-vacuous: now() is txn-constant, so without backdating t=0 and the
  #    "interpolated" point trivially equals the origin. The harness must backdate and assert a midpoint.
  grep -q "interval '30 seconds'" "$SQL" || fail "redirect block does not backdate the leg (t would be 0 → vacuous)"
  grep -q "exact midpoint"        "$SQL" || fail "redirect block does not assert the exact interpolated midpoint"

  # ── the speed fold must be recomputed INDEPENDENTLY, not read back from the same helper. ─────────
  grep -q "calculate_expedition_stats" "$SQL" \
    || fail "SPEEDMIN does not recompute from the per-member adapter (would agree with itself)"
  grep -q "calculate_group_expedition_stats" "$SQL" \
    && fail "SPEEDMIN must NOT reuse the same group helper the RPC used (self-agreeing)" || true

  # ── the migration itself must stay dark + additive: it may not re-create or alter a live path. ───
  # NOTE: these checks run against the migration with SQL comments STRIPPED. The migration's header
  # deliberately NAMES the banned constructs in prose (to tell the next reader why they are banned),
  # and its body carries a "there is deliberately NO `update main_ship_instances` below" marker — a
  # naive grep matches that prose and fails the honest file. Strip comments, then judge the CODE.
  [ -f "$MIGRATION" ] || fail "migration 0207 not found"
  MIG_CODE="$(sed -E "s/--.*//" "$MIGRATION")"
  grep -q "fleet_movement_unified_enabled" "$MIGRATION" || fail "migration does not seed its dark flag"
  printf '%s' "$MIG_CODE" | grep -qE "^[[:space:]]*(alter table|drop function|drop table)" \
    && fail "migration alters/drops an existing object (step 3a must be purely additive)" || true
  # THE MODEL: the mover must not write ship movement state. Enforced statically, not just by comment.
  printf '%s' "$MIG_CODE" | grep -qiE "update[[:space:]]+(public\.)?main_ship_instances" \
    && fail "migration UPDATEs main_ship_instances — charter §2 says a ship does not move" || true
  # and it must not compose any per-ship mover (the §0 mistake / the old §3).
  for banned in command_main_ship_space_move mainship_space_begin_move move_main_ship_to_location command_main_ship_space_stop; do
    printf '%s' "$MIG_CODE" | grep -q "$banned" \
      && fail "migration composes the per-ship mover '$banned' — §2 retires them, never composes them" || true
  done
  # the prose ban must be real: the mover's own body must still contain no ship UPDATE (proven above),
  # AND the file must keep the marker that tells the next reader why (so the ban survives edits).
  grep -q "there is deliberately NO" "$MIGRATION" \
    || fail "migration lost the no-ship-write marker that explains the §2 omission to the next reader"

  tp_assert_out_of_scope "$SQL"

  echo "FLEET-GO SELFTEST: ALL PASSED (self-rolling-back; flags in-txn only; real-RPC provisioning; dark reject-before-read; §2 no-ship-write asserted 3× with a non-vacuous both-way diff; non-vacuous redirect; independent speed fold; migration additive + composes no per-ship mover)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "FLEET-GO" "$SQL" "$PASS_LINE" "$MARKERS"
echo "FLEET-GO LOCAL PROOF: OVERALL_PASS"
