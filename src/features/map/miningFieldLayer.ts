// MINING-FIELD-MARKERS — the mining-field range-ring layer: one WORLD-TRUE ring per active field,
// sized to `mining_extract_radius` (game_config; the distance a settled fleet must be within to
// extract — 0102/0104). Follows the territoryLayer/teamMarkersLayer element-helper convention:
// pure, hook-free, returns element descriptors, so GalaxyMap and the unit test call the SAME
// function. Mounted BEFORE the interactive field markers (a range is scenery, drawn under its own
// glyph) and pointer-transparent (a range ring is never a tap target — the glyph is).
//
// WORLD-TRUE, deliberately NOT screen-constant — same reasoning as territoryLayer: the extraction
// range is a real distance in world units, so its SVG radius is
// `radius * WORLD_TO_VIEWBOX_SCALE` viewBox units and grows/shrinks with the camera zoom (the
// OPPOSITE of the `/k` marker-glyph idiom, which pins GLYPHS to a screen size). Only the stroke
// width/dash divide by k: line weight is presentation, not geometry.
import { createElement, type ReactElement } from 'react'
import type { MiningField } from '../mining/miningTypes'
import { WORLD_TO_VIEWBOX_SCALE } from './openSpaceTransform'

export function miningFieldRangeLayer(args: {
  fields: readonly MiningField[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
  /** world-unit extraction radius (mining_extract_radius, read once from game_config by the
   *  caller). Non-finite / non-positive → no rings (never a guessed radius). */
  radius: number
}): ReactElement[] {
  if (!Number.isFinite(args.radius) || args.radius <= 0) return []
  const out: ReactElement[] = []
  for (const f of args.fields) {
    const p = args.norm({ x: f.space_x, y: f.space_y })
    const ringR = args.radius * WORLD_TO_VIEWBOX_SCALE // world-true: viewBox units, NOT /k
    out.push(
      createElement(
        'g',
        { key: `mining-range-${f.name}`, 'data-testid': `mining-field-range-${f.name}`, style: { pointerEvents: 'none' as const } },
        // faint filled disc — the reachable area reads at a glance, even at low zoom
        createElement('circle', { cx: p.x, cy: p.y, r: ringR, fill: 'var(--color-warning)', opacity: 0.05 }),
        // dashed boundary — screen-constant line weight over the world-true geometry
        createElement('circle', {
          cx: p.x,
          cy: p.y,
          r: ringR,
          fill: 'none',
          stroke: 'var(--color-warning)',
          strokeOpacity: 0.3,
          strokeWidth: 1 / args.k,
          strokeDasharray: `${3 / args.k} ${3 / args.k}`,
        }),
      ),
    )
  }
  return out
}
