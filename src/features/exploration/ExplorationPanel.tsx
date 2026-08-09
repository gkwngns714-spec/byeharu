import { useCallback, useEffect, useState } from 'react'
import { isSettledInSpace } from '../../lib/osnState'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { commandExplorationScan, getMyExplorationDiscoveries } from './explorationApi'
import {
  explorationScanErrorMessage,
  type GetMyExplorationDiscoveriesResult,
} from './explorationTypes'
import { Button, OverlayPanel, overlayAccountClass, overlayReachClass } from '../../components/ui'
import { ItemChip } from '../../components/items'

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

  // ── FAIL CLOSED, IN THREE STATES RATHER THAN TWO ─────────────────────────────────────────────────
  // This used to be one line — `if (!isServerLit(result)) return null` — which collapsed "the read
  // has not come back yet" and "the server says this feature is off" into the same blank. That was
  // right while the panel merely rode a rail (an absent panel is an absent panel), and it is wrong
  // now that it is a TAB BODY the player has deliberately opened: a tab that opens onto nothing is
  // indistinguishable from a broken game, which is the silence the owner has objected to before.
  //
  //   · result === null   → the read is in flight. Render nothing; a "not available" flashed for
  //                         200ms and then replaced is a lie the player saw.
  //   · result.ok false   → the SERVER said so. Say it, in the server's own words through the ONE
  //                         reject-copy map, never a sentence invented here.
  //   · result.ok true    → the surface, as before.
  // The gate itself is unchanged: the client still reads no flag and still never lets a scan through
  // that the server has not lit.
  if (result === null) return null
  if (!isServerLit(result)) {
    return (
      <OverlayPanel tone="accent" data-testid="exploration-panel-dark" className="flex min-h-[3.75rem] w-64 max-w-full flex-col text-ink">
        <p className="text-[11px] font-medium text-accent">Exploration</p>
        <p className="mt-1 text-[11px] text-ink-muted">{explorationScanErrorMessage('feature_disabled')}</p>
      </OverlayPanel>
    )
  }

  return (
    // UI R2: the OverlayPanel primitive owns the chrome (accent tone = the exploration identity;
    // ex-violet). Rides MapScreen's top-left OverlayRail (UI R1) — no self-positioning; the primitive
    // keeps it interactive inside the pointer-transparent rail. Tokens only.
    // THE REACH LAW (components/ui/overlayLayout.ts): the panel is a flex column whose CONTROL is
    // pinned and whose readout is an account. In the map's top-left rail the panels are squeezed
    // whenever a fight starts — the squeeze must land on the discoveries list, never on Scan.
    <OverlayPanel tone="accent" data-testid="exploration-panel" className="flex min-h-[5.5rem] w-64 shrink-[999] flex-col text-ink">
      <div className={overlayReachClass()}>
        <p className="text-[11px] font-medium text-accent">Exploration</p>
        <Button
          variant="primary"
          size="sm"
          data-testid="exploration-scan-button"
          disabled={!settled || !mainShipId}
          busy={scanPending}
          busyLabel="Scanning…"
          onClick={() => void scan()}
          // The 44px touch floor, like every other action in the map rails. Measured at 24px on a
          // 390px phone by tests/actionsAreReachable.uispec.ts — present, reachable and too small
          // to press, which is the same defect as being clipped wearing different clothes.
          className="min-h-11 w-full"
        >
          Scan for signals
        </Button>
      </div>
      {/* THE ACCOUNT — everything below is what the scan HAS FOUND. It scrolls and it yields room. */}
      <div className={overlayAccountClass('mt-1')}>
      {!settled && (
        <p data-testid="exploration-scan-hint" className="text-[10px] text-ink-faint">
          Stop in open space to scan.
        </p>
      )}
      {scanNote && (
        <p data-testid="exploration-scan-note" className="text-[10px] text-accent">
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
                  className={`rounded px-1.5 py-0.5 text-[10px] ${
                    d.secured_at ? 'bg-success/15 text-success' : 'bg-warning/15 text-warning'
                  }`}
                >
                  {d.secured_at ? 'Secured' : 'Pending'}
                </span>
              </div>
              {/* ITEM-VIZ: the discovery's reward bundle (already in the 0101 read, previously not
                  shown) as ItemChips — glyph + humanized name + mono qty; metal rides alongside. */}
              {((d.bundle.items ?? []).length > 0 || (d.bundle.metal ?? 0) > 0) && (
                <span className="mt-0.5 flex flex-wrap gap-1">
                  {(d.bundle.metal ?? 0) > 0 && (
                    <ItemChip id="metal" kind="resource" qty={d.bundle.metal} />
                  )}
                  {(d.bundle.items ?? []).map((it) => (
                    <ItemChip key={it.item_id} id={it.item_id} kind="item" qty={it.quantity} />
                  ))}
                </span>
              )}
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
      </div>
    </OverlayPanel>
  )
}
