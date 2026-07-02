import { useMemo } from 'react'
import type { MapLocation } from './mapTypes'
import type { MainShipSpaceMovement } from './mainshipApi'
import type { OsnReadiness } from './osnReadiness'
import {
  selectableDestinationIds,
  isPortNavActionable,
  isActiveLocationTargetTransit,
} from './osnReadiness'
import { useOsnReadiness } from './useOsnReadiness'
import { usePortMoveCommand } from './usePortMoveCommand'
import { useSpaceStopCommand } from './useSpaceStopCommand'
import { SpaceStopControls } from './SpaceStopControls'

// PORT-LAUNCH-1B — the DARK port-to-port OSN navigation surface.
//
// Renders NOTHING unless the SERVER readiness projection says it should: the selection UI mounts only when
// osn_available===true AND origin_category==='anchored' AND at least one VISIBLE eligible destination
// exists; the travel/Stop view mounts only for a real active location-target transit whose destination is
// visible. Both conditions are unreachable while production is dark (mainship_space_movement_enabled=false
// → osn_available=false, and no location movement can exist), so this merges with zero player-visible change
// and shows no banner/teaser/error. There is NO coordinate field, crosshair, or empty-space target here.

function formatEta(arriveAt: string | null | undefined): string | null {
  if (!arriveAt) return null
  const t = Date.parse(arriveAt)
  if (!Number.isFinite(t)) return null
  return new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

export function PortNavPanel({
  visibleLocations,
  shipStatus,
  shipSpatialState,
  spaceMovement,
  currentDockedLocationId,
  mainShipId = null,
  onCommitted,
  deps,
}: {
  visibleLocations: MapLocation[]
  shipStatus: string | null | undefined
  shipSpatialState: string | null | undefined
  spaceMovement: MainShipSpaceMovement | null
  currentDockedLocationId: string | null | undefined
  // TRADE-FLEET-0C §2.5: the current/sole main-ship id, threaded to the port-move command as an explicit
  // p_main_ship_id. Optional (defaults null → server sole-ship shim → behavior-identical while single-ship).
  mainShipId?: string | null
  onCommitted: () => void
  // Injection seam for tests / integration; defaults call the real server readiness + command path.
  deps?: {
    readinessFetcher?: () => Promise<OsnReadiness>
    portRpc?: (locationId: string, requestId: string) => Promise<{ ok: true } | { ok: false; code: string; message?: string }>
    stopRpc?: (requestId: string) => Promise<{ ok: true; outcome: 'stopped' | 'arrived' } | { ok: false; code: string; message: string }>
    genRequestId?: () => string
  }
}) {
  // Lifecycle key: any main-ship/movement lifecycle change re-validates server readiness (B/A refetch).
  const lifecycleKey = `${shipStatus ?? 'n'}|${shipSpatialState ?? 'n'}|${spaceMovement?.id ?? 'none'}|${spaceMovement?.status ?? 'none'}`
  const { readiness, refresh: refreshReadiness } = useOsnReadiness(lifecycleKey, { fetcher: deps?.readinessFetcher })
  const port = usePortMoveCommand({ mainShipId, rpc: deps?.portRpc, genRequestId: deps?.genRequestId })
  const stop = useSpaceStopCommand({ rpc: deps?.stopRpc, genRequestId: deps?.genRequestId })

  const visibleIds = useMemo(() => new Set(visibleLocations.map((l) => l.id)), [visibleLocations])
  const selectable = useMemo(() => {
    const allow = new Set(selectableDestinationIds(readiness, visibleIds, currentDockedLocationId))
    return visibleLocations.filter((l) => allow.has(l.id))
  }, [readiness, visibleIds, currentDockedLocationId, visibleLocations])

  const showSelection = isPortNavActionable(readiness, selectable.length)

  // Travel/Stop view: a real active LOCATION-target transit whose destination is in the visible map
  // (fail-closed — a hidden destination shows nothing, no name/id/coord leak). Flag-independent so an
  // in-flight ship can always Stop; naturally dark in production.
  const inLocTransit = isActiveLocationTargetTransit({
    spatialState: shipSpatialState,
    spaceMovementStatus: spaceMovement?.status,
    spaceMovementTargetKind: spaceMovement?.target_kind,
  })
  const destId = spaceMovement?.target_location_id ?? null
  const destName = destId ? (visibleLocations.find((l) => l.id === destId)?.name ?? null) : null
  const showTravel = inLocTransit && destName !== null

  if (!showSelection && !showTravel) return null

  const onConfirm = async () => {
    await port.submit()
    onCommitted()
    refreshReadiness()
  }
  const onStop = async () => {
    await stop.submit()
    onCommitted()
    refreshReadiness()
  }

  return (
    <div
      data-testid="port-nav-panel"
      className="pointer-events-auto absolute left-2 top-2 z-10 w-60 rounded-lg border border-sky-500/30 bg-slate-900/90 p-2 text-slate-100"
    >
      {showSelection && (
        <div data-testid="port-nav-selection">
          <p className="mb-1 text-[11px] font-medium text-sky-300">Travel to a port</p>
          <ul className="flex max-h-48 flex-col gap-1 overflow-auto">
            {selectable.map((loc) => {
              const isSel = port.state.selected?.id === loc.id
              return (
                <li key={loc.id}>
                  <button
                    type="button"
                    data-testid={`port-nav-dest-${loc.id}`}
                    onClick={() => port.selectPort(loc)}
                    className={`w-full truncate rounded px-2 py-1 text-left text-xs ${isSel ? 'bg-sky-600/80 text-white' : 'bg-slate-800/80 text-slate-200 hover:bg-slate-700'}`}
                  >
                    {loc.name}
                  </button>
                </li>
              )
            })}
          </ul>
          {port.state.selected && (
            <button
              type="button"
              data-testid="port-nav-confirm"
              disabled={port.state.phase === 'submitting'}
              onClick={() => void onConfirm()}
              className="mt-2 w-full rounded bg-sky-600/90 px-3 py-1 text-xs font-medium text-white hover:bg-sky-500 disabled:opacity-50"
            >
              {port.state.phase === 'submitting' ? 'Sending…' : `Travel to ${port.state.selected.name}`}
            </button>
          )}
          {port.state.phase === 'error' && port.state.errorMessage && (
            <p data-testid="port-nav-error" className="mt-1 text-[10px] text-rose-300">
              {port.state.errorMessage}
            </p>
          )}
        </div>
      )}

      {showTravel && (
        <div data-testid="port-nav-travel" className="mt-1">
          <p className="text-[11px] text-sky-300">
            Travelling to {destName}
            {formatEta(spaceMovement?.arrive_at) ? ` · arrives ${formatEta(spaceMovement?.arrive_at)}` : ''}
          </p>
          {/* Re-use the EXISTING Stop command path (useSpaceStopCommand) + control for a location-target route. */}
          <SpaceStopControls
            phase={stop.state.phase}
            errorMessage={stop.state.errorMessage}
            outcome={stop.state.outcome}
            onStop={() => void onStop()}
          />
        </div>
      )}
    </div>
  )
}
