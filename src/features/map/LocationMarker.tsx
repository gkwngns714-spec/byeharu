import type { LocationType, MapLocation } from './mapTypes'

// Read-only SVG marker for one location. Positions are in normalized 0..1000 space;
// radius/label are counter-scaled by the zoom factor `k` so they stay a constant on-screen
// size. Selecting only highlights — it never sends an expedition.

const TYPE_STYLE: Record<LocationType, { fill: string; ring: string }> = {
  pirate_hunt: { fill: '#f43f5e', ring: '#fb7185' },
  pirate_den: { fill: '#e11d48', ring: '#fb7185' },
  mining_site: { fill: '#f59e0b', ring: '#fbbf24' },
  trade_outpost: { fill: '#10b981', ring: '#34d399' },
  derelict_station: { fill: '#a78bfa', ring: '#c4b5fd' },
  rally_point: { fill: '#6366f1', ring: '#818cf8' },
  safe_zone: { fill: '#38bdf8', ring: '#7dd3fc' },
  event_site: { fill: '#e879f9', ring: '#f0abfc' },
}
const FALLBACK = { fill: '#94a3b8', ring: '#cbd5e1' }

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
  const style = TYPE_STYLE[location.location_type] ?? FALLBACK
  const r = 7 / k
  const label = location.name.length > 18 ? `${location.name.slice(0, 17)}…` : location.name

  return (
    <g
      data-testid="galaxy-location-marker"
      data-location-id={location.id}
      data-activity={location.activity_type}
      data-location-type={location.location_type}
      onClick={(e) => {
        e.stopPropagation()
        onSelect(location.id)
      }}
      style={{ cursor: 'pointer' }}
    >
      {selected && (
        <circle cx={x} cy={y} r={r * 2.1} fill="none" stroke={style.ring} strokeWidth={2} vectorEffect="non-scaling-stroke" opacity={0.9} />
      )}
      <circle cx={x} cy={y} r={r} fill={style.fill} stroke="#0b1220" strokeWidth={1} vectorEffect="non-scaling-stroke" />
      {showLabel && (
        <text x={x} y={y - r - 3 / k} fontSize={11 / k} textAnchor="middle" fill="#e2e8f0" style={{ pointerEvents: 'none', userSelect: 'none' }}>
          {label}
        </text>
      )}
    </g>
  )
}
