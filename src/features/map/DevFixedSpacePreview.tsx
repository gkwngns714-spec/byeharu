import { worldToViewBox } from './openSpaceTransform'

// OSN-3 S6B3 — DEVELOPMENT-ONLY, non-interactive fixed-space preview marker. NOT a gameplay feature and
// NOT an S6C destination model: it renders ONE constant fixed-world coordinate through the S6B1 fixed
// transform, purely to prove the fixed coordinate layer renders and co-moves with the camera. It is
// rendered ONLY behind `import.meta.env.DEV` in GalaxyMap, so Vite replaces that with the literal `false`
// in `vite build` and Rollup strips this module (and its `s6b3-dev-preview` sentinel + fixture) from the
// production bundle. No data / fetch / state / input / persistence / RPC. It uses `worldToViewBox` and is
// rendered inside the existing camera <g>, so it shares the map's fixed coordinate layer + pan/zoom.

// A point in OPEN SPACE, deliberately away from the home base (world 0,0) and the named-location cluster
// — it is NOT a landmark and is NOT spatially co-registered with named locations. Constant only; never an
// exported gameplay target and never a precursor to S6C selected-target state.
const DEV_PREVIEW_WORLD = { x: 8000, y: -8000 } // worldToViewBox === { x: 900, y: 900 }

export function DevFixedSpacePreview({ k }: { k: number }) {
  const p = worldToViewBox(DEV_PREVIEW_WORLD)
  const r = 7 / k // constant on-screen size (same counter-scale convention as the other markers)
  // Minimal hollow ring + crosshair, neutral/dev grey — structurally distinct from the filled ship
  // chevron and the filled location dots. No label/text/coordinate copy. Pointer-transparent + aria-hidden.
  return (
    <g data-testid="s6b3-dev-preview" aria-hidden="true" opacity={0.7} style={{ pointerEvents: 'none' }}>
      <circle cx={p.x} cy={p.y} r={r} fill="none" stroke="#94a3b8" strokeWidth={1} vectorEffect="non-scaling-stroke" />
      <line x1={p.x - r} y1={p.y} x2={p.x + r} y2={p.y} stroke="#94a3b8" strokeWidth={1} vectorEffect="non-scaling-stroke" />
      <line x1={p.x} y1={p.y - r} x2={p.x} y2={p.y + r} stroke="#94a3b8" strokeWidth={1} vectorEffect="non-scaling-stroke" />
    </g>
  )
}
