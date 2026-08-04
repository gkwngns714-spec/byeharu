// THE ONE reject-copy map for every fleet surface — pure and fail-closed (the tradeReasonMessage/
// haulReasonMessage idiom verbatim). Maps the ACTUAL server reject vocabulary of the fleet RPCs —
// the hunt send (0168), the roster writes (0161/0204/0216), the auto-exit writer (0310), the
// unified mover/brake/dock (0207/0208/0209/0219/0292/0298), the route planner (0233), and the
// totals/preview reads (0165/0166) —
// plus the teamApi transport fallback ('unavailable') to short player-facing text; any unmapped/
// unknown reason degrades to a generic "Fleet order unavailable." so the UI never surfaces a raw
// code and never throws. No React/DOM/state — unit-tested in tests/teamReasonMessage.spec.ts.
//
// ONE MAP, NOT SEVERAL (no-spaghetti): the roster panel, the preview/totals section and the
// pirate-route panel used to interpolate `res.reason` STRAIGHT INTO player copy ("Couldn't complete
// that action (group_fleet_elsewhere)."). They now all route here. The route planner belongs here
// too rather than in a map of its own: its first leg COMPOSES command_ship_group_go, so its rejects
// are this vocabulary — a second map would have had to duplicate all of it.

import { HOW_A_FIGHT_STARTS } from './howAFightStarts'

const REASON_MESSAGES: Record<string, string> = {
  // shared prefix (every fleet RPC, 0161/0165/0166/0168/0204/0216/…)
  team_command_disabled: 'Fleet commands are not available right now.',
  not_authenticated: 'Sign in to command fleets.',
  group_not_found: 'That fleet no longer exists.',
  // "Fleet tab" — the nav destination's real name (navTabs.ts); the old "Fleets panel" named a
  // surface that no longer exists as such.
  empty_group: 'That fleet has no ships yet — add ships on the Fleet tab.',
  // NO LIVING SHIPS (0312) — every ship in the group is wrecked, so the mover/dock refuse the
  // order. DISTINCT from empty_group: that fleet has no ships at all; this one has ships and they
  // are all disabled. The copy says what to actually do — the recovery path is per-ship (Fitting
  // screen: Repair in port, Tow when adrift — shipRecovery.ts), never another fleet order.
  no_living_ships: 'Every ship in this fleet is wrecked — repair them (or tow them to a port first) from the Ships screen, then give the order again.',
  // hunt send (0168)
  invalid_location: 'This destination can’t take a fleet right now.',
  // shared readiness reject: hunt (0168 — every ship home and battle-ready) and docked-team move
  // (0190 — every ship docked together at one port)
  member_not_ready: 'Every ship in the fleet must be free first — idle for a hunt, docked together for a move.',
  fleet_limit_reached: 'Too many fleets are already deployed — wait for one to return.',
  stats_invalid: 'The fleet’s stats couldn’t be verified — check each ship on the Fleet tab.',
  power_below_required: 'The fleet’s combat power is below what this zone requires.',
  no_home_base: 'The fleet has no port to launch from.',
  // preview/totals reads (0165/0166)
  invalid_activity: 'That activity isn’t recognized for fleet orders.',
  // FLEET-CONTROL (0204): the fleet control-model rejects (movement RPCs + assign cap + command-ship setter)
  //
  // THE ONE SENTENCE FOR THE COMMAND-SHIP RULE (owner, 2026-08-04, playing: "i am in snare but in no
  // fight is occuring"). This is the FIRST thing send_ship_group_hunt checks — 0330:1353-1359, before
  // the destination is even read — and of the 77 ships live on production only 2 carry the flag
  // (measured in 0335:5-8). So it is the likeliest reason a fleet standing on a pirate site refuses
  // to fight, and it was being said THREE different ways: this map ("designate one"), the map's hunt
  // section ("set one on the Fleet tab") and the roster ("Fleet inactive — set a command ship"). One
  // rule, three wordings, and only one of them named where the fix is. Folded here, composed by all
  // three surfaces plus the map's fleet readout — a fourth wording is the defect, not a style choice.
  //
  // It NAMES THE FIX because a refusal the player cannot act on is the same as no refusal at all.
  fleet_inactive_no_command:
    'This fleet has no command ship — set one on the Fleet tab to move, send, or hunt with it.',
  fleet_full: 'This fleet is full (8 ships max) — remove a ship or use another fleet.',
  ship_not_in_fleet: 'Add this ship to a fleet before making it a command ship.',
  // FLEET-GO 4a-1 — the UNIFIED mover/brake reject vocabulary (command_ship_group_go 0207/0208 +
  // command_ship_group_stop 0209). Dark in prod until 4b flips fleet_movement_unified_enabled;
  // mapping the copy now costs nothing dark and makes the lit world speak player, not code.
  unified_movement_disabled: 'Fleet movement isn’t available right now.',
  member_busy: 'A ship in this fleet is still flying its own course — wait for it to arrive.',
  // 0292 narrowed this: a fleet IN COMBAT can now be ordered away and will retreat under fire. This
  // refusal survives only for a sortie with no encounter behind it, so the copy no longer claims that
  // combat blocks every order — it did, and saying so while the retreat path exists would be a lie.
  // PLAIN-WORDS: "sortie" is military jargon — say what it means. (The reason KEY is the server's.)
  group_on_sortie: 'This fleet is out on a mission and can’t take a new course yet.',
  // The combat-time OUTCOMES (`retreat_started`, `retreat_destination_updated`) are deliberately NOT
  // mapped here — this map is the REJECT vocabulary. Those two are successes whose copy must name the
  // destination, so their one authority is `fleetRetreatOutcomeMessage` in teamMove.ts, composed
  // where that name is in scope. THE RETREAT HAS NO REJECT: 0298 removed the port-only restriction,
  // so a coordinate order given mid-combat is accepted like any other and no reason code is emitted
  // for the shape of a destination (see the retirement pin in tests/teamReasonMessage.spec.ts).
  // REPOSITION (0311): an in-zone order MOVES an open-space fleet and the fight continues — the
  // 'repositioned' SUCCESS copy lives in fleetRetreatOutcomeMessage, per the rule above. There is
  // deliberately NO reposition reject code: a fleet that cannot make the jump (fighting 'present'
  // at a site) falls through server-side to the retreat arms, exactly as before 0311, so nothing
  // new arrives here to map.
  fleet_ambiguous: 'This fleet’s position is unclear — try again in a moment.',
  group_scattered: 'The fleet’s ships are split across ports — dock them together once to gather the fleet.',
  no_origin: 'The fleet has nowhere to depart from yet.',
  invalid_origin: 'The fleet’s current port couldn’t be found — try again.',
  movement_settled_retry: 'The fleet just arrived — give the order again from where it is now.',
  // HOW-A-FIGHT-STARTS: the server's refusal is a RULE (command_ship_group_go's own comment: "A
  // move is not a hunt: hunts go through send_ship_group_hunt"), so this copy does not argue with
  // it — it says what to do instead, in the ONE wording every other surface uses. "use Hunt for
  // that" named a control without saying where it is, which is the same dead end the zone panel
  // had. Deliberately says "site", not "zone": conflating the two IS the defect.
  combat_destination: `A pirate site can’t be travelled to. ${HOW_A_FIGHT_STARTS}`,
  target_out_of_bounds: 'That point lies outside charted space.',
  invalid_target_shape: 'Pick one destination — a port or a point in space, not both.',
  invalid_coordinate: 'That isn’t a usable point in space.',
  // S4 TIMED DOCKING — the dock verb's reject vocabulary (command_ship_group_dock, 0219).
  timed_docking_disabled: 'Docking isn’t available right now.',
  not_parked: 'The fleet must be holding in open space to dock — stop it first.',
  not_in_territory: 'The fleet isn’t in any port’s territory — move into orbit first.',
  not_dockable: 'There’s nothing to dock at here.',
  // The dock verb's "the group resolved no live fleet" arm (0219:191-193). The brake's same-named
  // token rides an ok:true envelope (0209/0215/0218) and never reaches this map.
  no_fleet: 'This fleet isn’t out in space — there’s nothing to dock.',
  // ROSTER WRITES — fleet create/rename (upsert_ship_group 0161:73-79).
  invalid_group_index: 'You can have up to three fleets — that slot doesn’t exist.',
  invalid_name: 'Give the fleet a name between 1 and 40 characters.',
  // ROSTER WRITES — the command-ship setter (0204:104) and the assign/unassign guards (0216:214).
  ship_not_found: 'That ship couldn’t be found — open the Fleet tab and pick it again.',
  // HP AUTO-EXIT — set_group_auto_exit (0310). The server is the authority on the [5,95] bounds;
  // the client control mirrors them, so these normally surface only for a stale/bypassed client.
  invalid_auto_exit_pct: 'Auto-retreat needs a hull percent between 5 and 95.',
  invalid_auto_exit_toggle: 'Choose whether auto-retreat is on or off.',
  // Joining a fleet: the ship is still on another one (0216:303-304).
  must_unassign_first: 'That ship is on another fleet — remove it from that fleet first.',
  // Joining a fleet in flight (0216:308) / hunting with one already in flight (0231:535).
  group_fleet_in_flight: 'The fleet is in flight — stop it, or wait for it to arrive.',
  // Joining a fleet docked somewhere else than the ship (0216:319).
  group_fleet_elsewhere: 'The fleet is docked at another port — bring them to the same port first.',
  // Leaving a fleet (0216:413,431) or deleting one (0216:584,608): a ship can only step off in port.
  fleet_in_flight: 'The fleet isn’t in port — dock it at a port first.',
  // DEFERRED-ENTRY INTERCEPT (0301) — the ambush no longer fires when the order is given; it fires
  // when the fleet actually reaches the zone boundary. So an order or a stop can now arrive in the
  // instant the fleet is being jumped: the verb resolves the owed ambush FIRST, and if it fires, the
  // order is refused because the fleet is no longer travelling — it is fighting. Re-issuing the same
  // order then lands on the retreat path, which is the right thing to do next, so the copy says so.
  intercepted_in_transit: 'Ambushed on the way — the fleet is in combat now. Order it again to retreat.',
  // The resolver raised while deciding whether an owed ambush fires. These verbs are raise-free at
  // their boundary and deliberately FAIL the order rather than let it through: "the ambush could not
  // be resolved" must never quietly mean "so you may go".
  intercept_resolution_failed: 'Couldn’t tell whether the fleet was ambushed — try that order again.',
  // PIRATE INTERCEPT route planner (command_ship_group_go_route / _cancel_route, 0233). Leg 1
  // composes the unified mover, so the mover's rejects above reach this surface unchanged.
  pirate_intercept_disabled: 'Route planning isn’t available right now.',
  invalid_waypoints: 'That route couldn’t be read — plot it again.',
  invalid_waypoint_count: 'Plot at least one point before the destination, and no more than three.',
  invalid_waypoint_point: 'One of those points lies outside charted space — move it inside.',
}

/** A short player-facing message for a server/transport team reason; unknown → generic "Fleet order unavailable." */
export function teamReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Fleet order unavailable.'
}
