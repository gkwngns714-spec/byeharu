import { useCallback, useEffect, useState } from 'react'
import { isServerLit, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { craftModule, fetchModuleCatalog, fetchMyItemBalances, getMyModuleInstances } from './modulesApi'
import {
  craftModuleErrorMessage,
  type GetMyModuleInstancesResult,
  type ModuleCatalogEntry,
} from './modulesTypes'

// MODULES-P13 — the dark module-crafting surface: the craftable catalog (recipes + the player's
// balances) and the crafted-instances list. SERVER-DRIVEN visibility (no client flag constant):
// the panel reads get_my_module_instances on mount / lifecycle change and renders NOTHING unless
// the server affirmatively lit the feature ({ok:true}); the module_crafting_disabled dark
// envelope — and any other failure — fails closed to null (the Exploration/Mining twins' posture;
// isServerLit's documented server-lit stance — NOT MarketPanel's shell-with-unavailable-note,
// which the hook reserves for client-flag-mounted shells), so today's production experience is
// unchanged. The server also rejects craft_module while dark; the UI is never the control.
// Crafting is NON-SPATIAL (player-scoped, 0109) — no ship/settled precondition, so unlike the
// twins this panel takes no ship props. Shortfall disabling is a client preview only; the server
// re-checks balances authoritatively (insufficient_items).

export function ModulesPanel({
  lifecycleKey,
}: {
  // Re-reads instances/balances whenever the main-ship lifecycle changes (DockServicesPanel
  // idiom) — securing deposits land items on exactly those transitions.
  lifecycleKey: string
}) {
  const [result, setResult] = useState<GetMyModuleInstancesResult | null>(null)
  const [catalog, setCatalog] = useState<ModuleCatalogEntry[] | null>(null)
  const [balances, setBalances] = useState<Record<string, number> | null>(null)
  // Per-row state (the MarketPanel per-row granularity — the catalog lists multiple craftables).
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowNote, setRowNote] = useState<Record<string, string | null>>({})

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const { activeRef, tryClaim, release } = useActivityPanelGuards()

  const refresh = useCallback(async () => {
    const res = await getMyModuleInstances()
    if (!activeRef.current) return
    setResult(res)
    // Catalog + balances only matter once the server lit the surface (while dark the panel is
    // null anyway); both are direct reads of already-granted tables (0107 public / 0039 own-row).
    if (res.ok) {
      const [cat, bal] = await Promise.all([fetchModuleCatalog(), fetchMyItemBalances()])
      if (!activeRef.current) return
      setCatalog(cat)
      setBalances(bal)
    }
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule without changing refresh's identity

  // lifecycleKey is a deliberate re-fetch trigger (the useDockServices dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // One intentional Craft per row. Fresh request id per submit (crypto.randomUUID — the
  // MarketPanel idiom; the server dedups on (player_id, request_id)); success → note + refresh
  // (instances AND balances change); failure → the server's message, falling back to the shared
  // copy map (+ the shortfall's real item/have/need when sent).
  async function craft(entry: ModuleCatalogEntry) {
    if (!tryClaim(entry.id)) return // synchronous per-row claim, before any await
    setPending((p) => ({ ...p, [entry.id]: true }))
    setRowNote((n) => ({ ...n, [entry.id]: null }))
    const requestId = crypto.randomUUID()
    try {
      const res = await craftModule(requestId, entry.id)
      if (!activeRef.current) return
      if (res.ok) {
        setRowNote((n) => ({ ...n, [entry.id]: `Crafted ${entry.name}.` }))
        await refresh()
      } else {
        const base = res.message ?? craftModuleErrorMessage(res.code)
        setRowNote((n) => ({
          ...n,
          [entry.id]:
            res.code === 'insufficient_items' && res.item_id
              ? `${base} (${res.item_id}: ${res.have ?? 0}/${res.need ?? 0})`
              : base,
        }))
      }
    } finally {
      release(entry.id)
      if (activeRef.current) setPending((p) => ({ ...p, [entry.id]: false }))
    }
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the surface. This is the dark
  // path in production today (module_crafting_disabled); transport errors collapse to null the
  // same way.
  if (!isServerLit(result)) return null

  return (
    <div
      data-testid="modules-panel"
      // Bottom-left row, beside MiningPanel (w-64 panels at left-2 and left-[17rem] → this sits at
      // left-[33.5rem]); the other OSN overlays hold the remaining corners. All three activity
      // panels are server-lit, so overlap only ever involves lit surfaces.
      className="pointer-events-auto absolute bottom-2 left-[33.5rem] z-10 w-64 rounded-lg border border-sky-500/30 bg-slate-900/90 p-2 text-slate-100"
    >
      <p className="text-[11px] font-medium text-sky-300">Modules</p>
      {catalog === null ? (
        <p data-testid="modules-catalog-unavailable" className="mt-1 text-[10px] text-slate-400">
          Catalog unavailable right now.
        </p>
      ) : catalog.length > 0 ? (
        <ul data-testid="modules-catalog" className="mt-1 space-y-1.5">
          {catalog.map((entry) => {
            const isPending = !!pending[entry.id]
            const note = rowNote[entry.id]
            // Client preview only — the server re-checks authoritatively. With no balances read
            // (null) nothing is flagged/disabled; the server still answers insufficient_items.
            const short =
              balances != null && entry.ingredients.some((i) => (balances[i.item_id] ?? 0) < i.qty)
            return (
              <li key={entry.id} data-testid={`modules-catalog-${entry.id}`} className="text-[10px]">
                <div className="flex items-center justify-between gap-2">
                  <span className="truncate text-slate-200">{entry.name}</span>
                  <span className="rounded bg-sky-600/30 px-1.5 py-0.5 text-[9px] text-sky-300">
                    {entry.slot_type}
                  </span>
                </div>
                <p className="text-slate-400">
                  {entry.ingredients.map((i, idx) => {
                    const have = balances?.[i.item_id]
                    const lacking = balances != null && (have ?? 0) < i.qty
                    return (
                      <span key={i.item_id} className={lacking ? 'text-rose-400' : undefined}>
                        {idx > 0 && ' · '}
                        {i.item_id} ×{i.qty}
                        {balances != null && ` (have ${have ?? 0})`}
                      </span>
                    )
                  })}
                </p>
                <button
                  type="button"
                  data-testid={`modules-craft-button-${entry.id}`}
                  disabled={isPending || short}
                  onClick={() => void craft(entry)}
                  className="mt-0.5 rounded bg-sky-600/90 px-3 py-1 text-xs font-medium text-white hover:bg-sky-500 disabled:opacity-50"
                >
                  {isPending ? 'Crafting…' : 'Craft'}
                </button>
                {note && (
                  <p data-testid={`modules-craft-note-${entry.id}`} className="mt-0.5 text-[10px] text-sky-200/90">
                    {note}
                  </p>
                )}
              </li>
            )
          })}
        </ul>
      ) : (
        <p data-testid="modules-catalog-none" className="mt-1 text-[10px] text-slate-400">
          No module designs available.
        </p>
      )}
      {result.instances.length > 0 ? (
        <ul data-testid="modules-instances" className="mt-2 space-y-1 border-t border-slate-700/60 pt-2">
          {result.instances.map((m) => (
            <li key={m.instance_id} data-testid={`modules-instance-${m.instance_id}`} className="text-[10px]">
              <div className="flex items-center justify-between gap-2">
                <span className="truncate text-slate-200">{m.name}</span>
                <span className="rounded bg-sky-600/30 px-1.5 py-0.5 text-[9px] text-sky-300">{m.slot_type}</span>
              </div>
              <p className="text-slate-500">{new Date(m.created_at).toLocaleString()}</p>
            </li>
          ))}
        </ul>
      ) : (
        <p data-testid="modules-instances-none" className="mt-2 border-t border-slate-700/60 pt-2 text-[10px] text-slate-400">
          No modules crafted yet.
        </p>
      )}
    </div>
  )
}
