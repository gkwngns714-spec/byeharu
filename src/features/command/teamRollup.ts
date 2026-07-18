import type { GroupRow } from './teamRoster'
import type { PresentShipFleetLite, UnifiedGroupFleetLite } from './teamApi'

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

// FLEET-GO 4a-1 — the UNIFIED branch (optional 4th input; omitted/[] → byte-identical fold).
// Under §2 the group's ONE fleet (main_ship_id NULL, 0207) carries the position, and its members'
// per-ship 'present' fleets were DISSOLVED at launch (0208's ghost-dock fix) — so a unified fleet
// docked ('present') at L matches NEITHER legacy input: dockedAt keys by main_ship_id and
// presentFleets filters `.not('main_ship_id','is',null)`. Without this branch a lit, docked group
// loses its "Fleet X n/n" identity and the port shows N naked chevrons. The branch is simply: the
// fleet is docked at L ⇒ EVERY member is docked at L (a ship's location IS its fleet's location).
// ⚠ NOT dark-inert by construction: the live hunt mints the same fleet shape (see the
// fetchMyUnifiedGroupFleets caveat in teamApi.ts) — callers gate the FETCH on the runtime unified
// flag and exclude combat-site presence, so while dark this array is always [] and the fold is
// byte-identical to today.
export function deriveDockedTeamRollups(
  groups: readonly GroupRow[],
  membership: Readonly<Record<string, { group_id: string | null }>>,
  presentFleets: readonly PresentShipFleetLite[],
  unifiedFleets: readonly UnifiedGroupFleetLite[] = [],
): DockedTeamRollup[] {
  // One docked location per ship. A ship has at most one active 'present' fleet; if the read ever
  // surfaced duplicates, first-wins keeps the fold deterministic (never a fabricated second dock).
  const dockedAt = new Map<string, string>()
  for (const f of presentFleets) {
    if (!f.main_ship_id || !f.current_location_id) continue
    if (!dockedAt.has(f.main_ship_id)) dockedAt.set(f.main_ship_id, f.current_location_id)
  }

  // One docked location per GROUP from its unified fleet. First-wins on duplicates (two live unified
  // fleets for one group is a broken invariant the server rejects as fleet_ambiguous — never guess).
  const unifiedDockAt = new Map<string, string>()
  for (const f of unifiedFleets) {
    if (!f.group_id || f.status !== 'present' || !f.current_location_id) continue
    if (!unifiedDockAt.has(f.group_id)) unifiedDockAt.set(f.group_id, f.current_location_id)
  }

  return groups.map((g) => {
    const memberIds = Object.keys(membership).filter((id) => membership[id].group_id === g.group_id)
    const unifiedLoc = unifiedDockAt.get(g.group_id)
    if (unifiedLoc !== undefined) {
      // The unified world: the fleet's dock is every member's dock, by definition (n/n). An empty
      // group keeps locationId null (the documented "n/n, n>0" invariant — no badge for a ghost).
      return {
        groupId: g.group_id,
        name: g.name,
        memberCount: memberIds.length,
        dockedCount: memberIds.length,
        locationId: memberIds.length > 0 ? unifiedLoc : null,
      }
    }
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

// FLEET-GO 4a-1 — the ONE combat-exclusion for the unified-dock fold. A group's unified fleet
// 'present' at a COMBAT location can only be the hunt's sortie (the unified mover refuses combat
// destinations — 0208 combat_destination — so a group fleet never legitimately docks at a hunt
// site). Folding such a fleet as a dock would badge it "docked n/n" mid-combat and light an
// otherwise-committed group's Send/Hunt arms. EVERY caller that folds unifiedFleets through
// deriveDockedTeamRollups MUST filter through this first — one authority, no second inline copy
// (this arc's whole disease is copies). Locations are structurally typed so the helper stays pure
// and does not depend on MapLocation's full shape. Dark: unifiedFleets is always [] (the fetch is
// gated), so this is a no-op and the fold is byte-identical to today.
// The ONE combat-sortie classification both folds below share (never a second inline copy).
function combatLocationIdSet(locations: readonly { id: string; activity_type: string }[]): Set<string> {
  return new Set(locations.filter((l) => l.activity_type !== 'none').map((l) => l.id))
}

function isCombatSortiePresence(f: UnifiedGroupFleetLite, combatIds: ReadonlySet<string>): boolean {
  return f.status === 'present' && f.current_location_id !== null && combatIds.has(f.current_location_id)
}

export function excludeCombatSortieFleets(
  fleets: readonly UnifiedGroupFleetLite[],
  locations: readonly { id: string; activity_type: string }[],
): UnifiedGroupFleetLite[] {
  const combatIds = combatLocationIdSet(locations)
  return fleets.filter((f) => !isCombatSortiePresence(f, combatIds))
}

// MAP-INTEGRATION M1 — the exact COMPLEMENT of excludeCombatSortieFleets (same predicate, same
// authority — the two partition the raw fleet read, nothing double-counts and nothing vanishes).
// The exclusion above strips a mid-combat fleet from the dock fold (correct: it is not docked), but
// with the per-ship chevron layer deleted (S5) that stripping made the fleet INVISIBLE for the whole
// combat phase of every hunt — no dock badge, no moving badge, no space badge. This selector feeds
// the map's "in combat at X" team badge (teamMarkers.resolveFleetCombatBadges) so a combat-present
// fleet keeps a real marker. Dark: unifiedFleets is always [] (the fetch is gated) → always [].
export function selectCombatSortieFleets(
  fleets: readonly UnifiedGroupFleetLite[],
  locations: readonly { id: string; activity_type: string }[],
): UnifiedGroupFleetLite[] {
  const combatIds = combatLocationIdSet(locations)
  return fleets.filter((f) => isCombatSortiePresence(f, combatIds))
}
