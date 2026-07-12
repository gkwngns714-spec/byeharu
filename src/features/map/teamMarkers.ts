import { createElement, useEffect, useState, type ReactElement } from 'react'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { GroupRow } from '../command/teamRoster'
import type { DockedTeamRollup } from '../command/teamRollup'
import type { MapLocation } from './mapTypes'
import { interpolateMovementPoint } from './movementInterpolation'

// TEAMMAP-2 — the team's OWN map marker (owner directive: "The team should have a marker of its own
// and be shown on map"). Read-only display layer over server-committed rows; additive beside the
// existing marker/line layers — it changes NO existing marker resolution and duplicates NO pipeline:
//   • position math   → the ONE shared interpolateMovementPoint (extracted from resolveMainShipMarker)
//   • fleet team tag  → movements' flattened fleets.group_id (0168/0187, informational/display-only)
//   • docked teams    → the pure deriveDockedTeamRollups fold (command/teamRollup)
//   • wiring          → the pure, hook-free `teamMarkersLayer` element-descriptor helper (the
//                       SpaceRouteLine `shipLayer` element-tree convention; GalaxyMap and the unit
//                       tests call the SAME function).
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
      label: list.length > 1 ? `Team ${name} · ${list.length} ships` : `Team ${name}`,
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
      label: `Team ${r.name} ${r.dockedCount}/${r.memberCount}`,
      locationId: r.locationId,
    }))
}

// ── Presentation ────────────────────────────────────────────────────────────────────────────────────

/** One in-flight team badge: accent diamond + haloed label. Pointer-transparent, tokens only. */
export function TeamMarkerBadge({
  groupId,
  label,
  x,
  y,
  k,
}: {
  groupId: string
  label: string
  x: number
  y: number
  k: number
}) {
  const r = 5 / k
  return createElement(
    'g',
    { 'data-testid': `team-marker-${groupId}`, style: { pointerEvents: 'none' as const } },
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

/** In-flight team badges with the MainShipMarker 1s visual tick (only while any team is moving). */
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
  // `now` in state (lazy init), advanced by the tick ONLY while a team badge exists — the exact
  // MainShipMarker idiom (Date.now() stays out of render; the interval clears when static).
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
  locations: Pick<MapLocation, 'id' | 'x' | 'y'>[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
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
  return out
}
