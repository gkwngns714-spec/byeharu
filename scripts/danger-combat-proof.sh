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
# UNION AGAIN at the 0312/0313 merge — main carried …AUTOEXIT REPOSITION REPOOVERLAP REPOOUTSIDE
# REPOMODE NOLIVE and that branch carried …AUTOEXIT CLOSURE. Every marker from both sides is below.
# UNION A THIRD TIME at the 0313/0314 merge — 0313 brought CLOSURE (and, through main, 0311's four
# and 0312's NOLIVE) while 0314 brought RSFEEL. Twenty markers now, from four slices, and the count
# only ever grows. This is the trap the comment exists for: taking either side WHOLE drops the
# other's markers, the local run then never checks for those notices, and the suite prints
# OVERALL_PASS with entire runtime blocks unverified. It is silent, and it survives CI.
# 0315 appends LEAD — twenty-one markers now, from five slices.
# 0317 appends ONEPOWER — twenty-two markers, from six slices. Same law as every line above: a merge
# that resolves this string by taking one side DROPS the other side's markers, the local run then
# never checks for those notices, and the suite prints OVERALL_PASS with whole runtime blocks
# unverified. Union, always.
MARKERS="DZCOMBAT_PASS_ORDER DZCOMBAT_PASS_NOTYET DZCOMBAT_PASS_FIRE DZCOMBAT_PASS_ENGAGEMENT DZCOMBAT_PASS_ONCE DZCOMBAT_PASS_EVASION DZCOMBAT_PASS_SPATIAL DZCOMBAT_PASS_PIRATEFIRE DZCOMBAT_PASS_MANIFESTHELD DZCOMBAT_PASS_ROSTERAUTH DZCOMBAT_PASS_RIGFALLBACK DZCOMBAT_PASS_FITTEDEXACT DZCOMBAT_PASS_ONEPOWER DZCOMBAT_PASS_AUTOEXIT DZCOMBAT_PASS_REPOSITION DZCOMBAT_PASS_REPOOVERLAP DZCOMBAT_PASS_REPOOUTSIDE DZCOMBAT_PASS_REPOMODE DZCOMBAT_PASS_NOLIVE DZCOMBAT_PASS_CLOSURE DZCOMBAT_PASS_RSFEEL DZCOMBAT_PASS_LEAD"
PASS_LINE="DANGER-ZONE COMBAT PROOF PASSED"

if [ "$MODE" = "selftest" ]; then
  [ -f "$SQL" ] || fail "proof sql not found"

  # ── GENERATED-MIGRATION PARITY GATE (added 0308; 0311 joined; 0307 backfilled) ─────────────────
  # THE ONE AUTHORITY for "every generated migration still matches the slices it claims to take".
  # Each such migration re-creates LIVE plpgsql by SLICING the deployed text and replacing marked
  # hunks, and each ships a generator whose --check re-derives the migration from those slices. That
  # makes byte parity outside the hunks a property of the METHOD rather than a review promise — but
  # ONLY if the generator is actually run. Before this gate existed, `--check` was wired into no
  # workflow, no harness and no npm script, so a hand-edit of a generated migration passed every gate
  # in the repo and would have surfaced as an exactly-once probe failing AT DEPLOY TIME ON PRODUCTION
  # instead of in CI. Adversarial review found that hole. Every generator is gated together, not just
  # the newest, because the gap is identical for the ones that came before.
  # THIS SUITE IS THE HOST because it is the only proof triggered on `pull_request` AND on push to
  # main — every PR and every merge runs it. fleetgo-proof.yml, which briefly carried a second copy
  # of this check for gen-0306 alone, fires only on `osn3-**`/`slice-**` pushes, so it was strictly
  # narrower coverage of the same property in a second place. That copy is deleted; one authority.
  # 0307 JOINS — AND THE HAND-MAINTAINED LIST IS NO LONGER TRUSTED TO BE COMPLETE. gen-0307 was
  # authored TEN MINUTES before this gate was written (1d3e3e4 2026-08-02 12:11 vs the gate in
  # c34ee51 12:48), which enumerated "0305/0306/0308" — the wave its author was holding in mind — and
  # 0307 fell between them and was never registered. It then sat ungated for the whole 0310→0316 arc
  # while nine siblings were added around it, and its --check had been reporting the DEPLOYED,
  # UNMODIFIED migration as OUT OF DATE the entire time (it lacked the CRLF normalisation every
  # sibling has), which nothing ran and nobody saw. THE REAL DEFECT WAS NOT THE MISSING NAME — it was
  # that a hand-written list can be incomplete and still print ALL PASSED. So the loop below is now
  # closed in BOTH directions: every scripts/gen-*.mjs on disk must be registered here (a new
  # generator can never again be silently ungated), and every registered generator must still exist
  # and pass (a deleted generator can never again be silently skipped). Neither half alone is enough.
  # 0317 joins: it is the first generator to rewrite TWO live functions in one migration — nine
  # hunks inside calculate_expedition_stats (sliced from 0205, still its byte source) and eight
  # inside combat_create_group_encounter (sliced from 0301 and from 0315's own emitted text). TEN
  # generators now. Same law as every line above: a missing or unrun generator is a HARD FAIL.
  GENERATORS="gen-0305-sortie-authority gen-0306-dock-authority gen-0307-loot-secures-on-arrival gen-0308-combat-roster-authority gen-0310-hp-auto-exit gen-0311-reposition-in-zone gen-0312-no-living-ships gen-0314-runescape-combat-feel gen-0315-every-fleet-has-a-lead gen-0316-combat-five-times-tighter gen-0317-one-authority-for-attack"
  if command -v node >/dev/null 2>&1; then
    # DIRECTION 1 — nothing on disk may be unregistered. This is the half that would have caught 0307
    # on the day the gate was written, and it needs no maintenance to keep working.
    found_any=0
    for f in "$REPO_ROOT"/scripts/gen-*.mjs; do
      [ -f "$f" ] || continue
      found_any=1
      b="$(basename "$f" .mjs)"
      case " $GENERATORS " in
        *" $b "*) ;;
        *) fail "$b.mjs exists but is NOT registered in this gate's GENERATORS list — its migration is re-created by slicing LIVE plpgsql and NOTHING is verifying that it still matches its slices. Add it to the list (that is the whole fix); do not delete this check." ;;
      esac
    done
    [ "$found_any" = "1" ] \
      || fail "no scripts/gen-*.mjs found at all — every generated migration is unverified. The generators were moved or deleted; this gate must never pass on an empty set."
    # DIRECTION 2 — nothing registered may be missing or failing.
    # UNION, resolved by hand at the 0310/0311 merge. Adversarial review warned about exactly this
    # conflict: "a resolution that drops gen-0311 from the generator loop silently reopens the hole
    # this gate exists to close." BOTH generators stay. Never resolve this hunk by taking one side.
    # UNION again at the 0311/0312 merge: every generator stays. Dropping one silently
    # un-verifies the migration it guards and the failure resurfaces at deploy time on prod.
    # UNION a third time at the 0313/0314 merge: 0313 re-creates no plpgsql and so has no generator,
    # but 0314 does (gen-0314 slices the combat tick out of 0299), and the 0314 side of this loop had
    # never seen gen-0311/gen-0312. Seven generators now. A missing generator is a HARD FAIL here,
    # never a skip — that property is only worth anything if the list is complete.
    # 0315 joins: it rewrites FIVE hunks inside combat_create_group_encounter, slicing four from
    # 0301 and one from 0308's own emitted text (0308 owns the deployed roster projection). Eight
    # generators now. Same law as every line above — a missing or unrun generator is a HARD FAIL.
    # 0316 joins: it is mostly config/catalog (which needs no generator machinery at all) but it also
    # rewrites ONE hunk inside that same builder — the world-travel -> combat-space speed conversion,
    # sliced from 0301:754, the one line 0308 and 0315 both left alone. NINE generators now. Note
    # that gen-0315's own "nobody rewrote this function after me" head check names 0316 explicitly
    # rather than being widened, so it still fires for 0317 and everything after it.
    for gen in $GENERATORS; do
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
  #   3. AUTOEXIT + CLOSURE + RSFEEL — pg_temp.ae_tick, the one-encounter tick driver (rewinds ONE
  #                      encounter's cadence clock then runs the real engine); AUTOEXIT (0310) uses
  #                      it to erode a fleet to its threshold, CLOSURE (0313) to walk an escort and
  #                      a pirate into range across ticks, RSFEEL (0314) to drive its two ticks.
  #                      One helper, one engine call site — three slices, no fourth driver.
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
  grep -q "drifted from its catalog row"                          "$SQL" || fail "harness lacks the fitted-weapon DELIVERY-profile assert (range/projectile speed/cooldown/ammo still pinned to the catalog row)"
  # 0317 — THE ONE AUTHORITY FOR ATTACK, in assert-form. Every one of these is RED on the pre-0317
  # builder, which copied module_types.power into weapons_json FLAT; these greps are what stop the
  # block being deleted, or quietly weakened back into a catalog comparison, without CI noticing.
  grep -q "the catalog is still deciding damage"                  "$SQL" || fail "harness lacks the fitted-weapon-fires-the-FOLD assert (the 0317 red: attack_snapshot is used for damage zero times on the spatial arm)"
  grep -q "HAPPENS to equal the catalog share weight"             "$SQL" || fail "harness lacks the FITTEDEXACT non-vacuity pin (if the fold equalled the catalog weight, the pre-0317 flat copy would satisfy the assert)"
  grep -q "would satisfy assertion (1) and this block would prove nothing" "$SQL" || fail "harness lacks the ONEPOWER pre-0317-shape-is-distinguishable pin"
  grep -q "the catalog is still deciding damage instead of the fold" "$SQL" || fail "harness lacks the ONEPOWER volley-equals-fold assert"
  grep -q "still contributes NOTHING to damage: this is the whole defect" "$SQL" || fail "harness lacks the ONEPOWER non-module-source-raises-damage assert (the trait/captain/buff property)"
  grep -q "the fixture is not a controlled pair"                  "$SQL" || fail "harness lacks the ONEPOWER controlled-pair premise (B must differ from A by exactly the trait)"
  grep -q "a multi-weapon ship must total to its own combat_power" "$SQL" || fail "harness lacks the ONEPOWER multi-weapon total assert"
  grep -qF 'that is "each", not "share"'                          "$SQL" || fail "harness lacks the ONEPOWER share-not-each assert"
  grep -q "the shares sum to"                                     "$SQL" || fail "harness lacks the ONEPOWER shares-sum-to-one assert"
  grep -q "the fitted and unfitted paths are not the same rule"    "$SQL" || fail "harness lacks the ONEPOWER one-rule assert"
  grep -q "a knob only the unfitted path obeys IS a second rule"   "$SQL" || fail "harness lacks the ONEPOWER deleted-knob pin"
  grep -q "produced LESS OR EQUAL damage"                         "$SQL" || fail "harness lacks the ONEPOWER stronger-weapon-never-reduces-dps assert"
  grep -q "so a volley comparison is not a dps comparison"        "$SQL" || fail "harness lacks the ONEPOWER cadence premise (the volley ordering is only a dps ordering while every cooldown is at or under the tick)"
  grep -q "every comparison below would be vacuous"               "$SQL" || fail "harness lacks the ONEPOWER NULL attack_snapshot pin (a comparison against NULL proves nothing)"
  grep -q "B is not a controlled variant of A"                    "$SQL" || fail "harness lacks the ONEPOWER controlled-trait precondition (commissioning ROLLS random traits; the block must own this, not inherit it)"
  grep -q "want exactly the one this block gave it"               "$SQL" || fail "harness lacks the ONEPOWER exactly-one-trait-on-B pin"
  grep -q "the multi-weapon property has nothing to total"        "$SQL" || fail "harness lacks the ONEPOWER two-guns-actually-fitted premise"
  grep -q "the unfitted path would never be exercised"            "$SQL" || fail "harness lacks the ONEPOWER no-weapon-hull premise"
  grep -q "would have no stronger weapon to test"                 "$SQL" || fail "harness lacks the ONEPOWER stronger-gun-exists premise"
  grep -q "cannot demonstrate that a NON-MODULE source raises damage" "$SQL" || fail "harness lacks the ONEPOWER positive-attack-trait premise"
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
  grep -q "it is not damaged, so a first-tick exit could not distinguish" "$SQL" || fail "harness lacks the re-entry divergence vacuity guard (0317 repoint: the LIVE hull, not the entry integrity, is the quantity that still varies)"
  grep -q "the bar and the safety line are measuring different things again" "$SQL" || fail "harness lacks the 0317 identity pin (player_integrity_max IS the auto-exit denominator; a re-seed from live hp must fail here, not silently reopen the compounding denominator)"
  grep -q "differs from its entry integrity"                      "$SQL" || fail "harness lacks the fresh-fleet capacity==entry identity assert"
  # 0314 — the RuneScape-feel properties, in assert-form (each is RED on the pre-0314 tick body):
  # the harness OWNS the frozen-now() cooldown world (zeroed knobs) and RSFEEL owns its 3600s one.
  grep -q "set_game_config('enemy_synthetic_cooldown_seconds', '0'" "$SQL" \
    || fail "harness lost the zeroed enemy cooldown — with 0314's real cooldowns and txn-frozen now(), every multi-tick fire block (AUTOEXIT above all) would stall"
  grep -q "set_game_config('combat_player_fallback_weapon_cooldown_seconds', '0'" "$SQL" \
    || fail "harness lost the zeroed fallback cooldown (the frozen-now() precondition)"
  grep -q "set_game_config('combat_hit_variance_pct',         '0'" "$SQL" \
    || fail "harness lost the per-hit variance determinism pin — every exact damage number above RSFEEL would flake"
  grep -q "set_game_config('combat_debug_logging',            'false'" "$SQL" \
    || fail "harness lost the pinned-dark debug flag — RSFEEL's hitsplat-promotion property would be provable by the wrong flag"
  grep -q "produced no per-hit hull_damage under EVENT logging"   "$SQL" || fail "harness lacks the visible-hitsplat assert (the pre-0314 red: debug-gated)"
  grep -q "every same-tick hit carries the same damage"           "$SQL" || fail "harness lacks the per-hit distinct-roll assert (the pre-0314 red: one shared roll per tick)"
  grep -q "fired again through an unelapsed 3600s cooldown"       "$SQL" || fail "harness lacks the attack-interval assert (the pre-0314 red: armed with bare now())"
  grep -q "armed with bare now() and the cooldown never reached the clock" "$SQL" || fail "harness lacks the exact now()+cooldown arming pin"
  grep -q "a zero-cooldown weapon must stay ready every tick"     "$SQL" || fail "harness lacks the fail-open zero-cooldown assert (today's cadence must survive for cooldowns at or under the tick)"
  grep -q "the wave is too small to exercise the roll spread"     "$SQL" || fail "harness lacks the multi-unit-volley vacuity guard"
  grep -q "silence would be vacuous"                              "$SQL" || fail "harness lacks the tick-2 silence vacuity guard (live wave, active fight)"
  # 0312 — the no-living-ships properties are asserted in assert-form too (gutting any block fails here).
  grep -q "a dead fleet was ordered onto the map"                 "$SQL" || fail "harness lacks the dead-fleet refusal assert (the pre-0312 red)"
  grep -q "minted a fleet or a leg"                               "$SQL" || fail "harness lacks the refused-volley-writes-nothing assert (the pre-0312 bootstrap mint)"
  grep -q "a merely damaged ship was treated as dead"             "$SQL" || fail "harness lacks the damaged-alive-still-moves assert (the hp-predicate trap)"
  grep -q "recovery is blocked on a dead fleet"                   "$SQL" || fail "harness lacks the recovery-never-blocked asserts (tow/repair/brake/re-assign)"
  grep -q "did not answer empty_group"                            "$SQL" || fail "harness lacks the empty-vs-dead distinctness assert (two states, two codes)"
  grep -q "must mean ALL"                                         "$SQL" || fail "harness lacks the one-living-ship-suffices assert (the un-brick loop)"
  # 0313 — the CLOSURE properties (units MOVE at the seeded cut ranges; fire only after closure) are
  # asserted in assert-form too, and the SPATIAL range expectation must stay catalog-DERIVED.
  grep -q "the catalog autocannon_battery range"                  "$SQL" || fail "harness's SPATIAL range assert is no longer derived from the catalog (the 0313 repoint regressed to a hard-coded seed)"
  grep -q "the seeded world no longer forces closure"             "$SQL" || fail "harness lacks the CLOSURE gap-exceeds-both-ranges premise assert"
  grep -q "the fight no longer starts instantly"                  "$SQL" || fail "harness lacks the command-ship-fires-tick-1 assert (combat must start despite the gap)"
  grep -q "the CLOSE arm never ran"                               "$SQL" || fail "harness lacks the escort-moved-on-tick-1 assert (the first observed movement)"
  grep -q "the enemy CLOSE arm never ran"                         "$SQL" || fail "harness lacks the pirate-moved-off-anchor assert"
  grep -q "they are not closing"                                  "$SQL" || fail "harness lacks the gap-shrinks assert"
  grep -q "something fired across a gap larger than its own range" "$SQL" || fail "harness lacks the no-fire-beyond-range tick-1 assert"
  grep -q "the escort NEVER fired within 12 ticks"                "$SQL" || fail "harness lacks the closure-completes assert (approach must reach firing range)"
  grep -q "the fire gate is not honouring the cut range"          "$SQL" || fail "harness lacks the first-shot-within-own-range assert"
  grep -q "no silent closing tick before it"                      "$SQL" || fail "harness lacks the closure non-vacuity guard (at least one silent approach tick)"
  grep -q "the out-range order inverted"                          "$SQL" || fail "harness lacks the longer-range-fires-first assert"
  # 0313 rev.2 — NULL-VACUITY PINS. combat_units.pos_x/pos_y and combat_encounters.engagement_x/y are
  # all NULLABLE, and `x is not distinct from NULL` is FALSE for any real number — so a missing
  # coordinate made the moved/closing asserts pass while proving nothing. Absence is failure now, and
  # these greps are what stops the pins being quietly removed again — but only if each pattern matches
  # exactly ONE line. The escort pattern below must NOT be shortened to "cannot prove it moved": that
  # substring also occurs in the PIRATE pin two lines down, so the escort pin could then be deleted and
  # this grep would still fire on the other line, silently guarding nothing. Pin it to the escort's own
  # wording ("unit", not "enemy").
  grep -q "an unpositioned unit cannot prove it moved"            "$SQL" || fail "harness lacks the escort NULL-coordinate pin (a moved-assert against NULL is vacuous)"
  grep -q "the spawn point this assert compares against does not exist" "$SQL" || fail "harness lacks the engagement-anchor NULL pin"
  grep -q "an unpositioned enemy cannot prove it moved off the anchor" "$SQL" || fail "harness lacks the pirate NULL-position pin"
  grep -q "the closure comparison would be vacuous"               "$SQL" || fail "harness lacks the tick-1 gap NULL pin"
  grep -q "makes every range check in the approach vacuous"       "$SQL" || fail "harness lacks the approach-loop pre-move-distance NULL pin"
  grep -q "the spawn-ring pin would prove nothing"                "$SQL" || fail "harness lacks the spawn-ring distance NULL pin"
  # 0316 — THE CLOSURE TICK COUNT is now a pinned property of the seeded world, not whatever the run
  # happened to produce. The block runs the engine's own recurrence over THIS encounter's real ring,
  # real weapon range and real frozen move_speeds, requires the answer to be 2 or 3 ticks, requires
  # the OBSERVED first salvo to land on exactly that tick, and refuses a pirate that swallows the
  # whole ring in one step. These greps are what stop the arithmetic being deleted again: a range cut
  # made WITHOUT the matching ring/speed cut (the 1-6 minute stall) fails the first of them, and a
  # speed left at world scale (the teleport — position ceasing to matter) fails the fourth.
  grep -q "the sprawl is back; closure must complete within one or two silent ticks" "$SQL" \
    || fail "harness lacks the CLOSURE tick-count upper bound (a range cut without the matching ring/speed cut must fail here, not in a playtest)"
  grep -q "there would be nothing to close and this block would prove nothing" "$SQL" \
    || fail "harness lacks the CLOSURE tick-count lower bound (an escort already in range at spawn makes the whole approach vacuous)"
  grep -q "the movement/fire arithmetic no longer matches the geometry the knobs were chosen for" "$SQL" \
    || fail "harness lacks the observed-equals-predicted closure assert (the recurrence must agree with the engine, or the scaling decision was made on the wrong model)"
  grep -q "it arrives on top of its target and the CLOSE/KITE arms run for a single tick" "$SQL" \
    || fail "harness lacks the CLOSURE no-teleport assert (a pirate crossing the whole ring in one tick buries the mechanic again)"
  grep -q "the closure recurrence would have no speeds in it" "$SQL" \
    || fail "harness lacks the frozen-move_speed NULL pin (move_speed is nullable, and a NULL would make the tick-count assert vacuous)"
  grep -q "the closure recurrence assumes the escort out-ranges the pirate" "$SQL" \
    || fail "harness lacks the recurrence's own range-ordering premise (it applies both CLOSE steps every tick, which is only the real fight while the pirate is the shorter-ranged one)"
  # 0315 — the LEAD properties, in assert-form. The first two are the pre-0315 REDS: on the head a
  # flagless fleet puts NOBODY on the anchor and NOBODY at priority 100. The rest are what stops the
  # block passing for the wrong reason — the engineered capacities (so the max_hp key and the uuid
  # tie-break are each decisive), the ring-exceeds-escort-range premise (so tick-1 fire is the
  # lead's alone), the flagged-fleet control (the fallback must never override a real command ship)
  # and the single-hull case. Every positional comparison is NULL-pinned, same law as 0313's.
  grep -q "no hull stands on the engagement anchor"               "$SQL" || fail "harness lacks the somebody-is-on-the-anchor assert (the pre-0315 red)"
  grep -qF "hull(s) on the engagement anchor (want exactly 1"     "$SQL" || fail "harness lacks the exactly-one-lead assert"
  grep -q "the lead is not the hull the rule names"               "$SQL" || fail "harness lacks the derived-lead-identity assert (capacity, then the uuid tie-break)"
  grep -q "the two capacities do not differ in the direction"     "$SQL" || fail "harness lacks the capacity-key non-vacuity premise (a green result must not be reachable by the tie-break alone)"
  grep -q "they must TIE or the uuid tie-break is never exercised" "$SQL" || fail "harness lacks the tie-break non-vacuity premise"
  grep -q "a hull standing on the enemy spawn point with no screen" "$SQL" || fail "harness lacks the lead-carries-priority-100 assert"
  grep -q "do not carry aggro priority 0"                         "$SQL" || fail "harness lacks the escorts-are-screened assert"
  grep -q "the escort ring slot moved"                            "$SQL" || fail "harness lacks the exact ring-slot assert (this slice moves ONE hull, it does not retune the formation)"
  grep -q "the fight did not fire on tick 1"                      "$SQL" || fail "harness lacks the fires-on-tick-1 assert (the thing that is broken today)"
  grep -q "the tick-1 fire is not attributable to the lead"       "$SQL" || fail "harness lacks the escorts-silent-on-tick-1 attribution assert"
  grep -q "ring no longer exceeds the escort range"               "$SQL" || fail "harness lacks the LEAD tick-1 attribution premise (a retune that puts escorts in range must raise, not pass)"
  grep -q "the derivation overrode a real command ship"           "$SQL" || fail "harness lacks the flagged-fleet control assert (the fallback is never an override)"
  grep -qF "flagged ship(s) were provisioned into the flagless fleet" "$SQL" || fail "harness lacks the no-command-ship precondition assert (owned, never inherited)"
  grep -q "the single hull did not lead"                          "$SQL" || fail "harness lacks the single-hull-fleet assert"
  grep -q "an unpositioned hull cannot prove where it spawned"    "$SQL" || fail "harness lacks the LEAD NULL-coordinate pin"
  grep -q "the anchor this assert measures from does not exist"   "$SQL" || fail "harness lacks the LEAD engagement-anchor NULL pin"

  # determinism: no session random() (0041 law). gen_random_uuid() is fixture identity only.
  grep -qE '[^_]random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  tp_assert_out_of_scope "$SQL"

  echo "DANGER-ZONE COMBAT SELFTEST: ALL PASSED (self-rolling-back; every dark flag enabled only inside the txn; combat_telegraph kept dark; risk knobs = 1.0 for a certain plan; sole-writer law for group_sortie_members + combat_units AND for the intercept lifecycle/geometry — only a symmetric depart/arrive/trigger time-travel is allowed; provisioning + entry 100% real-RPC incl. pirate_zone_create, command_ship_group_go, command_ship_group_go_route, command_ship_group_stop and set_group_auto_exit; the ambush is fired by the REAL process_fleet_movements and the single direct resolver call is the negative re-fire probe; exactly 3 known tick call sites; every property — the order starts a journey and no fight, the point is the zone EDGE not its centre, trigger_at is the leg's own interpolated clock, nothing fires early, the arrival cannot be settled past a due ambush, the fleet parks at the entry point, the route is abandoned, engagement_x/y equals the entry point with the command ship seeded on it, it cannot fire twice, stop/re-order before due cancels and re-plans while stop after due is refused, positioned spatial units, spawned + firing pirate + damage; the 0310 HP auto-exit fires at the player's threshold of REAL CAPACITY and never earlier, never re-requests, completes like a human press, exits a damaged fleet on re-entry (the compounding-denominator regression) and stays silent with the toggle OFF; and (0311) an in-zone order REPOSITIONS the fight (exact-delta translate, restamp, no retreat write, no leg), overlapping zones are QUANTIFIED over rather than chosen (a lower-area holder can neither veto nor decide), a destination admitted by no anchor-holding zone retreats byte-identically, a retreating fight never jumps, and a site fight falls through to the retreat — never repositioned, never refused — asserted in assert-form; no random() and the 0312 no-living-ships law — a dead fleet is refused go/go_route/dock with the typed no_living_ships and mints nothing, a damaged-but-alive hp-0 ship still moves, empty_group stays its own state, and the recovery path (brake/tow/repair/re-assign) works on exactly the dead fleet; and the 0313 CLOSURE properties (spawn gap exceeds the seeded cut ranges, command ship still fires tick 1, escort + pirate MOVE and hold fire until their own pre-move distance is inside their own range, and every positional comparison is NULL-pinned so absence is failure rather than a silent pass); and the 0314 RuneScape feel — a 3600s-cooldown wave holds fire on tick 2 while a zero-cooldown weapon keeps firing, six identical guns roll distinct damage in one tick, every landed hit emits its visible hull_damage under EVENT logging with debug pinned dark, and every fired clock armed now()+cooldown exactly); and the 0315 LEAD law — a fleet with NO command ship anywhere still elects one hull by the stated rule (a real flag first, then the greatest max_hp, then the lowest main_ship_id, over living hulls), anchors exactly THAT hull on the engagement point at aggro 100 with every escort at 0 on its unchanged ring slot, and fires on tick 1 from the anchor alone; a fleet that DOES carry a designated command ship is placed exactly as today even when the fallback would name a different hull on both derived keys; and a single-hull fleet is its own lead; and the 0316 FIVE-TIMES-TIGHTER geometry — the CLOSURE block now runs the engine own recurrence over the encounter real ring, weapon range and frozen move_speeds, demands the escort reach firing range within one or two silent closing ticks, demands the OBSERVED first salvo land on exactly the tick that recurrence predicts, and refuses a pirate that crosses the whole ring in a single step: a range cut made without the matching ring and speed cuts fails here instead of in a playtest; and the 0317 ONE-AUTHORITY-FOR-ATTACK law — a ship's weapons_json totals to EXACTLY its folded combat_power, a ship trait (a source no weapon row can carry) moves the damage by exactly its own attack, two identical guns SHARE that power in equal parts summing to 1 instead of each carrying it, the no-weapon hull obeys the same identity through the synthesized weapon with the old power_from_attack knob deleted, and the stronger gun never deals less than the weaker one — every one of those RED on the pre-0317 builder, each with its own non-vacuity pin so none can pass on a fold that happens to equal the catalog weight"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "DANGER-ZONE COMBAT" "$SQL" "$PASS_LINE" "$MARKERS"
echo "DANGER-ZONE COMBAT LOCAL PROOF: OVERALL_PASS"
