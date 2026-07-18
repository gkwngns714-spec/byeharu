import { formatCountdown } from '../../lib/time'

// Read-only path indicator for an active fleet movement. (x1,y1) is the fleet's CURRENT
// interpolated position and (x2,y2) the target, so the dashed line is the REMAINING path and
// shrinks in real time as the fleet advances (the caller re-feeds x1,y1 each clock tick). Dashed
// amber for outbound, sky for return-home. ETA at the midpoint. Purely visual — no state mutation.
//
// S4 TIMED DOCKING: `missionType` is OPTIONAL (every existing caller is unchanged) — a 'dock' leg
// (command_ship_group_dock, 0219) labels "Docking m:ss" instead of the direction arrow, so the 45s
// dock clock reads as what it is. Any other/absent mission keeps today's label byte-identically.

export function FleetMovementLine({
  x1,
  y1,
  x2,
  y2,
  k,
  isReturn,
  arriveAt,
  missionType,
}: {
  x1: number
  y1: number
  x2: number
  y2: number
  k: number
  isReturn: boolean
  arriveAt: string
  missionType?: string
}) {
  // Design-system tokens: outbound = warning (in-transit emphasis), return-home = accent.
  const color = isReturn ? 'var(--color-accent)' : 'var(--color-warning)'
  const mx = (x1 + x2) / 2
  const my = (y1 + y2) / 2
  const eta = formatCountdown(arriveAt)
  const dotR = 4 / k

  return (
    <g data-testid="galaxy-movement-line" style={{ pointerEvents: 'none' }}>
      <line x1={x1} y1={y1} x2={x2} y2={y2} stroke={color} strokeWidth={1.5} strokeDasharray="5 4" vectorEffect="non-scaling-stroke" opacity={0.75} />
      {/* travelling fleet dot AT its current position (the shrinking line's start) */}
      <circle cx={x1} cy={y1} r={dotR} fill={color} stroke="var(--color-app)" strokeWidth={1} vectorEffect="non-scaling-stroke" />
      {eta && (
        <text
          x={mx}
          y={my - 4 / k}
          fontSize={10 / k}
          textAnchor="middle"
          fill={color}
          stroke="var(--color-app)"
          strokeWidth={3 / k}
          paintOrder="stroke"
          style={{ userSelect: 'none' }}
        >
          {missionType === 'dock' ? `Docking ${eta}` : `${isReturn ? '↩ ' : '→ '}${eta}`}
        </text>
      )}
    </g>
  )
}
