// WORLD EDITOR — C1: the CANONICAL COORDINATE + DISPLAY-ADAPTER CONTRACT. Types + presentation
// formatting ONLY — deliberately minimal logic. This module must NEVER become a second transform
// authority (guarded by tests/worldEditorC1Guards.spec.ts).
//
// THE FOUR COORDINATE CONCEPTS (one authority each):
//   1. STORED WORLD COORDINATE (StoredWorldCoord below) — the authoritative gameplay x/y a live row
//      carries (locations.x/y, mining_fields.space_x/space_y, exploration_sites.space_x/space_y,
//      danger_zones ring vertices). READ-ONLY to the editor: display concerns NEVER change a stored
//      gameplay coordinate. There is NO client-side rescale, no remap, no coordinate migration —
//      how the world READS in the editor is controlled entirely by concepts 2–4.
//   2. MAP PROJECTION (world ↔ viewBox) — owned by openSpaceTransform (worldToViewBox /
//      viewBoxToWorld / WORLD_TO_VIEWBOX_SCALE), re-exported below as a REFERENCE, never
//      reimplemented. The ONE fixed linear projection both the player map and the editor render
//      through; positions go through worldToViewBox, world-unit LENGTHS through
//      WORLD_TO_VIEWBOX_SCALE.
//   3. EDITOR CAMERA / VIEW — owned by galaxyCamera (Camera {k, tx, ty}, fitCameraToWorldPoints,
//      clampK / clampPan). Pure presentation state: deriving or moving a camera NEVER produces or
//      mutates a world coordinate. Domain-scoped framing (worldEditorFocus.cameraForDomain) is
//      CAMERA-ONLY — it changes what the editor LOOKS AT, never what the world IS.
//   4. PRESENTATION FORMATTING — formatWorldCoord below: the ONE formatter every editor surface
//      (the inspector's World X / World Y fields etc.) renders a stored world coordinate with.
//
// CONVERSION OWNERSHIP (stated once, here): openSpaceTransform owns world↔viewBox; galaxyCamera
// owns viewBox↔camera/screen framing; THIS module owns only the types, the presentation formatter,
// and the domain-focus contract type (FocusDomain). NO new world↔viewBox math may be added here.
import type { WorldCoord } from '../map/openSpaceTransform'
import type { LayerId } from './worldEditorTypes'

/** (1) The authoritative STORED gameplay coordinate — the server's fixed open-space domain
 *  (x, y ∈ [-10000, 10000]). Read-only in the editor: nothing in the display/camera/focus path may
 *  assign to it. Structurally identical to WorldCoord — the readonly view IS the contract. */
export type StoredWorldCoord = Readonly<WorldCoord>

/** (2) The ONE map-projection authority, re-exported as a reference (NOT reimplemented): the fixed
 *  linear world↔viewBox map and the one world-length→viewBox scale. */
export {
  worldToViewBox,
  viewBoxToWorld,
  WORLD_TO_VIEWBOX_SCALE,
} from '../map/openSpaceTransform'

/** (3) The editor camera/view type — galaxyCamera's Camera, referenced (never redefined). */
export type { Camera } from '../map/galaxyCamera'

/** The domain-focus contract: what a camera-only focus action frames — ONE content layer, or 'all'
 *  (today's content-fit-everything default). Consumed by worldEditorFocus; framing a domain is a
 *  camera derivation and nothing else. */
export type FocusDomain = LayerId | 'all'

/** (4) The ONE coordinate presentation formatter (moved here from worldEditorAdapters' local
 *  fmtCoord — single authority). One decimal place; non-finite renders as an em dash, never NaN. */
export const formatWorldCoord = (n: number): string => (Number.isFinite(n) ? n.toFixed(1) : '—')
