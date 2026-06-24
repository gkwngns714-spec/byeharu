import type { SpaceStopPhase } from './spaceStopCommand'

// OSN-4 — the narrow Stop safety CTA (hook-free presentational component). Rendered by GalaxyMap ONLY
// when the ship is in a real active coordinate transit, INDEPENDENT of the initiation flag (Constraint 1).
// It exposes a single Stop action; the server interpolates the current point and is the final authority.
// Hook-free so the unit tests can call it directly and inspect the returned element tree.
export function SpaceStopControls({
  phase,
  errorMessage,
  outcome,
  onStop,
}: {
  phase: SpaceStopPhase
  errorMessage: string | null
  outcome: 'stopped' | 'arrived' | null
  onStop: () => void
}) {
  const busy = phase === 'submitting'
  return (
    <div
      data-testid="osn4-stop-controls"
      className="pointer-events-auto absolute bottom-2 right-2 z-10 flex flex-col items-end gap-1 rounded-lg border border-amber-500/40 bg-slate-900/85 p-2"
    >
      <p className="text-[10px] text-amber-300/80">Travelling in open space</p>
      <button
        type="button"
        data-testid="osn4-stop-button"
        disabled={busy}
        onClick={onStop}
        className="rounded bg-amber-600/90 px-3 py-1 text-xs font-medium text-white hover:bg-amber-500 disabled:opacity-50"
      >
        {busy ? 'Stopping…' : 'Stop here'}
      </button>
      {phase === 'done' && (
        <p data-testid="osn4-stop-done" className="text-[10px] text-emerald-300/80">
          {outcome === 'arrived' ? 'Arrived at destination.' : 'Stopped in open space.'}
        </p>
      )}
      {phase === 'error' && errorMessage && (
        <p data-testid="osn4-stop-error" className="text-[10px] text-rose-300/80">
          {errorMessage}
        </p>
      )}
    </div>
  )
}
