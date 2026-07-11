import { useCallback, useEffect, useState } from 'react'
import { isSettledInSpace } from '../../lib/osnState'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
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

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refresh = useCallback(async () => {
    const res = await getMyExplorationDiscoveries()
    if (!activeRef.current) return
    setResult(res)
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule without changing refresh's identity

  // lifecycleKey is a deliberate re-fetch trigger (the useDockServices dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  const settled = isSettledInSpace({ spatialState: shipSpatialState, status: shipStatus })

  // One intentional Scan — the shared guarded-submit body (runGuardedCommand); the server dedups
  // on (main_ship_id, request_id). Failure copy: the server's message, else the shared map.
  async function scan() {
    if (!mainShipId) return
    await runGuardedCommand({
      key: 'scan',
      guards,
      setPending: setScanPending,
      setNote: setScanNote,
      exec: () => commandExplorationScan(mainShipId, crypto.randomUUID()),
      successNote: (res) => `Discovered ${res.name}.`,
      errorNote: (res) => res.message ?? explorationScanErrorMessage(res.code),
      refresh,
    })
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the surface. This is the dark
  // path in production today (exploration_disabled); transport errors collapse to null the same way.
  if (!isServerLit(result)) return null

  return (
    <div
      data-testid="exploration-panel"
      // UI R1: self-positioning dropped — this now rides MapScreen's top-left OverlayRail, which stacks
      // co-corner overlays in a flex column (no more magic offsets). Keeps pointer-events-auto so it stays
      // interactive inside the pointer-transparent rail. Inner skin (violet/slate) is R2's tokenization pass.
      className="pointer-events-auto w-64 rounded-lg border border-violet-500/30 bg-slate-900/90 p-2 text-slate-100"
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
