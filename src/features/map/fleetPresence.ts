import type { FleetPosition } from './mainshipApi'
import type { GroupRow, ShipGroupMapEntry } from '../command/teamRoster'
import type { UnifiedGroupFleetLite } from '../command/teamApi'
import type { CombatUnit } from '../combat/combatTypes'
import type { FleetEncounterLite } from '../combat/encounterAnchor'
import { liveEncounterForFleet } from '../combat/encounterAnchor'
import { resolveFleetFightPosition } from './fleetFightPosition'
import { interpolateMovementPoint } from './movementInterpolation'
import { territoryAt } from './territoryAt'
import { fleetLabel } from '../command/fleetLabel'
import type { MapLocation } from './mapTypes'

// ██ WHERE IS MY FLEET — THE ONE ANSWER, FOR EVERY STATE A FLEET CAN BE IN. ██
//
// ── THE DEFECT THIS REPLACES ───────────────────────────────────────────────────────────────────────
// The owner: "in map, tell me where my fleets are too." Verified against the LIVE game on 2026-08-04:
// the map drew ONE badge for TWO fleets. Fleet 1 (4 ships, one of them docked at Haven) had no marker
// at all.
//
// The cause was not a missing branch. It was that "does this fleet get a marker?" was answered FOUR
// separate times, by four resolvers with four different EXISTENCE predicates over four different
// inputs:
//   · resolveTeamMarkers        — needed a fleet_movements row with status='moving'
//   · resolveFleetSpaceBadges   — needed a group fleet row with location_mode='space'
//   · resolveFleetCombatBadges  — needed a group fleet row 'present' at a COMBAT location
//   · resolveTeamDockBadges     — needed a COMPLETE (n/n) dock rollup
// A fleet that matched none of them was INVISIBLE, and the union of four predicates is not a
// partition of the state space — it is four holes with badges around them. Fleet 1 fell in the last
// hole: prod says one member is docked at Haven and three carry the abolished `legacy_home` state, so
// the rollup was 1/4, `locationId` came back null, and the fleet vanished. Adding a fifth resolver for
// "partially docked" would have bought the next hole.
//
// ── THE RULE ───────────────────────────────────────────────────────────────────────────────────────
// EXISTENCE IS UNCONDITIONAL: every group the player owns produces EXACTLY ONE presence, always.
// THE STATE DECIDES PRESENTATION, NEVER EXISTENCE. `FLEET_PRESENCE_STATES` is the closed set, and
// tests/fleetPresence.spec.ts iterates it — a state added here without a marker fails the suite.
//
// ── WHERE THE PLACES COME FROM (one input, one job each) ───────────────────────────────────────────
//   · positions  — get_my_fleet_positions (0200/0216), the SERVER's own per-ship place projection.
//     Its `place` domain IS the exhaustive per-ship state set, read off the deployed body:
//     'transit' | 'in_space' | 'docked' | 'berthed' | 'hidden'. Already fetched every poll by
//     useGalaxyMapData for the Port hub and the Fleet roster; this adds NO read.
//   · fleets     — IDENTITY only: which `fleets.id` is this group's, so the fight join can be made.
//     Never a position source; the positions read is fleet-first for open space already (0210).
//   · encounters / units — the live fight, the SAME arrays the spatial units layer is drawn from.
//   · locations  — port coordinates + names, and the territory read for the orbit clause.
//
// ── COMPOSED, NEVER RE-DERIVED ─────────────────────────────────────────────────────────────────────
//   · a fighting fleet's point → map/fleetFightPosition (THE authority: a real hull — the fleet's own
//     elected LEAD, never a mean and never a synthesised point). This module does not re-derive one
//     pixel of it, which is why killing an enemy cannot move this badge either.
//   · a moving fleet's point   → movementInterpolation.interpolateMovementPoint (the ONE segment math)
//   · which fight is ours      → combat/encounterAnchor.liveEncounterForFleet
//   · "in orbit of X"          → map/territoryAt (the ONE containment test)
//   · the fleet's name         → command/fleetLabel (the ONE naming rule — no "Fleet Fleet 2")
//
// ── HONESTY ────────────────────────────────────────────────────────────────────────────────────────
// A fleet is drawn where the world places its ships, with the count of how many of them the world
// could actually place. When NOTHING can place a single member, the answer is 'unplaced' and `at` is
// null: the fleet is still listed on the map, but no world coordinate is invented for it. That is the
// one line this module will not cross — a badge standing somewhere it is not is worse than a badge
// that says it does not know.
//
// PURE. No React/DOM/fetch/clock (`nowMs` is passed in). Proven in tests/fleetPresence.spec.ts.

/** The closed set of states a fleet can be in on the map. Every member MUST produce one marker. */
export const FLEET_PRESENCE_STATES = ['in-combat', 'moving', 'in-space', 'docked', 'unplaced'] as const

export type FleetPresenceState = (typeof FLEET_PRESENCE_STATES)[number]

export interface FleetPresence {
  groupId: string
  state: FleetPresenceState
  /** The one badge string: "<name> <placed>/<members>" plus the state's own clause. */
  label: string
  /** The fleet's OWN name (fleetLabel), split out of the badge string so a panel can render the name
   *  and the place in different places without parsing the badge back apart. */
  name: string
  /** The NAME of the place this fleet's state refers to — the port it is docked at, the territory it
   *  orbits, the site its fight belongs to — or null when it stands nowhere named (deep space, in
   *  flight, unplaceable). The badge clause above and `fleetWhereText` below are BOTH built from
   *  this one value, so the map badge and the fleet panel can never name two different places. */
  placeName: string | null
  /** WORLD coordinates. Null EXACTLY when `state === 'unplaced'` — never a guessed point. */
  at: { x: number; y: number } | null
  /** The port/site the fleet stands at, when its state has one. Drives per-site badge stacking only. */
  locationId: string | null
  memberCount: number
  /** How many members the world could place. 0 ⇔ 'unplaced'. */
  placedCount: number
}

/**
 * WHERE THE FLEET IS, AS ONE PLAIN SENTENCE — the panel-side rendering of the same (state,
 * placeName) pair the map badge's clause is built from.
 *
 * Two formats exist because two media need them: the badge is a haloed SVG label drawn at 10px over
 * the starfield and has to stay short ("Fleet 1 1/4 · in orbit of Haven"), while a panel row reads
 * as a sentence. They are NOT two answers — both take the state and the place off ONE presence, so
 * the map can never draw a badge at Haven while the panel says Slagworks.
 *
 * Exhaustive over FLEET_PRESENCE_STATES by construction (no default arm): a state added without a
 * phrase fails the typecheck, the same law that governs the markers.
 */
export function fleetWhereText(state: FleetPresenceState, placeName: string | null): string {
  switch (state) {
    case 'in-combat':
      return placeName ? `In combat at ${placeName}` : 'In combat'
    // A fleet in flight is not anywhere yet — the map's own movement line carries the path and the
    // ETA, so naming a half-passed coordinate here would be precision the player cannot use.
    case 'moving':
      return 'In flight'
    case 'in-space':
      return placeName ? `In orbit of ${placeName}` : 'In open space'
    case 'docked':
      return placeName ? `Docked at ${placeName}` : 'Docked'
    // Not "nowhere": the server itself cannot place a single member, and saying so is the answer.
    case 'unplaced':
      return 'Location unknown'
  }
}

/** The location fields this module reads (MapLocation satisfies it). */
export type PresenceLocation = Pick<MapLocation, 'id' | 'name' | 'x' | 'y' | 'territory_radius'> & {
  /** 'none' ⇔ not a combat site (the SAME classification teamRollup's combat fold uses). */
  activity_type?: string
}

/** get_my_fleet_positions carries the parked coordinate for the 'in_space' arm (the fleet-first read
 *  added by FLEET-GO 3c-3 and live in the deployed body). The row type is widened at its source
 *  (mainshipApi.FleetPosition); this alias documents what this module needs of it. */
export type PositionRow = Pick<FleetPosition, 'main_ship_id' | 'place' | 'location_id' | 'segment' | 'space_x' | 'space_y'>

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

interface Placed {
  shipId: string
  kind: 'moving' | 'in-space' | 'docked'
  point: { x: number; y: number }
  locationId: string | null
}

/** One ship's row → where that ship is, or null when the world cannot place it ('hidden', a transit
 *  row with no usable segment, a dock at a site outside the visible world read). Never a guess. */
function placeShip(
  row: PositionRow,
  locById: ReadonlyMap<string, PresenceLocation>,
  nowMs: number,
): Placed | null {
  if (row.place === 'transit') {
    if (!row.segment) return null
    const p = interpolateMovementPoint(row.segment, nowMs)
    return p ? { shipId: row.main_ship_id, kind: 'moving', point: p, locationId: null } : null
  }
  if (row.place === 'in_space') {
    if (!finite(row.space_x) || !finite(row.space_y)) return null
    return { shipId: row.main_ship_id, kind: 'in-space', point: { x: row.space_x, y: row.space_y }, locationId: null }
  }
  // 'docked' (fleeted, at its fleet's port) and 'berthed' (unfleeted, at its berth) are the SAME
  // answer to "where is it": a port. They differ only in what owns the ship, which is not a place.
  if (row.place === 'docked' || row.place === 'berthed') {
    if (!row.location_id) return null
    const loc = locById.get(row.location_id)
    if (!loc || !finite(loc.x) || !finite(loc.y)) return null // outside the visible world read → no badge, no id leak
    return { shipId: row.main_ship_id, kind: 'docked', point: { x: loc.x, y: loc.y }, locationId: loc.id }
  }
  return null // 'hidden' — the server itself cannot say where this ship is
}

/** The fleet's dock, when its members are docked: the port holding the MOST of them. Ties break on
 *  the lowest location id, so the badge never flickers between two ports on re-render. A fleet is ONE
 *  thing and gets ONE badge — a split fleet is reported by its count, never by two labels at two ports. */
function majorityDock(docked: readonly Placed[]): Placed | null {
  const tally = new Map<string, number>()
  for (const d of docked) tally.set(d.locationId as string, (tally.get(d.locationId as string) ?? 0) + 1)
  let bestId: string | null = null
  let bestN = 0
  for (const [id, n] of tally) {
    if (n > bestN || (n === bestN && bestId !== null && id < bestId)) {
      bestId = id
      bestN = n
    }
  }
  return docked.find((d) => d.locationId === bestId) ?? null
}

export function resolveFleetPresence(input: {
  groups: readonly GroupRow[]
  /** main_ship_id → membership (teamGroupMap). The LIVE membership truth. */
  membership: Readonly<Record<string, Pick<ShipGroupMapEntry, 'group_id'>>>
  positions: readonly PositionRow[]
  /** Identity only: the group's own `fleets.id`, for the encounter join. */
  fleets?: readonly Pick<UnifiedGroupFleetLite, 'id' | 'group_id'>[]
  locations?: readonly PresenceLocation[]
  encounters?: readonly FleetEncounterLite[]
  units?: readonly CombatUnit[]
  nowMs: number
}): FleetPresence[] {
  const { groups, membership, positions, nowMs } = input
  if (groups.length === 0) return []
  const fleets = input.fleets ?? []
  const locations = input.locations ?? []
  const encounters = input.encounters ?? []
  const units = input.units ?? []

  const locById = new Map(locations.map((l) => [l.id, l]))
  const posByShip = new Map(positions.map((p) => [p.main_ship_id, p]))
  // One fleet row per group; a second live one is a broken server invariant (fleet_ambiguous) — first
  // wins rather than a coin flip, exactly like the fold this replaces.
  const fleetIdByGroup = new Map<string, string>()
  for (const f of fleets) {
    if (!f.group_id || fleetIdByGroup.has(f.group_id)) continue
    fleetIdByGroup.set(f.group_id, f.id)
  }
  // Membership, folded ONCE for every group (never re-scanned per group).
  const membersByGroup = new Map<string, string[]>()
  for (const shipId of Object.keys(membership)) {
    const gid = membership[shipId]?.group_id
    if (!gid) continue
    const list = membersByGroup.get(gid) ?? []
    list.push(shipId)
    membersByGroup.set(gid, list)
  }

  const out: FleetPresence[] = []
  for (const g of groups) {
    // Deterministic member order — the tie-break for "which transit leg / which parked hull".
    const members = (membersByGroup.get(g.group_id) ?? []).slice().sort()
    const placed: Placed[] = []
    for (const shipId of members) {
      const row = posByShip.get(shipId)
      if (!row) continue
      const p = placeShip(row, locById, nowMs)
      if (p) placed.push(p)
    }

    const memberCount = members.length
    const placedCount = placed.length
    const name = fleetLabel(g.name)
    const counts = `${placedCount}/${memberCount}`

    // ── PRECEDENCE: the strongest thing this fleet is doing decides where it is drawn. ────────────
    // A fight outranks everything (that is where the player's attention is); a leg outranks a park;
    // a park outranks a dock. Each arm below composes an EXISTING authority for its point.
    const moving = placed.find((p) => p.kind === 'moving') ?? null
    const inSpace = placed.find((p) => p.kind === 'in-space') ?? null
    const docked = majorityDock(placed.filter((p) => p.kind === 'docked'))
    const resting = moving ?? inSpace ?? docked

    const encounter = liveEncounterForFleet(encounters, fleetIdByGroup.get(g.group_id) ?? null)
    if (encounter) {
      // The fight's own fallback: where the fleet rests, else the server's engagement anchor. Both are
      // real committed points; resolveFleetFightPosition upgrades either to a REAL HULL when the fight
      // is positioned, which is the whole reason that module exists.
      const fallback =
        resting?.point ??
        (finite(encounter.engagement_x) && finite(encounter.engagement_y)
          ? { x: encounter.engagement_x, y: encounter.engagement_y }
          : null)
      const at = fallback ? resolveFleetFightPosition({ fleetId: fleetIdByGroup.get(g.group_id), encounters, units, fallback }) : null
      if (at) {
        // Name the place the badge is actually DRAWN at — the site when the fight owns one, else the
        // territory the point sits in. Never a place the badge is not near.
        const site = docked && docked.locationId ? locById.get(docked.locationId) : undefined
        const place = site ?? territoryAt(at, locations)
        out.push({
          groupId: g.group_id,
          state: 'in-combat',
          label: `${name} ${counts}${place ? ` · in combat at ${place.name}` : ' · in combat'}`,
          name,
          placeName: place?.name ?? null,
          at: { x: at.x, y: at.y },
          locationId: site?.id ?? null,
          memberCount,
          placedCount,
        })
        continue
      }
      // Fighting but unplaceable — fall through to the resting arms rather than inventing a point.
    }

    if (moving) {
      out.push({
        groupId: g.group_id,
        state: 'moving',
        label: `${name} ${counts}`,
        name,
        placeName: null,
        at: moving.point,
        locationId: null,
        memberCount,
        placedCount,
      })
      continue
    }
    if (inSpace) {
      const place = territoryAt(inSpace.point, locations)
      out.push({
        groupId: g.group_id,
        state: 'in-space',
        label: `${name} ${counts}${place ? ` · in orbit of ${place.name}` : ''}`,
        name,
        placeName: place?.name ?? null,
        at: inSpace.point,
        locationId: null,
        memberCount,
        placedCount,
      })
      continue
    }
    if (docked) {
      // The port's own marker is already labelled — the badge names the fleet, not the place again.
      // The PANEL still needs the port's name (it has no marker beside it to read), so it is carried
      // as `placeName` rather than re-looked-up by the caller.
      out.push({
        groupId: g.group_id,
        state: 'docked',
        label: `${name} ${counts}`,
        name,
        placeName: (docked.locationId ? locById.get(docked.locationId)?.name : undefined) ?? null,
        at: docked.point,
        locationId: docked.locationId,
        memberCount,
        placedCount,
      })
      continue
    }
    // Nothing in the world places a single member. Say so — do NOT invent a coordinate.
    out.push({
      groupId: g.group_id,
      state: 'unplaced',
      label: `${name} ${counts} · location unknown`,
      name,
      placeName: null,
      at: null,
      locationId: null,
      memberCount,
      placedCount,
    })
  }
  // Deterministic output order (the groups read is slot-ordered, but pin it anyway).
  return out.sort((a, b) => (a.groupId < b.groupId ? -1 : a.groupId > b.groupId ? 1 : 0))
}
