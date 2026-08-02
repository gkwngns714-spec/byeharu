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

# UNION of 0310's and 0311's markers, resolved by hand at the 0310/0311 merge. Taking either side
# alone would leave a runtime block unchecked while the suite still printed ALL PASSED.
MARKERS="DZCOMBAT_PASS_ORDER DZCOMBAT_PASS_NOTYET DZCOMBAT_PASS_FIRE DZCOMBAT_PASS_ENGAGEMENT DZCOMBAT_PASS_ONCE DZCOMBAT_PASS_EVASION DZCOMBAT_PASS_SPATIAL DZCOMBAT_PASS_PIRATEFIRE DZCOMBAT_PASS_MANIFESTHELD DZCOMBAT_PASS_ROSTERAUTH DZCOMBAT_PASS_RIGFALLBACK DZCOMBAT_PASS_FITTEDEXACT DZCOMBAT_PASS_AUTOEXIT DZCOMBAT_PASS_REPOSITION DZCOMBAT_PASS_REPOOVERLAP DZCOMBAT_PASS_REPOOUTSIDE DZCOMBAT_PASS_REPOMODE DZCOMBAT_PASS_NOLIVE"
PASS_LINE="DANGER-ZONE COMBAT PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  # ── GENERATED-MIGRATION PARITY GATE (added 0308; 0311 joined) ──────────────────────────────────
  # 0305, 0306, 0308 and 0311 each re-create LIVE plpgsql by SLICING the deployed text and replacing
  # marked hunks, and each ships a generator whose --check re-derives the migration from those slices.
  # That makes byte parity outside the hunks a property of the METHOD rather than a review promise —
  # but ONLY if the generator is actually run. Before this gate existed, `--check` was wired into no
  # workflow, no harness and no npm script, so a hand-edit of a generated migration passed every gate
  # in the repo and would have surfaced as an exactly-once probe failing AT DEPLOY TIME ON PRODUCTION
  # instead of in CI. Adversarial review found that hole. All three are gated together, not just the
  # newest, because the gap was identical for the two that came before.
  if command -v node >/dev/null 2>&1; then
    # UNION, resolved by hand at the 0310/0311 merge. Adversarial review warned about exactly this
    # conflict: "a resolution that drops gen-0311 from the generator loop silently reopens the hole
    # this gate exists to close." BOTH generators stay. Never resolve this hunk by taking one side.
    # UNION again at the 0311/0312 merge: every generator stays. Dropping one silently
    # un-verifies the migration it guards and the failure resurfaces at deploy time on prod.
    for gen in gen-0305-sortie-authority gen-0306-dock-authority gen-0308-combat-roster-authority gen-0310-hp-auto-exit gen-0311-reposition-in-zone gen-0312-no-living-ships; do
      # A MISSING generator is a HARD FAIL, not a skip. The first version of this gate wrapped the
      # check in `if [ -f … ]; then … fi`, and adversarial review broke it empirically: hand-edit a
      # generated migration AND delete its generator, and the selftest went green. A refactor that
      # moved these into scripts/gen/ or renamed one would have silently un-verified all three
      # migrations forever, and the failure would resurface as an exactly-once probe raising AT
      # DEPLOY TIME ON PRODUCTION — the exact sequence this gate exists to prevent. Absence of the
      # checker is not evidence of correctness; it is loss of the only evidence there was.
      [ -f "$REPO_ROOT/scripts/$gen.mjs" ] \
        || fail "$gen.mjs is MISSING — migration $(echo "$gen" | sed 's/^gen-\([0-9]*\).*/\1/') can no longer be verified against the slices it claims to take. Restore it or delete the gate deliberately; do not let it skip."
      # stderr is NOT swallowed: the generator distinguishes "a source migration drifted" from "the
      # file was hand-edited", and that line is the only actionable diagnostic.
      node "$REPO_ROOT/scripts/$gen.mjs" --check \
        || fail "$gen --check FAILED (its own message is above): the migration no longer matches the slices it takes from the deployed heads. Do NOT re-generate blindly — read the diff first; a slice that no longer matches may mean the head moved under you."
    done
  else
    fail "node not found — the generated-migration parity gate cannot run, and a hand-edited migration would reach production unchecked"
  fi

  tp_assert_self_rolling_back "$SQL"

  # every dark capability flag this scenario needs is enabled ONLY strictly inside the txn.
  tp_assert_flags_inside_txn "$SQL" team_command_enabled mainship_additional_commission_enabled \
    module_crafting_enabled module_fitting_enabled spatial_combat_enabled pirate_intercept_enabled \
    fleet_movement_unified_enabled timed_docking_enabled

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
  grep -q "public.set_group_auto_exit("        "$SQL" || fail "harness does not adjust the auto-exit through the real RPC (the 0310 writer under test)"
  # 0312 — the dead fleet is produced by the tick's OWN terminal leaves (never a hand-write of
  # main_ship_instances), the damaged ship by the tick's own hp writer, and the recovery path is
  # exercised through the real recovery RPCs.
  grep -q "public.fleet_destroy("                 "$SQL" || fail "harness does not kill the fleet through the tick's own terminal leaf (0312)"
  grep -q "public.mainship_mark_combat_destroyed(" "$SQL" || fail "harness does not wreck the ships through the tick's own terminal leaf (0312)"
  grep -q "public.mainship_sync_combat_hp("       "$SQL" || fail "harness does not damage a ship through the tick's own hp writer (the 0312 round-to-zero shape)"
  grep -q "public.mainship_emergency_tow("        "$SQL" || fail "harness does not exercise the tow on the dead fleet (the 0312 recovery half)"
  grep -q "public.repair_main_ship("              "$SQL" || fail "harness does not exercise the repair on the towed wreck (the 0312 recovery half)"
  grep -q "public.command_ship_group_dock("       "$SQL" || fail "harness does not exercise the dock refusal (the 0312 second compose site)"

  # the ambush must be fired by the REAL movement processor, never by calling the resolver to make it
  # happen. The one direct resolver call in the file is the NEGATIVE re-fire probe.
  grep -q "public.process_fleet_movements();" "$SQL" \
    || fail "harness does not fire the ambush through the real movement processor"
  n="$(grep -c 'public\.pirate_intercept_resolve_due_for_movement(' "$SQL" || true)"
  [ "$n" = "1" ] || fail "expected exactly 1 direct resolver call (the negative re-fire probe), found $n"

  # exactly THREE process_combat_ticks() call sites, and no other combat engine:
  #   1. PIRATEFIRE    — the first wave spawn + fire pass.
  #   2. MANIFESTHELD  — the drain that FINISHES the hunt sortie, so its manifest becomes a RETAINED
  #                      one and the later course change is ambushed while holding it (0303).
  #   3. AUTOEXIT      — pg_temp.ae_tick, the one-encounter tick driver (rewinds ONE encounter's
  #                      cadence clock then runs the real engine) that erodes the fleet to its
  #                      threshold (0310).
  # Still a real pin: a fourth, unexplained invocation fails here.
  n="$(grep -c 'perform public\.process_combat_ticks();' "$SQL" || true)"
  [ "$n" = "3" ] || fail "expected exactly 3 process_combat_ticks() call sites (PIRATEFIRE + the MANIFESTHELD hunt-fight drain + the AUTOEXIT ae_tick driver), found $n"
  # and process_combat_ticks must remain the ONLY combat engine this proof drives.
  n="$(grep -cE 'perform public\.process_(combat|encounter)[a-z_]*\(' "$SQL" || true)"
  [ "$n" = "3" ] || fail "the proof invokes a combat engine other than process_combat_ticks ($n engine calls)"

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
  # 0308 — the roster-authority + weapon-authority properties are asserted in assert-form too.
  grep -q "was seeded into its next fight (the 0308 defect)"      "$SQL" || fail "harness lacks the departed-ship-not-seeded assert"
  grep -q "the snapshot was replaced"                             "$SQL" || fail "harness lacks the freeze-replaces-the-snapshot assert"
  grep -q "a rig still counts as a gun (the 0308 defect)"         "$SQL" || fail "harness lacks the rig-is-not-a-gun assert"
  grep -q "the ship does not fire its own attack"                 "$SQL" || fail "harness lacks the fallback-power-from-attack assert"
  grep -q "drifted from its catalog row"                          "$SQL" || fail "harness lacks the fitted-weapon-exactness assert"
  # 0311 — the reposition properties are asserted in assert-form too. A failing block reds CI, but a
  # DELETED block would not — these pins are what makes deletion fail here.
  grep -q "armed a retreat instead of repositioning"              "$SQL" || fail "harness lacks the in-zone-order-repositions assert"
  grep -q "a reposition wrote a retreat destination"              "$SQL" || fail "harness lacks the no-retreat-destination-on-reposition assert"
  grep -q "the in-zone order broke the combat"                    "$SQL" || fail "harness lacks the fight-continues assert"
  grep -q "the formation did not translate with the fleet"        "$SQL" || fail "harness lacks the exact-delta translate assert"
  grep -q "wave 2 would spawn at the abandoned point"             "$SQL" || fail "harness lacks the engagement-restamp assert"
  grep -q "a reposition must never mint a leg"                    "$SQL" || fail "harness lacks the no-leg-on-reposition assert"
  # 0311 overlap semantics (the 131e027 tie-break defect, killed): quantify, never choose.
  grep -q "VETOED an in-zone move"                                "$SQL" || fail "harness lacks the lower-area-zone-cannot-veto assert"
  grep -q "the area order still decided the outcome"              "$SQL" || fail "harness lacks the area-never-decides assert"
  grep -q "a zone that does not hold the fight granted a jump"    "$SQL" || fail "harness lacks the non-holding-zone-never-grants assert"
  grep -q "a free escape from the damage window"                  "$SQL" || fail "harness lacks the retreating-never-jumps assert"
  grep -q "the retreat window was restarted"                      "$SQL" || fail "harness lacks the no-clock-restart assert"
  # 0311 site fights: fall through to the retreat — never a reposition, never a refusal.
  grep -q "must fall through to the retreat, never a refusal"     "$SQL" || fail "harness lacks the site-fight-falls-through assert"
  grep -q "a site fight was repositioned"                         "$SQL" || fail "harness lacks the reposition-is-open-space-only assert"
  # 0310 — the HP auto-exit properties are asserted in assert-form too (gutting any block fails here).
  grep -q "the fleet never auto-requested leave"                  "$SQL" || fail "harness lacks the fires-at-threshold assert (the pre-0310 red)"
  grep -q "auto-exited ABOVE its threshold"                       "$SQL" || fail "harness lacks the never-fires-early assert"
  grep -q "never observed above threshold"                        "$SQL" || fail "harness lacks the above-threshold vacuity guard"
  grep -q "a second tick re-requested the retreat"                "$SQL" || fail "harness lacks the no-re-request idempotency assert"
  grep -q "did not complete like a human press"                   "$SQL" || fail "harness lacks the completes-like-a-human-press assert"
  grep -q "auto-exited with the toggle OFF"                       "$SQL" || fail "harness lacks the toggle-off control assert"
  grep -q "the CHECK accepted NaN on a direct write"              "$SQL" || fail "harness lacks the table-CHECK NaN probe"
  grep -q "it died instead of leaving"                            "$SQL" || fail "harness lacks the survives-the-exit assert"
  # 0310 rev.2 — the CAPACITY denominator (the review's HIGH finding): the damaged re-entry must
  # exist, must assert the two denominators actually DIVERGE (or it proves nothing), and must
  # demand the first-tick exit an entry-hull denominator cannot produce.
  grep -q "did not auto-exit on entry"                            "$SQL" || fail "harness lacks the damaged-re-entry first-tick assert (the compounding-denominator regression)"
  grep -q "the two denominators do not differ"                    "$SQL" || fail "harness lacks the re-entry divergence vacuity guard (entry integrity strictly under capacity)"
  grep -q "differs from its entry integrity"                      "$SQL" || fail "harness lacks the fresh-fleet capacity==entry identity assert"
  # 0312 — the no-living-ships properties are asserted in assert-form too (gutting any block fails here).
  grep -q "a dead fleet was ordered onto the map"                 "$SQL" || fail "harness lacks the dead-fleet refusal assert (the pre-0312 red)"
  grep -q "minted a fleet or a leg"                               "$SQL" || fail "harness lacks the refused-volley-writes-nothing assert (the pre-0312 bootstrap mint)"
  grep -q "a merely damaged ship was treated as dead"             "$SQL" || fail "harness lacks the damaged-alive-still-moves assert (the hp-predicate trap)"
  grep -q "recovery is blocked on a dead fleet"                   "$SQL" || fail "harness lacks the recovery-never-blocked asserts (tow/repair/brake/re-assign)"
  grep -q "did not answer empty_group"                            "$SQL" || fail "harness lacks the empty-vs-dead distinctness assert (two states, two codes)"
  grep -q "must mean ALL"                                         "$SQL" || fail "harness lacks the one-living-ship-suffices assert (the un-brick loop)"

  # determinism: no session random() (0041 law). gen_random_uuid() is fixture identity only.
  grep -qE '[^_]random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  tp_assert_out_of_scope "$SQL"

  echo "DANGER-ZONE COMBAT SELFTEST: ALL PASSED (self-rolling-back; every dark flag enabled only inside the txn; combat_telegraph kept dark; risk knobs = 1.0 for a certain plan; sole-writer law for group_sortie_members + combat_units AND for the intercept lifecycle/geometry — only a symmetric depart/arrive/trigger time-travel is allowed; provisioning + entry 100% real-RPC incl. pirate_zone_create, command_ship_group_go, command_ship_group_go_route, command_ship_group_stop and set_group_auto_exit; the ambush is fired by the REAL process_fleet_movements and the single direct resolver call is the negative re-fire probe; exactly 3 known tick call sites; every property — the order starts a journey and no fight, the point is the zone EDGE not its centre, trigger_at is the leg's own interpolated clock, nothing fires early, the arrival cannot be settled past a due ambush, the fleet parks at the entry point, the route is abandoned, engagement_x/y equals the entry point with the command ship seeded on it, it cannot fire twice, stop/re-order before due cancels and re-plans while stop after due is refused, positioned spatial units, spawned + firing pirate + damage; the 0310 HP auto-exit fires at the player's threshold of REAL CAPACITY and never earlier, never re-requests, completes like a human press, exits a damaged fleet on re-entry (the compounding-denominator regression) and stays silent with the toggle OFF; and (0311) an in-zone order REPOSITIONS the fight (exact-delta translate, restamp, no retreat write, no leg), overlapping zones are QUANTIFIED over rather than chosen (a lower-area holder can neither veto nor decide), a destination admitted by no anchor-holding zone retreats byte-identically, a retreating fight never jumps, and a site fight falls through to the retreat — never repositioned, never refused — asserted in assert-form; no random() and the 0312 no-living-ships law — a dead fleet is refused go/go_route/dock with the typed no_living_ships and mints nothing, a damaged-but-alive hp-0 ship still moves, empty_group stays its own state, and the recovery path (brake/tow/repair/re-assign) works on exactly the dead fleet)"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "DANGER-ZONE COMBAT" "$SQL" "$PASS_LINE" "$MARKERS"
echo "DANGER-ZONE COMBAT LOCAL PROOF: OVERALL_PASS"
