import type { ReactNode } from 'react'
import { worldToViewBox, type WorldCoord } from './openSpaceTransform'
import type { SpaceMovePhase } from './spaceMoveCommand'
import { Button, Notice, OverlayPanel } from '../../components/ui'

// OSN-3 S6C — presentational pieces for the empty-space coordinate command surface. PURE: props in,
// element tree out (no hooks, no fetch, no state) so each is directly unit-testable. All copy is
// empty-space/coordinate only — it NEVER implies docking, a location visit, or arrival at a named place.
// UI R1: chrome/colors come ONLY from the design-system tokens + primitives (OverlayPanel/Button/Notice).

// ── In-SVG target marker (rendered inside GalaxyMap's camera <g>, pointer-transparent) ───────────────
// Projects a fixed-domain WORLD target through the S6B1 fixed transform (`worldToViewBox`) — never the
// dynamic named-location normalizer. Distinct dashed warning-toned crosshair (not a filled location dot /
// ship chevron). No text label that could be read as a place name.
export function SpaceMoveTargetMarker({ target, k }: { target: WorldCoord; k: number }) {
  const p = worldToViewBox(target)
  const r = 9 / k
  const arm = 6 / k
  const dash = 3 / k
  const stroke = 'var(--color-warning)'
  return (
    <g data-testid="s6c-space-move-target" style={{ pointerEvents: 'none' }} aria-hidden="true">
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

// ── Overlay controls (rendered over the map, inside GalaxyMap's top-right overlay rail) ──────────────
export type SpaceMoveEligibility = 'eligible' | 'no_ship' | 'destroyed' | 'in_transit'

const fmt = (w: WorldCoord): string => `${w.x}, ${w.y}`

export function SpaceMoveControls({
  enabled,
  eligibility,
  phase,
  target,
  targetWithinBounds,
  serverTarget,
  errorMessage,
  onConfirm,
  onClear,
}: {
  enabled: boolean
  eligibility: SpaceMoveEligibility
  phase: SpaceMovePhase
  target: WorldCoord | null
  targetWithinBounds: boolean
  serverTarget: WorldCoord | null
  errorMessage: string | null
  onConfirm: () => void
  onClear: () => void
}) {
  const submitting = phase === 'submitting'

  // Body varies by flag/eligibility/phase. The header is constant and explicitly frames this as an
  // open-space coordinate move, never a location visit.
  let body: ReactNode
  if (!enabled) {
    // Flag dark: clearly non-actionable, not "broken". No tap targeting reaches here in the app.
    body = (
      <p data-testid="s6c-disabled" className="mt-1 text-xs text-ink-faint">
        Coordinate travel is not available yet.
      </p>
    )
  } else if (eligibility === 'no_ship') {
    body = <p data-testid="s6c-no-ship" className="mt-1 text-xs text-ink-faint">No main ship.</p>
  } else if (eligibility === 'destroyed') {
    body = (
      <p data-testid="s6c-ineligible" className="mt-1 text-xs text-warning/90">
        Main ship is disabled. Repair it first.
      </p>
    )
  } else if (eligibility === 'in_transit') {
    body = (
      <p data-testid="s6c-ineligible" className="mt-1 text-xs text-ink-muted">
        Main ship is already travelling.
      </p>
    )
  } else if (phase === 'success' && serverTarget) {
    body = (
      <div className="mt-1">
        <Notice tone="success" data-testid="s6c-success" className="px-2 py-1.5 text-xs">
          ✓ Main ship moving to open-space coordinate {fmt(serverTarget)}.
        </Notice>
        <Button variant="secondary" size="sm" data-testid="s6c-clear" onClick={onClear} className="mt-2 w-full">
          Done
        </Button>
      </div>
    )
  } else if (phase === 'error') {
    body = (
      <div className="mt-1">
        <Notice tone="danger" data-testid="s6c-error" className="px-2 py-1.5 text-xs">
          {errorMessage ?? 'The ship is not available to move right now.'}
        </Notice>
        <div className="mt-2 flex gap-2">
          {/* Retry reuses the SAME request id (the controller keeps it after an error). */}
          <Button variant="warning" size="sm" data-testid="s6c-retry" onClick={onConfirm} className="flex-1">
            Retry
          </Button>
          <Button variant="secondary" size="sm" data-testid="s6c-clear" onClick={onClear} className="flex-1">
            Clear
          </Button>
        </div>
      </div>
    )
  } else if (phase === 'rejected') {
    body = (
      <div className="mt-1">
        <Notice tone="danger" data-testid="s6c-error" className="px-2 py-1.5 text-xs">
          That point is outside the navigable region.
        </Notice>
        <Button variant="secondary" size="sm" data-testid="s6c-clear" onClick={onClear} className="mt-2 w-full">
          Clear
        </Button>
      </div>
    )
  } else if ((phase === 'previewing' || phase === 'submitting') && target && targetWithinBounds) {
    body = (
      <div className="mt-1">
        <p data-testid="s6c-target" className="text-xs text-ink">
          Destination: <span className="font-mono font-medium">{fmt(target)}</span>
        </p>
        <p className="mt-0.5 text-[11px] text-ink-faint">Open-space coordinate — the ship travels here, not to a location.</p>
        <div className="mt-2 flex gap-2">
          <Button variant="warning" size="sm" data-testid="s6c-confirm" disabled={submitting} onClick={onConfirm} className="flex-1">
            {submitting ? 'Sending…' : 'Move here'}
          </Button>
          <Button variant="secondary" size="sm" data-testid="s6c-clear" disabled={submitting} onClick={onClear} className="flex-1">
            Clear
          </Button>
        </div>
      </div>
    )
  } else {
    body = (
      <p data-testid="s6c-hint" className="mt-1 text-xs text-ink-muted">
        Tap empty space to choose a destination.
      </p>
    )
  }

  return (
    <OverlayPanel tone="warning" data-testid="s6c-panel" className="w-56">
      <p className="font-mono text-[11px] uppercase tracking-wider text-warning/90">Open-space move</p>
      {body}
    </OverlayPanel>
  )
}
