#!/usr/bin/env bash
# DANGER-ZONE COMBAT — disposable proof orchestrator for the owner's #1 chain: "send a fleet into a
# danger zone → you get jumped by pirates WHERE you meet the zone, WHEN you get there." Drives the
# REAL entry path end to end:
#   command_ship_group_go(_route) (leg crosses a drawn danger_zone) → pirate_intercept_plan_leg
#   (risk 1.0 → a certain PENDING ambush) → ... the fleet TRAVELS ... → process_fleet_movements'
#   due-intercept scan → movement_advance → pirate_intercept_resolve_due_for_movement → manifest
#   freeze + presence_create → combat_create_encounter (resolves the engagement point) →
#   combat_create_group_encounter (MANDATORY point, SPATIAL positions) → process_combat_ticks.
# Modes:
#   selftest — DB-free static checks: the harness is well-formed, self-rolling-back, toggles every dark
#              flag ONLY inside the txn, provisions ONLY via the real RPCs, never hand-writes
#              group_sortie_members/combat_units, never hand-writes an intercept LIFECYCLE or its
#              geometry (it may only time-travel the clock), and asserts every property in assert-form.
#   local    — run the write-then-ROLLBACK proof against a disposable DB_URL.
# The shared blocks live in scripts/lib/trade-proof-lib.sh (the house convention; sourced, not re-copied).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/trade-proof-lib.sh"
tp_init "${1:-}"
SQL="$REPO_ROOT/scripts/danger-combat-proof.sql"

MARKERS="DZCOMBAT_PASS_ORDER DZCOMBAT_PASS_NOTYET DZCOMBAT_PASS_FIRE DZCOMBAT_PASS_ENGAGEMENT DZCOMBAT_PASS_ONCE DZCOMBAT_PASS_EVASION DZCOMBAT_PASS_SPATIAL DZCOMBAT_PASS_PIRATEFIRE"
PASS_LINE="DANGER-ZONE COMBAT PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  tp_assert_self_rolling_back "$SQL"

  # every dark capability flag this scenario needs is enabled ONLY strictly inside the txn.
  tp_assert_flags_inside_txn "$SQL" team_command_enabled mainship_additional_commission_enabled \
    module_crafting_enabled module_fitting_enabled spatial_combat_enabled pirate_intercept_enabled \
    fleet_movement_unified_enabled

  # the commission precondition: a fresh disposable chain seeds the starter ports INACTIVE.
  grep -q "public.reveal_starter_ports()" "$SQL" || fail "harness does not reveal the starter ports (commission would fail closed)"

  # combat_telegraph stays DARK so the encounter opens inside the RESOLUTION, observably.
  grep -q "set value='false'::jsonb where key='combat_telegraph_enabled'" "$SQL" \
    || fail "harness does not keep combat_telegraph_enabled dark (the encounter must open inside the resolution)"

  # the DETERMINISTIC-AMBUSH knobs: risk = 1.0 for any crossing (so the plan needs no harness random()).
  grep -q "set_game_config('pirate_intercept_base_risk',      '1.0'" "$SQL"      || fail "harness lost the base_risk=1.0 determinism knob"
  grep -q "set_game_config('pirate_intercept_min_risk',       '1.0'" "$SQL"      || fail "harness lost the min_risk=1.0 determinism knob"
  grep -q "set_game_config('pirate_intercept_max_risk',       '1.0'" "$SQL"      || fail "harness lost the max_risk=1.0 determinism knob"
  grep -q "set_game_config('pirate_intercept_exposure_floor', '1.0'" "$SQL"      || fail "harness lost the exposure_floor=1.0 determinism knob"

  # SOLE-WRITER LAW: group_sortie_members and combat_units are NEVER hand-written.
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?group_sortie_members' "$SQL" \
    && fail "harness inserts group_sortie_members directly (the resolver is its sole writer here)" || true
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?combat_units' "$SQL" \
    && fail "harness inserts combat_units directly (the engine functions are its sole writers)" || true
  grep -qiE 'update[[:space:]]+(public\.)?combat_units' "$SQL" \
    && fail "harness UPDATEs combat_units directly (only the engine functions may write it)" || true

  # SOLE-WRITER LAW, 0301 EDITION: the harness must never hand-write an intercept's LIFECYCLE or its
  # GEOMETRY — those are exactly the properties under test, and writing them would prove nothing.
  # It may only TIME-TRAVEL (trigger_at, alongside the leg's own depart_at/arrive_at).
  grep -qiE 'insert[[:space:]]+into[[:space:]]+(public\.)?pirate_intercepts' "$SQL" \
    && fail "harness inserts pirate_intercepts directly (the planner is its sole writer here)" || true
  grep -qiE 'set[[:space:]]+lifecycle_state' "$SQL" \
    && fail "harness writes lifecycle_state directly — the lifecycle is the thing under test" || true
  grep -qiE 'set[[:space:]]+entry_(x|y|fraction)' "$SQL" \
    && fail "harness writes the intercept geometry directly — the entry point is the thing under test" || true
  grep -q "set trigger_at = trigger_at - p_by" "$SQL" \
    || fail "harness lost its single, symmetric time-travel (trigger_at must move with depart_at/arrive_at, never alone)"
  grep -q "set depart_at = depart_at - p_by, arrive_at = arrive_at - p_by" "$SQL" \
    || fail "harness time-travels the ambush without time-travelling the leg — that would move the ambush, not the clock"

  # provisioning + the entry path are 100% real-RPC.
  grep -q "public.commission_first_main_ship(" "$SQL" || fail "harness does not commission via the real RPC"
  grep -q "public.craft_module("               "$SQL" || fail "harness does not craft the weapon via the real RPC"
  grep -q "public.fit_module_to_ship("         "$SQL" || fail "harness does not fit the weapon via the real RPC"
  grep -q "public.upsert_ship_group("          "$SQL" || fail "harness does not form the team via the real RPC"
  grep -q "public.assign_ship_to_group("       "$SQL" || fail "harness does not assign the ship via the real RPC"
  grep -q "public.set_fleet_command_ship("     "$SQL" || fail "harness does not designate the command ship via the real RPC"
  grep -q "public.pirate_zone_create("         "$SQL" || fail "harness does not draw the danger zone via the real RPC"
  grep -q "public.command_ship_group_go_route(" "$SQL" || fail "harness does not order the route via the real RPC (the route-abandon property needs it)"
  grep -q "public.command_ship_group_go("      "$SQL" || fail "harness does not send the fleet via the real unified mover (the path under test)"
  grep -q "public.command_ship_group_stop("    "$SQL" || fail "harness does not exercise the brake (the evasion window needs it)"
  grep -q "public.reward_grant("               "$SQL" || fail "harness does not fund crafting materials via the real Reward writer"

  # the ambush must be fired by the REAL movement processor, never by calling the resolver to make it
  # happen. The one direct resolver call in the file is the NEGATIVE re-fire probe.
  grep -q "public.process_fleet_movements();" "$SQL" \
    || fail "harness does not fire the ambush through the real movement processor"
  n="$(grep -c 'public\.pirate_intercept_resolve_due_for_movement(' "$SQL" || true)"
  [ "$n" = "1" ] || fail "expected exactly 1 direct resolver call (the negative re-fire probe), found $n"

  # exactly TWO process_combat_ticks() call sites, and no other combat engine:
  #   1. PIRATEFIRE — the first wave spawn + fire pass.
  #   2. REAMBUSH   — the retreat drain that ends the first fight so the fleet can be re-ordered
  #                   (added with 0303; the second-ambush regression needs the first encounter closed).
  # Still a real pin: a third, unexplained invocation fails here.
  n="$(grep -c 'perform public\.process_combat_ticks();' "$SQL" || true)"
  [ "$n" = "2" ] || fail "expected exactly 2 process_combat_ticks() call sites (PIRATEFIRE + REAMBUSH drain), found $n"
  # and process_combat_ticks must remain the ONLY combat engine this proof drives.
  n="$(grep -cE 'perform public\.process_(combat|encounter)[a-z_]*\(' "$SQL" || true)"
  [ "$n" = "2" ] || fail "the proof invokes a combat engine other than process_combat_ticks ($n engine calls)"

  # every property is asserted in assert-form (gutting any block fails here).
  grep -q "the order-time ambush is still cancelling it"          "$SQL" || fail "harness lacks the leg-still-moving assert"
  grep -q "fleet_set_in_space still runs on the order path"       "$SQL" || fail "harness lacks the fleet-not-parked-at-order-time assert"
  grep -q "retired intercepted / intercept_encounter_id fields"   "$SQL" || fail "harness lacks the removed-envelope-fields assert"
  grep -q "encounter(s) already exist at order commit"            "$SQL" || fail "harness lacks the no-combat-at-order-time assert"
  grep -q "pending intercept rows for this leg"                   "$SQL" || fail "harness lacks the exactly-one-pending assert"
  grep -q "the retired ST_ClosestPoint(leg, centroid) formula"    "$SQL" || fail "harness lacks the not-the-zone-centre assert"
  grep -q "it is not on the zone boundary 100 units from the centre" "$SQL" || fail "harness lacks the on-the-zone-boundary assert"
  grep -q "is not depart + duration\*entry_fraction"              "$SQL" || fail "harness lacks the trigger_at interpolation assert"
  grep -q "encounter(s) opened before trigger_at"                 "$SQL" || fail "harness lacks the nothing-fires-before-trigger assert"
  grep -q "an arrival was settled past an ambush that was already owed" "$SQL" || fail "harness lacks the arrival-cannot-precede-resolution assert"
  grep -q "but was ambushed at"                                   "$SQL" || fail "harness lacks the parked-at-the-entry-point assert"
  grep -q "it TELEPORTED instead of stopping where it was ambushed" "$SQL" || fail "harness lacks the no-teleport assert"
  grep -q "route leg(s) still queued for the ambushed fleet"      "$SQL" || fail "harness lacks the route-abandoned assert"
  grep -q "but the fleet was ambushed at"                         "$SQL" || fail "harness lacks the engagement-point-equals-entry-point assert"
  grep -q "not on the engagement point"                           "$SQL" || fail "harness lacks the command-ship-seeded-on-the-point assert"
  grep -q "fired a SECOND time"                                   "$SQL" || fail "harness lacks the cannot-fire-twice assert"
  grep -q "did not cancel it as player_stop"                      "$SQL" || fail "harness lacks the stop-before-due-cancels assert"
  grep -q "the NEW leg was not re-planned"                        "$SQL" || fail "harness lacks the reorder-before-due-replans assert"
  grep -q "the evasion window is open"                            "$SQL" || fail "harness lacks the stop-after-due-cannot-evade assert"
  grep -q "the encounter is NOT spatial"                          "$SQL" || fail "harness lacks the positioned-units (spatial) assert"
  grep -q "command ship weapons_json did not carry the fitted range" "$SQL" || fail "harness lacks the weapons_json range assert"
  grep -q "no positioned synthetic pirate spawned"                "$SQL" || fail "harness lacks the synthetic-pirate-spawn assert"
  grep -q "no pirate-sourced spatial missile_salvo"               "$SQL" || fail "harness lacks the pirate-fire assert"
  grep -q "no damage exchanged"                                   "$SQL" || fail "harness lacks the damage-dealt assert"

  # determinism: no session random() (0041 law). gen_random_uuid() is fixture identity only.
  grep -qE '[^_]random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  tp_assert_out_of_scope "$SQL"

  echo "DANGER-ZONE COMBAT SELFTEST: ALL PASSED (self-rolling-back; every dark flag enabled only inside the txn; combat_telegraph kept dark; risk knobs = 1.0 for a certain plan; sole-writer law for group_sortie_members + combat_units AND for the intercept lifecycle/geometry — only a symmetric depart/arrive/trigger time-travel is allowed; provisioning + entry 100% real-RPC incl. pirate_zone_create, command_ship_group_go, command_ship_group_go_route and command_ship_group_stop; the ambush is fired by the REAL process_fleet_movements and the single direct resolver call is the negative re-fire probe; exactly 1 combat tick; every property — the order starts a journey and no fight, the point is the zone EDGE not its centre, trigger_at is the leg's own interpolated clock, nothing fires early, the arrival cannot be settled past a due ambush, the fleet parks at the entry point, the route is abandoned, engagement_x/y equals the entry point with the command ship seeded on it, it cannot fire twice, stop/re-order before due cancels and re-plans while stop after due is refused, positioned spatial units, spawned + firing pirate + damage — asserted in assert-form; no random())"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "DANGER-ZONE COMBAT" "$SQL" "$PASS_LINE" "$MARKERS"
echo "DANGER-ZONE COMBAT LOCAL PROOF: OVERALL_PASS"
