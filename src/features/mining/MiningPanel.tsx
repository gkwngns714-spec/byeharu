import { useCallback, useEffect, useState } from 'react'
import { isSettledInSpace } from '../../lib/osnState'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { commandMiningExtract, getMyMiningExtractions } from './miningApi'
import {
  miningExtractErrorMessage,
  type GetMyMiningExtractionsResult,
} from './miningTypes'
import { Button, OverlayPanel } from '../../components/ui'
import { ItemChip } from '../../components/items'

// MINING-P12 — the dark mining surface: one Extract action + the player's extraction history.
// SERVER-DRIVEN visibility (no client flag constant): the panel reads get_my_mining_extractions
// on mount / lifecycle change and renders NOTHING unless the server affirmatively lit the feature
// ({ok:true}); the mining_disabled dark envelope — and any other failure — fails closed to null,
// so today's production experience is unchanged. The server also rejects the extract command while
// dark; the UI is never the control. Extract is enabled only when the parent-reported ship state is
// settled in space (0055 model: in_space ⇔ stationary); the server stays authoritative
// (not_in_space), and also enforces the per-(player, field) cooldown + extractor radius.

export function MiningPanel({
  lifecycleKey,
  mainShipId,
  shipStatus,
  shipSpatialState,
}: {
  // Re-reads the extractions whenever the main-ship lifecycle changes (DockServicesPanel idiom).
  lifecycleKey: string
  mainShipId: string | null
  shipStatus: string | null | undefined
  shipSpatialState: string | null | undefined
}) {
  const [result, setResult] = useState<GetMyMiningExtractionsResult | null>(null)
  const [extractPending, setExtractPending] = useState(false)
  const [extractNote, setExtractNote] = useState<string | null>(null)

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refresh = useCallback(async () => {
    const res = await getMyMiningExtractions()
    if (!activeRef.current) return
    setResult(res)
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule without changing refresh's identity

  // lifecycleKey is a deliberate re-fetch trigger (the useDockServices dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  const settled = isSettledInSpace({ spatialState: shipSpatialState, status: shipStatus })

  // One intentional Extract — the shared guarded-submit body (runGuardedCommand); the server
  // dedups on (main_ship_id, request_id). Failure copy: the server's message, else the shared
  // map, plus the cooldown's real seconds when sent.
  async function extract() {
    if (!mainShipId) return
    await runGuardedCommand({
      key: 'extract',
      guards,
      setPending: setExtractPending,
      setNote: setExtractNote,
      exec: () => commandMiningExtract(mainShipId, crypto.randomUUID()),
      successNote: (res) => `Extracted from ${res.name}.`,
      errorNote: (res) => {
        const base = res.message ?? miningExtractErrorMessage(res.code)
        return res.code === 'cooldown' && typeof res.retry_after_seconds === 'number'
          ? `${base} (~${res.retry_after_seconds}s)`
          : base
      },
      refresh,
    })
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the surface. This is the dark
  // path in production today (mining_disabled); transport errors collapse to null the same way.
  if (!isServerLit(result)) return null

  return (
    // UI R2: the OverlayPanel primitive owns the chrome (warning tone = the mining identity;
    // ex-amber). Rides MapScreen's top-left OverlayRail (UI R1) — no self-positioning; the primitive
    // keeps it interactive inside the pointer-transparent rail. Tokens only.
    <OverlayPanel tone="warning" data-testid="mining-panel" className="w-64 text-ink">
      <p className="text-sm font-medium text-warning">Mining</p>
      <Button
        variant="warning"
        size="sm"
        data-testid="mining-extract-button"
        disabled={!settled || !mainShipId}
        busy={extractPending}
        busyLabel="Extracting…"
        onClick={() => void extract()}
        className="mt-1"
      >
        Extract minerals
      </Button>
      {!settled && (
        <p data-testid="mining-extract-hint" className="mt-1 text-xs text-ink-faint">
          Stop in open space to extract.
        </p>
      )}
      {extractNote && (
        <p data-testid="mining-extract-note" className="mt-1 text-xs text-warning">
          {extractNote}
        </p>
      )}
      {result.extractions.length > 0 ? (
        <ul data-testid="mining-extractions" className="mt-2 space-y-1 border-t border-edge pt-2">
          {result.extractions.map((e) => (
            <li key={e.extraction_id} data-testid={`mining-extraction-${e.extraction_id}`} className="text-xs">
              <div className="flex items-center justify-between gap-2">
                <span className="truncate text-ink">{e.field_name}</span>
                <span
                  data-testid={`mining-extraction-badge-${e.extraction_id}`}
                  className={`rounded px-1.5 py-0.5 text-[11px] ${
                    e.secured_at ? 'bg-success/15 text-success' : 'bg-warning/15 text-warning'
                  }`}
                >
                  {e.secured_at ? 'Secured' : 'Pending'}
                </span>
              </div>
              {/* ITEM-VIZ: the extraction bundle as ItemChips (glyph + humanized name + mono qty)
                  instead of raw `item_id ×qty` strings — same server data, richer presentation.
                  Any metal in the bundle renders alongside the items; an empty bundle stays '—'. */}
              {(e.bundle.items ?? []).length > 0 || (e.bundle.metal ?? 0) > 0 ? (
                <span className="mt-0.5 flex flex-wrap gap-1">
                  {(e.bundle.metal ?? 0) > 0 && (
                    <ItemChip id="metal" kind="resource" qty={e.bundle.metal} />
                  )}
                  {(e.bundle.items ?? []).map((it) => (
                    <ItemChip key={it.item_id} id={it.item_id} kind="item" qty={it.quantity} />
                  ))}
                </span>
              ) : (
                <p className="text-ink-muted">—</p>
              )}
              <p className="font-mono text-ink-faint">
                {Math.round(e.space_x)}, {Math.round(e.space_y)} · {new Date(e.extracted_at).toLocaleString()}
              </p>
            </li>
          ))}
        </ul>
      ) : (
        <p data-testid="mining-extractions-none" className="mt-2 border-t border-edge pt-2 text-xs text-ink-muted">
          No extractions yet.
        </p>
      )}
    </OverlayPanel>
  )
}
