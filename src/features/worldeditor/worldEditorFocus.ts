// WORLD EDITOR — C1: PURE domain-scoped FRAMING (camera-only). Data in → world points / Camera out.
// This module NEVER mutates its inputs and NEVER writes a coordinate anywhere: focusing a domain
// changes what the editor LOOKS AT, never what the world IS (the C1 contract,
// worldEditorCoordinates.ts). It REUSES the two existing authorities end-to-end — every item's
// canonical world points come from worldEditorGeometry.representationWorldPoints, and the camera
// comes from galaxyCamera.fitCameraToWorldPoints (which itself projects through the ONE shared
// openSpaceTransform projection) — so there is NO new transform math here of any kind. No React,
// no DOM, no IO: unit-tested directly (tests/worldEditorFocus.spec.ts).
import { fitCameraToWorldPoints, type Camera } from '../map/galaxyCamera'
import { representationWorldPoints } from './worldEditorGeometry'
import type { FocusDomain } from './worldEditorCoordinates'
import type { LayerId, LayerItem, WorldPoint } from './worldEditorTypes'

/** The domain the editor's DEFAULT frame (auto-fit-once + Reset) uses, so the editor opens at the same
 *  scale as the player's map. The game frames its locations (galaxyCamera.focusWorldPoints returns
 *  `[...locations]` when the player is not in open space); framing 'all' here additionally pulled in
 *  every zone ring vertex, which reach past the locations, so the two surfaces showed the same world at
 *  different sizes and a zone drawn to look right in the editor read differently in game.
 *
 *  It is a NAMED CONSTANT rather than a literal because both call sites must agree: an auto-fit that
 *  differs from Reset means the owner cannot get back to the frame they started in.
 *
 *  Parity holds for the not-in-open-space case only — the game's focus is player-priority and frames the
 *  ship or its movement segment when in transit. The editor has no ship, so that case has no counterpart. */
export const DEFAULT_FRAME_DOMAIN: FocusDomain = 'locations'

/** Optional focus refinements. `selected` includes ONE item's world points in the frame even when
 *  its layer is outside the chosen domain (so a cross-domain selection stays visible). */
export interface FocusOptions {
  readonly selected?: { readonly layer: LayerId; readonly id: string } | null
}

/** The canonical WORLD points a domain-focus should frame: every item of the chosen layer (or every
 *  layer for 'all'), plus the optionally-selected item. Pure filter + collect — the points are the
 *  items' own canonical world coordinates, untouched. */
export function focusPointsForDomain(
  itemsByLayer: ReadonlyMap<LayerId, readonly LayerItem[]>,
  domain: FocusDomain,
  opts?: FocusOptions,
): WorldPoint[] {
  const sel = opts?.selected ?? null
  const pts: WorldPoint[] = []
  for (const [layer, items] of itemsByLayer) {
    for (const it of items) {
      const inDomain = domain === 'all' || layer === domain
      const isSelected = sel !== null && sel.layer === layer && sel.id === it.id
      if (inDomain || isSelected) pts.push(...representationWorldPoints(it.representation))
    }
  }
  return pts
}

/** The content-fit Camera for one domain — galaxyCamera.fitCameraToWorldPoints over the domain's
 *  points (the SAME fit the auto-fit-once and Reset use for 'all'). Camera-only: returns {k, tx, ty}
 *  presentation state; an empty domain yields the identity camera (the fit's own empty-input rule). */
export function cameraForDomain(
  itemsByLayer: ReadonlyMap<LayerId, readonly LayerItem[]>,
  domain: FocusDomain,
  opts?: FocusOptions,
): Camera {
  return fitCameraToWorldPoints(focusPointsForDomain(itemsByLayer, domain, opts))
}
