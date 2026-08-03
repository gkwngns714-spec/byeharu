import { useEffect } from 'react'
import { WHEEL_ZOOM_STEP } from './galaxyCamera'
import { screenToViewBoxRaw, type ViewBoxCoord } from './openSpaceTransform'

// The ONE wheel-zoom binding for every SVG map surface (the game map and the World Editor). It owns
// four things that were previously copied into each surface: the non-passive listener, the
// preventDefault, the per-notch step, and the cursor→anchor projection.
//
// WHY A NATIVE, NON-PASSIVE LISTENER: React routes `onWheel` through a PASSIVE root listener, where
// preventDefault is ignored — so the browser would scroll the page (or ctrl+wheel page-zoom) instead of
// the map zooming. That is the only reason this is a manual addEventListener rather than a JSX prop.
//
// WHY IT TAKES THE ELEMENT AND NOT A REF: an effect keyed on `ref.current` does not re-run when the ref
// is finally populated. A surface that renders its SVG behind a gate (a flag, an ownership check, a data
// fetch) therefore ran this effect ONCE while the ref was still null, bailed, and never re-attached —
// every wheel gesture then fell silently through to the browser. The World Editor hit exactly that and
// carried a nine-line comment about it. Taking the ELEMENT makes it a reactive value, so attachment
// happens precisely when the SVG exists and the trap cannot be re-entered by either caller.
//
// Pass a STABLE `zoom` (a `useCallback` with no changing deps) so the listener is not re-bound per render.

/**
 * Bind non-passive wheel-zoom to `el`, anchored on the CURSOR.
 *
 * @param el   the mounted SVG element, or null before it mounts (hold it in STATE, not a ref)
 * @param zoom applies one notch: `factor` is `WHEEL_ZOOM_STEP` (in) or its reciprocal (out), and
 *             `anchor` is the cursor in PRE-camera viewBox space — null only when the element has no
 *             box yet, in which case the caller must fall back to its centre-anchored behaviour.
 */
export function useWheelZoom(
  el: SVGSVGElement | null,
  zoom: (factor: number, anchor: ViewBoxCoord | null) => void,
): void {
  useEffect(() => {
    if (!el) return
    const onWheel = (e: WheelEvent) => {
      e.preventDefault() // also swallows ctrl+wheel, so the page never zooms over the map
      const rect = el.getBoundingClientRect()
      // Anchor on the CURSOR: the point under the pointer stays put, so the map zooms toward what the
      // player is looking at rather than toward the viewport centre.
      const anchor =
        rect.width > 0 && rect.height > 0
          ? screenToViewBoxRaw(
              { x: e.clientX - rect.left, y: e.clientY - rect.top },
              { width: rect.width, height: rect.height },
            )
          : null
      zoom(e.deltaY < 0 ? WHEEL_ZOOM_STEP : 1 / WHEEL_ZOOM_STEP, anchor)
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => el.removeEventListener('wheel', onWheel)
  }, [el, zoom])
}
