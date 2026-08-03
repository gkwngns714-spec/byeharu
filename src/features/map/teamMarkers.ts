import { createElement, useEffect, useState, type ReactElement } from 'react'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { GroupRow } from '../command/teamRoster'
import type { DockedTeamRollup } from '../command/teamRollup'
import type { UnifiedGroupFleetLite } from '../command/teamApi'
import type { CombatUnit } from '../combat/combatTypes'
import type { FleetEncounterLite } from '../combat/encounterAnchor'
import { resolveFleetFightPosition } from './fleetFightPosition'
import type { MapLocation } from './mapTypes'
import { interpolateMovementPoint } from './movementInterpolation'
import { territoryAt } from './territoryAt'
import { fleetLabel } from '../command/fleetLabel'

// TEAMMAP-2 — the team's OWN map marker (owner directive: "The team should have a marker of its own
// and be shown on map"). Read-only display layer over server-committed rows; additive beside the
// existing marker/line layers — it changes NO existing marker resolution and duplicates NO pipeline:
//   • position math   → the ONE shared interpolateMovementPoint (movementInterpolation)
//   • fleet team tag  → movements' flattened fleets.group_id (0168/0187, informational/display-only)
//   • docked teams    → the pure deriveDockedTeamRollups fold (command/teamRollup)
//   • wiring          → the pure, hook-free `teamMarkersLayer` element-descriptor helper (the
//                       element-tree convention; GalaxyMap and the unit tests call the SAME function).
//
// Cluster semantics (pure, unit-tested in tests/teamMarkers.spec.ts):
//   • multi-fleet group (expedition send, N member fleets) → ONE badge at the LEAD (earliest-ETA)
//     fleet's interpolated position, labeled "Team <name> · n ships"; the individual dashed lines +
//     dots stay rendered by the existing FleetMovementLine layer untouched.
//   • single-fleet group (hunt sortie — 0168 sends the whole team as ONE fleet) → the badge rides
//     that fleet's interpolated position, labeled "Team <name>".
//   • docked team (the rollup's complete n/n dock) → a badge on the port's marker position,
//     labeled "Team <name> n/n".
// Fail closed: a tag pointing at a group not in the owner's groups read produces NO badge (never a
// guessed label), exactly like the roster's dangling-membership posture.

export interface TeamMarkerDescriptor {
  groupId: string
  label: string
  /** WORLD coordinates in the legacy movement domain (project through the map's `norm`). */
  x: number
  y: number
  fleetCount: number
  /** The lead (earliest) arrive_at — informational; the movement lines own ETA display. */
  arriveAt: string
}

// ── The pure cluster function: active movements (with group_id) + groups → team-marker descriptors. ──
export function resolveTeamMarkers(
  movements: readonly FleetMovement[],
  groups: readonly GroupRow[],
  nowMs: number,
): TeamMarkerDescriptor[] {
  if (groups.length === 0) return []
  const nameById = new Map(groups.map((g) => [g.group_id, g.name]))

  const byGroup = new Map<string, FleetMovement[]>()
  for (const m of movements) {
    const gid = m.group_id
    if (!gid || m.status !== 'moving') continue
    if (!nameById.has(gid)) continue // fail closed: unknown/foreign tag → no badge
    const list = byGroup.get(gid) ?? []
    list.push(m)
    byGroup.set(gid, list)
  }

  const out: TeamMarkerDescriptor[] = []
  for (const [gid, list] of byGroup) {
    // Lead = earliest ETA; deterministic tie-break on movement id (stable across re-renders).
    const lead = list.reduce((a, b) => {
      const ta = Date.parse(a.arrive_at)
      const tb = Date.parse(b.arrive_at)
      if (ta !== tb) return ta <= tb ? a : b
      return a.id <= b.id ? a : b
    })
    const p = interpolateMovementPoint(lead, nowMs)
    if (!p) continue // an incoherent lead segment renders nothing, never a guessed position
    const name = nameById.get(gid) as string
    out.push({
      groupId: gid,
      label: list.length > 1 ? `${fleetLabel(name)} · ${list.length} ships` : fleetLabel(name),
      x: p.x,
      y: p.y,
      fleetCount: list.length,
      arriveAt: lead.arrive_at,
    })
  }
  // Deterministic output order (map iteration order is insertion order, but pin it anyway).
  return out.sort((a, b) => (a.groupId < b.groupId ? -1 : a.groupId > b.groupId ? 1 : 0))
}

// ── The pure dock-badge selection: complete (n/n) rollups → badge descriptors. ──
export interface TeamDockBadgeDescriptor {
  groupId: string
  label: string
  locationId: string
}

export function resolveTeamDockBadges(rollups: readonly DockedTeamRollup[]): TeamDockBadgeDescriptor[] {
  return rollups
    .filter((r): r is DockedTeamRollup & { locationId: string } => r.locationId !== null && r.memberCount > 0)
    .map((r) => ({
      groupId: r.groupId,
      label: `${fleetLabel(r.name)} ${r.dockedCount}/${r.memberCount}`,
      locationId: r.locationId,
    }))
}

// ── FLEET-GO 4a-1 — the IN-SPACE fleet badge (charter §2: the fleet has its OWN position, 0208). ──
// A unified fleet parked in open space (location_mode='space' + its own space_x/space_y — written
// only by fleet_set_in_space: a coordinate arrival or the 0209 brake) is at a place no existing
// layer can draw: it is not a movement (no segment to interpolate) and not a dock (no location).
// This badge is that place. GENUINELY dark-inert by construction — unlike the dock branch, NO live
// path writes location_mode='space' while the unified gate is false (the hunt never parks in space),
// so an empty input is guaranteed in today's prod and the layer renders nothing.
// The label takes the member count from the group's rollup (rollups exist for every group, docked or
// not) — the fleet's ships are WITH it in space, mirroring the in-flight badge's phrasing.
//
// ⚑ THIS IS THE AMBUSH-COMBAT BADGE TOO, AND IT MUST FOLLOW THE FIGHT. An ambush does NOT leave the
// fleet 'present' at a location: 0301:1109 calls fleet_set_in_space, which writes status='idle',
// location_mode='space', current_location_id=NULL (0231:1157-1161). teamRollup's
// isCombatSortiePresence (:103-105) requires 'present' AND a location, so an ambushed fleet is
// invisible to resolveFleetCombatBadges and lands HERE — verified against production: all eight of
// the owner's off-centre encounters are idle/space/no-location. So the parked point this badge used
// to draw is a STALE start-of-fight position, while the fleet's own ships (spatialCombatLayer, from
// combat_units.pos_x/pos_y) march 20-30 units away from it. Same fleet, drawn twice, two places.
// Position now comes from the ONE shared rule — fleetFightPosition: THE HULL NEAREST THE ENEMY, a
// real ship, never an average of several — with the parked coordinate as its fallback, so a fleet
// that is NOT fighting is byte-identical to before.
export interface FleetSpaceBadgeDescriptor {
  groupId: string
  label: string
  /** WORLD coordinates in the legacy movement domain (project through the map's `norm`). While the
   *  fleet is in a positioned fight this is the position of one of its OWN SHIPS — the one nearest
   *  the enemy — not its parked point. */
  x: number
  y: number
}

export function resolveFleetSpaceBadges(
  unifiedFleets: readonly UnifiedGroupFleetLite[],
  groups: readonly GroupRow[],
  rollups: readonly DockedTeamRollup[],
  /** S2 TERRITORY: world locations for the "in orbit of X" read — a fleet parked inside a
   *  location's territory_radius extends its badge label. Containment is the ONE pure territoryAt
   *  (which composes the ONE distance()). Optional, default [] → byte-identical labels for every
   *  existing caller (and for a world with no territory data). */
  locations: readonly Pick<MapLocation, 'id' | 'name' | 'x' | 'y' | 'territory_radius'>[] = [],
  /** The caller's live encounters + combat units (useCombat's already-polled rows — no new fetch).
   *  Optional, default [] → no fleet is ever "fighting" and every badge keeps its parked point, i.e.
   *  today's behaviour for every existing caller. */
  encounters: readonly FleetEncounterLite[] = [],
  units: readonly CombatUnit[] = [],
): FleetSpaceBadgeDescriptor[] {
  if (groups.length === 0) return []
  const nameById = new Map(groups.map((g) => [g.group_id, g.name]))
  const countByGroup = new Map(rollups.map((r) => [r.groupId, r.memberCount]))
  const out: FleetSpaceBadgeDescriptor[] = []
  const seen = new Set<string>()
  for (const f of unifiedFleets) {
    if (!f.group_id || f.location_mode !== 'space') continue
    if (f.space_x == null || f.space_y == null || !Number.isFinite(f.space_x) || !Number.isFinite(f.space_y)) continue
    if (!nameById.has(f.group_id)) continue // fail closed: unknown/foreign tag → no badge, never a guessed name
    if (seen.has(f.group_id)) continue // one fleet per group; duplicates are a broken invariant — first wins
    // WHERE the fleet is: the ship of its own at the point of attack while it fights, its parked
    // point otherwise — the ONE shared rule. The parked coordinate is finite (guarded above), so
    // this cannot be null.
    const at = resolveFleetFightPosition({
      fleetId: f.id,
      encounters,
      units,
      fallback: { x: f.space_x, y: f.space_y },
    })
    if (!at) continue // unreachable given the guard above; never emit an unplaced badge
    seen.add(f.group_id)
    const name = nameById.get(f.group_id) as string
    const n = countByGroup.get(f.group_id) ?? 0
    const base = n > 1 ? `${fleetLabel(name)} · ${n} ships` : fleetLabel(name)
    // S2 TERRITORY: a WORLD-domain point is exactly what territoryAt takes, and it reads the point
    // the badge is actually DRAWN at, so the label can never name a place the badge is not near.
    // No containing territory → the plain label (never a guessed orbit).
    const place = territoryAt({ x: at.x, y: at.y }, locations)
    // A fighting fleet says so. "in orbit of X" describes a fleet at rest and would be a quiet lie
    // mid-battle; the place name is kept either way so the player still knows where they are.
    const suffix = at.fighting
      ? place
        ? ` · in combat near ${place.name}`
        : ' · in combat'
      : place
        ? ` · in orbit of ${place.name}`
        : ''
    out.push({
      groupId: f.group_id,
      label: `${base}${suffix}`,
      x: at.x,
      y: at.y,
    })
  }
  return out.sort((a, b) => (a.groupId < b.groupId ? -1 : a.groupId > b.groupId ? 1 : 0))
}

// ── MAP-INTEGRATION M1 — the IN-COMBAT fleet badge (a mid-combat fleet must never vanish) ──────────
// A group fleet 'present' at a COMBAT location is the hunt's sortie mid-fight: it is deliberately
// stripped from the dock fold (excludeCombatSortieFleets — it must not badge "docked" mid-combat),
// has no 'moving' movement (no in-flight badge) and no space park (no orbit badge), and the per-ship
// chevron fallback that used to draw its members (fleetShipsLayer) was DELETED in S5 — so without
// this badge the fleet is INVISIBLE for the whole combat phase of every hunt. Input is the exact
// COMPLEMENT of the dock fold's exclusion (teamRollup.selectCombatSortieFleets — the ONE combat
// classification, never re-derived here); this resolver only validates shape, names, and places the
// badge. Fail closed like every sibling: unknown/foreign group tag, or a combat
// site not in the visible world read → NO badge (never a guessed name/position, no hidden-site leak).
//
// ⚑ THE BADGE STANDS ON A SHIP, NOT ON THE SITE'S CENTRE AND NOT ON AN AVERAGE — the SAME rule the
// in-space badge above obeys, so "where is this fleet" has ONE answer no matter which arm draws it.
// The deliberate-hunt path needs it just as badly as the ambush path: 0234 seeds this fight's units at
// the site centre and the tick then MOVES them (0234/0294/0311/0314 are the writers of pos_x; 0313
// writes none — it cut the ranges that make the mover's close/kite arms fire at all, which is why the
// drift only became visible now, but crediting it with the movement is wrong), so within a couple of
// ticks the ships have walked 20-30 world units off the centre this badge used to be pinned to — the
// identical drawn-twice-in-two-places defect, differing only in where the drift starts. Position
// therefore comes from map/fleetFightPosition (this fleet's own living, positioned ship NEAREST THE
// ENEMY), with the site centre as its fallback: no live encounter, or an aggregate fight with no
// positioned unit, and the badge is exactly where it has always been.
// The LABEL is unchanged: the fleet really is fighting at that site, it is simply not standing on
// the site's centre pixel.
export interface FleetCombatBadgeDescriptor {
  groupId: string
  label: string
  /** The combat SITE — the fight's owning location. Drives per-site badge stacking, not position. */
  locationId: string
  /** WORLD coordinates — the position of this fleet's own ship nearest the enemy while it fights,
   *  the site centre when it has no positioned fight. Always finite (a site with unusable
   *  coordinates yields no badge). */
  x: number
  y: number
}

export function resolveFleetCombatBadges(
  combatFleets: readonly UnifiedGroupFleetLite[],
  groups: readonly GroupRow[],
  rollups: readonly DockedTeamRollup[],
  locations: readonly Pick<MapLocation, 'id' | 'name' | 'x' | 'y'>[],
  /** The caller's live encounters + combat units (useCombat's already-polled rows — already on the
   *  map for the units layer; no new fetch, no new poll). Optional, default [] → every badge sits on
   *  its site's centre, i.e. the pre-slice position, for any caller with nothing in hand. */
  encounters: readonly FleetEncounterLite[] = [],
  units: readonly CombatUnit[] = [],
): FleetCombatBadgeDescriptor[] {
  if (groups.length === 0) return []
  const nameById = new Map(groups.map((g) => [g.group_id, g.name]))
  const countByGroup = new Map(rollups.map((r) => [r.groupId, r.memberCount]))
  const out: FleetCombatBadgeDescriptor[] = []
  const seen = new Set<string>()
  for (const f of combatFleets) {
    if (!f.group_id || f.status !== 'present' || !f.current_location_id) continue // shape guard on the pre-filtered input
    if (!nameById.has(f.group_id)) continue // fail closed: unknown/foreign tag → no badge
    if (seen.has(f.group_id)) continue // one fleet per group; duplicates are a broken invariant — first wins
    const loc = locations.find((l) => l.id === f.current_location_id)
    if (!loc) continue // combat site not in the visible world read → no badge, no id leak
    // WHERE the fleet is — the ONE shared rule. It answers null only for a site with non-finite
    // coordinates, which drops the badge rather than pushing NaN into an SVG transform (a NaN in a
    // transform silently blanks the element).
    const at = resolveFleetFightPosition({
      fleetId: f.id,
      encounters,
      units,
      fallback: { x: loc.x, y: loc.y },
    })
    if (!at) continue
    seen.add(f.group_id)
    const name = nameById.get(f.group_id) as string
    const n = countByGroup.get(f.group_id) ?? 0
    const base = n > 1 ? `${fleetLabel(name)} · ${n} ships` : fleetLabel(name)
    out.push({
      groupId: f.group_id,
      label: `${base} · in combat at ${loc.name}`,
      locationId: loc.id,
      x: at.x,
      y: at.y,
    })
  }
  return out.sort((a, b) => (a.groupId < b.groupId ? -1 : a.groupId > b.groupId ? 1 : 0))
}

// (4C-CLIENT: deriveTeamRepresentedShipIds — the fleetShipsLayer de-dup set — DELETED. Its only
// consumer, the per-ship chevron layer, was removed in S5; nothing draws per-ship chevrons now.)

// ── Presentation ────────────────────────────────────────────────────────────────────────────────────

/** One in-flight team badge: accent diamond + haloed label. Pointer-transparent, tokens only.
 *  FLEET-GO 4a-1: `testIdPrefix` lets the in-space fleet badge reuse this EXACT presentation under
 *  its own testid (`fleet-space-badge-<groupId>`) — default unchanged for every existing caller. */
export function TeamMarkerBadge({
  groupId,
  label,
  x,
  y,
  k,
  testIdPrefix = 'team-marker',
}: {
  groupId: string
  label: string
  x: number
  y: number
  k: number
  testIdPrefix?: string
}) {
  const r = 5 / k
  return createElement(
    'g',
    { 'data-testid': `${testIdPrefix}-${groupId}`, style: { pointerEvents: 'none' as const } },
    createElement('circle', { cx: x, cy: y, r: r * 1.8, fill: 'var(--color-accent)', opacity: 0.15 }),
    createElement('polygon', {
      points: `${x},${y - r} ${x + r},${y} ${x},${y + r} ${x - r},${y}`,
      fill: 'var(--color-accent)',
      stroke: 'var(--color-app)',
      strokeWidth: 1,
      vectorEffect: 'non-scaling-stroke',
    }),
    createElement(
      'text',
      {
        x,
        y: y - r - 3 / k,
        fontSize: 10 / k,
        textAnchor: 'middle',
        fill: 'var(--color-accent)',
        stroke: 'var(--color-map-halo)',
        strokeWidth: 3 / k,
        paintOrder: 'stroke',
        style: { userSelect: 'none' as const },
      },
      label,
    ),
  )
}

/** Docked-team badge under a location marker; `stack` staggers co-docked teams. */
export function TeamDockBadge({
  groupId,
  label,
  x,
  y,
  k,
  stack,
}: {
  groupId: string
  label: string
  x: number
  y: number
  k: number
  stack: number
}) {
  return createElement(
    'g',
    { 'data-testid': `team-dock-badge-${groupId}`, style: { pointerEvents: 'none' as const } },
    createElement(
      'text',
      {
        x,
        y: y + (14 + stack * 11) / k,
        fontSize: 10 / k,
        textAnchor: 'middle',
        fill: 'var(--color-accent)',
        stroke: 'var(--color-map-halo)',
        strokeWidth: 3 / k,
        paintOrder: 'stroke',
        style: { userSelect: 'none' as const },
      },
      label,
    ),
  )
}

/** MAP-INTEGRATION M1 — the in-combat fleet badge: a DANGER-tinted engagement ring around the combat
 *  site's marker plus a haloed danger label below it (the TeamDockBadge below-marker convention, so
 *  it never collides with the site's own name label above; `stack` staggers co-fighting teams).
 *  Pointer-transparent, tokens only — the combat tint is the map's existing hostile color. */
export function TeamCombatBadge({
  groupId,
  label,
  x,
  y,
  k,
  stack,
}: {
  groupId: string
  label: string
  x: number
  y: number
  k: number
  stack: number
}) {
  const r = 5 / k
  return createElement(
    'g',
    { 'data-testid': `fleet-combat-badge-${groupId}`, style: { pointerEvents: 'none' as const } },
    createElement('circle', {
      cx: x,
      cy: y,
      r: r * 2.4,
      fill: 'none',
      stroke: 'var(--color-danger)',
      strokeWidth: 1.25,
      vectorEffect: 'non-scaling-stroke',
      opacity: 0.85,
    }),
    createElement(
      'text',
      {
        x,
        y: y + (14 + stack * 11) / k,
        fontSize: 10 / k,
        textAnchor: 'middle',
        fill: 'var(--color-danger)',
        stroke: 'var(--color-map-halo)',
        strokeWidth: 3 / k,
        paintOrder: 'stroke',
        style: { userSelect: 'none' as const },
      },
      label,
    ),
  )
}

/** In-flight team badges with a 1s visual tick (only while any team is moving). */
export function TeamMovingMarkers({
  movements,
  groups,
  norm,
  k,
}: {
  movements: FleetMovement[]
  groups: GroupRow[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
}) {
  // `now` in state (lazy init), advanced by the tick ONLY while a team badge exists
  // (Date.now() stays out of render; the interval clears when static).
  const [now, setNow] = useState(() => Date.now())
  const markers = resolveTeamMarkers(movements, groups, now)
  const active = markers.length > 0

  useEffect(() => {
    if (!active) return
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [active])

  if (!active) return null
  return createElement(
    'g',
    { 'data-testid': 'team-markers-layer' },
    ...markers.map((m) => {
      const p = norm({ x: m.x, y: m.y })
      return createElement(TeamMarkerBadge, { key: m.groupId, groupId: m.groupId, label: m.label, x: p.x, y: p.y, k })
    }),
  )
}

// ── Pure, hook-free GalaxyMap team-overlay layer (the `shipLayer` element-tree convention): moving
// badges first, dock badges after. Returns element DESCRIPTORS only — it executes no hooks, so the
// unit tests call this SAME function and inspect the tree. Zero groups → [] (the map renders
// byte-identical to today; TEAM_COMMAND dark keeps the groups read empty upstream). ──
export function teamMarkersLayer(args: {
  movements: FleetMovement[]
  groups: GroupRow[]
  rollups: DockedTeamRollup[]
  // S2 TERRITORY widened the pick with name + territory_radius for the in-space badge's
  // "in orbit of X" read; the dock badges still use only id/x/y.
  locations: Pick<MapLocation, 'id' | 'name' | 'x' | 'y' | 'territory_radius'>[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
  /** FLEET-GO 4a-1: unified group fleets for the in-space badge. Optional, default [] →
   *  byte-identical layer (dark-inert by construction — nothing writes location_mode='space'
   *  while the unified gate is false). */
  unifiedFleets?: UnifiedGroupFleetLite[]
  /** MAP-INTEGRATION M1: the COMBAT-PRESENT fleets (teamRollup.selectCombatSortieFleets — the exact
   *  complement of the dock fold's exclusion) for the in-combat badge. Optional, default [] →
   *  byte-identical layer (dark: the unified fetch is gated, so this is always []). */
  combatFleets?: UnifiedGroupFleetLite[]
  /** The caller's live encounters + combat units — the SAME arrays the spatial units layer beside
   *  this one is drawn from, so a fleet's badge and its ships are placed from one source. Optional,
   *  default [] → no fleet reads as fighting and every badge keeps its resting position, i.e. the
   *  pre-slice layer byte for byte. */
  encounters?: FleetEncounterLite[]
  units?: CombatUnit[]
}): ReactElement[] {
  if (args.groups.length === 0) return []
  const out: ReactElement[] = [
    createElement(TeamMovingMarkers, {
      key: 'team-moving-markers',
      movements: args.movements,
      groups: args.groups,
      norm: args.norm,
      k: args.k,
    }),
  ]
  const perLoc = new Map<string, number>()
  for (const b of resolveTeamDockBadges(args.rollups)) {
    const loc = args.locations.find((l) => l.id === b.locationId)
    if (!loc) continue // location not in the visible world read → no badge (fail closed)
    const stack = perLoc.get(b.locationId) ?? 0
    perLoc.set(b.locationId, stack + 1)
    const p = args.norm({ x: loc.x, y: loc.y })
    out.push(
      createElement(TeamDockBadge, {
        key: `team-dock-${b.groupId}`,
        groupId: b.groupId,
        label: b.label,
        x: p.x,
        y: p.y,
        k: args.k,
        stack,
      }),
    )
  }
  // MAP-INTEGRATION M1 — in-combat fleet badges (the hunt sortie's combat phase), rendered on the
  // fleet's own LEAD SHIP (see the resolver's header) with the danger tint, and so moving with it as
  // the poll advances. Shares the per-location stack counter with the dock badges so co-located badge
  // text never overlaps (a combat site can never carry a dock badge — the fold excludes it — but
  // co-fighting teams stack). Stacking stays keyed on the SITE, which is what they share.
  for (const b of resolveFleetCombatBadges(
    args.combatFleets ?? [],
    args.groups,
    args.rollups,
    args.locations,
    args.encounters ?? [],
    args.units ?? [],
  )) {
    const stack = perLoc.get(b.locationId) ?? 0
    perLoc.set(b.locationId, stack + 1)
    const p = args.norm({ x: b.x, y: b.y })
    out.push(
      createElement(TeamCombatBadge, {
        key: `fleet-combat-${b.groupId}`,
        groupId: b.groupId,
        label: b.label,
        x: p.x,
        y: p.y,
        k: args.k,
        stack,
      }),
    )
  }
  // FLEET-GO 4a-1 — in-space fleet badges (parked unified fleets), reusing the moving badge's
  // presentation under its own testid. No interpolation tick: a parked fleet does not move, and a
  // FIGHTING one is repositioned by the ~1.5s useCombat poll that refreshes `units`, not by a clock
  // here. S2 TERRITORY: the world read feeds the place-name clause.
  // ⚑ This is also the AMBUSH-combat badge — per production, every one of the owner's off-centre
  // fights lands here, not on the combat arm above (see the resolver's header).
  for (const b of resolveFleetSpaceBadges(
    args.unifiedFleets ?? [],
    args.groups,
    args.rollups,
    args.locations,
    args.encounters ?? [],
    args.units ?? [],
  )) {
    const p = args.norm({ x: b.x, y: b.y })
    out.push(
      createElement(TeamMarkerBadge, {
        key: `fleet-space-${b.groupId}`,
        groupId: b.groupId,
        label: b.label,
        x: p.x,
        y: p.y,
        k: args.k,
        testIdPrefix: 'fleet-space-badge',
      }),
    )
  }
  return out
}
