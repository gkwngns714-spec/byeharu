import type { MapLocation } from './mapTypes'
import { markerStyle } from './markerStyle'

// Read-only SVG marker for one location. Positions are in normalized 0..1000 space; radius/label are
// counter-scaled by the zoom factor `k` so they stay a constant on-screen size. Selecting only
// highlights — it never sends an expedition.
//
// UI R1: this is a THIN renderer — every size/glyph/halo/label decision comes from the pure
// markerStyle policy (./markerStyle.ts, unit-tested), tokens only:
//   • glyph shape by type: diamond = dockable port (+ hub ring), triangle = combat/hazard, circle = waypoint
//   • sized + haloed by importance (reward/danger bands), so the hierarchy reads at a glance
//   • selection = an accent scan reticle (ring + crosshair ticks) over a --color-map-halo wash
//   • labels wear a paint-order halo so they stay legible over the grid/starfield

export function LocationMarker({
  x,
  y,
  k,
  location,
  selected,
  showLabel,
  onSelect,
}: {
  x: number
  y: number
  k: number
  location: MapLocation
  selected: boolean
  showLabel: boolean
  onSelect: (id: string) => void
}) {
  const s = markerStyle(location)
  const r = s.radius / k
  const label = location.name.length > 18 ? `${location.name.slice(0, 17)}…` : location.name

  // Selection reticle geometry (ring radius + the four crosshair ticks reaching outward).
  const ringR = r * 2.2
  const tick = r * 0.8

  // Hit target is ONE invisible constant-radius disc (~19px, matching pre-R1 parity); every visible
  // element below is pointer-transparent so the glyph size/halo/reticle are presentation only and never
  // change what's clickable (no shrunk tap targets, no halo occluding a neighbor, no reticle eating
  // the deselect/empty-space tap). Selection stays a pure highlight.
  const hitR = 19 / k

  // Core glyph by shape (all wear the app-colored knockout stroke so they pop off the halo).
  const glyphStroke = { stroke: 'var(--color-app)', strokeWidth: 1.5, vectorEffect: 'non-scaling-stroke' as const, style: { pointerEvents: 'none' as const } }
  const glyph =
    s.shape === 'diamond' ? (
      <polygon points={`${x},${y - r} ${x + r},${y} ${x},${y + r} ${x - r},${y}`} fill={s.color} {...glyphStroke} />
    ) : s.shape === 'triangle' ? (
      <polygon points={`${x},${y - r} ${x + r * 0.9},${y + r * 0.75} ${x - r * 0.9},${y + r * 0.75}`} fill={s.color} {...glyphStroke} />
    ) : (
      <circle cx={x} cy={y} r={r} fill={s.color} {...glyphStroke} />
    )

  return (
    <g
      data-testid="galaxy-location-marker"
      data-location-id={location.id}
      data-activity={location.activity_type}
      data-location-type={location.location_type}
      className="group"
      onClick={(e) => {
        e.stopPropagation()
        onSelect(location.id)
      }}
      style={{ cursor: 'pointer' }}
    >
      {/* invisible constant-radius hit target — the ONLY pointer-interactive element (parity with pre-R1) */}
      <circle cx={x} cy={y} r={hitR} fill="transparent" />
      {/* soft identity halo — always on, sized/weighted by importance, so type/danger reads zoomed out */}
      <circle cx={x} cy={y} r={r * s.haloRadius} fill={s.color} opacity={s.haloOpacity} style={{ pointerEvents: 'none' }} />
      {/* hover halo (presentation only) */}
      <circle
        cx={x}
        cy={y}
        r={r * 2.6}
        fill="none"
        stroke="var(--color-map-halo)"
        strokeWidth={1.5}
        vectorEffect="non-scaling-stroke"
        className="opacity-0 transition-opacity group-hover:opacity-100"
        style={{ pointerEvents: 'none' }}
      />
      {/* selection reticle — accent scan ring + crosshair ticks over a map-halo wash (presentation only) */}
      {selected && (
        <g data-testid="galaxy-marker-reticle" opacity={0.95} style={{ pointerEvents: 'none' }}>
          <circle cx={x} cy={y} r={ringR} fill="var(--color-map-halo)" />
          <circle cx={x} cy={y} r={ringR} fill="none" stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
          <line x1={x} y1={y - ringR - tick} x2={x} y2={y - ringR} stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
          <line x1={x} y1={y + ringR} x2={x} y2={y + ringR + tick} stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
          <line x1={x - ringR - tick} y1={y} x2={x - ringR} y2={y} stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
          <line x1={x + ringR} y1={y} x2={x + ringR + tick} y2={y} stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
        </g>
      )}
      {/* dockable-port "hub" ring — ports read differently from waypoints at any zoom */}
      {s.hubRing && (
        <circle cx={x} cy={y} r={r * 1.45} fill="none" stroke={s.color} strokeWidth={1.25} vectorEffect="non-scaling-stroke" opacity={0.8} style={{ pointerEvents: 'none' }} />
      )}
      {/* core glyph */}
      {glyph}
      {showLabel && (
        <text
          x={x}
          y={y - r * (s.hubRing ? 1.75 : 1.45) - 3 / k}
          fontSize={14 / k}
          textAnchor="middle"
          fill="var(--color-ink)"
          stroke="var(--color-map-halo)"
          strokeWidth={3.5 / k}
          paintOrder="stroke"
          style={{ pointerEvents: 'none', userSelect: 'none' }}
        >
          {label}
        </text>
      )}
    </g>
  )
}
