import type { GroupRow } from '../command/teamRoster'
import type { UnifiedGroupFleetLite } from '../command/teamApi'
import type { MapLocation } from './mapTypes'
import type { DangerZoneLite } from './pirateApi'
import { zoneAtPoint, zoneHuntSite } from './zoneInfoModel'

// ██ THE FIGHT UNDER THE FLEET'S FEET — the ONE derivation, for every surface that offers it. ██
//
// ── WHY THIS FILE EXISTS ───────────────────────────────────────────────────────────────────────────
// The owner, playing, for the third time in three days: "I am in snare but in no fight is occuring."
// The answer is `howAFightStarts`: standing in a zone starts nothing, and the only way into a fight
// is `send_ship_group_hunt` on the SITE. So a fleet parked inside a zone that wraps a huntable site
// must be OFFERED that site, wherever the player is looking.
//
// That offer was derived inline inside `buildFleetCommandModel` (the bottom-right command hub). The
// map's fleet readout needs exactly the same answer, and copying eleven lines of containment +
// huntability into a second model is how "N implementations of one concept" starts. So the
// derivation moved HERE and the command model composes it. One rule, one home, two consumers.
//
// ── COMPOSED, NEVER RE-DERIVED ─────────────────────────────────────────────────────────────────────
//   · containment — `zoneAtPoint`, the map's own ray-cast (the same one that answers "What's here"
//     for a double-tap, and the client-side mirror of the server's PostGIS zone test).
//   · huntability — `zoneHuntSite`, the ONE authority the zone panel asks (teamDestinationKind).
//   · the words   — `huntSiteActionLabel`, reached through `zoneHuntSite`, so the signpost's label
//     is the hunt-copy authority's and never a second wording (tests/howAFightStarts.spec.ts).
//
// ── HONEST AT THE EDGES ────────────────────────────────────────────────────────────────────────────
// A fleet in flight is not standing anywhere; a docked fleet is not in space; a fleet with no
// coordinates is nowhere this can speak about; a zone with no huntable site offers nothing at all.
// Each of those yields NO row rather than a guess.
//
// It carries NO wire and submits nothing. `locationId` is handed to the map's marker selection,
// exactly as tapping that marker would — which renders the EXISTING hunt control, with its
// two-click armed confirm and its return-port picker. There is still exactly ONE call site for the
// hunt RPC in the whole client.
//
// PURE. No React, no DOM, no fetch, no clock.

/** One fleet standing inside a pirate zone that wraps a huntable site. */
export interface FleetStandingHunt {
  groupId: string
  name: string
  /** The SITE to select — never the zone: a zone is not a destination (howAFightStarts). */
  locationId: string
  siteName: string
  /** The signpost's words, from the ONE hunt-copy authority (huntSiteActionLabel). */
  label: string
}

export interface FleetStandingHuntInput {
  groups: readonly GroupRow[]
  /** The group fleets (combat-sortie rows already excluded upstream). Empty ⇔ no offer. */
  unifiedFleets: readonly UnifiedGroupFleetLite[]
  /** The live danger zones. Empty ⇔ no offer, so a failed/dark read simply yields nothing. */
  dangerZones: readonly DangerZoneLite[]
  locations: readonly MapLocation[]
}

/** Every owned fleet parked in a zone whose site can be hunted, in `groups` order. */
export function resolveFleetStandingHunts(input: FleetStandingHuntInput): FleetStandingHunt[] {
  return input.groups.flatMap((g) => {
    const fleet = input.unifiedFleets.find((f) => f.group_id === g.group_id)
    if (!fleet || fleet.status === 'moving' || fleet.location_mode !== 'space') return []
    if (fleet.space_x === null || fleet.space_y === null) return []
    const zone = zoneAtPoint({ x: fleet.space_x, y: fleet.space_y }, input.dangerZones)
    if (!zone) return []
    const site = zoneHuntSite(zone, input.locations)
    if (!site) return [] // a zone with no huntable site offers nothing at all
    return [{ groupId: g.group_id, name: g.name, locationId: site.locationId, siteName: site.name, label: site.label }]
  })
}
