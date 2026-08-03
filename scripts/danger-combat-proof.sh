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
# 0317 appends DEADFIRE — twenty-two. Same law as every line above: a resolution that drops a marker
# leaves its runtime block unchecked while the suite still prints ALL PASSED.
# 0331 (authored as 0317, renumbered when the-dead-do-not-shoot took that number and DEPLOYED it)
# appends ONEPOWER — TWENTY-THREE markers now, from seven slices. This is the fourth hand-resolved
# UNION of this one string, and every one of them was a merge where two branches each appended a
# single marker. Taking either side whole drops the other's block from the local run while the
# suite still prints OVERALL_PASS. Union, always.
# 0334 appends DOCKWRECK — TWENTY-FIVE markers now, from nine slices. It is the only runtime
# check that a wreck standing in a DOCKED fleet resolves that dock and repairs without a tow, and
# the only one that pins that a fleet's living ships and its wrecks cannot disagree about where
# they are. Union, always — the sixth hand-resolved merge of this one string.
# 0332 appends WRECKHOME — TWENTY-FOUR markers now, from eight slices. Same law, fifth time: this
# block is the ONLY runtime check that a fight the fleet SURVIVES still reconciles its casualties,
# and dropping the marker in a merge would leave that entirely unverified while the suite prints
# ALL PASSED. Union, always.
# 0336 appends NINE — OWNWORLD (which the 0336 branch added ahead of the PROVISION banner and which
# had no marker at all until now) plus the slice's own eight: RANGEINVARIANT VOLLEY WAVERING
# RETREATNOSPAWN NOWEDGE ORDERSTABLE SHORTGUN RETREATCLEAR. THIRTY-FOUR markers now, from ten
# slices. Same law as every line above, for the seventh hand-resolved union of this one string: a
# resolution that takes either side WHOLE drops the other's markers, the local run then never checks
# for those notices, and the suite prints OVERALL_PASS with entire runtime blocks unverified.
MARKERS="DZCOMBAT_PASS_ORDER DZCOMBAT_PASS_NOTYET DZCOMBAT_PASS_FIRE DZCOMBAT_PASS_ENGAGEMENT DZCOMBAT_PASS_ONCE DZCOMBAT_PASS_EVASION DZCOMBAT_PASS_SPATIAL DZCOMBAT_PASS_PIRATEFIRE DZCOMBAT_PASS_MANIFESTHELD DZCOMBAT_PASS_ROSTERAUTH DZCOMBAT_PASS_RIGFALLBACK DZCOMBAT_PASS_FITTEDEXACT DZCOMBAT_PASS_AUTOEXIT DZCOMBAT_PASS_REPOSITION DZCOMBAT_PASS_REPOOVERLAP DZCOMBAT_PASS_REPOOUTSIDE DZCOMBAT_PASS_REPOMODE DZCOMBAT_PASS_NOLIVE DZCOMBAT_PASS_CLOSURE DZCOMBAT_PASS_RSFEEL DZCOMBAT_PASS_LEAD DZCOMBAT_PASS_DEADFIRE DZCOMBAT_PASS_ONEPOWER DZCOMBAT_PASS_WRECKHOME DZCOMBAT_PASS_DOCKWRECK DZCOMBAT_PASS_OWNWORLD DZCOMBAT_PASS_RANGEINVARIANT DZCOMBAT_PASS_VOLLEY DZCOMBAT_PASS_WAVERING DZCOMBAT_PASS_RETREATNOSPAWN DZCOMBAT_PASS_NOWEDGE DZCOMBAT_PASS_ORDERSTABLE DZCOMBAT_PASS_SHORTGUN DZCOMBAT_PASS_RETREATCLEAR"
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
  # 0331 joins: the first generator to rewrite TWO live functions in one migration — nine hunks
  # inside calculate_expedition_stats (sliced from 0205, still its byte source) and eight inside
  # combat_create_group_encounter (sliced from 0301 and from 0315's own emitted text). THIRTEEN
  # generators now. Same law as every line above: a missing or unrun generator is a HARD FAIL.
  # 0332 joins: ONE hunk inside process_combat_ticks (the escape/completed settle arm's member
  # loop, sliced from 0299:622-624), statically disjoint from 0310's, 0314's and 0317's sites, all
  # three of which gen-0332's own head check names explicitly rather than widening the window — so
  # 0333 still cannot cut a slice from a head that has moved without failing here first. FOURTEEN
  # generators now. Same law as every line above: a missing or unrun generator is a HARD FAIL.
  # 0333 joins: TWENTY-TWO hunks over TEN functions (reward_grant 0040, craft 0109, recruit 0126,
  # salvage sell 0174, shipyard order 0188, shipyard refund 0194, port shop buy 0235) plus SIX
  # signature widenings. It carries its OWN per-function drift gate — for each of those ten it
  # refuses to generate if any later migration textually re-created the function or rewrote it by
  # hunk surgery — so the same protection every line above describes is enforced ten times over.
  # FIFTEEN generators now.
  GENERATORS="gen-0305-sortie-authority gen-0306-dock-authority gen-0307-loot-secures-on-arrival gen-0308-combat-roster-authority gen-0310-hp-auto-exit gen-0311-reposition-in-zone gen-0312-no-living-ships gen-0314-runescape-combat-feel gen-0315-every-fleet-has-a-lead gen-0316-combat-five-times-tighter gen-0317-the-dead-do-not-shoot gen-0319-drawn-zones-stay-drawn gen-0331-one-authority-for-attack gen-0332-a-wreck-can-always-come-home gen-0333-items-live-at-ports gen-0336-combat-engine-repairs"
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
    # 0317 joins: ONE hunk inside process_combat_ticks (the actor-liveness guard at the top of the
    # spatial per-unit loop), sliced from 0299 like 0310's and 0314's and statically disjoint from
    # both. TEN generators now. gen-0317 carries the same two head checks in its own shape — no later
    # textual re-create, and no UNKNOWN later hunk surgery on the tick — so 0318 cannot cut a slice
    # from a head that has moved without failing here first.
    # 0319 joins (UNION, resolved by hand TWICE — this list is APPENDED to, never replaced): it touches
    # no combat function at all. It rewrites TWO hunks inside zone_update so a zone the owner DRAWS is
    # flagged 'drawn' and permanently leaves 0296's derived-geometry regenerator selection. It is
    # registered here anyway, and that is deliberate: this gate is the repo's ONLY runner of any
    # generator's --check, and #360 closed it in BOTH directions, so an unregistered gen-*.mjs is now
    # a HARD FAIL. The gate is about the METHOD, not about combat. TWELVE generators now.
    # It was authored as 0317, renumbered to 0318 when the_dead_do_not_shoot took that number and
    # DEPLOYED it, then to 0319 when hidden_stays_hidden took THAT one and deployed too. The number
    # moved three times; the slice source (0287, zone_update's textual head) never did, and
    # gen-0319's own head check re-proves that on every run rather than trusting the rename.
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
  grep -q "public.repair_ship_hull("              "$SQL" || fail "harness does not exercise the repair on the towed wreck (the 0312 recovery half)"
  grep -q "public.command_ship_group_dock("       "$SQL" || fail "harness does not exercise the dock refusal (the 0312 second compose site)"

  # the ambush must be fired by the REAL movement processor, never by calling the resolver to make it
  # happen. The one direct resolver call in the file is the NEGATIVE re-fire probe.
  grep -q "public.process_fleet_movements();" "$SQL" \
    || fail "harness does not fire the ambush through the real movement processor"
  n="$(grep -c 'public\.pirate_intercept_resolve_due_for_movement(' "$SQL" || true)"
  [ "$n" = "1" ] || fail "expected exactly 1 direct resolver call (the negative re-fire probe), found $n"

  # exactly TWO process_combat_ticks() call sites, and no other combat engine:
  #   1. MANIFESTHELD  — pg_temp.drain_encounter, the drain that FINISHES the hunt sortie, so its
  #                      manifest becomes a RETAINED one and the later course change is ambushed
  #                      while holding it (0303).
  #   2. THE ONE CADENCE DRIVER — pg_temp.ae_tick (rewinds ONE encounter's cadence clock then runs
  #                      the real engine). AUTOEXIT (0310) uses it to erode a fleet to its threshold,
  #                      CLOSURE (0313) to walk an escort and a pirate into range across ticks,
  #                      RSFEEL (0314) to drive its two ticks, and — from 0336 — PIRATEFIRE to drive
  #                      the wave's SILENT spawn tick plus the closing ticks up to its first salvo.
  # THIS PIN WENT 3 -> 2 WITH 0336, DELIBERATELY. PIRATEFIRE used to hand-roll the rewind-then-tick
  # idiom as a third direct engine site; it now composes pg_temp.ae_tick, which is the same idiom with
  # a name. Fewer engine call sites is the direction this pin exists to protect: a THIRD, unexplained
  # invocation still fails here.
  n="$(grep -c 'perform public\.process_combat_ticks();' "$SQL" || true)"
  [ "$n" = "2" ] || fail "expected exactly 2 process_combat_ticks() call sites (the MANIFESTHELD drain_encounter + the ae_tick cadence driver), found $n"
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
  # 0336 PIRATEFIRE re-premise, in assert form. The wave now arrives OUTSIDE its own reach, so the
  # spawn tick is silent and the fire is reached by driving ticks until it is OBSERVED. Each of these
  # is a line the repoint added; a resolution that drops one takes a real property with it.
  grep -q "pirate salvo(s) on the SPAWN tick"                     "$SQL" || fail "harness lacks the 0336 wave-is-SILENT-on-its-spawn-tick assert"
  grep -q "the spawn tick is numbered"                            "$SQL" || fail "harness lacks the PIRATEFIRE spawn-tick-is-tick-1 pin (the silence assert must read the tick the wave actually arrived on)"
  grep -q "within 12 ticks of the spawn"                          "$SQL" || fail "harness lacks the PIRATEFIRE bounded closing-loop failure (a wave that never fires must fail loudly, not hang)"
  grep -q "this block observed no closing approach at all"        "$SQL" || fail "harness lacks the PIRATEFIRE non-vacuity pin (the first salvo must land strictly after the silent spawn tick)"
  grep -q "the encounter went % during the approach"              "$SQL" || fail "harness lacks the PIRATEFIRE approach-not-interrupted guard"
  grep -q "does not RESOLVE to a real firer/target pair"          "$SQL" || fail "harness lacks the PIRATEFIRE payload-resolves assert (unit_id/target_id must name real rows, not merely exist)"
  grep -q "the pirate carries a NULL hp column"                   "$SQL" || fail "harness lacks the PIRATEFIRE hp NULL-pin (a NULL hp column would make the damage comparison vacuous)"
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
  # 0336 RSFEEL re-premise, in assert form. The volley is no longer on tick 1 — a wave arrives at
  # (measured player extent + its own range + 1), so it is SILENT on its spawn tick and the volley is
  # OBSERVED by driving ticks. Every 0314 clause above is unchanged; these are the lines the repoint
  # added, and each pattern is worded so it matches exactly ONE line (PIRATEFIRE carries its own
  # near-identical wording a thousand lines up — a shortened pattern here would match THAT line and
  # this block could then be gutted with the grep still passing).
  grep -q "pirate salvo(s) on the tick the wave arrived on"       "$SQL" || fail "harness lacks the RSFEEL wave-is-SILENT-on-its-spawn-tick assert (the property only 0336 makes statable)"
  grep -q "the arrival tick is numbered"                          "$SQL" || fail "harness lacks the RSFEEL arrival-tick-is-tick-1 pin (the silence assert must read the tick the wave actually arrived on)"
  grep -q "no pirate volley in 12 ticks after the spawn"          "$SQL" || fail "harness lacks the RSFEEL bounded closing-loop failure (a wave that never fires must fail loudly, not hang)"
  grep -q "the volley loop observed nothing"                      "$SQL" || fail "harness lacks the RSFEEL non-vacuity pin (the volley must land strictly after the silent spawn tick)"
  grep -q "the encounter went % while the wave was closing"       "$SQL" || fail "harness lacks the RSFEEL approach-not-interrupted guard"
  grep -q "pirate salvo(s) on the volley tick"                    "$SQL" || fail "harness lacks the RSFEEL full-volley vacuity guard (the measured tick must carry a real volley)"
  grep -q "the tick after the volley did not advance"             "$SQL" || fail "harness lacks the RSFEEL cadence pin (the silence tick must be the volley tick + 1)"
  grep -q "set_game_config('combat_player_speed_scale',       '0'" "$SQL" \
    || fail "harness lost RSFEEL's held-anchor precondition — a KITING hull makes one arc of the wave's ring arrive before another, and \"six identical guns in ONE tick\" becomes a statement about a split volley"
  grep -q "set_game_config('combat_player_speed_scale',        to_jsonb(v_ps_before))" "$SQL" \
    || fail "RSFEEL borrows combat_player_speed_scale without giving it back (every block after it would inherit a frozen player fleet)"
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
  # 0336 REPOINT of the old command-ship-fires-tick-1 pin. That assert held only because the wave
  # spawned ON the engagement anchor, which is where the lead stands; 0336 moves the wave onto a
  # formation ring, so nothing sits at distance 0 any more and an escort (on the ring) is ALWAYS
  # nearer the wave than the lead (on the anchor) — there is no radius that rescues it. The property
  # is repointed to the STRONGER statement 0336 actually establishes, quantified over BOTH sides:
  # the opening tick of a fight is silent because the wave arrives outside every gun on the field.
  grep -q "the opening tick cannot start instantly any more"      "$SQL" || fail "harness lacks the CLOSURE silent-opening-tick assert (the 0336 repoint of the command-ship-fires-tick-1 pin)"
  grep -q "did not move off its own ring spawn point"             "$SQL" || fail "harness lacks the CLOSURE pirate-moved-off-its-OWN-spawn-point assert (comparing against the engagement anchor went vacuous the moment 0336 stopped spawning there)"
  grep -q "or the CLOSE step is no longer capped by move_speed"   "$SQL" || fail "harness lacks the CLOSURE exact-step pin (the one line that fails loudly if the wave stops spawning where combat_formation_point puts it)"
  grep -q "spawn gap does not exceed both ranges"                 "$SQL" || fail "harness lacks the CLOSURE measured-spawn-gap premise (seeding the recurrence with the ring is only correct while the pirate stands on the anchor)"
  # ── THE WAVE RADIUS HAS ONE AUTHORITY, AND IT IS THE MEASURED FORMATION EXTENT ────────────────
  # An earlier draft OWNED spatial_formation_ring_radius: it solved for a ring, wrote the knob AFTER
  # the encounter was created, and predicted the wave's spawn point from the value it wrote. 0336
  # does not read that knob to place a wave — it measures `max(distance from the anchor to each
  # LIVING player unit)` — so the escort spawned on the committed ring, the wave stood clear of THAT,
  # and the two authorities drifted apart. CI caught it as `the pirate moved 1.9398 from the slot-0
  # formation point but its own frozen move_speed is 1`. The solve is DELETED, not corrected. These
  # greps are what stop a second lever growing back.
  grep -q "the MEASURED formation extent, which is the one authority for the wave radius" "$SQL" \
    || fail "harness lacks the CLOSURE one-authority pin (the wave radius is the measured extent; a block predicting from the ring knob is predicting from something that no longer controls it)"
  grep -q "derived its spawn point for"                           "$SQL" || fail "harness lacks the CLOSURE derived-vs-actual wave pin (the spawn point is derived from a PREDICTED range/speed before the wave exists, so the spawned row must agree with the prediction)"
  grep -q "some other hull is now the outermost one"              "$SQL" || fail "harness lacks the CLOSURE extent-is-the-escort pin (a further-out hull would make the wave stand clear of THAT one, and the chord this block models would be the wrong one)"
  grep -q "the measured extent below would not be this formation" "$SQL" || fail "harness lacks the CLOSURE positioned-living-player non-vacuity guard (a defaulted extent of 0 looks exactly like a lone hull standing on the anchor)"
  grep -q "the escort-to-wave spawn gap measures"                 "$SQL" || fail "harness lacks the CLOSURE measured-gap NULL/positive pin"
  grep -q "an id-ordered pick over a larger wave would not find"  "$SQL" || fail "harness lacks the CLOSURE one-unit-wave pin (combat_units.id is a random uuid, so slot 0 is only identifiable while the wave is a single unit)"
  grep -q "it either closed on a different hull than the lowest-aggro escort" "$SQL" \
    || fail "harness lacks the CLOSURE exact-landing-point pin (step LENGTH alone would pass for a step in any direction; the end point pins the target choice, the direction and the cap together)"
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
  # ── 0336 REPOINT OF THE LEAD BLOCK'S BEHAVIOURAL HALF ─────────────────────────────────────────
  # It asserted a TICK-1 salvo from the lead, with zero escort salvos as the attribution, premised on
  # `ring > escort range`. All three were statements about the pre-0336 world and two of them are
  # INVERTED, not merely late: this fixture is THREE hulls, so the extent is the escort ring and the
  # lead — alone on the anchor — is a full RADIUS from the wave (11.0) while each escort is a CHORD
  # from it (5.92). The escorts are NEARER and open the fight; the lead is the last hull that can
  # reach, and no ring radius inverts a chord and a radius. The defect the block guards (a flagless
  # fleet opens a fight it cannot join) is now proven by TWO things, and neither is "fires
  # eventually": the fleet joins on exactly the tick the engine's own recurrence predicts, and the
  # lead is proven to be CLOSING off the anchor by exactly its own frozen move_speed.
  grep -q "a flagless fleet still opens a fight its lead cannot join" "$SQL" \
    || fail "harness lacks the LEAD is-CLOSING-off-the-anchor assert (the direct 'it can join' evidence, and strictly more than the old form, which only proved the lead fired BECAUSE it stood at distance 0)"
  grep -q "the fleet never fired within 12 ticks of the spawn"    "$SQL" || fail "harness lacks the LEAD bounded joining loop (a fleet that cannot join must fail loudly, not hang)"
  grep -q "the fleet joined its fight on tick % but the engine"   "$SQL" || fail "harness lacks the LEAD predicted-equals-observed joining tick (growing silence must fail here, not pass as 'fires eventually')"
  grep -q "the fleet needs % ticks to join its own fight"         "$SQL" || fail "harness lacks the LEAD joining-tick upper bound (the sprawl must fail here, not in a playtest)"
  grep -q "there would be nothing to close and the silent opening tick above would be vacuous" "$SQL" \
    || fail "harness lacks the LEAD joining-tick lower bound (a hull already in range at spawn makes the silent opening tick vacuous)"
  grep -q "so the lead is not the screened hull any more"         "$SQL" \
    || fail "harness lacks the LEAD attribution, repointed: the lead must be STRICTLY FURTHER from the wave than every escort (that is the screen working, and it is the inverse of the dead 'only the lead can reach' premise)"
  grep -q "a hull could open the fight from its spawn slot"       "$SQL" || fail "harness lacks the LEAD silent-spawn-tick premise (measured on the escort-to-wave gap, which is the gap that decides who can fire — never the ring)"
  grep -q "salvo(s) on the spawn tick"                            "$SQL" || fail "harness lacks the LEAD silent-opening-tick assert (the property only 0336 makes statable)"
  grep -q "an opener that is not an escort"                       "$SQL" || fail "harness lacks the LEAD opener-is-the-nearest-hull assert"
  grep -q "the measured extent would not be this formation"       "$SQL" || fail "harness lacks the LEAD positioned-living-player non-vacuity guard"
  grep -q "the derivation overrode a real command ship"           "$SQL" || fail "harness lacks the flagged-fleet control assert (the fallback is never an override)"
  grep -qF "flagged ship(s) were provisioned into the flagless fleet" "$SQL" || fail "harness lacks the no-command-ship precondition assert (owned, never inherited)"
  grep -q "the single hull did not lead"                          "$SQL" || fail "harness lacks the single-hull-fleet assert"
  grep -q "an unpositioned hull cannot prove where it spawned"    "$SQL" || fail "harness lacks the LEAD NULL-coordinate pin"
  grep -q "the anchor this assert measures from does not exist"   "$SQL" || fail "harness lacks the LEAD engagement-anchor NULL pin"
  # 0317 — THE DEAD DO NOT SHOOT. The first three are the pre-0317 REDS (the head produced TWO of
  # each in a mutual-kill tick because the loser fired after dying); the rest are what stops the
  # block passing for the wrong reason — the loser must have been a live threat, the survivors must
  # still act (the way this fix could go green by breaking the fight), and the population freeze must
  # still be the thing that decides targeting.
  grep -q "a unit that was destroyed earlier in the tick still fired" "$SQL" \
    || fail "harness lacks the one-salvo-per-mutual-kill assert (the pre-0317 red: the loser fired after its own destruction)"
  grep -q "the dead unit dealt damage after its own destruction"  "$SQL" \
    || fail "harness lacks the one-landed-hit assert (a posthumous shot must deal nothing, not merely be logged)"
  grep -q "the loser still fired from beyond the grave"           "$SQL" \
    || fail "harness lacks the exactly-one-death assert (on the head a mutual kill killed both)"
  grep -q "the loser could not have killed its target anyway"     "$SQL" \
    || fail "harness lacks the mutual-kill non-vacuity guard (the silenced unit must have been able to destroy the survivor)"
  grep -q "the survivor took damage from a unit that was already destroyed" "$SQL" \
    || fail "harness lacks the survivor-is-unhit assert"
  grep -q "a living unit went silent"                             "$SQL" \
    || fail "harness lacks the survivors-still-act assert (the failure mode where 0317 goes green by silencing everybody)"
  grep -q "the second shooter re-acquired a live target"          "$SQL" \
    || fail "harness lacks the frozen-snapshot assert (0317 must re-read the ACTOR's liveness only, never the population)"
  grep -q "the second shot must land on a corpse and deal nothing" "$SQL" \
    || fail "harness lacks the corpse-shot assert (the positive proof that targeting was not re-read)"
  grep -q "the dead unit fired after its own destruction"         "$SQL" \
    || fail "harness lacks the both-sides ordering invariant (no salvo at a seq later than the destruction event naming its firer)"
  grep -q "the ordering invariant would be vacuous"               "$SQL" \
    || fail "harness lacks the ordering-invariant vacuity guard (it must quantify over real destructions)"
  # 0332 — A WRECK CAN ALWAYS COME HOME, in assert-form. The first is the pre-0332 RED (the settle
  # arm filtered its dead members out and gave them no terminal write, so the casualty of a fight
  # the fleet SURVIVED ended at hp 0 / status 'home' — recoverable by nothing). The rest are what
  # stops the block passing for the wrong reason: the fleet must actually survive with exactly one
  # casualty (or the DEFEAT arm, which always reconciled, would be doing the work), the survivor's
  # hp-0-but-alive trap must be armed (or an hp-shaped "fix" would pass), and the recovery must be
  # proven reachable, owner-scoped and non-destructive of the hull's capacity.
  grep -q "a hull at 0 that the settle arm never marked"          "$SQL" \
    || fail "harness lacks the settle-arm-reconciles assert (the pre-0332 red: a fight the fleet survived left its casualty unrecoverable)"
  grep -q "this block needs EXACTLY ONE casualty beside a survivor" "$SQL" \
    || fail "harness lacks the WRECKHOME window premise (0 dead makes property 1 vacuous; both dead hands the work to the DEFEAT arm, which was never broken)"
  grep -q "the aggro concentration this block relies on did not hold" "$SQL" \
    || fail "harness lacks the WRECKHOME casualty-identity pin (the fight it staged must be the fight it describes)"
  grep -q "something other than the settle arm reconciled it"     "$SQL" \
    || fail "harness lacks the WRECKHOME attribution pin (the wreck must still be unreconciled immediately BEFORE the settle, or property 1 cannot be attributed to the arm under test)"
  grep -q "a merely damaged ship was wrecked by the settle"       "$SQL" \
    || fail "harness lacks the damaged-but-alive survivor assert (the 0312 fractional-hull law: an hp-shaped reconciliation passes property 1 and must fail here)"
  grep -q "the hp-predicate trap is not armed"                    "$SQL" \
    || fail "harness lacks the WRECKHOME hp-trap non-vacuity guard (the survivor's unit must really still be alive while its instance row reads 0)"
  grep -q "the recovery UI 0297 shipped keys on exactly this read" "$SQL" \
    || fail "harness lacks the wreck-is-listed assert (server verbs the client cannot see leave the player just as stuck)"
  grep -q "must accept exactly the ships the position gate rejects" "$SQL" \
    || fail "harness lacks the tow-accepts-the-reconciled-wreck assert (0297's escape hatch, end to end)"
  grep -q "a wreck must keep the capacity its owner paid for"     "$SQL" \
    || fail "harness lacks the max_hp-survives assert (a wreck at max_hp<=0 raises invalid max_hp and can never be repaired — the 0052 softlock)"
  grep -q "another player towed a wreck they do not own"          "$SQL" \
    || fail "harness lacks the owner-scoped tow refusal assert"
  grep -q "another player repaired a wreck they do not own"       "$SQL" \
    || fail "harness lacks the owner-scoped repair refusal assert"
  grep -q "a fight it was never in must not touch a ship that was already destroyed" "$SQL" \
    || fail "harness lacks the already-destroyed-bystander assert (the shape the real destroyed ships in production carry must be undisturbed)"
  grep -q "this slice must not have touched the recovery path that already worked" "$SQL" \
    || fail "harness lacks the bystander-still-repairs assert"
  grep -q "the fleet was wiped before the auto-exit could arm"    "$SQL" \
    || fail "harness lacks the WRECKHOME erosion premise (a wipe routes through the DEFEAT arm and the settle arm under test would never run)"
  grep -q "public.get_my_disabled_ships("                         "$SQL" \
    || fail "harness does not read the client's own wreck list (0297 §4) — the seam where a reconciled wreck becomes a button the player can press"
  # 0334 — A WRECK IS WHERE ITS FLEET IS, in assert-form. The first is the pre-0334 RED (a ship that
  # owns no per-ship fleet resolves none, and being grouped can hold no berth, so the two-arm body
  # had NO position for it and demanded a tow to a port its fleet was already at). The rest stop the
  # block passing for the wrong reason: the group must have no unified fleet (a group that has one
  # was never broken), the fleetmate's fleet must not be group-tagged (or the member-ownership
  # clause — the load-bearing half of the fix — goes untested), no tow may have occurred, and the
  # tow must still be required and still work for a wreck that is genuinely nowhere.
  # NOTE: matched on an apostrophe-free phrase on purpose — the assert text lives inside a SQL
  # string literal, so every apostrophe in it is DOUBLED and a natural-English pattern will not hit.
  grep -q "as a fleet we have arrived at a dock already"          "$SQL" \
    || fail "harness lacks the wreck-is-at-its-fleets-dock assert (the pre-0334 red: a docked fleet's wreck had no position at all)"
  grep -q "a group with a unified fleet was NEVER broken"         "$SQL" \
    || fail "harness lacks the DOCKWRECK staging premise (a group that owns a unified fleet resolves through branch 1 and proves nothing about the defect)"
  grep -q "then a tagged-only implementation would pass"          "$SQL" \
    || fail "harness lacks the member-ownership pin (the fleetmate's commission fleet must carry no group_id, or the clause the fix turns on is never exercised)"
  grep -q "the pre-0334 dead end is not staged"                   "$SQL" \
    || fail "harness lacks the DOCKWRECK red premise (the wreck must resolve NO fleet, or the old body could have answered)"
  grep -q "the old berth arm would already have answered"         "$SQL" \
    || fail "harness lacks the no-berth premise (a berthed wreck was never the broken case)"
  grep -q "disagreeing about where they are"                      "$SQL" \
    || fail "harness lacks the living-and-wrecked-agree assert (the invariant whose absence produced this defect)"
  grep -qF 'the client shows "Tow to the nearest port" and disables Repair' "$SQL" \
    || fail "harness lacks the at_port-is-what-the-client-reads assert (a server fix the Ships tab cannot see is half a slice)"
  grep -q "the signature of a tow the owner said should not be needed" "$SQL" \
    || fail "harness lacks the no-tow-occurred assert (the ship must keep its place in the fleet — an un-grouped berthed ship means it was hauled)"
  grep -q "must answer only from a dock the fleet actually holds" "$SQL" \
    || fail "harness lacks the never-invent-a-dock assert (a wreck whose group holds no docked fleet must still resolve nothing)"
  grep -q "must not have broken the escape hatch"                 "$SQL" \
    || fail "harness lacks the tow-still-works assert (0297's escape hatch must survive for the case it was built for)"
  grep -q "the position gate must still be the thing that answers" "$SQL" \
    || fail "harness lacks the nowhere-wreck reject-code assert (repair must still refuse with not_at_port, not some other reason)"
  grep -q "public.fleet_docked_location("                         "$SQL" \
    || fail "harness does not compose the 0306 docked authority when asserting the nowhere premise — it would be re-stating the docked test instead of using the one the fix uses"

  # ── 0336 COMBAT ENGINE REPAIRS, in assert-form. Every one of the eight blocks is RED by
  # construction on the pre-0336 tick, and these pins are what stops a block being deleted, or
  # quietly weakened, without CI noticing. Every vacuity guard gets its own pin beside its property,
  # because on this chain the guard is the half that rots first.
  # NOTE: matched on apostrophe-free phrases on purpose — the assert text lives inside a SQL string
  # literal, so every apostrophe in it is DOUBLED and a natural-English pattern will not hit.
  #
  # OWNWORLD — the proof owns its zone world (the randomly-shaped-seed flake, ended).
  grep -q "randomly-shaped seeded zone(s) are still active"       "$SQL" || fail "harness lacks the OWNWORLD deactivation assert (a seeded blob redrawn with random() on every CI database would keep covering a fixed test coordinate at random)"
  grep -q "seeded ZERO active non-drawn danger zones"             "$SQL" || fail "harness lacks the OWNWORLD non-vacuity guard (an empty seed satisfies the deactivation asserts while proving nothing)"
  grep -q "active zone(s) remain before any fixture is drawn"     "$SQL" || fail "harness lacks the OWNWORLD ordering pin (it must run before the first pirate_zone_create or it is not establishing the world it claims)"
  # RANGEINVARIANT — a wave must never arrive inside its own reach. There is deliberately NO grep for
  # a knob inequality (`ring > enemy_range(D)`) and there must never be one again: 0336 spawns the
  # wave at `ring + THAT WAVE'S OWN range + 1`, so the clearance is structural and an inequality
  # between two knobs would be asserting a coincidence that goes red the moment either knob moves.
  # The measured form below replaces it and is strictly stronger — it witnesses the geometry.
  grep -q "not one location carries a positive base_difficulty"   "$SQL" || fail "harness lacks the RANGEINVARIANT empty-location-set vacuity guard"
  grep -q "fall outside this quantifier"                          "$SQL" || fail "harness lacks the RANGEINVARIANT NULL-difficulty pin (a row with an unknown difficulty slips out of the quantifier unnoticed)"
  grep -q "inside the wave own reach of"                          "$SQL" || fail "harness lacks the RANGEINVARIANT measured-on-a-real-wave assert (a knob inequality that stopped describing the geometry would pass the arithmetic and fail here)"
  grep -q "there is no wave to measure"                           "$SQL" || fail "harness lacks the RANGEINVARIANT empty-wave vacuity guard"
  grep -q "it stops in the kite band at"                          "$SQL" || fail "harness lacks the RANGEINVARIANT kite-band assert (spawning outside its own reach is not enough if the closing enemy STOPS beyond the player shortest gun)"
  # VOLLEY — a kill does not disarm the rest of the volley.
  grep -q "the target was resolved ONCE above the per-weapon loop" "$SQL" || fail "harness lacks the VOLLEY distinct-targets assert (the pre-0336 red: three guns, one target)"
  grep -q "landed hit(s) from a three-gun volley"                 "$SQL" || fail "harness lacks the VOLLEY three-landed-hits assert"
  grep -q "destroyed by a three-gun volley"                       "$SQL" || fail "harness lacks the VOLLEY three-kills assert"
  grep -q "one gun does not one-shot it"                          "$SQL" || fail "harness lacks the VOLLEY one-shot-sizing pin (if a pirate survived a single gun the re-aim could not happen on ANY body)"
  grep -q "the wave must hold strictly more pirates than the ship has guns" "$SQL" || fail "harness lacks the VOLLEY wave-size vacuity guard (the last gun must have something left to re-aim at)"
  grep -q "this block is about a THREE-gun ship"                  "$SQL" || fail "harness lacks the VOLLEY three-guns-really-fitted fixture pin"
  grep -q "name no target at all"                                 "$SQL" || fail "harness lacks the VOLLEY NULL-target pin (a distinct count over NULLs proves nothing)"
  # WAVERING — a wave arrives on a ring, not on one point.
  grep -q "the whole wave was inserted at one identical point"    "$SQL" || fail "harness lacks the WAVERING distinct-positions assert (the pre-0336 red: production holds every wave at exactly ONE position)"
  grep -q "the wave is still being planted on the anchor itself"  "$SQL" || fail "harness lacks the WAVERING nobody-on-the-anchor assert"
  grep -q "it is not one ring"                                    "$SQL" || fail "harness lacks the WAVERING equidistant-radius assert"
  grep -q "sit on a slot of combat_formation_point(anchor"        "$SQL" || fail "harness lacks the WAVERING formation-leaf assert (the radius is MEASURED and every unit must be reproduced by the leaf at half-slot phase on a slot no other unit used — so a later change to the spawn radius cannot make this block wrong)"
  grep -q "a ring cannot be told apart from a point or a line"    "$SQL" || fail "harness lacks the WAVERING wave-size vacuity guard"
  grep -q "an unpositioned wave cannot prove it arrived anywhere" "$SQL" || fail "harness lacks the WAVERING NULL-coordinate pin (the 0313 law)"
  # RETREATNOSPAWN — pressing Retreat does not summon a bigger wave.
  grep -q "wave_spawned event(s) fired on the retreat tick"       "$SQL" || fail "harness lacks the RETREATNOSPAWN no-spawn assert (the pre-0336 red: four production encounters died to the wave their own Retreat summoned)"
  grep -q "the transition window is still OPEN"                   "$SQL" || fail "harness lacks the RETREATNOSPAWN transition-window vacuity guard (with the window open the head takes the next_wave_incoming pause and this block goes green on the defect)"
  grep -q "the wave was never cleared"                            "$SQL" || fail "harness lacks the RETREATNOSPAWN wave-really-cleared premise"
  grep -q "living pirate(s) exist after the retreat tick"         "$SQL" || fail "harness lacks the RETREATNOSPAWN no-living-enemy assert"
  grep -q "the wave counter advanced"                             "$SQL" || fail "harness lacks the RETREATNOSPAWN wave-counter assert"
  grep -q "it completed instead of running the combat step"       "$SQL" || fail "harness lacks the RETREATNOSPAWN still-retreating pin (a tick that took the completion branch never evaluated the spawn guard)"
  # NOWEDGE — a terminal-arm mismatch concludes instead of wedging.
  grep -q "the encounter is wedged retrying the identical tick forever" "$SQL" || fail "harness lacks the NOWEDGE reaches-a-terminal-status assert (the pre-0336 red)"
  grep -q "last_resolved_at went BACKWARDS"                       "$SQL" || fail "harness lacks the NOWEDGE cadence-clock-advanced assert (reaching a terminal status is not what separates the bodies; the head rolls the whole tick back)"
  grep -q "tick_number did not advance"                           "$SQL" || fail "harness lacks the NOWEDGE tick-advanced assert"
  grep -q "the mismatch this block exists to survive was never created" "$SQL" || fail "harness lacks the NOWEDGE mismatch-really-exists guard"
  grep -q "presence_complete accepted the already-completed presence without raising" "$SQL" || fail "harness lacks the NOWEDGE the-leaf-really-raises guard (without it a body with no confinement at all would pass)"
  grep -q "the wave never landed a hit in 10 ticks"               "$SQL" || fail "harness lacks the NOWEDGE reachability guard (the fixture must be able to reach a terminal arm)"
  grep -q "must still CONCLUDE the encounter"                     "$SQL" || fail "harness lacks the NOWEDGE terminal-status assert"
  # ORDERSTABLE — the actor loop order is decided, not heap order.
  grep -q "acted out of id order on tick"                         "$SQL" || fail "harness lacks the ORDERSTABLE id-ascending-seq assert (the ORDER BY effect, stated as itself rather than as a difference from something)"
  grep -q "an id-ascending sequence is not evidence of an ORDER BY" "$SQL" || fail "harness lacks the ORDERSTABLE firing-population vacuity guard (with too few firing units the head satisfies this by coincidence)"
  grep -q "they must be CONSECUTIVE"                              "$SQL" || fail "harness lacks the ORDERSTABLE consecutive-ticks premise"
  grep -q "an ordering over NULLs is vacuous"                     "$SQL" || fail "harness lacks the ORDERSTABLE NULL-unit_id pin"
  grep -q "name a unit that is not in this encounter"             "$SQL" || fail "harness lacks the ORDERSTABLE ids-are-really-combat_units-ids pin"
  # SHORTGUN — a longer gun no longer disables a shorter one.
  grep -q "so it parks at the long gun edge and the short gun is silently disabled" "$SQL" || fail "harness lacks the SHORTGUN both-guns-fire assert (the pre-0336 red: my_range was max(range) for BOTH the close decision and the kite cap)"
  grep -q "the kite cap is still the longest gun"                 "$SQL" || fail "harness lacks the SHORTGUN settled-distance assert (the hull must come to rest inside its SHORTEST gun)"
  grep -q "there was never a tick on which only the LONGER gun could reach" "$SQL" || fail "harness lacks the SHORTGUN band vacuity guard (the fixture must pass through the band the head parks in, or a green run says nothing)"
  grep -q "it never had to close"                                 "$SQL" || fail "harness lacks the SHORTGUN starts-outside-both-ranges premise"
  grep -q "they must differ, with one strictly SHORTER"           "$SQL" || fail "harness lacks the SHORTGUN mixed-range fixture pin"
  grep -q "a ship that cannot move can never settle anywhere"     "$SQL" || fail "harness lacks the SHORTGUN move_speed vacuity guard"
  # RETREATCLEAR — every terminal arm consumes fleets.retreat_target_*.
  grep -q "the DEATH arm left the retreat destination behind"     "$SQL" || fail "harness lacks the RETREATCLEAR death-arm assert (the pre-0336 red: three of the four arms leaked the recording into the next sortie)"
  grep -q "the SETTLE arm left the retreat destination behind"    "$SQL" || fail "harness lacks the RETREATCLEAR settle-arm assert (not a regression test — it is what stops the shared leaf being dropped from the arm that always did this correctly)"
  grep -q "cleared the recording without READING it"              "$SQL" || fail "harness lacks the RETREATCLEAR consumed-means-read-and-clear assert (the return leg must depart for the point the player ordered)"
  grep -q "there is nothing for a terminal arm to leak"           "$SQL" || fail "harness lacks the RETREATCLEAR destination-really-armed guard"
  grep -q "that order repositions instead of retreating"          "$SQL" || fail "harness lacks the RETREATCLEAR unadmitted-destination guard (an admitted point repositions under 0311 and records nothing)"
  grep -q "would be re-proving part (B)"                          "$SQL" || fail "harness lacks the RETREATCLEAR death-arm attribution pin (a completed retreat routes through the settle arm, which was never broken)"
  grep -q "owned the knob and did not give it back"               "$SQL" || fail "harness lacks the 0336 formation-ring leak pin (every block below RANGEINVARIANT owns that knob; a restore that leaks would silently repoint the invariant instead of failing)"

  # determinism: no session random() (0041 law). gen_random_uuid() is fixture identity only.
  grep -qE '[^_]random\(' "$SQL" && fail "harness uses random() (0041 determinism law)" || true

  tp_assert_out_of_scope "$SQL"

  echo "DANGER-ZONE COMBAT SELFTEST: ALL PASSED (self-rolling-back; every dark flag enabled only inside the txn; combat_telegraph kept dark; risk knobs = 1.0 for a certain plan; sole-writer law for group_sortie_members + combat_units AND for the intercept lifecycle/geometry — only a symmetric depart/arrive/trigger time-travel is allowed; provisioning + entry 100% real-RPC incl. pirate_zone_create, command_ship_group_go, command_ship_group_go_route, command_ship_group_stop and set_group_auto_exit; the ambush is fired by the REAL process_fleet_movements and the single direct resolver call is the negative re-fire probe; exactly 2 known tick call sites (0336 folded PIRATEFIRE hand-rolled rewind-then-tick into pg_temp.ae_tick); every property — the order starts a journey and no fight, the point is the zone EDGE not its centre, trigger_at is the leg's own interpolated clock, nothing fires early, the arrival cannot be settled past a due ambush, the fleet parks at the entry point, the route is abandoned, engagement_x/y equals the entry point with the command ship seeded on it, it cannot fire twice, stop/re-order before due cancels and re-plans while stop after due is refused, positioned spatial units, and (0336) a wave that arrives SILENT on its spawn tick, CLOSES, and then fires a salvo whose unit_id/target_id RESOLVE to real rows, taking real damage back; the 0310 HP auto-exit fires at the player's threshold of REAL CAPACITY and never earlier, never re-requests, completes like a human press, exits a damaged fleet on re-entry (the compounding-denominator regression) and stays silent with the toggle OFF; and (0311) an in-zone order REPOSITIONS the fight (exact-delta translate, restamp, no retreat write, no leg), overlapping zones are QUANTIFIED over rather than chosen (a lower-area holder can neither veto nor decide), a destination admitted by no anchor-holding zone retreats byte-identically, a retreating fight never jumps, and a site fight falls through to the retreat — never repositioned, never refused — asserted in assert-form; no random() and the 0312 no-living-ships law — a dead fleet is refused go/go_route/dock with the typed no_living_ships and mints nothing, a damaged-but-alive hp-0 ship still moves, empty_group stays its own state, and the recovery path (brake/tow/repair/re-assign) works on exactly the dead fleet; and the 0313 CLOSURE properties (the escort-pirate spawn gap is MEASURED off combat_formation_point at the radius the tick itself derives -- the MEASURED formation extent plus the wave own range plus one, the ONE authority for a wave radius, with no geometry knob written by the block at all -- and exceeds the seeded cut ranges, the opening tick is silent on BOTH sides because 0336 moved the wave off the anchor and outside every gun on the field, escort + pirate MOVE and hold fire until their own pre-move distance is inside their own range, and every positional comparison is NULL-pinned so absence is failure rather than a silent pass); and the 0314 RuneScape feel — a 3600s-cooldown wave holds fire on tick 2 while a zero-cooldown weapon keeps firing, six identical guns roll distinct damage in one tick, every landed hit emits its visible hull_damage under EVENT logging with debug pinned dark, and every fired clock armed now()+cooldown exactly); and the 0315 LEAD law — a fleet with NO command ship anywhere still elects one hull by the stated rule (a real flag first, then the greatest max_hp, then the lowest main_ship_id, over living hulls), anchors exactly THAT hull on the engagement point at aggro 100 with every escort at 0 on its unchanged ring slot, and (0336 re-premised) the opening tick is SILENT across the field while the lead CLOSES off the anchor by exactly its own frozen move_speed, the fleet then joining its fight on EXACTLY the tick the engine own recurrence predicts, opened by an escort -- the lead being a full RADIUS from the wave where an escort is a CHORD, which is the screen working; a fleet that DOES carry a designated command ship is placed exactly as today even when the fallback would name a different hull on both derived keys; and a single-hull fleet is its own lead; and the 0316 FIVE-TIMES-TIGHTER geometry — the CLOSURE block now runs the engine own recurrence over the encounter real ring, weapon range and frozen move_speeds, demands the escort reach firing range within one or two silent closing ticks, demands the OBSERVED first salvo land on exactly the tick that recurrence predicts, and refuses a pirate that crosses the whole ring in a single step: a range cut made without the matching ring and speed cuts fails here instead of in a playtest; and the 0317 DEAD-DO-NOT-SHOOT law — a mutual one-shot kill now produces exactly ONE salvo, ONE landed hit and ONE destroyed unit (the head produced two of each), the silenced loser is proven to have been able to destroy the survivor, every surviving pirate still fires and both hulls still fire at the pirate the FROZEN snapshot named with only one of the two shots landing, and across both staged fights no unit emits an attack event at a seq later than the destruction event naming it'; and the 0331 ONE-AUTHORITY-FOR-ATTACK law — a ship's weapons_json totals to EXACTLY its folded combat_power, a ship trait (a source no weapon row can carry) moves the damage by exactly its own attack, two identical guns SHARE that power in equal parts summing to 1 instead of each carrying it, the no-weapon hull obeys the same identity through the synthesized weapon with the old power_from_attack knob deleted, and the stronger gun never deals less than the weaker one — every one of those RED on the pre-0317 builder, each with its own non-vacuity pin so none can pass on a fold that happens to equal the catalog weight and (0336) the COMBAT ENGINE REPAIRS -- the proof first OWNS its zone world by deactivating every randomly-shaped seeded zone in-txn (the flake that failed and passed on identical commits, ended at the source rather than by widening a guard); a wave must never arrive inside its own reach -- MEASURED on a real staged wave (min distance from every player unit to every enemy against the wave own frozen range) rather than inferred from a knob inequality, because 0336 makes that clearance structural (spawn radius = ring + that wave own range + 1) and an inequality between two knobs would assert a coincidence; plus the kite band the closing enemy actually stops in, over EVERY location with a positive difficulty including hidden ones; a THREE-gun hull meeting a wave larger than its gun count fires 3 salvos at 3 DISTINCT targets for 3 landed hits and 3 kills (the head resolved the target once above the per-weapon loop and dropped guns 2 and 3); a wave arrives on a RING -- every unit on its own point, none on the anchor, all at one MEASURED radius and every one of them reproduced by combat_formation_point at half-slot phase on a slot no other unit used; pressing Retreat with the transition window PROVEN closed raises no wave_spawned, adds no enemy row and moves neither wave counter; a terminal arm meeting a presence that was completed out of band (with presence_complete PROVEN to raise for it) still CONCLUDES the encounter and advances both last_resolved_at and tick_number instead of rolling the tick back forever; six firing units emit their salvos in ascending combat_units.id on two consecutive ticks; a hull carrying an autocannon beside an Mk-II passes through the band where only the Mk-II reaches and then settles inside its SHORTEST gun with both module types on the record; and a fleet that DIES with a recorded retreat destination comes back with all three retreat_target_* columns NULL while the settle arm still both clears that recording and USES it -- each with its own non-vacuity pin, and a formation-ring leak pin so a block that owns the knob and fails to give it back cannot silently repoint the range invariant'"
  exit 0
fi

: "${DB_URL:?DB_URL (disposable stack) required}"
tp_run_local "DANGER-ZONE COMBAT" "$SQL" "$PASS_LINE" "$MARKERS"
echo "DANGER-ZONE COMBAT LOCAL PROOF: OVERALL_PASS"
