// WORLD EDITOR — MAP HIT-TESTING: which entities sit under a click? Props in → candidates out.
// NO React, no DOM, no SVG, no storage, no network — the worldEditorChrome / worldEditorDraftGuard
// pure-module idiom, unit-tested directly (tests/worldEditorHitTest.spec.ts).
//
// ── THE DEFECT THIS EXISTS TO FIX ───────────────────────────────────────────────────────────────
// pirate_hunt locations and their danger zones are CO-LOCATED, and the map draws polygons UNDER
// points. Each shape carried its own onClick with stopPropagation, so the topmost element always won
// and a click on a zone's label or marker silently selected the LOCATION instead. The zone could only
// be selected by finding shaded fill far enough from the marker — which reads, correctly, as "I
// cannot select this zone".
//
// ── WHY NOT JUST RAISE THE POLYGON ──────────────────────────────────────────────────────────────
// Because that inverts the bug rather than fixing it: the zone would become selectable and the
// co-located location would become the unreachable one. Whichever shape is on top wins, and both are
// legitimate targets at the same coordinate. Silent priority is the wrong answer in either direction.
//
// So the hit-test returns EVERY candidate under the point and lets the caller disambiguate:
//   • exactly one  → select it directly, no ceremony;
//   • more than one → the caller summons a chooser (map-UX law #2: the UI is summoned, never parked).
// The pure part is only "what is under this point, in what order" — the UI decision stays outside.

import { pointInCircle, pointInPolygon } from './zoneGeometryMath'
import type { LayerId, LayerItem, WorldPoint } from './worldEditorTypes'

/** One entity under the cursor. Carries enough to render a chooser row and to select. */
export interface HitCandidate {
  readonly layer: LayerId
  readonly id: string
  readonly label: string
  /** How it was hit — drives the chooser's icon and the ordering below. */
  readonly shape: 'point' | 'polygon' | 'circle'
}

/** Ordering, and the reason for it.
 *  POINTS FIRST: a marker is a small, deliberate target; a polygon is a large region that merely
 *  contains it. When both are hit, the smaller intent is the likelier one, so it heads the list and
 *  becomes the default in any UI that offers one. Ties break by label then id so the order is total
 *  and stable — a chooser must not reshuffle between identical clicks. */
const SHAPE_RANK: Record<HitCandidate['shape'], number> = { point: 0, circle: 1, polygon: 2 }

export function compareCandidates(a: HitCandidate, b: HitCandidate): number {
  if (SHAPE_RANK[a.shape] !== SHAPE_RANK[b.shape]) return SHAPE_RANK[a.shape] - SHAPE_RANK[b.shape]
  if (a.label !== b.label) return a.label < b.label ? -1 : 1
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
}

/** Does this item contain the world point?
 *  `pointRadius` is the marker's clickable radius in WORLD units — the caller converts it from the
 *  on-screen radius using the current zoom, because a marker's hit area is constant on screen and
 *  therefore shrinks in world terms as you zoom in. Passing a view-space radius here would make
 *  markers unhittable at high zoom. */
function itemContains(item: LayerItem, world: WorldPoint, pointRadius: number): boolean {
  const r = item.representation
  if (r.kind === 'point') return pointInCircle(world, r.world, pointRadius)
  if (r.kind === 'circle') return pointInCircle(world, r.center, r.radius)
  return r.ring.length >= 3 && pointInPolygon(world, r.ring)
}

/** EVERY visible item under the point, deterministically ordered. Empty when the click hit bare map.
 *  Pure: it reads only what it is given, so the same inputs always yield the same list in the same
 *  order — which is what lets a chooser be stable and a test be exhaustive. */
export function hitTestAt(
  items: readonly LayerItem[],
  world: WorldPoint,
  pointRadius: number,
): HitCandidate[] {
  const hits: HitCandidate[] = []
  for (const item of items) {
    if (!itemContains(item, world, pointRadius)) continue
    hits.push({
      layer: item.layer,
      id: item.id,
      label: item.label,
      shape: item.representation.kind,
    })
  }
  return hits.sort(compareCandidates)
}

/** True when the caller must ask rather than guess. One candidate is not ambiguous; none is a
 *  deselect. */
export function needsDisambiguation(candidates: readonly HitCandidate[]): boolean {
  return candidates.length > 1
}

/** The candidate a UI should preselect / a keyboard "just pick one" should take — the first under the
 *  ordering above. Null when nothing was hit, so a caller can treat that as "deselect". */
export function primaryCandidate(candidates: readonly HitCandidate[]): HitCandidate | null {
  return candidates.length > 0 ? candidates[0] : null
}

/** Convert the marker's drawn hit radius to WORLD units. Two conversions, and both are needed:
 *
 *    r_viewBox = markerRadius / k            the map draws the hit circle inside a scale(k) group,
 *                                            so it stays a constant size on screen
 *    r_world   = r_viewBox / worldToViewBox  viewBox units are not world units
 *
 *  Skipping the second step silently shrinks the marker's hit area by the world→viewBox factor,
 *  which in this map is large enough that a click landing exactly on a marker misses it entirely.
 *  That is not hypothetical — it is the bug this function was written wrong for the first time. */
export function markerRadiusInWorld(
  markerRadius: number,
  scale: number,
  worldToViewBox: number,
): number {
  if (!(scale > 0) || !(worldToViewBox > 0)) return markerRadius
  return markerRadius / scale / worldToViewBox
}
