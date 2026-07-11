import type { SpaceStopPhase } from './spaceStopCommand'
import { Button, OverlayPanel, type OverlaySlot } from '../../components/ui'

// OSN-4 — the narrow Stop safety CTA (hook-free presentational component). Rendered by GalaxyMap ONLY
// when the ship is in a real active coordinate transit, INDEPENDENT of the initiation flag (Constraint 1).
// It exposes a single Stop action; the server interpolates the current point and is the final authority.
// Hook-free so the unit tests can call it directly and inspect the returned element tree.
// UX-CLEANUP item 3: the copy props (defaults = the original OSN strings) let the SAME component serve the
// legacy transit halt ("Stop — hold here") — one stop control, no parallel component.
// UI R1: chrome comes from the OverlayPanel primitive. Pass a `slot` when this floats over the map
// (GalaxyMap's coordinate stop / MapScreen's legacy stop — mutually exclusive by state, one movement
// owner per ship); omit it to render inline inside another overlay (PortNavPanel's travel view).
export function SpaceStopControls({
  phase,
  errorMessage,
  outcome,
  onStop,
  slot,
  title = 'Travelling in open space',
  stopLabel = 'Stop here',
  stoppedMessage = 'Stopped in open space.',
}: {
  phase: SpaceStopPhase
  errorMessage: string | null
  outcome: 'stopped' | 'arrived' | null
  onStop: () => void
  slot?: OverlaySlot
  title?: string
  stopLabel?: string
  stoppedMessage?: string
}) {
  const busy = phase === 'submitting'
  const body = (
    <>
      <p className="text-[10px] text-warning/90">{title}</p>
      <Button
        variant="warning"
        size="sm"
        data-testid="osn4-stop-button"
        busy={busy}
        busyLabel="Stopping…"
        onClick={onStop}
      >
        {stopLabel}
      </Button>
      {phase === 'done' && (
        <p data-testid="osn4-stop-done" className="text-[10px] text-success/90">
          {outcome === 'arrived' ? 'Arrived at destination.' : stoppedMessage}
        </p>
      )}
      {phase === 'error' && errorMessage && (
        <p data-testid="osn4-stop-error" className="text-[10px] text-danger/90">
          {errorMessage}
        </p>
      )}
    </>
  )

  if (!slot) {
    return (
      <div data-testid="osn4-stop-controls" className="flex flex-col items-start gap-1">
        {body}
      </div>
    )
  }
  return (
    <OverlayPanel slot={slot} tone="warning" data-testid="osn4-stop-controls" className="flex flex-col items-end gap-1">
      {body}
    </OverlayPanel>
  )
}
