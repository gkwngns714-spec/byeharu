// TEAM-MAP-SEND — pure, fail-closed reason→message map for the team-command surfaces (the
// tradeReasonMessage/haulReasonMessage idiom verbatim). Maps the ACTUAL server reject vocabulary of
// the team RPCs — send_ship_group_expedition (0163), send_ship_group_hunt (0168), and the
// totals/preview reads (0165/0166) — plus the teamApi transport fallback ('unavailable') to short
// player-facing text; any unmapped/unknown reason degrades to a generic "Team order unavailable."
// so the UI never surfaces a raw code and never throws. No React/DOM/state — unit-tested in
// tests/teamReasonMessage.spec.ts.

const REASON_MESSAGES: Record<string, string> = {
  // shared prefix (every team RPC, 0163/0165/0166/0168)
  team_command_disabled: 'Team commands are not available right now.',
  not_authenticated: 'Sign in to command teams.',
  group_not_found: 'That team no longer exists.',
  empty_group: 'That team has no ships yet — add ships in the Teams panel.',
  // expedition send (0163)
  member_send_failed: 'A ship in the team couldn’t launch, so nothing was sent.',
  // hunt send (0168)
  invalid_location: 'This destination can’t take a team right now.',
  member_not_ready: 'Every ship in the team must be home and battle-ready first.',
  fleet_limit_reached: 'Too many fleets are already deployed — wait for one to return.',
  stats_invalid: 'The team’s stats couldn’t be verified — check each ship in the Teams panel.',
  power_below_required: 'The team’s combat power is below what this zone requires.',
  no_home_base: 'The team has no home port to launch from.',
  // preview/totals reads (0165/0166)
  invalid_activity: 'That activity isn’t recognized for team orders.',
}

/** A short player-facing message for a server/transport team reason; unknown → generic "Team order unavailable." */
export function teamReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Team order unavailable.'
}
