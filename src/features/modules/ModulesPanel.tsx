import { useCallback, useEffect, useState } from 'react'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { fetchMyMainShips, type MainShipRow } from '../map/mainshipApi'
import {
  craftModule,
  fetchModuleCatalog,
  fetchMyItemBalances,
  fitModuleToShip,
  getMyModuleInstances,
  getMyShipFittings,
  unfitModuleFromShip,
} from './modulesApi'
import {
  craftModuleErrorMessage,
  fittingErrorMessage,
  type FittingCommandResult,
  type GetMyModuleInstancesResult,
  type GetMyShipFittingsResult,
  type ModuleCatalogEntry,
  type ModuleInstance,
} from './modulesTypes'
import { Button, Card, CardHeader } from '../../components/ui'
import { ItemChip, ItemGlyph, itemLabel } from '../../components/items'

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
//
// FITTING-P14 (slice F) — the fitting UI EXTENDS this panel rather than adding a parallel one:
// the panel already lists the player's module instances, and a second panel would duplicate that
// list (the no-duplication rule). CONSEQUENCE (recorded honestly): the fitting section is
// server-gated TWICE — it renders only when the CRAFTING read surface is lit (this panel's
// isServerLit gate, module_crafting_enabled) AND get_my_ship_fittings answers ok
// (module_fitting_enabled) — i.e. it fails closed both ways and renders NOTHING today, while
// either flag is dark. Slot arithmetic shown in the ship picker (Σ slot_cost / module_slots) is
// display-only; the server (fitting_apply's hard cap + the 0114 settled-SAFE rule) remains the
// enforcer.

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
  // FITTING-P14: the fittings read (dark envelope fails the section closed) + the caller's own
  // ships for the fit picker (the mainshipApi list variant; fetched only once fittings are lit).
  const [fittings, setFittings] = useState<GetMyShipFittingsResult | null>(null)
  const [ships, setShips] = useState<MainShipRow[] | null>(null)
  const [shipPick, setShipPick] = useState<Record<string, string>>({})
  // Per-row state (the MarketPanel per-row granularity — the catalog lists multiple craftables).
  // Shared by craft rows (keyed by catalog id) and fit/unfit rows (keyed by instance uuid) — the
  // key spaces cannot collide.
  const [pending, setPending] = useState<Record<string, boolean>>({})
  const [rowNote, setRowNote] = useState<Record<string, string | null>>({})

  // Mounted + synchronous in-flight guards — the shared home of the idiom (useActivityPanelGuards).
  const guards = useActivityPanelGuards()
  const { activeRef } = guards

  const refresh = useCallback(async () => {
    const res = await getMyModuleInstances()
    if (!activeRef.current) return
    setResult(res)
    // Catalog + balances only matter once the server lit the surface (while dark the panel is
    // null anyway); both are direct reads of already-granted tables (0107 public / 0039 own-row).
    // The fittings read (0116) rides the same batch: its own dark envelope
    // (module_fitting_disabled) just fails the fitting section closed — the second gate.
    if (res.ok) {
      const [cat, bal, fit] = await Promise.all([
        fetchModuleCatalog(),
        fetchMyItemBalances(),
        getMyShipFittings(),
      ])
      if (!activeRef.current) return
      setCatalog(cat)
      setBalances(bal)
      setFittings(fit)
      // The ship picker's list is needed only once fitting is lit (owner-read RLS direct select).
      if (fit.ok) {
        const myShips = await fetchMyMainShips()
        if (!activeRef.current) return
        setShips(myShips)
      }
    }
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule without changing refresh's identity

  // lifecycleKey is a deliberate re-fetch trigger (the useDockServices dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, lifecycleKey])

  // One intentional Craft per row — the shared guarded-submit body (runGuardedCommand) over the
  // per-row key (catalog id); the server dedups on (player_id, request_id). Refresh re-reads
  // instances AND balances. Failure copy: the server's message, else the shared map, plus the
  // shortfall's real item/have/need when sent.
  async function craft(entry: ModuleCatalogEntry) {
    await runGuardedCommand({
      key: entry.id,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [entry.id]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [entry.id]: note })),
      exec: () => craftModule(crypto.randomUUID(), entry.id),
      successNote: () => `Crafted ${entry.name}.`,
      errorNote: (res) => {
        const base = res.message ?? craftModuleErrorMessage(res.code)
        // ITEM-VIZ: humanize the shortfall's item id ('pirate_alloy' → 'Pirate Alloy') — the
        // same real server have/need data, reader-friendly name.
        return res.code === 'insufficient_items' && res.item_id
          ? `${base} (${itemLabel(res.item_id, 'item')}: ${res.have ?? 0}/${res.need ?? 0})`
          : base
      },
      refresh,
    })
  }

  // FITTING-P14: one intentional fit/unfit per instance row — the shared guarded-submit body
  // over the per-row key (instance uuid); the JSX passes the exec thunk (fit vs unfit, minting
  // its fresh request id) + the success verb. Failure copy: the server's message, else the
  // shared map, plus the real insufficient_slots {used, cost, limit} detail. Refresh re-reads
  // instances AND fittings.
  async function runFitting(m: ModuleInstance, exec: () => Promise<FittingCommandResult>, verb: string) {
    await runGuardedCommand({
      key: m.instance_id,
      guards,
      setPending: (on) => setPending((p) => ({ ...p, [m.instance_id]: on })),
      setNote: (note) => setRowNote((n) => ({ ...n, [m.instance_id]: note })),
      exec,
      successNote: () => `${verb} ${m.name}.`,
      errorNote: (res) => {
        const base = res.message ?? fittingErrorMessage(res.code)
        return res.code === 'insufficient_slots' && res.limit != null
          ? `${base} (${res.used ?? 0}/${res.limit} used, needs ${res.cost ?? 0})`
          : base
      },
      refresh,
    })
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the surface. This is the dark
  // path in production today (module_crafting_disabled); transport errors collapse to null the
  // same way.
  if (!isServerLit(result)) return null

  // FITTING-P14 second gate: the fitting section exists only when get_my_ship_fittings answered
  // ok (module_fitting_enabled lit). While dark (module_fitting_disabled) litFittings is null and
  // every fitting element below renders nothing — the panel output is exactly the pre-slice-F
  // markup.
  const litFittings = isServerLit(fittings) ? fittings : null
  const fittedBy = new Map((litFittings?.fittings ?? []).map((f) => [f.module_instance_id, f]))
  const usedByShip: Record<string, number> = {}
  for (const f of litFittings?.fittings ?? []) {
    usedByShip[f.main_ship_id] = (usedByShip[f.main_ship_id] ?? 0) + f.slot_cost
  }
  const myShips = ships ?? []
  const shipLabel = (shipId: string) =>
    myShips.find((s) => s.main_ship_id === shipId)?.name ?? `ship ${shipId.slice(0, 8)}…`

  return (
    // UI R2: the Card primitive owns the chrome (accent tone = the modules identity; ex-sky).
    // Screen-embedded — rides ShipScreen's Screen stack (space-y-4), so the legacy map-corner
    // absolute offset (bottom-2 left-[33.5rem]) is gone with the hand-rolled skin. Tokens only.
    <Card tone="accent" data-testid="modules-panel">
      <CardHeader title="Modules" />
      {catalog === null ? (
        <p data-testid="modules-catalog-unavailable" className="mt-1 text-[10px] text-ink-muted">
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
                  {/* ITEM-VIZ: the module's own glyph beside its catalog name. */}
                  <span className="flex min-w-0 items-center gap-1.5">
                    <ItemGlyph id={entry.id} kind="module" size={14} className="shrink-0 text-accent" />
                    <span className="truncate text-ink">{entry.name}</span>
                  </span>
                  <span className="rounded bg-accent/15 px-1.5 py-0.5 text-[9px] text-accent">
                    {entry.slot_type}
                  </span>
                </div>
                {/* ITEM-VIZ: recipe ingredients as ItemChips (glyph + humanized name + mono qty +
                    the same real have-count hint); a lacking ingredient wears the danger tone —
                    the exact information the raw `item_id ×qty (have n)` string carried. */}
                <span className="mt-0.5 flex flex-wrap gap-1">
                  {entry.ingredients.map((i) => {
                    const have = balances?.[i.item_id]
                    const lacking = balances != null && (have ?? 0) < i.qty
                    return (
                      <ItemChip
                        key={i.item_id}
                        id={i.item_id}
                        kind="item"
                        qty={i.qty}
                        alert={lacking}
                        hint={balances != null ? `have ${have ?? 0}` : undefined}
                      />
                    )
                  })}
                </span>
                <Button
                  variant="primary"
                  size="sm"
                  data-testid={`modules-craft-button-${entry.id}`}
                  disabled={short}
                  busy={isPending}
                  busyLabel="Crafting…"
                  onClick={() => void craft(entry)}
                  className="mt-0.5"
                >
                  Craft
                </Button>
                {note && (
                  <p data-testid={`modules-craft-note-${entry.id}`} className="mt-0.5 text-[10px] text-accent">
                    {note}
                  </p>
                )}
              </li>
            )
          })}
        </ul>
      ) : (
        <p data-testid="modules-catalog-none" className="mt-1 text-[10px] text-ink-muted">
          No module designs available.
        </p>
      )}
      {result.instances.length > 0 ? (
        <ul data-testid="modules-instances" className="mt-2 space-y-1 border-t border-edge pt-2">
          {result.instances.map((m) => {
            // FITTING-P14 per-instance controls — everything below the timestamp is double-gated
            // (litFittings): while module_fitting_enabled is dark these render nothing and the row
            // is byte-identical to the pre-slice-F markup.
            const fitting = fittedBy.get(m.instance_id)
            const isPending = !!pending[m.instance_id]
            const note = rowNote[m.instance_id]
            const pick = shipPick[m.instance_id] ?? myShips[0]?.main_ship_id ?? ''
            return (
              <li key={m.instance_id} data-testid={`modules-instance-${m.instance_id}`} className="text-[10px]">
                <div className="flex items-center justify-between gap-2">
                  {/* ITEM-VIZ: the instance's module-type glyph beside its name. */}
                  <span className="flex min-w-0 items-center gap-1.5">
                    <ItemGlyph id={m.module_type_id} kind="module" size={14} className="shrink-0 text-accent" />
                    <span className="truncate text-ink">{m.name}</span>
                  </span>
                  <span className="rounded bg-accent/15 px-1.5 py-0.5 text-[9px] text-accent">{m.slot_type}</span>
                </div>
                <p className="font-mono text-ink-faint">{new Date(m.created_at).toLocaleString()}</p>
                {litFittings && fitting && (
                  <div className="mt-0.5 flex items-center justify-between gap-2">
                    <span data-testid={`modules-fitted-on-${m.instance_id}`} className="truncate text-accent">
                      Fitted → {shipLabel(fitting.main_ship_id)}
                    </span>
                    <Button
                      variant="secondary"
                      size="sm"
                      data-testid={`modules-unfit-button-${m.instance_id}`}
                      busy={isPending}
                      busyLabel="Unfitting…"
                      onClick={() =>
                        void runFitting(m, () => unfitModuleFromShip(m.instance_id, crypto.randomUUID()), 'Unfitted')
                      }
                    >
                      Unfit
                    </Button>
                  </div>
                )}
                {litFittings && !fitting && myShips.length > 0 && (
                  <div className="mt-0.5 flex items-center gap-1.5">
                    <select
                      data-testid={`modules-fit-ship-${m.instance_id}`}
                      value={pick}
                      onChange={(e) => setShipPick((p) => ({ ...p, [m.instance_id]: e.target.value }))}
                      className="min-w-0 flex-1 rounded border border-edge bg-surface-2 px-1 py-0.5 text-[10px] text-ink"
                    >
                      {myShips.map((s) => (
                        <option key={s.main_ship_id} value={s.main_ship_id}>
                          {/* display-only slot arithmetic; fitting_apply's hard cap is the enforcer */}
                          {s.name} ({usedByShip[s.main_ship_id] ?? 0}/{s.module_slots})
                        </option>
                      ))}
                    </select>
                    <Button
                      variant="primary"
                      size="sm"
                      data-testid={`modules-fit-button-${m.instance_id}`}
                      disabled={!pick}
                      busy={isPending}
                      busyLabel="Fitting…"
                      onClick={() =>
                        void runFitting(m, () => fitModuleToShip(m.instance_id, pick, crypto.randomUUID()), 'Fitted')
                      }
                    >
                      Fit
                    </Button>
                  </div>
                )}
                {litFittings && note && (
                  <p data-testid={`modules-fitting-note-${m.instance_id}`} className="mt-0.5 text-[10px] text-accent">
                    {note}
                  </p>
                )}
              </li>
            )
          })}
        </ul>
      ) : (
        <p data-testid="modules-instances-none" className="mt-2 border-t border-edge pt-2 text-[10px] text-ink-muted">
          No modules crafted yet.
        </p>
      )}
    </Card>
  )
}
