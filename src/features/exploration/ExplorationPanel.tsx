import { useCallback, useEffect, useState } from 'react'
import { isSettledInSpace } from '../../lib/osnState'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { commandExplorationScan, getMyExplorationDiscoveries } from './explorationApi'
import {
  explorationScanErrorMessage,
  type GetMyExplorationDiscoveriesResult,
} from './explorationTypes'
import { Button, OverlayPanel } from '../../components/ui'

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
    // UI R2: the OverlayPanel primitive owns the chrome (accent tone = the exploration identity;
    // ex-violet). Rides MapScreen's top-left OverlayRail (UI R1) — no self-positioning; the primitive
    // keeps it interactive inside the pointer-transparent rail. Tokens only.
    <OverlayPanel tone="accent" data-testid="exploration-panel" className="w-64 text-ink">
      <p className="text-[11px] font-medium text-accent">Exploration</p>
      <Button
        variant="primary"
        size="sm"
        data-testid="exploration-scan-button"
        disabled={!settled || !mainShipId}
        busy={scanPending}
        busyLabel="Scanning…"
        onClick={() => void scan()}
        className="mt-1"
      >
        Scan for signals
      </Button>
      {!settled && (
        <p data-testid="exploration-scan-hint" className="mt-1 text-[10px] text-ink-faint">
          Stop in open space to scan.
        </p>
      )}
      {scanNote && (
        <p data-testid="exploration-scan-note" className="mt-1 text-[10px] text-accent">
          {scanNote}
        </p>
      )}
      {result.discoveries.length > 0 ? (
        <ul data-testid="exploration-discoveries" className="mt-2 space-y-1 border-t border-edge pt-2">
          {result.discoveries.map((d) => (
            <li key={d.discovery_id} data-testid={`exploration-discovery-${d.discovery_id}`} className="text-[10px]">
              <div className="flex items-center justify-between gap-2">
                <span className="truncate text-ink">{d.site_name}</span>
                <span
                  data-testid={`exploration-discovery-badge-${d.discovery_id}`}
                  className={`rounded px-1.5 py-0.5 text-[9px] ${
                    d.secured_at ? 'bg-success/15 text-success' : 'bg-warning/15 text-warning'
                  }`}
                >
                  {d.secured_at ? 'Secured' : 'Pending'}
                </span>
              </div>
              <p className="font-mono text-ink-faint">
                {Math.round(d.space_x)}, {Math.round(d.space_y)} · {new Date(d.discovered_at).toLocaleString()}
              </p>
            </li>
          ))}
        </ul>
      ) : (
        <p data-testid="exploration-discoveries-none" className="mt-2 border-t border-edge pt-2 text-[10px] text-ink-muted">
          No discoveries yet.
        </p>
      )}
    </OverlayPanel>
  )
}
