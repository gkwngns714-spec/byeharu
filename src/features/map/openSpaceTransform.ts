// OSN-3 S6B1 — fixed-domain open-space coordinate transform (PURE logic only).
//
// No DOM, no React, no SVG element, no events, no fetch, no state. This module is dark/read-only
// scaffolding for the OSN open-space map surface: it is wired to NOTHING here. S6B2+ will consume
// `worldToViewBox` for rendering the ship's open-space states; `screenToWorld` / `mapToWorld`-style
// inverses are provided and unit-tested for S6C's FUTURE tap, but must NOT be wired to an input event
// in S6B.
//
// ── Coordinate spaces (explicit, named) ─────────────────────────────────────────────────────────────
//   WORLD   — the server's FIXED open-space domain. x,y ∈ [-10000, 10000]. +y points "north/up".
//   VIEWBOX — SVG user space of GalaxyMap's `<svg viewBox="0 0 1000 1000">`. x,y ∈ [0, 1000], y grows
//             DOWN (SVG convention). This is the PRE-camera space — the coordinates a marker is given
//             INSIDE the camera `<g>`. The fixed world↔viewBox map carries the Y inversion.
//   SCREEN  — CSS pixels relative to the SVG element's top-left, y grows DOWN. Depends on the camera
//             (pan/zoom) AND the element's pixel size via `preserveAspectRatio="xMidYMid meet"`.
//
// Pipeline (world → pixel): worldToViewBox (fixed, Y-invert) → camera (scale THEN translate, exactly
// GalaxyMap's `<g transform="translate(tx ty) scale(k)">`, i.e. cameraPoint = tx + k·viewBoxX) →
// preserveAspectRatio letterbox (viewBox units → pixels). Each inverse reverses each step.
//
// No `[0,1]` normalized intermediate is used or exposed — the world↔viewBox map is a single linear
// step, so an extra normalized layer would add surface area without purpose.
//
// ── SAFEGUARD: NO HIDDEN CLAMPING ───────────────────────────────────────────────────────────────────
// Every conversion below is a pure linear map. It NEVER clamps world / viewBox / screen / pan / zoom and
// NEVER validates domain bounds. Out-of-domain inputs convert to out-of-range outputs (e.g. world
// x=20000 → viewBox x=1500), they are NOT snapped to an edge. Non-finite inputs (NaN / ±Infinity)
// propagate arithmetically to non-finite outputs; no conversion throws on an ordinary numeric input.
// Bounds validation is a SEPARATE concern — use `isWithinOpenSpaceBounds()`. A command / target-
// validation path MUST use that predicate and MUST NOT infer validity from a conversion result.
// (`screenToViewBox` divides by the camera zoom `k`; GalaxyMap's `k` is always in [0.4, 8] and never 0.
// This module does not clamp `k`; a `k` of 0 yields non-finite output — the documented "garbage in,
// non-finite out" behavior, not a throw and not a silent clamp.)

// ── Fixed domain constants (shared with GalaxyMap's VIEW = 1000) ─────────────────────────────────────
export const WORLD_MIN = -10000
export const WORLD_MAX = 10000
export const WORLD_SPAN = WORLD_MAX - WORLD_MIN // 20000
export const VIEWBOX_SIZE = 1000 // == GalaxyMap VIEW and the SVG viewBox width/height
const WORLD_TO_VIEWBOX_SCALE = VIEWBOX_SIZE / WORLD_SPAN // 0.05 viewBox-units per world-unit

// ── Coordinate types (one per space; never interchangeable by accident) ──────────────────────────────
export interface WorldCoord {
  x: number
  y: number
}
export interface ViewBoxCoord {
  x: number
  y: number
}
export interface ScreenCoord {
  x: number
  y: number
}
/** The GalaxyMap camera: `<g transform="translate(tx ty) scale(k)">`. Pan in viewBox units, zoom `k`. */
export interface Camera {
  k: number
  tx: number
  ty: number
}
/** The SVG element's rendered CSS pixel size. The effective (letterboxed) display square is DERIVED
 *  from this via `viewBoxDisplayRect` — width and height are NOT assumed equal. */
export interface Viewport {
  width: number
  height: number
}

// ── Fixed pure pair: WORLD ↔ VIEWBOX (the authoritative open-space layer; no camera, no viewport) ────

/** WORLD → VIEWBOX. Linear, fixed-domain, with explicit Y inversion (larger world-y → smaller
 *  viewBox-y → higher on screen). Pure: no clamping, no bounds check. */
export function worldToViewBox(w: WorldCoord): ViewBoxCoord {
  return {
    x: (w.x - WORLD_MIN) * WORLD_TO_VIEWBOX_SCALE,
    y: VIEWBOX_SIZE - (w.y - WORLD_MIN) * WORLD_TO_VIEWBOX_SCALE, // Y inversion
  }
}

/** VIEWBOX → WORLD. Exact inverse of `worldToViewBox`. Pure: no clamping, no bounds check. */
export function viewBoxToWorld(v: ViewBoxCoord): WorldCoord {
  return {
    x: v.x / WORLD_TO_VIEWBOX_SCALE + WORLD_MIN,
    y: (VIEWBOX_SIZE - v.y) / WORLD_TO_VIEWBOX_SCALE + WORLD_MIN, // undo Y inversion
  }
}

// ── preserveAspectRatio="xMidYMid meet" geometry (explicit; does NOT assume width === height) ────────

export interface ViewBoxDisplayRect {
  /** uniform px-per-viewBox-unit scale */
  scale: number
  /** left letterbox offset in CSS px */
  offsetX: number
  /** top letterbox offset in CSS px */
  offsetY: number
  /** side length of the displayed viewBox square in CSS px */
  size: number
}

/** Models how `<svg viewBox="0 0 1000 1000" preserveAspectRatio="xMidYMid meet">` places its square
 *  viewBox inside an arbitrary-aspect element: scale-to-FIT (meet) the smaller axis, centre (xMid/yMid)
 *  the square, and letterbox the remaining axis. Pure geometry — no clamping. */
export function viewBoxDisplayRect(vp: Viewport): ViewBoxDisplayRect {
  const scale = Math.min(vp.width, vp.height) / VIEWBOX_SIZE
  const size = VIEWBOX_SIZE * scale
  return { scale, offsetX: (vp.width - size) / 2, offsetY: (vp.height - size) / 2, size }
}

// ── Camera + viewport pair: VIEWBOX ↔ SCREEN (composes the camera and the letterbox) ─────────────────

/** VIEWBOX → SCREEN. (1) camera: scale THEN translate — cameraPoint = (tx + k·x, ty + k·y), exactly
 *  GalaxyMap's `<g transform>`. (2) letterbox: viewBox units → CSS px. Pure: no clamping. */
export function viewBoxToScreen(v: ViewBoxCoord, cam: Camera, vp: Viewport): ScreenCoord {
  const cx = cam.tx + cam.k * v.x
  const cy = cam.ty + cam.k * v.y
  const r = viewBoxDisplayRect(vp)
  return { x: r.offsetX + r.scale * cx, y: r.offsetY + r.scale * cy }
}

/** SCREEN → VIEWBOX. Exact inverse of `viewBoxToScreen` (undo letterbox, then undo camera). Divides by
 *  `cam.k` (see header — `k` is never 0 in GalaxyMap; not clamped here). Pure: no clamping. */
export function screenToViewBox(s: ScreenCoord, cam: Camera, vp: Viewport): ViewBoxCoord {
  const r = viewBoxDisplayRect(vp)
  const cx = (s.x - r.offsetX) / r.scale
  const cy = (s.y - r.offsetY) / r.scale
  return { x: (cx - cam.tx) / cam.k, y: (cy - cam.ty) / cam.k }
}

// ── Full compositions: WORLD ↔ SCREEN (S6C will use screenToWorld for taps; UNWIRED in S6B) ──────────

/** WORLD → SCREEN. `viewBoxToScreen(worldToViewBox(w))`. Pure: no clamping. */
export function worldToScreen(w: WorldCoord, cam: Camera, vp: Viewport): ScreenCoord {
  return viewBoxToScreen(worldToViewBox(w), cam, vp)
}

/** SCREEN → WORLD. `viewBoxToWorld(screenToViewBox(s))`. Pure: no clamping, no bounds check — a tapped
 *  pixel outside the world domain returns out-of-domain world coords; callers validate separately with
 *  `isWithinOpenSpaceBounds()`. UNWIRED in S6B (S6C owns tap selection). */
export function screenToWorld(s: ScreenCoord, cam: Camera, vp: Viewport): WorldCoord {
  return viewBoxToWorld(screenToViewBox(s, cam, vp))
}

// ── Bounds validation — SEPARATE from conversion (rendering must never be mistaken for validation) ───

/** True iff `w` is finite AND inside the fixed open-space domain [-10000, 10000] on both axes. This is
 *  the ONLY domain check; the conversions above never validate. A future command/target path must gate
 *  on this predicate, not on a conversion result. */
export function isWithinOpenSpaceBounds(w: WorldCoord): boolean {
  return (
    Number.isFinite(w.x) &&
    Number.isFinite(w.y) &&
    w.x >= WORLD_MIN &&
    w.x <= WORLD_MAX &&
    w.y >= WORLD_MIN &&
    w.y <= WORLD_MAX
  )
}
