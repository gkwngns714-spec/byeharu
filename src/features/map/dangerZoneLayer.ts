// PIRATE INTERCEPT (prototype) — the danger-zone polygon layer: one smooth "slime" blob per active
// danger_zones row (get_danger_zones). Follows the territoryLayer/teamMarkersLayer element-helper
// convention: pure, hook-free, returns element descriptors, so GalaxyMap and any future unit test can
// call the SAME function. Rendered ABOVE the plain circle territoryLayer (which stays untouched and
// keeps drawing today's rings for every location) and UNDER movement lines/markers.
//
// WORLD-TRUE: every ring vertex goes through the SAME `norm` (worldToViewBox) the rest of the map
// uses — a drawn/circle zone scales with the camera exactly like every other spatial element.
//
// ── ZONE INFO (owner, 2026-07-29: "i want to be able to click it, and see the info") ──────────────
// A zone used to be scenery and nothing else: `pointerEvents:'none'` throughout, so it could not be
// hovered or clicked and the client had no way to name one. It is now a TAP TARGET when — and only
// when — a caller passes `onSelect`. Without that prop the layer is byte-identical to the scenery it
// was, so every existing caller and test keeps today's behaviour.
//
// ONLY THE FILL IS HIT-TESTABLE, and the outline stays inert: the fill is the shape a player points
// at, and leaving the stroke out of hit-testing avoids a 1.5px ring stealing clicks aimed at a
// marker sitting on the boundary.
//
// WHY CLICK AND NOT DOUBLE-CLICK: double-tap on the map is already taken — it summons the command
// hub — and that gesture must keep working INSIDE a zone, which covers a large part of the map. A
// single click is the free gesture, so the zone takes it and lets everything else bubble.
import { createElement, type ReactElement } from 'react'
import type { DangerZoneLite } from './pirateApi'
import { smoothClosedPathD } from './smoothPolygon'

/** Fill opacity by state. Selected reads strongest so the panel and the map agree on which zone. */
const FILL_IDLE = 0.1
const FILL_HOVER = 0.2
const FILL_SELECTED = 0.28

export function dangerZoneLayer(args: {
  zones: readonly DangerZoneLite[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
  /** Present = the layer is interactive. Absent = scenery, exactly as before. */
  onSelect?: (zone: DangerZoneLite) => void
  /** Id under the pointer, from the caller's hover state (the caller owns React state). */
  hoveredId?: string | null
  /** Id currently open in the info panel. */
  selectedId?: string | null
  onHoverChange?: (id: string | null) => void
}): ReactElement[] {
  const interactive = typeof args.onSelect === 'function'
  const out: ReactElement[] = []
  for (const z of args.zones) {
    if (!z.ring || z.ring.length < 3) continue
    const screenRing = z.ring.map(([x, y]) => args.norm({ x, y }))
    const d = smoothClosedPathD(screenRing)
    if (!d) continue
    const tone = z.source === 'circle' ? 'var(--color-danger)' : 'var(--color-warning, var(--color-danger))'
    const selected = interactive && args.selectedId === z.id
    const hovered = interactive && args.hoveredId === z.id
    const fillOpacity = selected ? FILL_SELECTED : hovered ? FILL_HOVER : FILL_IDLE

    out.push(
      createElement(
        'g',
        {
          key: `danger-zone-${z.id}`,
          'data-testid': `danger-zone-${z.id}`,
          // The GROUP stays inert; only the fill below opts in. Keeps the outline from hit-testing.
          style: { pointerEvents: 'none' as const },
        },
        createElement('path', {
          d,
          fill: tone,
          opacity: fillOpacity,
          ...(interactive
            ? {
                'data-testid': `danger-zone-hit-${z.id}`,
                // NO role/tabIndex. LocationMarker (:64-68) — the map's existing clickable — is a
                // plain onClick + cursor:pointer, and matching it is not just consistency: a
                // focusable SVG path takes browser FOCUS on click and Chrome paints a filled focus
                // ring over the whole blob (seen in the local build: the zone went white with a
                // black halo). tabIndex -1 is not keyboard-reachable anyway, so it bought nothing.
                style: { pointerEvents: 'auto' as const, cursor: 'pointer' },
                onPointerEnter: () => args.onHoverChange?.(z.id),
                onPointerLeave: () => args.onHoverChange?.(null),
                // Do NOT stopPropagation: a click that lands on a zone should still reach the map's
                // own handlers, and the double-tap summon must survive inside a zone.
                onClick: () => args.onSelect?.(z),
              }
            : {}),
        }),
        createElement('path', {
          d,
          fill: 'none',
          stroke: tone,
          // A hovered or open zone gets a brighter, thicker outline — the "you can click this"
          // affordance the owner asked for, without adding any text to the map.
          strokeOpacity: selected ? 1 : hovered ? 0.85 : 0.55,
          strokeWidth: (selected ? 2.5 : hovered ? 2 : 1.5) / args.k,
          strokeDasharray: z.source === 'drawn' ? `${5 / args.k} ${3 / args.k}` : undefined,
        }),
        // SVG-native accessible name AND a free hover tooltip: pointing at a blob names it before
        // the player commits to a click. This is the a11y that role/tabIndex was reaching for, in
        // the form SVG actually supports.
        interactive ? createElement('title', { key: `danger-zone-title-${z.id}` }, z.name) : null,
      ),
    )
  }
  return out
}
