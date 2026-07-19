import { useState } from 'react'
import type { WorldCoord } from './openSpaceTransform'
import { commandShipGroupCancelRoute, commandShipGroupGoRoute } from './pirateApi'
import { Badge, Button, OverlayPanel } from '../../components/ui'

// PIRATE INTERCEPT — the player-facing ROUTE planner: plot 1-3 waypoints + a final open-space point to
// route a fleet AROUND known danger zones (or deliberately bait one), then send. Mounted by MapScreen
// ONLY while pirateInterceptEnabled is lit (the parent's gate) — this component does not re-check the
// flag; a dark deploy never mounts it.
//
// SCOPE: the zone-DRAWING (pirate_zone_create) authoring flow is a DEVELOPER/admin tool, not player
// gameplay — it is deliberately absent from this player UI (the server RPC stays for dev/admin use).
// Players only ROUTE around danger here; they never draw pirate territory.
//
// Operates on the player's FIRST ship group only (groupId prop), mirroring how FleetCommandPanel's own
// target model is singular. The route's final leg is always an open-space point tapped on the map.

export function PirateInterceptPanel({
  groupId,
  mode,
  onModeChange,
  draftPoints,
  onUndoDraft,
  onClearDraft,
  onCommanded,
  onClose,
}: {
  groupId: string | null
  mode: 'off' | 'route'
  onModeChange: (mode: 'off' | 'route') => void
  draftPoints: WorldCoord[]
  onUndoDraft: () => void
  onClearDraft: () => void
  onCommanded: () => void
  /** Optional self-dismiss. When the panel rides inside the command hub the hub header owns the ✕, so
   *  this is omitted and no per-panel close renders. */
  onClose?: () => void
}) {
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  const sendRoute = async () => {
    if (!groupId || draftPoints.length === 0) return
    setBusy(true)
    setMessage(null)
    const waypoints = draftPoints.slice(0, -1)
    const last = draftPoints[draftPoints.length - 1]
    const result = await commandShipGroupGoRoute(groupId, { waypoints, targetX: last.x, targetY: last.y })
    setBusy(false)
    if (result.ok) {
      setMessage(result.intercepted === true ? 'Route sent — ambushed on the first leg!' : 'Route sent.')
      onClearDraft()
      onModeChange('off')
      onCommanded()
    } else {
      setMessage(`Could not send route: ${result.reason}`)
    }
  }

  const cancelQueuedRoute = async () => {
    if (!groupId) return
    setBusy(true)
    const result = await commandShipGroupCancelRoute(groupId)
    setBusy(false)
    setMessage(result.ok ? `Cleared ${String(result.cleared ?? 0)} queued leg(s).` : `Could not clear route: ${result.reason}`)
  }

  // Arm/disarm the route-plotting tap mode. Toggling clears any in-progress draft so a stale plot never
  // carries between arming sessions.
  const toggleRoute = () => {
    onClearDraft()
    setMessage(null)
    onModeChange(mode === 'route' ? 'off' : 'route')
  }

  return (
    <OverlayPanel className="pointer-events-auto flex w-64 max-w-[calc(100vw-1.5rem)] flex-col gap-2 text-sm">
      <div className="flex items-center justify-between">
        <span className="font-semibold text-ink">Pirate Intercept</span>
        {onClose && (
          <button
            type="button"
            onClick={onClose}
            aria-label="Close pirate intercept"
            title="Close"
            className="-mr-1 flex h-6 w-6 items-center justify-center rounded text-base leading-none text-ink-muted hover:bg-edge/40 hover:text-ink"
          >
            ×
          </button>
        )}
      </div>
      <p className="text-ink-muted">Plot a path that routes your fleet around danger zones on the way to a destination.</p>
      <Button size="sm" variant={mode === 'route' ? 'primary' : 'secondary'} className="w-full" onClick={toggleRoute}>
        {mode === 'route' ? 'Stop plotting' : 'Plot a route'}
      </Button>

      {mode === 'route' && (
        <div className="flex flex-col gap-2">
          {!groupId && <p className="text-ink-muted">No fleet yet — add a ship to a team first.</p>}
          <p className="text-ink-muted">Tap the map to plot up to 4 points — the last one is the destination.</p>
          <p className="text-ink">{draftPoints.length} plotted</p>
          <div className="flex gap-2">
            <Button size="sm" variant="secondary" onClick={onUndoDraft} disabled={draftPoints.length === 0}>Undo</Button>
            <Button size="sm" variant="secondary" onClick={onClearDraft} disabled={draftPoints.length === 0}>Clear</Button>
          </div>
          <div className="flex gap-2">
            <Button size="sm" onClick={() => void sendRoute()} disabled={busy || !groupId || draftPoints.length === 0}>
              Send
            </Button>
            <Button size="sm" variant="secondary" onClick={() => void cancelQueuedRoute()} disabled={busy || !groupId}>
              Cancel queued
            </Button>
          </div>
        </div>
      )}

      {message && <Badge tone="accent">{message}</Badge>}
    </OverlayPanel>
  )
}
