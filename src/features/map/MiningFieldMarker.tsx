import type { MiningField } from '../mining/miningTypes'

// MINING-FIELD-MARKERS — the interactive glyph for one active mining field. Mirrors LocationMarker's
// idiom exactly (invisible constant-radius hit target, halo, app-colored knockout stroke, haloed
// label) but a DELIBERATELY distinct shape — a hexagon "gem" — so a field never reads as a port
// (diamond) / hostile (triangle) / waypoint (circle). Warning-toned (the mining_site marker color
// already in markerStyle.ts's TYPE_TOKEN) — a field is a resource site, same semantic family.
//
// Tapping a field selects it (MapScreen shows its name + a "send fleet here" affordance that reuses
// the existing open-space go — never a second command surface). Selecting never sends anything by
// itself, same posture as LocationMarker.

const HEX_UNIT: ReadonlyArray<[number, number]> = [
  [0.87, 0.5],
  [0, 1],
  [-0.87, 0.5],
  [-0.87, -0.5],
  [0, -1],
  [0.87, -0.5],
]

export function MiningFieldMarker({
  x,
  y,
  k,
  field,
  selected,
  onSelect,
}: {
  x: number
  y: number
  k: number
  field: MiningField
  selected: boolean
  onSelect: (field: MiningField) => void
}) {
  const r = 9 / k
  const points = HEX_UNIT.map(([dx, dy]) => `${x + dx * r},${y + dy * r}`).join(' ')
  // Hit target matches LocationMarker's ~19px constant-radius disc — presentation (halo/reticle)
  // never shrinks or grows what's tappable.
  const hitR = 19 / k
  const ringR = r * 2.2
  const tick = r * 0.8

  return (
    <g
      data-testid="mining-field-marker"
      data-field-name={field.name}
      className="group"
      onClick={(e) => {
        e.stopPropagation()
        onSelect(field)
      }}
      style={{ cursor: 'pointer' }}
    >
      <circle cx={x} cy={y} r={hitR} fill="transparent" />
      {/* soft identity halo — always on, so the resource-site read carries at low zoom */}
      <circle cx={x} cy={y} r={r * 1.9} fill="var(--color-warning)" opacity={0.14} style={{ pointerEvents: 'none' }} />
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
      {selected && (
        <g data-testid="mining-field-marker-reticle" opacity={0.95} style={{ pointerEvents: 'none' }}>
          <circle cx={x} cy={y} r={ringR} fill="var(--color-map-halo)" />
          <circle cx={x} cy={y} r={ringR} fill="none" stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
          <line x1={x} y1={y - ringR - tick} x2={x} y2={y - ringR} stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
          <line x1={x} y1={y + ringR} x2={x} y2={y + ringR + tick} stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
          <line x1={x - ringR - tick} y1={y} x2={x - ringR} y2={y} stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
          <line x1={x + ringR} y1={y} x2={x + ringR + tick} y2={y} stroke="var(--color-accent)" strokeWidth={1.5} vectorEffect="non-scaling-stroke" />
        </g>
      )}
      <polygon
        points={points}
        fill="var(--color-warning)"
        stroke="var(--color-app)"
        strokeWidth={1.5}
        vectorEffect="non-scaling-stroke"
        style={{ pointerEvents: 'none' }}
      />
      {/* a small inner facet cross reads as a mineral/gem, not a plain hex tile */}
      <line x1={x} y1={y - r * 0.55} x2={x} y2={y + r * 0.55} stroke="var(--color-app)" strokeWidth={1} opacity={0.5} vectorEffect="non-scaling-stroke" style={{ pointerEvents: 'none' }} />
      {/* fields are sparse (a handful, world-wide) and the whole point is to be found — always label,
          unlike LocationMarker's zoom-tiered declutter for a much denser location set. */}
      <text
        x={x}
        y={y - r * 1.6 - 3 / k}
        fontSize={14 / k}
        textAnchor="middle"
        fill="var(--color-ink)"
        stroke="var(--color-map-halo)"
        strokeWidth={3.5 / k}
        paintOrder="stroke"
        style={{ pointerEvents: 'none', userSelect: 'none' }}
      >
        {field.name}
      </text>
    </g>
  )
}
