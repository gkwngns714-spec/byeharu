// WORLD EDITOR — V5: COORDINATE JUMP. The complement to entity SEARCH: instead of finding a named
// entity, jump the camera to a RAW world coordinate the owner types. Pure NAVIGATION, exactly like
// worldEditorSearch — data in (an x/y pair) → a camera/view value out. It NEVER writes a coordinate,
// mutates selection, or issues IO, and it invents NO camera engine and NO bounds rule: it REUSES the
// two existing authorities end-to-end —
//   • validity comes from openSpaceTransform.isWithinOpenSpaceBounds (the ONE finite + ±10000-inclusive
//     open-space domain gate — the same predicate a command/target path must gate on), and
//   • the camera comes from galaxyCamera.fitCameraToWorldPoints over the single typed point (a
//     coordinate is just a one-point set; the fit's DEGENERATE_SPAN gives it a gentle default zoom,
//     the SAME frame a point entity gets through search / Focus).
// No React, no DOM, no fetch: unit-tested directly (tests/worldEditorGoto.spec.ts).
import { fitCameraToWorldPoints, type Camera } from '../map/galaxyCamera'
import { isWithinOpenSpaceBounds } from '../map/openSpaceTransform'

/** Why a typed coordinate was rejected — drives the UI's inline hint, never a thrown error.
 *   • `not-finite`  — x or y is NaN / ±Infinity (a non-numeric / blank input).
 *   • `out-of-bounds` — both finite, but outside the fixed ±10000 open-space domain. */
export type GotoInvalidReason = 'not-finite' | 'out-of-bounds'

/** The result of a coordinate jump, as a discriminated union — a valid in-bounds point yields the
 *  SAME `Camera` value `fitCameraToWorldPoints` produces; anything else is a typed rejection the
 *  caller renders as a hint (and performs NO navigation). */
export type GotoResult =
  | { readonly ok: true; readonly camera: Camera }
  | { readonly ok: false; readonly reason: GotoInvalidReason }

/** Frame the camera on a single raw world coordinate (x, y). Validity is decided by the ONE authority
 *  `isWithinOpenSpaceBounds` (finite AND within ±10000 on both axes, boundary inclusive); a valid point
 *  frames through the ONE camera authority `fitCameraToWorldPoints`. Pure: no IO, no mutation. */
export function gotoCamera(x: number, y: number): GotoResult {
  const point = { x, y }
  if (!isWithinOpenSpaceBounds(point)) {
    // Split the rejection ONLY for the hint copy — validity itself is the single predicate above.
    const finite = Number.isFinite(x) && Number.isFinite(y)
    return { ok: false, reason: finite ? 'out-of-bounds' : 'not-finite' }
  }
  return { ok: true, camera: fitCameraToWorldPoints([point]) }
}
