import { formatCountdown } from '../../lib/time'

// Read-only path indicator for an active fleet movement, drawn from origin→target in
// normalized 0..1000 space. Dashed amber for outbound, sky for return-home. Shows a small
// ETA at the midpoint. Purely visual — clicking does nothing that mutates state.

export function FleetMovementLine({
  x1,
  y1,
  x2,
  y2,
  k,
  isReturn,
  arriveAt,
}: {
  x1: number
  y1: number
  x2: number
  y2: number
  k: number
  isReturn: boolean
  arriveAt: string
}) {
  const color = isReturn ? '#38bdf8' : '#fbbf24'
  const mx = (x1 + x2) / 2
  const my = (y1 + y2) / 2
  const eta = formatCountdown(arriveAt)
  const dotR = 4 / k

  return (
    <g data-testid="galaxy-movement-line" style={{ pointerEvents: 'none' }}>
      <line x1={x1} y1={y1} x2={x2} y2={y2} stroke={color} strokeWidth={1.5} strokeDasharray="5 4" vectorEffect="non-scaling-stroke" opacity={0.85} />
      {/* travelling fleet dot near the destination end */}
      <circle cx={x2 - (x2 - x1) * 0.12} cy={y2 - (y2 - y1) * 0.12} r={dotR} fill={color} stroke="#0b1220" strokeWidth={1} vectorEffect="non-scaling-stroke" />
      {eta && (
        <text x={mx} y={my - 4 / k} fontSize={10 / k} textAnchor="middle" fill={color} style={{ userSelect: 'none' }}>
          {isReturn ? '↩ ' : '→ '}
          {eta}
        </text>
      )}
    </g>
  )
}
