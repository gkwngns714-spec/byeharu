// WORLD EDITOR — the ONE map-representation resolver (§WE.2 "resolve map representation", §WE.11 "one
// real map"). PURE: it forwards CANONICAL WORLD coordinates through the SHARED openSpaceTransform
// (worldToViewBox) — the single projection authority the real GalaxyMap uses — and NEVER invents a
// second world↔viewBox map (the retired ZoneEditor's bespoke fit-to-content transform was exactly
// that spaghetti, §WE.11). No React, no DOM, no clamping: unit-tested directly against worldToViewBox.
import { WORLD_TO_VIEWBOX_SCALE, worldToViewBox, type ViewBoxCoord } from '../map/openSpaceTransform'
import type { MapRepresentation, WorldPoint } from './worldEditorTypes'

/** A map representation resolved into viewBox space (still pre-camera; the shell applies the camera
 *  `<g transform>` exactly like GalaxyMap). Same tagged-union shape as MapRepresentation; a circle's
 *  radius is a LENGTH, converted through WORLD_TO_VIEWBOX_SCALE — the one world-length→viewBox
 *  authority (positions go through worldToViewBox; never a second scale). */
export type ResolvedRepresentation =
  | { readonly kind: 'point'; readonly point: ViewBoxCoord }
  | { readonly kind: 'polygon'; readonly ring: ViewBoxCoord[] }
  | { readonly kind: 'circle'; readonly center: ViewBoxCoord; readonly radius: number }

/** Project a representation's canonical world coords → viewBox via the SHARED transform (§WE.4: ONE
 *  projection authority; never a third coordinate system). */
export function resolveToViewBox(rep: MapRepresentation): ResolvedRepresentation {
  if (rep.kind === 'point') return { kind: 'point', point: worldToViewBox(rep.world) }
  if (rep.kind === 'circle') {
    return {
      kind: 'circle',
      center: worldToViewBox(rep.center),
      radius: rep.radius * WORLD_TO_VIEWBOX_SCALE,
    }
  }
  return { kind: 'polygon', ring: rep.ring.map((p) => worldToViewBox(p)) }
}

/** The canonical WORLD points a representation occupies — fed to the camera content-fit
 *  (galaxyCamera.fitCameraToWorldPoints) so the initial/reset frame includes every visible item.
 *  A circle contributes its world-space bbox corners (center ± radius on both axes) so the fit
 *  frames the WHOLE disc, not just its center. */
export function representationWorldPoints(rep: MapRepresentation): WorldPoint[] {
  if (rep.kind === 'point') return [rep.world]
  if (rep.kind === 'circle') {
    const { center, radius } = rep
    return [
      { x: center.x - radius, y: center.y - radius },
      { x: center.x + radius, y: center.y - radius },
      { x: center.x + radius, y: center.y + radius },
      { x: center.x - radius, y: center.y + radius },
    ]
  }
  return [...rep.ring]
}
