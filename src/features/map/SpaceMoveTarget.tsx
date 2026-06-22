import type { ReactNode } from 'react'
import { worldToViewBox, type WorldCoord } from './openSpaceTransform'
import type { SpaceMovePhase } from './spaceMoveCommand'

// OSN-3 S6C — presentational pieces for the empty-space coordinate command surface. PURE: props in,
// element tree out (no hooks, no fetch, no state) so each is directly unit-testable. All copy is
// empty-space/coordinate only — it NEVER implies docking, a location visit, or arrival at a named place.

// ── In-SVG target marker (rendered inside GalaxyMap's camera <g>, pointer-transparent) ───────────────
// Projects a fixed-domain WORLD target through the S6B1 fixed transform (`worldToViewBox`) — never the
// dynamic named-location normalizer. Distinct dashed amber crosshair (not a filled location dot / ship
// chevron). No text label that could be read as a place name.
export function SpaceMoveTargetMarker({ target, k }: { target: WorldCoord; k: number }) {
  const p = worldToViewBox(target)
  const r = 9 / k
  const arm = 6 / k
  const dash = 3 / k
  return (
    <g data-testid="s6c-space-move-target" style={{ pointerEvents: 'none' }} aria-hidden="true">
      <circle
        cx={p.x}
        cy={p.y}
        r={r}
        fill="none"
        stroke="#fbbf24"
        strokeWidth={1.5}
        strokeDasharray={`${dash} ${dash}`}
        vectorEffect="non-scaling-stroke"
      />
      <line x1={p.x - arm} y1={p.y} x2={p.x + arm} y2={p.y} stroke="#fbbf24" strokeWidth={1} vectorEffect="non-scaling-stroke" />
      <line x1={p.x} y1={p.y - arm} x2={p.x} y2={p.y + arm} stroke="#fbbf24" strokeWidth={1} vectorEffect="non-scaling-stroke" />
    </g>
  )
}

// ── Overlay controls (rendered over the map, outside the SVG) ─────────────────────────────────────────
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
      <p data-testid="s6c-disabled" className="mt-1 text-xs text-slate-500">
        Coordinate travel is not available yet.
      </p>
    )
  } else if (eligibility === 'no_ship') {
    body = <p data-testid="s6c-no-ship" className="mt-1 text-xs text-slate-500">No main ship.</p>
  } else if (eligibility === 'destroyed') {
    body = (
      <p data-testid="s6c-ineligible" className="mt-1 text-xs text-amber-300/80">
        Main ship is disabled. Repair it first.
      </p>
    )
  } else if (eligibility === 'in_transit') {
    body = (
      <p data-testid="s6c-ineligible" className="mt-1 text-xs text-slate-400">
        Main ship is already travelling.
      </p>
    )
  } else if (phase === 'success' && serverTarget) {
    body = (
      <div className="mt-1">
        <p data-testid="s6c-success" className="rounded border border-emerald-600/40 bg-emerald-500/10 px-2 py-1.5 text-xs text-emerald-300">
          ✓ Main ship moving to open-space coordinate {fmt(serverTarget)}.
        </p>
        <button data-testid="s6c-clear" onClick={onClear} className="mt-2 w-full rounded-md border border-slate-600 py-1.5 text-xs text-slate-300 hover:bg-slate-700/50">
          Done
        </button>
      </div>
    )
  } else if (phase === 'error') {
    body = (
      <div className="mt-1">
        <p data-testid="s6c-error" className="rounded border border-rose-600/40 bg-rose-500/10 px-2 py-1.5 text-xs text-rose-300">
          {errorMessage ?? 'The ship is not available to move right now.'}
        </p>
        <div className="mt-2 flex gap-2">
          {/* Retry reuses the SAME request id (the controller keeps it after an error). */}
          <button data-testid="s6c-retry" onClick={onConfirm} className="flex-1 rounded-md bg-amber-500 py-1.5 text-xs font-medium text-slate-900 hover:bg-amber-400">
            Retry
          </button>
          <button data-testid="s6c-clear" onClick={onClear} className="flex-1 rounded-md border border-slate-600 py-1.5 text-xs text-slate-300 hover:bg-slate-700/50">
            Clear
          </button>
        </div>
      </div>
    )
  } else if (phase === 'rejected') {
    body = (
      <div className="mt-1">
        <p data-testid="s6c-error" className="rounded border border-rose-600/40 bg-rose-500/10 px-2 py-1.5 text-xs text-rose-300">
          That point is outside the navigable region.
        </p>
        <button data-testid="s6c-clear" onClick={onClear} className="mt-2 w-full rounded-md border border-slate-600 py-1.5 text-xs text-slate-300 hover:bg-slate-700/50">
          Clear
        </button>
      </div>
    )
  } else if ((phase === 'previewing' || phase === 'submitting') && target && targetWithinBounds) {
    body = (
      <div className="mt-1">
        <p data-testid="s6c-target" className="text-xs text-slate-200">
          Destination: <span className="font-medium">{fmt(target)}</span>
        </p>
        <p className="mt-0.5 text-[11px] text-slate-500">Open-space coordinate — the ship travels here, not to a location.</p>
        <div className="mt-2 flex gap-2">
          <button
            data-testid="s6c-confirm"
            disabled={submitting}
            onClick={onConfirm}
            className="flex-1 rounded-md bg-amber-500 py-1.5 text-xs font-medium text-slate-900 transition hover:bg-amber-400 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {submitting ? 'Sending…' : 'Move here'}
          </button>
          <button
            data-testid="s6c-clear"
            disabled={submitting}
            onClick={onClear}
            className="flex-1 rounded-md border border-slate-600 py-1.5 text-xs text-slate-300 transition hover:bg-slate-700/50 disabled:opacity-50"
          >
            Clear
          </button>
        </div>
      </div>
    )
  } else {
    body = (
      <p data-testid="s6c-hint" className="mt-1 text-xs text-slate-400">
        Tap empty space to choose a destination.
      </p>
    )
  }

  return (
    <div data-testid="s6c-panel" className="absolute left-2 top-2 z-10 w-56 rounded-md border border-amber-500/30 bg-slate-900/90 p-2.5 backdrop-blur-sm">
      <p className="text-[11px] uppercase tracking-wide text-amber-300/80">🧭 Open-space move</p>
      {body}
    </div>
  )
}
