import { useCallback, useEffect, useState } from 'react'
import { isSettledInSpace } from '../../lib/osnState'
import { isServerLit, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { commandMiningExtract, getMyMiningExtractions } from './miningApi'
import {
  miningExtractErrorMessage,
  type GetMyMiningExtractionsResult,
} from './miningTypes'

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
  const { activeRef, tryClaim, release } = useActivityPanelGuards()

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

  // One intentional Extract. Fresh request id per submit (crypto.randomUUID — the MarketPanel idiom;
  // the server dedups on (main_ship_id, request_id)); success → note + refresh; failure → the
  // server's message, falling back to the shared copy map (+ the cooldown's real seconds when sent).
  async function extract() {
    if (!mainShipId) return
    if (!tryClaim('extract')) return
    setExtractPending(true)
    setExtractNote(null)
    const requestId = crypto.randomUUID()
    try {
      const res = await commandMiningExtract(mainShipId, requestId)
      if (!activeRef.current) return
      if (res.ok) {
        setExtractNote(`Extracted from ${res.name}.`)
        await refresh()
      } else {
        const base = res.message ?? miningExtractErrorMessage(res.code)
        setExtractNote(
          res.code === 'cooldown' && typeof res.retry_after_seconds === 'number'
            ? `${base} (~${res.retry_after_seconds}s)`
            : base,
        )
      }
    } finally {
      release('extract')
      if (activeRef.current) setExtractPending(false)
    }
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the surface. This is the dark
  // path in production today (mining_disabled); transport errors collapse to null the same way.
  if (!isServerLit(result)) return null

  return (
    <div
      data-testid="mining-panel"
      // Bottom-left, beside ExplorationPanel (w-64 at left-2 → this sits at left-[17rem]); the other
      // OSN overlays hold the remaining corners (PortNav top-left, DockServices top-right, Stop
      // bottom-right). Both activity panels are server-lit, so overlap only ever involves lit surfaces.
      className="pointer-events-auto absolute bottom-2 left-[17rem] z-10 w-64 rounded-lg border border-amber-500/30 bg-slate-900/90 p-2 text-slate-100"
    >
      <p className="text-[11px] font-medium text-amber-300">Mining</p>
      <button
        type="button"
        data-testid="mining-extract-button"
        disabled={!settled || !mainShipId || extractPending}
        onClick={() => void extract()}
        className="mt-1 rounded bg-amber-600/90 px-3 py-1 text-xs font-medium text-white hover:bg-amber-500 disabled:opacity-50"
      >
        {extractPending ? 'Extracting…' : 'Extract minerals'}
      </button>
      {!settled && (
        <p data-testid="mining-extract-hint" className="mt-1 text-[10px] text-slate-400">
          Stop in open space to extract.
        </p>
      )}
      {extractNote && (
        <p data-testid="mining-extract-note" className="mt-1 text-[10px] text-amber-200/90">
          {extractNote}
        </p>
      )}
      {result.extractions.length > 0 ? (
        <ul data-testid="mining-extractions" className="mt-2 space-y-1 border-t border-slate-700/60 pt-2">
          {result.extractions.map((e) => (
            <li key={e.extraction_id} data-testid={`mining-extraction-${e.extraction_id}`} className="text-[10px]">
              <div className="flex items-center justify-between gap-2">
                <span className="truncate text-slate-200">{e.field_name}</span>
                <span
                  data-testid={`mining-extraction-badge-${e.extraction_id}`}
                  className={`rounded px-1.5 py-0.5 text-[9px] ${
                    e.secured_at ? 'bg-emerald-600/30 text-emerald-300' : 'bg-amber-600/30 text-amber-300'
                  }`}
                >
                  {e.secured_at ? 'Secured' : 'Pending'}
                </span>
              </div>
              <p className="text-slate-400">
                {(e.bundle.items ?? []).map((it) => `${it.item_id} ×${it.quantity}`).join(' · ') || '—'}
              </p>
              <p className="text-slate-500">
                {Math.round(e.space_x)}, {Math.round(e.space_y)} · {new Date(e.extracted_at).toLocaleString()}
              </p>
            </li>
          ))}
        </ul>
      ) : (
        <p data-testid="mining-extractions-none" className="mt-2 border-t border-slate-700/60 pt-2 text-[10px] text-slate-400">
          No extractions yet.
        </p>
      )}
    </div>
  )
}
