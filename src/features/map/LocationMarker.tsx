import type { LocationType, MapLocation } from './mapTypes'

// Read-only SVG marker for one location. Positions are in normalized 0..1000 space;
// radius/label are counter-scaled by the zoom factor `k` so they stay a constant on-screen
// size. Selecting only highlights — it never sends an expedition.
//
// UX-CLEANUP item 5: colors come ONLY from the design-system tokens (var(--color-*), emitted by the
// @theme block in src/index.css) so the map reads by the SAME semantic language as the rest of the UI:
//   danger  → hostile (pirate_hunt / pirate_den)
//   success → safe (safe_zone)
//   accent  → dockable port (trade_outpost; gets a second "hub" ring) + rally
//   warning → resource/event (mining_site / event_site)
//   muted   → derelict / unknown
// Hover shows a soft halo (group-hover), selection a solid ring; labels carry an app-colored halo
// (paint-order stroke) so they stay legible over the grid/backdrop.

const TYPE_TOKEN: Record<LocationType, string> = {
  pirate_hunt: 'var(--color-danger)',
  pirate_den: 'var(--color-danger)',
  mining_site: 'var(--color-warning)',
  trade_outpost: 'var(--color-accent)',
  derelict_station: 'var(--color-ink-muted)',
  rally_point: 'var(--color-accent)',
  safe_zone: 'var(--color-success)',
  event_site: 'var(--color-warning)',
}
const FALLBACK_TOKEN = 'var(--color-ink-faint)'

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
  const color = TYPE_TOKEN[location.location_type] ?? FALLBACK_TOKEN
  const isPort = location.location_type === 'trade_outpost'
  const r = 10 / k
  const label = location.name.length > 18 ? `${location.name.slice(0, 17)}…` : location.name

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
      {/* soft identity halo — always on, so type/danger reads at a glance even zoomed out */}
      <circle cx={x} cy={y} r={r * 1.9} fill={color} opacity={0.14} />
      {/* hover halo (presentation only) */}
      <circle
        cx={x}
        cy={y}
        r={r * 2.4}
        fill="none"
        stroke={color}
        strokeWidth={1}
        vectorEffect="non-scaling-stroke"
        className="opacity-0 transition-opacity group-hover:opacity-50"
      />
      {/* selected ring */}
      {selected && (
        <circle cx={x} cy={y} r={r * 2.1} fill="none" stroke={color} strokeWidth={2} vectorEffect="non-scaling-stroke" opacity={0.95} />
      )}
      {/* dockable-port "hub" ring — ports read differently from waypoints at any zoom */}
      {isPort && (
        <circle cx={x} cy={y} r={r * 1.45} fill="none" stroke={color} strokeWidth={1.25} vectorEffect="non-scaling-stroke" opacity={0.8} />
      )}
      {/* core node */}
      <circle cx={x} cy={y} r={r} fill={color} stroke="var(--color-app)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
      {showLabel && (
        <text
          x={x}
          y={y - r * (isPort ? 1.75 : 1.45) - 3 / k}
          fontSize={14 / k}
          textAnchor="middle"
          fill="var(--color-ink)"
          stroke="var(--color-app)"
          strokeWidth={3 / k}
          paintOrder="stroke"
          style={{ pointerEvents: 'none', userSelect: 'none' }}
        >
          {label}
        </text>
      )}
    </g>
  )
}
