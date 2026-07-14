// TEAM-MAP-SEND — pure, fail-closed reason→message map for the team-command surfaces (the
// tradeReasonMessage/haulReasonMessage idiom verbatim). Maps the ACTUAL server reject vocabulary of
// the team RPCs — send_ship_group_expedition (0163), send_ship_group_hunt (0168),
// move_ship_group_to_location (0190), and the totals/preview reads (0165/0166) — plus the teamApi
// transport fallback ('unavailable') to short player-facing text; any unmapped/unknown reason
// degrades to a generic "Team order unavailable." so the UI never surfaces a raw code and never
// throws. No React/DOM/state — unit-tested in tests/teamReasonMessage.spec.ts.

const REASON_MESSAGES: Record<string, string> = {
  // shared prefix (every team RPC, 0163/0165/0166/0168/0190)
  team_command_disabled: 'Fleet commands are not available right now.',
  not_authenticated: 'Sign in to command fleets.',
  group_not_found: 'That fleet no longer exists.',
  empty_group: 'That fleet has no ships yet — add ships in the Fleets panel.',
  // expedition send (0163) + docked-team move (0190): the all-or-nothing member loops
  member_send_failed: 'A ship in the fleet couldn’t depart, so nothing moved.',
  // hunt send (0168)
  invalid_location: 'This destination can’t take a fleet right now.',
  // shared readiness reject: hunt (0168 — every ship home and battle-ready) and docked-team move
  // (0190 — every ship docked together at one port)
  member_not_ready: 'Every ship in the fleet must be ready first — home for a hunt, docked together for a move.',
  fleet_limit_reached: 'Too many fleets are already deployed — wait for one to return.',
  stats_invalid: 'The fleet’s stats couldn’t be verified — check each ship in the Fleets panel.',
  power_below_required: 'The fleet’s combat power is below what this zone requires.',
  no_home_base: 'The fleet has no home port to launch from.',
  // preview/totals reads (0165/0166)
  invalid_activity: 'That activity isn’t recognized for fleet orders.',
  // FLEET-CONTROL (0204): the fleet control-model rejects (movement RPCs + assign cap + command-ship setter)
  fleet_inactive_no_command: 'This fleet has no command ship — designate one to move, send, or hunt with it.',
  fleet_full: 'This fleet is full (8 ships max) — remove a ship or use another fleet.',
  ship_not_in_fleet: 'Add this ship to a fleet before making it a command ship.',
}

/** A short player-facing message for a server/transport team reason; unknown → generic "Fleet order unavailable." */
export function teamReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Fleet order unavailable.'
}
