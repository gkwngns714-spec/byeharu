import { sendableDestinations } from './teamSend'
import { huntableDestinations } from './teamCombat'

// TEAM-MAP-SEND — the ONE destination-kind classifier for a single map location, REUSING the pure
// list predicates (sendableDestinations / huntableDestinations) so the map sheet's "Send a team
// here" section can never drift from the roster's destination <select>s: a location is an
// expedition target iff the send list would contain it, a hunt target iff the hunt list would.
// Expedition wins by construction (the two server predicates are disjoint on activity_type —
// 'none' vs 'hunt_pirates' — so the order can never actually matter). Display-only, like its
// sources: the server (send_ship_group_expedition 0163 / send_ship_group_hunt 0168) re-validates
// the destination and stays the sole authority. No I/O — unit-tested in tests/teamDestination.spec.ts.

export type TeamDestinationKind = 'expedition' | 'hunt'

// Classify a location for team orders: 'expedition' (active + activity none — the safe send),
// 'hunt' (active + hunt_pirates — the combat send), or null (not a legal team destination).
// Takes the same structural row as the list predicates (not MapLocation) to stay pure + decoupled.
export function teamDestinationKind(location: {
  id: string
  name: string
  status: string
  activity_type: string
}): TeamDestinationKind | null {
  if (sendableDestinations([location]).length === 1) return 'expedition'
  if (huntableDestinations([location]).length === 1) return 'hunt'
  return null
}
