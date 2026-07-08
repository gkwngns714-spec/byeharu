import { worldToViewBox, type WorldCoord } from './openSpaceTransform'

// S6B-PRES — pure camera math for GalaxyMap's UNIFIED fixed-coordinate frame.
//
// SPATIAL TRUTH lives entirely in the fixed `worldToViewBox` / `viewBoxToWorld` domain
// (openSpaceTransform). This module derives ONLY presentation camera state `{k, tx, ty}` (zoom +
// pan). It NEVER produces or mutates a world/marker/line/target coordinate, and it is applied by
// GalaxyMap for the INITIAL view and explicit RESET only — once the player pans/zooms the camera is
// frozen (no continuous auto-fit/recenter). Framework-free + pure, so it is unit-tested directly.

export const VIEW = 1000
export const PAD = 0.08

// Camera ZOOM limits (a camera/UI concern — NOT the world coordinate bound; WORLD_MIN/MAX are
// unchanged in openSpaceTransform). MIN is unchanged. MAX is raised from the old hard `8` so the
// player can actually inspect tightly clustered current seed coordinates (which occupy <0.2% of the
// ±10000 world span). It is BOUNDED — never infinite.
export const MIN_K = 0.4
export const MAX_K = 1024

export interface Camera {
  k: number
  tx: number
  ty: number
}

/** Bounded zoom clamp. Non-finite → MIN_K (never NaN/∞ into the camera). */
export const clampK = (k: number): number =>
  Number.isFinite(k) ? Math.min(MAX_K, Math.max(MIN_K, k)) : MIN_K

/** Keep the (whole) 0..VIEW viewBox overlapping the viewport so the map can never be dragged/zoomed
 *  fully off-screen. Pan only; identical to the prior camera-pan invariant. */
export function clampPan(tx: number, ty: number, k: number): { tx: number; ty: number } {
  const content = k * VIEW
  const [minT, maxT] = content >= VIEW ? [VIEW - content, 0] : [0, VIEW - content]
  const cl = (t: number) => Math.min(maxT, Math.max(minT, t))
  return { tx: cl(tx), ty: cl(ty) }
}

/** Fit WORLD points into the camera so their FIXED-domain bounding box fills ~(1 − 2·PAD) of the
 *  view, centered. Presentation only: returns `{k, tx, ty}`; never returns/mutates world coordinates.
 *  Empty input → identity camera. Degenerate bbox (single point / zero span) → MAX_K, centered.
 *  Non-finite points are ignored. tx/ty are NOT pan-clamped here (initial/reset frames content
 *  exactly; GalaxyMap clamps only live drag/zoom). */
export function fitCameraToWorldPoints(points: readonly WorldCoord[]): Camera {
  const vs = points
    .filter((p) => Number.isFinite(p.x) && Number.isFinite(p.y))
    .map((p) => worldToViewBox(p))
  if (vs.length === 0) return { k: 1, tx: 0, ty: 0 }
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
  for (const v of vs) {
    if (v.x < minX) minX = v.x
    if (v.x > maxX) maxX = v.x
    if (v.y < minY) minY = v.y
    if (v.y > maxY) maxY = v.y
  }
  const span = Math.max(maxX - minX, maxY - minY)
  const inner = VIEW * (1 - 2 * PAD)
  const k = clampK(span > 0 ? inner / span : MAX_K)
  const cx = (minX + maxX) / 2
  const cy = (minY + maxY) / 2
  // Camera <g transform="translate(tx ty) scale(k)"> maps a viewBox point P → k·P + t. Center the
  // content bbox center at the viewBox center.
  return { k, tx: VIEW / 2 - k * cx, ty: VIEW / 2 - k * cy }
}

// ── Deterministic focus policy (rule: documented in code + tested) ───────────────────────────────────
//   • If the player's main ship is IN OPEN SPACE / IN TRANSIT, focus on the ship and its active
//     movement segment (origin→target) so the player is always visible — named content is NOT mixed in.
//   • Otherwise, focus on the active named locations.
export interface FocusInputs {
  /** the ship's current open-space / in-transit WORLD point, or null when not in open space */
  shipWorld: WorldCoord | null
  /** the active coordinate-move origin/target (WORLD), or null when not in transit */
  movementSegment: readonly [WorldCoord, WorldCoord] | null
  locations: readonly WorldCoord[]
}

/** The WORLD points the initial/reset camera should frame, per the deterministic focus policy. */
export function focusWorldPoints(f: FocusInputs): WorldCoord[] {
  if (f.shipWorld || f.movementSegment) {
    const pts: WorldCoord[] = []
    if (f.movementSegment) pts.push(f.movementSegment[0], f.movementSegment[1])
    if (f.shipWorld) pts.push(f.shipWorld)
    return pts
  }
  return [...f.locations]
}

/** The content-fit camera for the current focus (player-priority when in open space). */
export function focusCamera(f: FocusInputs): Camera {
  return fitCameraToWorldPoints(focusWorldPoints(f))
}
