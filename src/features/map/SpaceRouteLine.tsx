import { useEffect, useState } from 'react'
import { worldToViewBox } from './openSpaceTransform'
import { resolveActiveSpaceRoute, type ActiveSpaceRoute } from './spaceRouteModel'
import type { MarkerInputs } from './resolveMainShipMarker'
import { formatCountdown } from '../../lib/time'

// OSN-3 S6B-ROUTE — read-only display of an ACTIVE coordinate route: a committed origin→target line, a
// committed destination marker, and a display-only ETA. Both endpoints are projected ONLY through the
// fixed S6B1 transform (`worldToViewBox`) — never the dynamic named-location normalizer — so the route
// belongs to the same `open_space_fixed` domain as the ship marker and co-registers with it exactly.
//
// Pointer-inert (no click/tap/hover/command), no fetch, no write, no command-UI import. It owns NO route
// state interpretation: coherence is decided solely by `resolveActiveSpaceRoute` (which defers to the
// shared marker resolver). The presentation below renders strictly from that validated model.

// ── Pure presentation (hook-free → directly unit-testable, like the S6C marker) ───────────────────────
export function SpaceRoutePresentation({ route, k }: { route: ActiveSpaceRoute; k: number }) {
  const a = worldToViewBox(route.origin) // committed origin (fixed open-space domain)
  const b = worldToViewBox(route.target) // committed target (fixed open-space domain)
  const color = route.state === 'returning' ? '#38bdf8' : '#fbbf24'
  // Display-only ETA from the persisted arrival timestamp. `formatCountdown` returns null when the target
  // is missing/invalid/already elapsed → we show a NEUTRAL "arriving…" rather than ever claiming arrival
  // (the server's arrival processor, not this view, settles the movement).
  const eta = formatCountdown(route.arriveAt)
  const arrow = route.state === 'returning' ? '↩ ' : '→ '
  const label = `${arrow}${eta ?? 'arriving…'}`
  const mx = (a.x + b.x) / 2
  const my = (a.y + b.y) / 2
  const ring = 7 / k
  const dot = 2.5 / k

  return (
    <g data-testid="space-route" style={{ pointerEvents: 'none' }} aria-hidden="true">
      {/* committed route path: origin → target, dashed, route-colored */}
      <line
        x1={a.x}
        y1={a.y}
        x2={b.x}
        y2={b.y}
        stroke={color}
        strokeWidth={1.5}
        strokeDasharray="6 4"
        vectorEffect="non-scaling-stroke"
        opacity={0.8}
      />
      {/* committed destination marker — SOLID ring + filled centre dot. Deliberately distinct from the
          S6C prospective-target crosshair (dashed, hollow): this is an existing route's destination, not a
          player-selected target, and it exposes NO selection control. */}
      <g data-testid="space-route-destination">
        <circle cx={b.x} cy={b.y} r={ring} fill="none" stroke={color} strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
        <circle cx={b.x} cy={b.y} r={dot} fill={color} stroke="#0b1220" strokeWidth={0.5} vectorEffect="non-scaling-stroke" />
      </g>
      {/* display-only status/ETA at the route midpoint */}
      <text x={mx} y={my - 4 / k} fontSize={10 / k} textAnchor="middle" fill={color} style={{ userSelect: 'none' }}>
        {label}
      </text>
    </g>
  )
}

// ── Thin wrapper: resolve the validated model (with a 1s ETA tick while a route exists) and render it ──
// Mirrors MainShipMarker's pattern: Date.now() stays out of render; the interval runs ONLY while a route
// is active and clears otherwise. The wrapper performs NO coherence logic itself — it delegates to
// `resolveActiveSpaceRoute` and renders nothing when that returns null.
export function SpaceRouteLine({ inputs, k }: { inputs: MarkerInputs; k: number }) {
  const [now, setNow] = useState(() => Date.now())
  const route = resolveActiveSpaceRoute(inputs, now)
  const active = !!route

  useEffect(() => {
    if (!active) return
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [active])

  if (!route) return null
  return <SpaceRoutePresentation route={route} k={k} />
}
