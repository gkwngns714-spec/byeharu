import { createElement, useEffect, useState, type ReactElement } from 'react'
import type { GroupRow, ShipGroupMapEntry } from '../command/teamRoster'
import type { UnifiedGroupFleetLite } from '../command/teamApi'
import type { CombatUnit } from '../combat/combatTypes'
import type { FleetEncounterLite } from '../combat/encounterAnchor'
import type { FleetPosition } from './mainshipApi'
import { MARKER_BELOW_LABEL_OFFSET, MARKER_BELOW_LABEL_STEP } from './markerStyle'
import { renderShipVisual, shipGlyphHalf } from './shipGlyph'
import type { ShipVisual } from './shipVisual'
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
// ── THE STATE DECIDES DECORATION. IT NEVER DECIDES THE SHIP. ████████████████████████████████████████
//
// THE OWNER: "the fleet shape changes when in a combat, and outside combat. I want it to be same."
//
// This file used to hold THREE badge components and each drew its own idea of a fleet:
//   · FleetPointBadge  — an inline accent DIAMOND at `5 / k`
//   · TeamCombatBadge  — a bare danger circle and NO ship at all
//   · TeamDockBadge    — a label and NO ship at all
// …while spatialCombatLayer, in the same `<svg>` under the same camera, drew that same fleet as an
// up-pointing TRIANGLE at `px(7) × 1.35`. Nothing reprojected between states; the fleet simply
// changed shape, because "what does a fleet look like" had four answers in two files.
//
// TeamCombatBadge and TeamDockBadge are DELETED. There is ONE badge, and it draws the ship from the
// ONE authority (map/shipVisual, rendered by map/shipGlyph — the SAME call the combat layer makes).
// What the state still chooses is decoration and placement only:
//   · in-combat → a DANGER ring around the point + a danger label BELOW it (per-site stacked). The
//                 ship itself is drawn by the spatial combat layer whenever that fight is positioned
//                 (`fightGlyph`), so the badge does not draw a second one on top of it — one fleet,
//                 one glyph, whichever layer owns it, and both ask shipVisual so they cannot differ.
//   · moving    → the accent halo + the ship + a label above, re-interpolated on a 1s clock
//                 (TeamMovingMarkers)
//   · in-space  → identical, without the clock (a parked fleet does not move; a FIGHTING one is moved
//                 by the ~1.5s combat poll that refreshes `units`, not by a clock here)
//   · docked    → the whole badge moves into the marker's BELOW lane: the ship, then the label. A
//                 docked fleet stands INSIDE the port's own glyph+halo footprint (up to 27.6px), and
//                 drawing a ship there would bury the port the player navigates by — which is the
//                 exact collision MARKER_BELOW_LABEL_OFFSET was raised to 46 to end, measured on the
//                 owner's live map where "Fleet 2 1/1" sat unreadable across the Slagworks diamond.
//                 The SHAPE is unchanged; only where the badge sits is, for the same reason the label
//                 already sat there.
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
  pxScale,
}: {
  active: boolean
  resolve: (nowMs: number) => FleetPresence[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
  pxScale?: number
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
        return createElement(FleetPointBadge, {
          key: p.groupId,
          groupId: p.groupId,
          label: p.label,
          x: q.x,
          y: q.y,
          k,
          pxScale,
          state: p.state,
          visual: p.visual,
        })
      }),
  )
}

// ── Presentation ────────────────────────────────────────────────────────────────────────────────────

/** One fleet's badge, in EVERY state. `state` chooses decoration and placement; `visual` is the ship,
 *  and it is the same descriptor the spatial combat layer draws from. */
export interface FleetBadgeProps {
  groupId: string
  label: string
  x: number
  y: number
  k: number
  /** CSS px per viewBox unit (GalaxyMap measures it). Omitted → 1, i.e. the historic ÷k sizing. */
  pxScale?: number
  state: FleetPresenceState
  /** the ONE ship descriptor (map/shipVisual) — never re-derived here */
  visual: ShipVisual
  /** true ⇔ the spatial combat layer is already drawing this fleet's ship at this exact point, so
   *  this badge must draw the ring and the label and NOT a second hull. */
  fightGlyph?: boolean
  /** per-site stagger index for the below-the-marker lane (docked + in-combat share one anchor). */
  stack?: number
}

export function FleetPointBadge({
  groupId,
  label,
  x,
  y,
  k,
  pxScale,
  state,
  visual,
  fightGlyph = false,
  stack = 0,
}: FleetBadgeProps) {
  // The glyph's half-size in viewBox units, from the ONE sizing path (CSS px ÷ k ÷ pxScale) — the
  // same conversion the combat readout uses, which is why the badge and the combat glyph are the same
  // size on the owner's 390px phone instead of 4 pixels and 19.
  const half = shipGlyphHalf(visual, { x, y, k, pxScale })
  const fighting = state === 'in-combat'
  const tone = fighting ? 'var(--color-danger)' : 'var(--color-accent)'
  // The below-the-marker LANE, in viewBox units. `MARKER_BELOW_LABEL_OFFSET / k` is the clearance
  // markerStyle owns (46 on-screen px — measured against the biggest marker's 27.6px halo), and each
  // further fleet at the same site advances by what a badge actually DRAWS: its hull plus one text
  // line (MARKER_BELOW_LABEL_STEP, still the line height it has always been).
  const laneTop = MARKER_BELOW_LABEL_OFFSET / k + stack * (2 * half + MARKER_BELOW_LABEL_STEP / k)
  // DOCKED sits in that lane (see the header): the ship first, then its name under it. Everything else
  // stands ON the point, with the name above unless a fight puts it below.
  const docked = state === 'docked'
  const cy = docked ? y + laneTop + half : y
  const labelY = docked
    ? y + laneTop + 2 * half + 9 / k
    : fighting
      ? y + (MARKER_BELOW_LABEL_OFFSET + stack * MARKER_BELOW_LABEL_STEP) / k
      : cy - half - 3 / k
  const text = createElement(
    'text',
    {
      key: 'label',
      x,
      y: labelY,
      fontSize: 10 / k,
      textAnchor: 'middle',
      fill: tone,
      stroke: 'var(--color-map-halo)',
      strokeWidth: 3 / k,
      paintOrder: 'stroke',
      style: { userSelect: 'none' as const },
    },
    label,
  )
  return createElement(
    'g',
    {
      'data-testid': `fleet-marker-${groupId}`,
      'data-state': state,
      'data-fight-glyph': fightGlyph ? 'true' : 'false',
      style: { pointerEvents: 'none' as const },
    },
    // A fight is announced by a DANGER ring around the point — decoration, sized off the ship rather
    // than off a second constant, so it stays around the hull at any zoom or hull size.
    fighting
      ? createElement('circle', {
          key: 'engagement',
          cx: x,
          cy: y,
          r: half * 1.9,
          fill: 'none',
          stroke: 'var(--color-danger)',
          strokeWidth: 1.25,
          vectorEffect: 'non-scaling-stroke',
          opacity: 0.85,
        })
      : createElement('circle', { key: 'halo', cx: x, cy: cy, r: half * 1.8, fill: 'var(--color-accent)', opacity: 0.15 }),
    // THE SHIP — unless the combat layer is drawing this very fleet at this very point.
    fightGlyph ? null : renderShipVisual(visual, { x, y: cy, k, pxScale }, 'hull'),
    text,
  )
}

export interface FleetLayerArgs {
  groups: GroupRow[]
  membership: Readonly<Record<string, Pick<ShipGroupMapEntry, 'group_id'>>>
  /** `class` is `hull_type_id`, which is what makes a fleet's SHAPE resolvable off the roster read the
   *  map already makes — see fleetPresence.PositionRow. */
  positions: readonly Pick<
    FleetPosition,
    'main_ship_id' | 'class' | 'place' | 'location_id' | 'segment' | 'space_x' | 'space_y'
  >[]
  locations: readonly PresenceLocation[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
  /** CSS px per viewBox unit (openSpaceTransform.viewBoxDisplayRect, measured by GalaxyMap). The badge
   *  needs it because a ship's size is stated in CSS px — see ShipVisual.sizePx for why ÷k alone
   *  rendered the fleet marker four pixels wide on the owner's phone. */
  pxScale?: number
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
      pxScale: args.pxScale,
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
    // ONE badge, in every state. The two branches that used to pick a COMPONENT here are gone — the
    // only thing the state still decides is the stagger, and it only applies to the two states that
    // share an anchor with something else (a port marker, another fight at the same site).
    elements.push(
      createElement(FleetPointBadge, {
        key: p.groupId,
        groupId: p.groupId,
        label: p.label,
        x: q.x,
        y: q.y,
        k: args.k,
        pxScale: args.pxScale,
        state: p.state,
        visual: p.visual,
        fightGlyph: p.fightGlyph,
        stack: p.state === 'in-combat' || p.state === 'docked' ? stackFor(p.locationId) : 0,
      }),
    )
  }
  return { elements, unplaced }
}

export type { FleetPresence, FleetPresenceState }
