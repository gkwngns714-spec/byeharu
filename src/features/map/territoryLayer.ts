// S2 TERRITORY — the territory-ring layer: one WORLD-TRUE ring per location with a non-null
// territory_radius (0217). Follows the fleetShipsLayer/teamMarkersLayer element-helper convention:
// pure, hook-free, returns element descriptors, so GalaxyMap and the unit test call the SAME
// function. Mounted as the FIRST child of the camera <g> — under movement lines and every marker —
// and every element is pointerEvents:'none' (a region is scenery, never a tap target).
//
// WORLD-TRUE, deliberately NOT screen-constant: a territory is a region of SPACE, so its SVG
// radius is `territory_radius * WORLD_TO_VIEWBOX_SCALE` viewBox units and grows/shrinks with the
// camera zoom — the OPPOSITE of the `/k` marker-glyph idiom (which pins GLYPHS to a screen size).
// Only the stroke width and dash divide by k: line weight is presentation, not geometry.
//
// One ring layer suffices: LocationMarker stays the ONLY location renderer for glyphs/labels; this
// layer adds the region read for the same rows — no parallel location system. Ring tone composes
// markerStyle's ONE type→token decision (danger hostile / success safe / accent port) — no second
// color table.
//
// PIRATE-RING SUPPRESSION: a hostile location (markerStyle's `isCombatMarker` — pirate_hunt/pirate_den
// or the hunt_pirates activity) already gets the dangerZoneLayer "slime" polygon, so drawing this
// plain circle on top of it read as a redundant duplicate zone. Hostile locations are therefore
// SKIPPED here and represented ONLY by their danger-zone polygon; ports/safe/resource locations keep
// their ring exactly as before. This reuses markerStyle's ONE hostile classifier — no second table,
// no data change (territory_radius and the intercept/presence logic that reads it are untouched).
import { createElement, type ReactElement } from 'react'
import type { MapLocation } from './mapTypes'
import { isCombatMarker, markerStyle, type MarkerStyleInputs } from './markerStyle'
import { WORLD_TO_VIEWBOX_SCALE } from './openSpaceTransform'

/** What a ring needs: position + radius + the markerStyle tone inputs (any MapLocation satisfies). */
export type TerritoryRingLocation = Pick<MapLocation, 'id' | 'x' | 'y' | 'territory_radius'> & MarkerStyleInputs

export function territoryLayer(args: {
  locations: readonly TerritoryRingLocation[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
}): ReactElement[] {
  const out: ReactElement[] = []
  for (const loc of args.locations) {
    if (isCombatMarker(loc)) continue // hostile → shown by the danger-zone polygon; no duplicate ring
    const r = loc.territory_radius
    if (r == null || !Number.isFinite(r) || r <= 0) continue // null radius = no territory, no ring
    const p = args.norm({ x: loc.x, y: loc.y })
    const ringR = r * WORLD_TO_VIEWBOX_SCALE // world-true: viewBox units, NOT /k
    const color = markerStyle(loc).color
    out.push(
      createElement(
        'g',
        { key: `territory-${loc.id}`, 'data-testid': `territory-ring-${loc.id}`, style: { pointerEvents: 'none' as const } },
        // faint filled disc — the region reads as an area even at low zoom
        createElement('circle', { cx: p.x, cy: p.y, r: ringR, fill: color, opacity: 0.06 }),
        // dashed boundary — screen-constant line weight over the world-true geometry
        createElement('circle', {
          cx: p.x,
          cy: p.y,
          r: ringR,
          fill: 'none',
          stroke: color,
          strokeOpacity: 0.35,
          strokeWidth: 1 / args.k,
          strokeDasharray: `${4 / args.k} ${3 / args.k}`,
        }),
      ),
    )
  }
  return out
}
