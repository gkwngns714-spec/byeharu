import { worldToViewBox, type ViewBoxCoord, type WorldCoord } from './openSpaceTransform'

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

// A single focus point (e.g. a ship parked in open space right after Stop) has ZERO bounding-box span.
// Rather than slam to MAX_K (a jarring max zoom-in), frame a fixed neighbourhood around it: this synthetic
// viewBox span yields a gentle, deterministic zoom (~10× → roughly a 2000-world-unit window), so Stop /
// an already-held ship on load / Reset all recenter smoothly instead of zooming to maximum.
export const DEGENERATE_SPAN = 84

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

// ── Zoom steps (the ONE place either surface reads a zoom magnitude) ─────────────────────────────────
/** Per-notch WHEEL step. Kept gentle on purpose: a wheel gesture is many notches, so a step that feels
 *  right for ONE click of the +/− buttons overshoots badly here. 1.07 needs ~10 notches to double,
 *  which is roughly one comfortable scroll. Shared by the game map and the World Editor — the game map
 *  used to run 1.15, the value the editor had already tried and rejected as an overshoot. */
export const WHEEL_ZOOM_STEP = 1.07
/** Per-click step for the +/− BUTTONS. One deliberate click should be a decisive change, so it is much
 *  coarser than a wheel notch. Buttons stay CENTRE-anchored (there is no cursor to anchor on). */
export const BUTTON_ZOOM_STEP = 1.25

/** Zoom about an ANCHOR in VIEWBOX space — the cursor for a wheel gesture, the viewport centre for the
 *  +/− buttons (pass no anchor). The point under the anchor keeps its position on screen, which is what
 *  makes wheel-zoom feel like it pulls the map toward the pointer instead of drifting away from it.
 *
 *  Composes both camera invariants: `clampK` bounds the zoom, and `clampPan` still wins at the world
 *  edges — the anchor is honoured only up to the point where holding it would drag the viewBox off the
 *  viewport. A null/omitted anchor is exactly the centre (VIEW/2, VIEW/2).
 *
 *  The anchor is a PRE-camera viewBox point: get it from `openSpaceTransform.screenToViewBoxRaw`, which
 *  undoes the letterbox WITHOUT undoing the camera (the anchor lives in the same space as tx/ty). */
export function zoomCameraAbout(cam: Camera, factor: number, anchor?: ViewBoxCoord | null): Camera {
  const k = clampK(cam.k * factor)
  const ratio = k / cam.k
  const ax = anchor?.x ?? VIEW / 2
  const ay = anchor?.y ?? VIEW / 2
  return { k, ...clampPan(ax - (ax - cam.tx) * ratio, ay - (ay - cam.ty) * ratio, k) }
}

/** Fit WORLD points into the camera so their FIXED-domain bounding box fills ~(1 − 2·PAD) of the
 *  view, centered. Presentation only: returns `{k, tx, ty}`; never returns/mutates world coordinates.
 *  Empty input → identity camera. Degenerate bbox (single point / zero span) → a fixed comfortable
 *  neighbourhood zoom (DEGENERATE_SPAN), centered — never MAX_K.
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
  const k = clampK(inner / (span > 0 ? span : DEGENERATE_SPAN))
  const cx = (minX + maxX) / 2
  const cy = (minY + maxY) / 2
  // Camera <g transform="translate(tx ty) scale(k)"> maps a viewBox point P → k·P + t. Center the
  // content bbox center at the viewBox center.
  return { k, tx: VIEW / 2 - k * cx, ty: VIEW / 2 - k * cy }
}

/** Are ALL of these WORLD points inside the frame the player is actually looking at, under `cam`?
 *
 *  The exact INVERSE of `fitCameraToWorldPoints`, asked of the same projection: the map draws a world
 *  point at `k·worldToViewBox(p) + t` (its `<g transform="translate(t) scale(k)">`), so that is what
 *  is tested here. Nothing re-derives a bounding box — the caller passes the points whose box it
 *  already owns, and gets back a yes/no about the camera.
 *
 *  The region tested is the 0..VIEW viewBox. Under `preserveAspectRatio="xMidYMid meet"` the WHOLE
 *  viewBox is always on screen and the long axis shows a little MORE than it, so this is the
 *  conservative answer: everything it calls framed really is visible, and the only way it can err is
 *  by calling something off-frame that was still inside the letterbox margin.
 *
 *  Non-finite points are ignored — the same rule the fit uses, so the two agree about which points
 *  exist. NO points is vacuously framed: there is nothing to keep on screen. */
export function worldPointsFramed(points: readonly WorldCoord[], cam: Camera): boolean {
  for (const p of points) {
    if (!Number.isFinite(p.x) || !Number.isFinite(p.y)) continue
    const v = worldToViewBox(p)
    const x = cam.tx + cam.k * v.x
    const y = cam.ty + cam.k * v.y
    if (x < 0 || x > VIEW || y < 0 || y > VIEW) return false
  }
  return true
}

/** VALUE equality for a camera. Exists because the camera is compared two different ways and they
 *  mean different things: IDENTITY answers "is this still the camera we set?" (any pan/zoom builds a
 *  new object), while this answers "would applying that camera change anything?" — the guard that
 *  keeps a re-frame from re-setting a camera that is already exactly right. */
export const sameCamera = (a: Camera, b: Camera): boolean =>
  a.k === b.k && a.tx === b.tx && a.ty === b.ty

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
