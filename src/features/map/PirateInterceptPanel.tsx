import { useState } from 'react'
import type { MapLocation } from './mapTypes'
import type { WorldCoord } from './openSpaceTransform'
import { commandShipGroupCancelRoute, commandShipGroupGoRoute, pirateZoneCreate } from './pirateApi'
import { Badge, Button, OverlayPanel } from '../../components/ui'

// PIRATE INTERCEPT (prototype) — the ONE UI surface for the two new player/owner-facing capabilities:
//   'route' — plot 1-3 waypoints + a final open-space point, preview the danger-zone warning, send.
//   'draw'  — click-to-add-vertex polygon editor (functional prototype; freehand-stroke capture is the
//             documented stub — see the migration header) + save via pirate_zone_create.
// Mounted by MapScreen ONLY while pirateInterceptEnabled is lit (the parent's gate) — this component
// itself does not re-check the flag; a dark deploy never mounts it, so it adds zero bundle-visible
// surface to a player who never sees the flag flip.
//
// PROTOTYPE SCOPE (explicit): operates on the player's FIRST ship group only (groupId prop) — a
// multi-group route-planner selector is a follow-up, mirroring how FleetCommandPanel's own target
// model is singular. The route's final leg is always an open-space point tapped on the map (routing
// to a PORT as the final leg is supported server-side via p_target_location_id but has no UI here).

export function PirateInterceptPanel({
  groupId,
  locations,
  mode,
  onModeChange,
  draftPoints,
  onUndoDraft,
  onClearDraft,
  onCommanded,
  onClose,
}: {
  groupId: string | null
  locations: MapLocation[]
  mode: 'off' | 'route' | 'draw'
  onModeChange: (mode: 'off' | 'route' | 'draw') => void
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
  const [zoneName, setZoneName] = useState('New Danger Zone')
  const [attachLocationId, setAttachLocationId] = useState<string>('')

  const hostileLocations = locations.filter((l) => l.location_type === 'pirate_hunt' || l.location_type === 'pirate_den')

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

  const saveZone = async () => {
    if (draftPoints.length < 3) return
    setBusy(true)
    setMessage(null)
    const vertices: [number, number][] = draftPoints.map((p) => [p.x, p.y])
    const result = await pirateZoneCreate(zoneName.trim() || 'Danger Zone', vertices, attachLocationId || null)
    setBusy(false)
    if (result.ok) {
      setMessage(result.standalone === true ? 'Zone saved (standalone — warning only, no combat).' : 'Zone saved and linked to a hostile site.')
      onClearDraft()
      onModeChange('off')
      onCommanded()
    } else {
      setMessage(`Could not save zone: ${result.reason}`)
    }
  }

  const toggle = (next: 'route' | 'draw') => {
    onClearDraft()
    setMessage(null)
    onModeChange(mode === next ? 'off' : next)
  }

  return (
    <OverlayPanel className="pointer-events-auto flex w-64 flex-col gap-2 text-xs">
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
      <div className="flex gap-2">
        <Button size="sm" variant={mode === 'route' ? 'primary' : 'secondary'} onClick={() => toggle('route')}>
          Plot route
        </Button>
        <Button size="sm" variant={mode === 'draw' ? 'primary' : 'secondary'} onClick={() => toggle('draw')}>
          Draw zone
        </Button>
      </div>

      {mode === 'route' && (
        <div className="flex flex-col gap-2">
          {!groupId && <p className="text-ink-muted">No fleet yet — add a ship to a team first.</p>}
          <p className="text-ink-muted">Tap the map to plot up to 4 points — the last is the destination.</p>
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

      {mode === 'draw' && (
        <div className="flex flex-col gap-2">
          <p className="text-ink-muted">Tap the map to add zone corners (3+). Smoothed automatically.</p>
          <p className="text-ink">{draftPoints.length} corners</p>
          <input
            className="rounded border border-edge bg-app px-2 py-1 text-ink"
            value={zoneName}
            onChange={(e) => setZoneName(e.target.value)}
            placeholder="Zone name"
          />
          <select
            className="rounded border border-edge bg-app px-2 py-1 text-ink"
            value={attachLocationId}
            onChange={(e) => setAttachLocationId(e.target.value)}
          >
            <option value="">Standalone (no combat — geometry/warning only)</option>
            {hostileLocations.map((l) => (
              <option key={l.id} value={l.id}>Attach to: {l.name}</option>
            ))}
          </select>
          <div className="flex gap-2">
            <Button size="sm" variant="secondary" onClick={onUndoDraft} disabled={draftPoints.length === 0}>Undo</Button>
            <Button size="sm" variant="secondary" onClick={onClearDraft} disabled={draftPoints.length === 0}>Clear</Button>
          </div>
          <Button size="sm" onClick={() => void saveZone()} disabled={busy || draftPoints.length < 3}>
            Save zone
          </Button>
        </div>
      )}

      {message && <Badge tone="accent">{message}</Badge>}
    </OverlayPanel>
  )
}
