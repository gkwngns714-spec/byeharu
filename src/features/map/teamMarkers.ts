import { createElement, useEffect, useState, type ReactElement } from 'react'
import type { GroupRow, ShipGroupMapEntry } from '../command/teamRoster'
import type { UnifiedGroupFleetLite } from '../command/teamApi'
import type { CombatUnit } from '../combat/combatTypes'
import type { FleetEncounterLite } from '../combat/encounterAnchor'
import type { FleetPosition } from './mainshipApi'
import { MARKER_BELOW_LABEL_OFFSET, MARKER_BELOW_LABEL_STEP } from './markerStyle'
import {
  resolveFleetPresence,
  type FleetPresence,
  type FleetPresenceState,
  type PresenceLocation,
} from './fleetPresence'

// ██ THE FLEET LAYER — one fleet, one marker, in every state. ██
//
// This file used to hold FOUR resolvers, each deciding for itself whether a fleet EXISTS on the map.
// A fleet matching none of them was invisible, which is exactly what the owner hit: "in map, tell me
// where my fleets are too." All four are DELETED, not wrapped — the whole question now has one
// answer, in map/fleetPresence.ts, and this file is only its presentation.
//
// Presentation by state (the state decides HOW, never WHETHER):
//   · in-combat → the danger ring + a danger label under the point (TeamCombatBadge)
//   · moving    → the accent diamond, re-interpolated on a 1s clock (TeamMovingMarkers)
//   · in-space  → the same accent diamond, no clock (a parked fleet does not move; a FIGHTING one is
//                 moved by the ~1.5s combat poll that refreshes `units`, not by a clock here)
//   · docked    → the label under the port's marker (TeamDockBadge)
//   · unplaced  → no world point exists, so no world badge is drawn. It is still ON THE MAP: the
//                 layer hands these to GalaxyMap, which lists them in the map's own overlay rail.
//                 A fleet the world cannot place is reported, never silently dropped and never
//                 parked on a coordinate it is not at.
//
// Every badge carries the SAME testid prefix, `fleet-marker-<groupId>`, in every state — so "exactly
// one marker per fleet" is one query, and tests/fleetPresence.spec.ts asserts it across the whole
// closed state set.

/** In-flight fleet badges, re-interpolated on a 1s clock (mounted only while one is actually moving).
 *
 *  `resolve` is the SAME `resolveFleetPresence` call the layer already made, closed over its inputs and
 *  left open at the clock — so the ticked position comes from the ONE authority rather than from a
 *  second interpolation living here. `active` is passed in rather than re-derived: the layer already
 *  knows, and a component that re-decides its own existence is the shape this whole file just deleted. */
export function TeamMovingMarkers({
  active,
  resolve,
  norm,
  k,
}: {
  active: boolean
  resolve: (nowMs: number) => FleetPresence[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
}) {
  // `now` in state (lazy init), advanced ONLY while a moving fleet exists (Date.now() stays out of
  // render; the interval clears the moment nothing is in flight).
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!active) return
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [active])
  if (!active) return null
  return createElement(
    'g',
    { 'data-testid': 'team-markers-layer' },
    ...resolve(now)
      .filter((p): p is FleetPresence & { at: { x: number; y: number } } => p.state === 'moving' && p.at !== null)
      .map((p) => {
        const q = norm(p.at)
        return createElement(FleetPointBadge, { key: p.groupId, groupId: p.groupId, label: p.label, x: q.x, y: q.y, k })
      }),
  )
}

// ── Presentation ────────────────────────────────────────────────────────────────────────────────────

/** A fleet standing at a point in open space (moving or parked): accent diamond + haloed label. */
export function FleetPointBadge({
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
    { 'data-testid': `fleet-marker-${groupId}`, style: { pointerEvents: 'none' as const } },
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

/** A fleet docked at a port: a haloed label UNDER the port's marker (so it never collides with the
 *  location's own name above it); `stack` staggers fleets sharing one port. */
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
    { 'data-testid': `fleet-marker-${groupId}`, style: { pointerEvents: 'none' as const } },
    createElement(
      'text',
      {
        x,
        y: y + (MARKER_BELOW_LABEL_OFFSET + stack * MARKER_BELOW_LABEL_STEP) / k,
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

/** A fleet in a fight: a DANGER-tinted engagement ring at the point plus a haloed danger label below
 *  it (the dock badge's below-the-point convention; `stack` staggers fleets sharing one site). */
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
    { 'data-testid': `fleet-marker-${groupId}`, style: { pointerEvents: 'none' as const } },
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
        y: y + (MARKER_BELOW_LABEL_OFFSET + stack * MARKER_BELOW_LABEL_STEP) / k,
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

export interface FleetLayerArgs {
  groups: GroupRow[]
  membership: Readonly<Record<string, Pick<ShipGroupMapEntry, 'group_id'>>>
  positions: readonly Pick<FleetPosition, 'main_ship_id' | 'place' | 'location_id' | 'segment' | 'space_x' | 'space_y'>[]
  locations: readonly PresenceLocation[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
  nowMs: number
  /** Identity only — the group's `fleets.id` for the encounter join (map/fleetPresence). */
  fleets?: readonly Pick<UnifiedGroupFleetLite, 'id' | 'group_id'>[]
  /** The SAME encounters + units the spatial layer beside this one draws, so a fleet's badge and its
   *  own ships are placed from one source and can never render as two things in two places. */
  encounters?: readonly FleetEncounterLite[]
  units?: readonly CombatUnit[]
}

/** What GalaxyMap needs: the world badges, and the fleets no world point can carry. */
export interface FleetLayer {
  elements: ReactElement[]
  /** 'unplaced' presences — rendered by GalaxyMap in the map's overlay rail, never as a fake point. */
  unplaced: FleetPresence[]
}

// Pure and hook-free (the shipLayer element-tree convention): it executes no hooks itself, so the unit
// tests call this SAME function and inspect the tree. Zero groups → an empty layer.
export function fleetLayer(args: FleetLayerArgs): FleetLayer {
  // ONE call site for the authority, left open at the clock so the moving badge's 1s tick re-reads it
  // instead of interpolating again on its own.
  const resolve = (nowMs: number): FleetPresence[] =>
    resolveFleetPresence({
      groups: args.groups,
      membership: args.membership,
      positions: args.positions,
      fleets: args.fleets,
      locations: args.locations,
      encounters: args.encounters,
      units: args.units,
      nowMs,
    })
  const presences = resolve(args.nowMs)
  if (presences.length === 0) return { elements: [], unplaced: [] }

  const elements: ReactElement[] = [
    createElement(TeamMovingMarkers, {
      key: 'team-moving-markers',
      active: presences.some((p) => p.state === 'moving'),
      resolve,
      norm: args.norm,
      k: args.k,
    }),
  ]
  // Badges that sit UNDER a shared anchor (dock + combat) stagger so co-located text never overlaps.
  // Keyed on the site they share; a fleet with no site never stacks against another.
  const perLoc = new Map<string, number>()
  const stackFor = (locationId: string | null): number => {
    if (!locationId) return 0
    const n = perLoc.get(locationId) ?? 0
    perLoc.set(locationId, n + 1)
    return n
  }
  const unplaced: FleetPresence[] = []
  for (const p of presences) {
    if (p.at === null) {
      unplaced.push(p)
      continue
    }
    if (p.state === 'moving') continue // owned by TeamMovingMarkers above (it carries the clock)
    const q = args.norm(p.at)
    const common = { key: p.groupId, groupId: p.groupId, label: p.label, x: q.x, y: q.y, k: args.k }
    if (p.state === 'in-combat') {
      elements.push(createElement(TeamCombatBadge, { ...common, stack: stackFor(p.locationId) }))
    } else if (p.state === 'docked') {
      elements.push(createElement(TeamDockBadge, { ...common, stack: stackFor(p.locationId) }))
    } else {
      elements.push(createElement(FleetPointBadge, common))
    }
  }
  return { elements, unplaced }
}

export type { FleetPresence, FleetPresenceState }
