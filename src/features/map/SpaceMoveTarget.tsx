import { worldToViewBox, type WorldCoord } from './openSpaceTransform'

// OSN-3 S6C origin, 4A-POST trimmed — the in-SVG coordinate TARGET MARKER only. PURE: props in,
// element tree out (no hooks, no fetch, no state) so it is directly unit-testable
// (tests/spaceMoveTarget.spec.ts). The per-ship SpaceMoveControls confirm panel that used to live
// beside it was deleted with the per-ship movement client; the marker survives because the FLEET
// coordinate-go target reuses this exact crosshair geometry (GalaxyMap's fleet-go mount).

// ── In-SVG target marker (rendered inside GalaxyMap's camera <g>, pointer-transparent) ───────────────
// Projects a fixed-domain WORLD target through the S6B1 fixed transform (`worldToViewBox`) — never the
// dynamic named-location normalizer. Distinct dashed warning-toned crosshair (not a filled location dot /
// ship chevron). No text label that could be read as a place name.
// FLEET-GO 4a-2: `testId`/`stroke` are OPTIONAL with the original values as defaults; the fleet
// coordinate-go target reuses this geometry under its own testid + accent tone instead of cloning it.
export function SpaceMoveTargetMarker({
  target,
  k,
  testId = 's6c-space-move-target',
  stroke = 'var(--color-warning)',
}: {
  target: WorldCoord
  k: number
  testId?: string
  stroke?: string
}) {
  const p = worldToViewBox(target)
  const r = 9 / k
  const arm = 6 / k
  const dash = 3 / k
  return (
    <g data-testid={testId} style={{ pointerEvents: 'none' }} aria-hidden="true">
      <circle
        cx={p.x}
        cy={p.y}
        r={r}
        fill="none"
        stroke={stroke}
        strokeWidth={1.5}
        strokeDasharray={`${dash} ${dash}`}
        vectorEffect="non-scaling-stroke"
      />
      <line x1={p.x - arm} y1={p.y} x2={p.x + arm} y2={p.y} stroke={stroke} strokeWidth={1} vectorEffect="non-scaling-stroke" />
      <line x1={p.x} y1={p.y - arm} x2={p.x} y2={p.y + arm} stroke={stroke} strokeWidth={1} vectorEffect="non-scaling-stroke" />
    </g>
  )
}
