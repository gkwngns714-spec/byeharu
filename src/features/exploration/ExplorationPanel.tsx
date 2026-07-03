import { useCallback, useEffect, useRef, useState } from 'react'
import { isSettledInSpace } from '../../lib/osnState'
import { commandExplorationScan, getMyExplorationDiscoveries } from './explorationApi'
import {
  explorationScanErrorMessage,
  type GetMyExplorationDiscoveriesResult,
} from './explorationTypes'

// EXPLORATION-P11 — the dark exploration surface: one Scan action + the player's discoveries list.
// SERVER-DRIVEN visibility (no client flag constant): the panel reads get_my_exploration_discoveries
// on mount / lifecycle change and renders NOTHING unless the server affirmatively lit the feature
// ({ok:true}); the exploration_disabled dark envelope — and any other failure — fails closed to null,
// so today's production experience is unchanged. The server also rejects the scan command while dark;
// the UI is never the control. Scan is enabled only when the parent-reported ship state is settled in
// space (0055 model: in_space ⇔ stationary); the server stays authoritative (not_in_space).

export function ExplorationPanel({
  lifecycleKey,
  mainShipId,
  shipStatus,
  shipSpatialState,
}: {
  // Re-reads the discoveries whenever the main-ship lifecycle changes (DockServicesPanel idiom).
  lifecycleKey: string
  mainShipId: string | null
  shipStatus: string | null | undefined
  shipSpatialState: string | null | undefined
}) {
  const [result, setResult] = useState<GetMyExplorationDiscoveriesResult | null>(null)
  const [scanPending, setScanPending] = useState(false)
  const [scanNote, setScanNote] = useState<string | null>(null)

  // Mounted guard (MarketPanel idiom): refresh() (mount AND post-scan) never sets state after unmount.
  const activeRef = useRef(true)
  useEffect(() => {
    activeRef.current = true
    return () => {
      activeRef.current = false
    }
  }, [])

  // Synchronous in-flight guard (MarketPanel idiom): two clicks in the SAME render tick both read a
  // stale scanPending=false and would each mint a DISTINCT request id (which the server, keyed on
  // (main_ship_id, request_id), would NOT dedup). The ref flips synchronously before the first await.
  const inFlightRef = useRef(false)

  const refresh = useCallback(async () => {
    const res = await getMyExplorationDiscoveries()
    if (!activeRef.current) return
    setResult(res)
  }, [])

  // lifecycleKey is a deliberate re-fetch trigger (the useDockServices dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  const settled = isSettledInSpace({ spatialState: shipSpatialState, status: shipStatus })

  // One intentional Scan. Fresh request id per submit (crypto.randomUUID — the MarketPanel idiom;
  // the server dedups on (main_ship_id, request_id)); success → note + refresh; failure → the
  // server's message, falling back to the shared copy map.
  async function scan() {
    if (!mainShipId || inFlightRef.current) return
    inFlightRef.current = true
    setScanPending(true)
    setScanNote(null)
    const requestId = crypto.randomUUID()
    try {
      const res = await commandExplorationScan(mainShipId, requestId)
      if (!activeRef.current) return
      if (res.ok) {
        setScanNote(`Discovered ${res.name}.`)
        await refresh()
      } else {
        setScanNote(res.message ?? explorationScanErrorMessage(res.code))
      }
    } finally {
      inFlightRef.current = false
      if (activeRef.current) setScanPending(false)
    }
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the surface. This is the dark
  // path in production today (exploration_disabled); transport errors collapse to null the same way.
  if (!result || !result.ok) return null

  return (
    <div
      data-testid="exploration-panel"
      // Bottom-left; mirrors the other OSN overlays (PortNav top-left, DockServices top-right, Stop
      // bottom-right) so all four can coexist without overlap.
      className="pointer-events-auto absolute bottom-2 left-2 z-10 w-64 rounded-lg border border-violet-500/30 bg-slate-900/90 p-2 text-slate-100"
    >
      <p className="text-[11px] font-medium text-violet-300">Exploration</p>
      <button
        type="button"
        data-testid="exploration-scan-button"
        disabled={!settled || !mainShipId || scanPending}
        onClick={() => void scan()}
        className="mt-1 rounded bg-violet-600/90 px-3 py-1 text-xs font-medium text-white hover:bg-violet-500 disabled:opacity-50"
      >
        {scanPending ? 'Scanning…' : 'Scan for signals'}
      </button>
      {!settled && (
        <p data-testid="exploration-scan-hint" className="mt-1 text-[10px] text-slate-400">
          Stop in open space to scan.
        </p>
      )}
      {scanNote && (
        <p data-testid="exploration-scan-note" className="mt-1 text-[10px] text-violet-200/90">
          {scanNote}
        </p>
      )}
      {result.discoveries.length > 0 ? (
        <ul data-testid="exploration-discoveries" className="mt-2 space-y-1 border-t border-slate-700/60 pt-2">
          {result.discoveries.map((d) => (
            <li key={d.discovery_id} data-testid={`exploration-discovery-${d.discovery_id}`} className="text-[10px]">
              <div className="flex items-center justify-between gap-2">
                <span className="truncate text-slate-200">{d.site_name}</span>
                <span
                  data-testid={`exploration-discovery-badge-${d.discovery_id}`}
                  className={`rounded px-1.5 py-0.5 text-[9px] ${
                    d.secured_at ? 'bg-emerald-600/30 text-emerald-300' : 'bg-amber-600/30 text-amber-300'
                  }`}
                >
                  {d.secured_at ? 'Secured' : 'Pending'}
                </span>
              </div>
              <p className="text-slate-500">
                {Math.round(d.space_x)}, {Math.round(d.space_y)} · {new Date(d.discovered_at).toLocaleString()}
              </p>
            </li>
          ))}
        </ul>
      ) : (
        <p data-testid="exploration-discoveries-none" className="mt-2 border-t border-slate-700/60 pt-2 text-[10px] text-slate-400">
          No discoveries yet.
        </p>
      )}
    </div>
  )
}
