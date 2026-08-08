// ██ THE ONE THING THAT TURNS A ShipVisual INTO SVG. ██
//
// Hook-free and element-descriptor-only (the territoryLayer / miningFieldLayer / spatialCombatLayer
// convention), so the app and the specs call the SAME function. It decides NOTHING: the form, the
// size, the tone and the dimming all arrive on the descriptor from map/shipVisual.ts. This file only
// places them.
//
// WHY IT IS SEPARATE FROM shipVisual.ts: that file is the pure POLICY and imports no React, which is
// what lets it be driven as a table. This is its renderer, the LocationMarker.tsx side of the
// markerStyle split.
//
// HOW THE IMAGE SWAP STAYS FREE: both arms of `ShipForm` are handled HERE, once. When the owner adds
// spaceship art, `shipVisual`'s FORMS table starts returning `{kind:'image'}` and this function
// already draws it at the same place, the same size and the same opacity. No consumer of
// `renderShipVisual` changes, and there is no second draw path to keep in step.
import { createElement, type ReactElement } from 'react'
import type { ShipVisual } from './shipVisual'

/** WHERE and AT WHAT SCALE. `k` is the camera zoom, `pxScale` the CSS-px-per-viewBox-unit the map
 *  measures off its own element (openSpaceTransform.viewBoxDisplayRect). Together they turn the
 *  descriptor's CSS-pixel half-size into the number an SVG attribute takes — the SAME px() conversion
 *  spatialCombatLayer already uses for the combat readout, which is the correct sizing path. */
export interface ShipGlyphAt {
  x: number
  y: number
  k: number
  /** omitted / non-positive → 1, i.e. the historic ÷k sizing for a caller that does not measure */
  pxScale?: number
}

/** Half-size in the TARGET units (viewBox units on the map), from the descriptor's CSS px. */
export function shipGlyphHalf(v: ShipVisual, at: ShipGlyphAt): number {
  const scale = at.pxScale && Number.isFinite(at.pxScale) && at.pxScale > 0 ? at.pxScale : 1
  return v.sizePx / (at.k * scale)
}

/** The args that make a glyph exactly FILL a 24×24 host box — for an inline, non-map surface (a
 *  roster row's icon). Exported so the arithmetic exists once instead of being copied into a view. */
export function shipGlyphFillsBox(v: ShipVisual, box = 24): ShipGlyphAt {
  // half = sizePx / (k * pxScale); with k = 1 and pxScale = sizePx/(box/2), half = box/2.
  return { x: box / 2, y: box / 2, k: 1, pxScale: v.sizePx / (box / 2) }
}

/**
 * ONE ship, drawn. Returns a single element so a caller can put it inside its own group beside
 * whatever DECORATION that state adds (a danger ring, a hull pip, a label).
 *
 * Pointer-transparent, always: a ship glyph is a spectacle, not a tap surface — the location marker
 * or the map underneath it stays the tap target (the map-layer law every glyph here follows).
 */
export function renderShipVisual(v: ShipVisual, at: ShipGlyphAt, key?: string): ReactElement {
  const half = shipGlyphHalf(v, at)
  const common = {
    key,
    'data-ship-form': v.form.kind,
    'data-ship-known': v.known ? 'true' : 'false',
    style: { pointerEvents: 'none' as const },
  }
  if (v.form.kind === 'image') {
    return createElement('image', {
      ...common,
      href: v.form.href,
      x: at.x - half,
      y: at.y - half,
      width: half * 2,
      height: half * 2,
      opacity: v.fillOpacity,
      preserveAspectRatio: 'xMidYMid meet',
    })
  }
  // The subpaths are ONE `d`, so the whole silhouette is one filled shape with one knockout outline —
  // internal edges do not draw, and a counter-wound subpath (the frigate's porthole) stays a hole.
  // Scaled from the form's own square and re-centred on the point, so no form has to know the map.
  const s = (half * 2) / v.form.viewBox
  const c = v.form.viewBox / 2
  return createElement('path', {
    ...common,
    d: v.form.d.join(' '),
    transform: `translate(${at.x} ${at.y}) scale(${s}) translate(${-c} ${-c})`,
    fill: v.tone,
    fillOpacity: v.fillOpacity,
    stroke: 'var(--color-app)',
    strokeWidth: 1,
    vectorEffect: 'non-scaling-stroke' as const,
  })
}
