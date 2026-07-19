// PIRATE INTERCEPT (prototype) — the danger-zone polygon layer: one smooth "slime" blob per active
// danger_zones row (get_danger_zones). Follows the territoryLayer/teamMarkersLayer element-helper
// convention: pure, hook-free, returns element descriptors, so GalaxyMap and any future unit test can
// call the SAME function. Rendered ABOVE the plain circle territoryLayer (which stays untouched and
// keeps drawing today's rings for every location) and UNDER movement lines/markers — a danger zone is
// still scenery, never a tap target (pointerEvents:'none' throughout).
//
// WORLD-TRUE: every ring vertex goes through the SAME `norm` (worldToViewBox) the rest of the map
// uses — a drawn/circle zone scales with the camera exactly like every other spatial element.
import { createElement, type ReactElement } from 'react'
import type { DangerZoneLite } from './pirateApi'
import { smoothClosedPathD } from './smoothPolygon'

export function dangerZoneLayer(args: {
  zones: readonly DangerZoneLite[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
}): ReactElement[] {
  const out: ReactElement[] = []
  for (const z of args.zones) {
    if (!z.ring || z.ring.length < 3) continue
    const screenRing = z.ring.map(([x, y]) => args.norm({ x, y }))
    const d = smoothClosedPathD(screenRing)
    if (!d) continue
    const tone = z.source === 'circle' ? 'var(--color-danger)' : 'var(--color-warning, var(--color-danger))'
    out.push(
      createElement(
        'g',
        { key: `danger-zone-${z.id}`, 'data-testid': `danger-zone-${z.id}`, style: { pointerEvents: 'none' as const } },
        createElement('path', { d, fill: tone, opacity: 0.1 }),
        createElement('path', {
          d,
          fill: 'none',
          stroke: tone,
          strokeOpacity: 0.55,
          strokeWidth: 1.5 / args.k,
          strokeDasharray: z.source === 'drawn' ? `${5 / args.k} ${3 / args.k}` : undefined,
        }),
      ),
    )
  }
  return out
}
