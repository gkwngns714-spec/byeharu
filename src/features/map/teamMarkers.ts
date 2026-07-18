import { createElement, useEffect, useState, type ReactElement } from 'react'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { GroupRow } from '../command/teamRoster'
import type { DockedTeamRollup } from '../command/teamRollup'
import type { UnifiedGroupFleetLite } from '../command/teamApi'
import type { MapLocation } from './mapTypes'
import { interpolateMovementPoint } from './movementInterpolation'
import { territoryAt } from './territoryAt'

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
      label: list.length > 1 ? `Fleet ${name} · ${list.length} ships` : `Fleet ${name}`,
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
      label: `Fleet ${r.name} ${r.dockedCount}/${r.memberCount}`,
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
export interface FleetSpaceBadgeDescriptor {
  groupId: string
  label: string
  /** WORLD coordinates in the legacy movement domain (project through the map's `norm`). */
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
    seen.add(f.group_id)
    const name = nameById.get(f.group_id) as string
    const n = countByGroup.get(f.group_id) ?? 0
    const base = n > 1 ? `Fleet ${name} · ${n} ships` : `Fleet ${name}`
    // S2 TERRITORY: the parked coordinate is WORLD-domain, exactly what territoryAt takes. No
    // containing territory → the plain label (never a guessed orbit).
    const orbit = territoryAt({ x: f.space_x, y: f.space_y }, locations)
    out.push({
      groupId: f.group_id,
      label: orbit ? `${base} · in orbit of ${orbit.name}` : base,
      x: f.space_x,
      y: f.space_y,
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
// classification, never re-derived here); this resolver only validates shape, names, and renders at
// the site's own position. Fail closed like every sibling: unknown/foreign group tag, or a combat
// site not in the visible world read → NO badge (never a guessed name/position, no hidden-site leak).
export interface FleetCombatBadgeDescriptor {
  groupId: string
  label: string
  locationId: string
  /** WORLD coordinates — the combat site's own position (the fleet is present AT it). */
  x: number
  y: number
}

export function resolveFleetCombatBadges(
  combatFleets: readonly UnifiedGroupFleetLite[],
  groups: readonly GroupRow[],
  rollups: readonly DockedTeamRollup[],
  locations: readonly Pick<MapLocation, 'id' | 'name' | 'x' | 'y'>[],
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
    seen.add(f.group_id)
    const name = nameById.get(f.group_id) as string
    const n = countByGroup.get(f.group_id) ?? 0
    const base = n > 1 ? `Fleet ${name} · ${n} ships` : `Fleet ${name}`
    out.push({
      groupId: f.group_id,
      label: `${base} · in combat at ${loc.name}`,
      locationId: loc.id,
      x: loc.x,
      y: loc.y,
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
  // MAP-INTEGRATION M1 — in-combat fleet badges (the hunt sortie's combat phase). Static (a fleet
  // in combat holds at the site), rendered at the site's own marker with the danger tint. Shares
  // the per-location stack counter with the dock badges so co-located badge text never overlaps
  // (a combat site can never carry a dock badge — the fold excludes it — but co-fighting teams stack).
  for (const b of resolveFleetCombatBadges(args.combatFleets ?? [], args.groups, args.rollups, args.locations)) {
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
  // FLEET-GO 4a-1 — in-space fleet badges (parked unified fleets). Static (no interpolation tick —
  // a parked fleet does not move), reusing the moving badge's presentation under its own testid.
  // S2 TERRITORY: the world read feeds the "in orbit of X" label extension.
  for (const b of resolveFleetSpaceBadges(args.unifiedFleets ?? [], args.groups, args.rollups, args.locations)) {
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
