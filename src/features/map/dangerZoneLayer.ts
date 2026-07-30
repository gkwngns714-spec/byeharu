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
// hovered and the client had no way to name one. It now HOVERS — pointing at a blob brightens it and
// names it — when, and only when, a caller passes `onHoverChange`/`hoveredId`.
//
// ── THE ZONE DOES NOT OWN A CLICK (owner, 2026-07-30: "i can't send a fleet to zone since it is
//    pressed and info is shown") ────────────────────────────────────────────────────────────────────
// The first cut gave the fill its own `onClick` that opened the info panel. Two things followed, and
// both were wrong:
//
//   1. Hit-testing the fill broke the map's unwritten "every layer is pointerEvents:'none'" invariant,
//      which GalaxyMap's gesture handler depended on via an `e.target !== svg` identity test. The
//      double-tap hub summon and the pirate waypoint tap both went dead over the whole area of every
//      zone — no fleet could be sent to a point inside a zone at all. Fixed by declaring passthrough
//      (below) so the ONE background authority accepts the gesture; see `mapBackground.ts`.
//   2. A raw `onClick` cannot coexist with the double-tap even once the gate is fixed, because `click`
//      fires AFTER `pointerup`: the second tap of a double would open the hub menu and then the click
//      would immediately replace it with the zone panel. The conflict is structural, not a race to be
//      tuned — so the click is GONE and the gesture stays with the one authority that already owns it.
//
// Zone info is now reached the same way every other map action is: double-tap → the command hub's
// icon cluster offers "What's here" when the tapped point is inside a zone (MapScreen). ONE gesture,
// ONE hub, and the hover name still identifies a zone with no tap at all.
//
// ONLY THE FILL IS HIT-TESTABLE (for hover), and the outline stays inert: the fill is the shape a
// player points at, and leaving the stroke out avoids a 1.5px ring hovering when the pointer is
// really aimed at a marker sitting on the boundary.
import { MAP_PASSTHROUGH_ATTR } from './mapBackground'
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
  /** Present = the layer hovers (and names itself). Absent = scenery, exactly as before. */
  onHoverChange?: (id: string | null) => void
  /** Id under the pointer, from the caller's hover state (the caller owns React state). */
  hoveredId?: string | null
  /** Id currently open in the info panel. */
  selectedId?: string | null
}): ReactElement[] {
  const interactive = typeof args.onHoverChange === 'function'
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
                // TRANSPARENT TO MAP GESTURES. The fill hit-tests so it can hover, which makes it the
                // pointer target for everything inside the blob — so it MUST hand the map's own
                // gestures back, or the double-tap summon and the pirate waypoint tap die across the
                // zone. This marker is how it does that; `mapBackground.isMapBackground` is the only
                // reader. Not `pointerEvents:'none'` — that would lose the hover with it.
                [MAP_PASSTHROUGH_ATTR]: 'true',
                // NO role/tabIndex. LocationMarker (:64-68) — the map's existing clickable — is a
                // plain onClick + cursor:pointer, and matching it is not just consistency: a
                // focusable SVG path takes browser FOCUS on click and Chrome paints a filled focus
                // ring over the whole blob (seen in the local build: the zone went white with a
                // black halo). tabIndex -1 is not keyboard-reachable anyway, so it bought nothing.
                //
                // NO `cursor:pointer` either: the zone is not clickable any more, and a hand cursor
                // over a third of the map would promise a tap that does nothing. The map keeps its
                // own grab cursor, which is the truth — you can pan and double-tap here.
                style: { pointerEvents: 'auto' as const },
                onPointerEnter: () => args.onHoverChange?.(z.id),
                onPointerLeave: () => args.onHoverChange?.(null),
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
