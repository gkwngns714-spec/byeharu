import type { GroupRow } from './teamRoster'
import type { PresentShipFleetLite } from './teamApi'

// TEAMMAP-0 — the PURE docked-team rollup (owner directive: "the team should also be able to be
// docked … as a whole" — this is the read/derive side that makes a docked team VISIBLE; the engine
// already docks members individually at arrival, 0153).
//
// Inputs are the existing owner reads, nothing new is invented:
//   • groups      — fetchMyShipGroups (ship_groups: id → name/slot; the ONE groups fetch, reused)
//   • membership  — fetchMyShipGroupMap (main_ship_instances.group_id: the LIVE membership truth —
//                   deliberately NOT fleets.group_id, which is the informational in-flight label)
//   • presentFleets — fetchMyPresentShipFleets (a docked ship's 'present' fleet carries its
//                   current_location_id — the resolver-§D docked-location source)
//
// A team "is docked" ONLY when EVERY member ship is docked at the SAME location (n/n): a partial or
// split team keeps locationId null (dockedCount still reported for the muted roster line). No I/O,
// no clock — unit-tested in tests/teamRollup.spec.ts.

export interface DockedTeamRollup {
  groupId: string
  name: string
  memberCount: number
  dockedCount: number
  /** The ONE location every member is docked at; non-null ONLY for a complete (n/n, n>0) dock. */
  locationId: string | null
}

export function deriveDockedTeamRollups(
  groups: readonly GroupRow[],
  membership: Readonly<Record<string, { group_id: string | null }>>,
  presentFleets: readonly PresentShipFleetLite[],
): DockedTeamRollup[] {
  // One docked location per ship. A ship has at most one active 'present' fleet; if the read ever
  // surfaced duplicates, first-wins keeps the fold deterministic (never a fabricated second dock).
  const dockedAt = new Map<string, string>()
  for (const f of presentFleets) {
    if (!f.main_ship_id || !f.current_location_id) continue
    if (!dockedAt.has(f.main_ship_id)) dockedAt.set(f.main_ship_id, f.current_location_id)
  }

  return groups.map((g) => {
    const memberIds = Object.keys(membership).filter((id) => membership[id].group_id === g.group_id)
    const locs = memberIds.map((id) => dockedAt.get(id) ?? null)
    const docked = locs.filter((l): l is string => l !== null)
    const allSameComplete =
      memberIds.length > 0 && docked.length === memberIds.length && docked.every((l) => l === docked[0])
    return {
      groupId: g.group_id,
      name: g.name,
      memberCount: memberIds.length,
      dockedCount: docked.length,
      locationId: allSameComplete ? docked[0] : null,
    }
  })
}
