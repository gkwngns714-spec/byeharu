// WORLD EDITOR — the ONE map-representation resolver (§WE.2 "resolve map representation", §WE.11 "one
// real map"). PURE: it forwards CANONICAL WORLD coordinates through the SHARED openSpaceTransform
// (worldToViewBox) — the single projection authority the real GalaxyMap uses — and NEVER invents a
// second world↔viewBox map (that bespoke `makeFit` is exactly the ZoneEditor spaghetti being retired,
// §WE.11). No React, no DOM, no clamping: unit-tested directly against worldToViewBox.
import { worldToViewBox, type ViewBoxCoord } from '../map/openSpaceTransform'
import type { MapRepresentation, WorldPoint } from './worldEditorTypes'

/** A map representation resolved into viewBox space (still pre-camera; the shell applies the camera
 *  `<g transform>` exactly like GalaxyMap). Same tagged-union shape as MapRepresentation. */
export type ResolvedRepresentation =
  | { readonly kind: 'point'; readonly point: ViewBoxCoord }
  | { readonly kind: 'polygon'; readonly ring: ViewBoxCoord[] }

/** Project a representation's canonical world coords → viewBox via the SHARED transform (§WE.4: ONE
 *  projection authority; never a third coordinate system). */
export function resolveToViewBox(rep: MapRepresentation): ResolvedRepresentation {
  if (rep.kind === 'point') return { kind: 'point', point: worldToViewBox(rep.world) }
  return { kind: 'polygon', ring: rep.ring.map((p) => worldToViewBox(p)) }
}

/** The canonical WORLD points a representation occupies — fed to the camera content-fit
 *  (galaxyCamera.fitCameraToWorldPoints) so the initial/reset frame includes every visible item. */
export function representationWorldPoints(rep: MapRepresentation): WorldPoint[] {
  return rep.kind === 'point' ? [rep.world] : [...rep.ring]
}
