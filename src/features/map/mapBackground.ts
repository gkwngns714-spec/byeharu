// THE ONE AUTHORITY for "did this pointer event land on the map's NAVIGABLE BACKGROUND?" — the
// question GalaxyMap's gesture handler asks before it will treat a pointer-up as a map gesture
// (the double-tap command-hub summon, and the pirate route-planner's waypoint taps).
//
// ── WHY THIS EXISTS (the defect it retires) ────────────────────────────────────────────────────────
// The question used to be answered by ELEMENT IDENTITY, inline: `e.target !== svg` → not a gesture.
// That worked only because of an unwritten invariant — EVERY drawn layer on the map was
// `pointerEvents:'none'`, so the `<svg>` itself was always the hit target. `dangerZoneLayer` broke
// that invariant when zones became clickable: the zone fill hit-tests, so inside a zone `e.target`
// is the zone's `<path>` and the identity check rejected the gesture. The map's double-tap summon
// AND the pirate waypoint tap were both dead across the entire area of every danger zone — i.e. a
// player could not send a fleet to a point inside a zone, and could not plot an intercept route
// through the one kind of place intercepts happen.
//
// Bubbling was never the mechanism, so the layer's "do NOT stopPropagation, the summon must survive
// inside a zone" precaution could not have helped: an identity test is not satisfied by an event
// reaching the svg, only by the svg BEING the target.
//
// ── THE RULE ──────────────────────────────────────────────────────────────────────────────────────
// Background is now DECLARED, not inferred. An element that draws over the map but must not swallow
// the map's own gestures marks itself `data-map-passthrough="true"`; this module is the only place
// that knows the marker, and GalaxyMap is the only caller. A layer opting into hit-testing therefore
// has exactly two coherent choices — take the gesture, or declare passthrough — instead of silently
// deleting a gesture for everything drawn underneath it.
//
// Pure and DOM-shape-only (no React, no camera math) so it is directly unit-testable.

/** Marker attribute: this element is drawn over the map but is transparent to MAP GESTURES. */
export const MAP_PASSTHROUGH_ATTR = 'data-map-passthrough'

/**
 * True iff `target` should be treated as the map's navigable background: it either IS the map's
 * `<svg>`, or it is an element that has declared itself gesture-passthrough.
 *
 * Fails closed on anything else (null target, a marker, a panel, a non-Element target) — the
 * pre-existing behaviour for every element that has not opted in.
 */
export function isMapBackground(target: EventTarget | null, svg: SVGSVGElement | null): boolean {
  if (!svg || target === null) return false
  if (target === svg) return true
  // `getAttribute` rather than `instanceof Element`: the check has to work for SVG elements across
  // documents/realms, where `instanceof` is unreliable, and a duck-typed test is enough here.
  const el = target as Partial<Element>
  if (typeof el.getAttribute !== 'function') return false
  return el.getAttribute(MAP_PASSTHROUGH_ATTR) === 'true'
}
