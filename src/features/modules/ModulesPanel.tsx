import { useCallback, useEffect, useState } from 'react'
import { isServerLit, runGuardedCommand, useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { craftModule, fetchModuleCatalog, fetchMyItemBalances, getMyModuleInstances } from './modulesApi'
import {
  craftModuleErrorMessage,
  type GetMyModuleInstancesResult,
  type ModuleCatalogEntry,
} from './modulesTypes'
import { Button, Card, CardHeader, SectionLabel } from '../../components/ui'
import { ItemChip, ItemGlyph, itemLabel } from '../../components/items'

// MODULES-P13 — the module-CRAFTING surface: the craftable catalog (recipes + the player's
// balances) and the crafted-instances list. SERVER-DRIVEN visibility (no client flag constant):
// the panel reads get_my_module_instances on mount / lifecycle change and renders NOTHING unless
// the server affirmatively lit the feature ({ok:true}); the module_crafting_disabled dark
// envelope — and any other failure — fails closed to null (the Exploration/Mining twins' posture).
// The server also rejects craft_module while dark; the UI is never the control. Crafting is
// NON-SPATIAL (player-scoped, 0109) — no ship/settled precondition, so unlike the twins this panel
// takes no ship props. Shortfall disabling is a client preview only; the server re-checks balances
// authoritatively (insufficient_items).
//
// S6 (FITTING TAB): the fit/unfit EDIT surface that briefly lived here (FITTING-P14 slice F) moved
// to the Fitting tab's per-ship detail (features/ship/FittingDetail — the ONE fitting-edit surface;
// the row IS the ship, and the 0114 settled-safe gate derives from the ship's own fleet-positions
// row there). This panel is CRAFTING ONLY: catalog + craft + the crafted-instances list. Fitting
// state is deliberately not read here — one fact, one surface.

export function ModulesPanel({
  lifecycleKey,
  onChanged,
  sectionLabel,
}: {
  // Re-reads instances/balances whenever the main-ship lifecycle changes (DockServicesPanel
  // idiom) — securing deposits land items on exactly those transitions.
  lifecycleKey: string
  // Fires AFTER a successful craft's own refetch (craft consumes inventory) so sibling read
  // surfaces can re-read — the cross-panel refetch wire, never an optimistic patch.
  onChanged?: () => void
  // WORKSHOP (presentation only): an optional SectionLabel rendered INSIDE the lit branch — the
  // panel's visibility is server-decided at runtime, so a screen-owned header could label a void;
  // owning it here keeps the label void-safe.
  sectionLabel?: string
}) {
  const [result, setResult] = useState<GetMyModuleInstancesResult | null>(null)
  const [catalog, setCatalog] = useState<ModuleCatalogEntry[] | null>(null)
  const [balances, setBalances] = useState<Record<string, number> | null>(null)
  // Per-row state (the MarketPanel per-row granularity — the catalog lists multiple craftables).
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

  // Post-success refetch + sibling notification (guarded commands only — the mount refresh must
  // NOT ping siblings, or every lifecycle tick would fan out into a refetch storm).
  async function refreshAndNotify() {
    await refresh()
    onChanged?.()
  }

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
      refresh: refreshAndNotify,
    })
  }

  // FAIL CLOSED: render nothing unless the server affirmatively lit the surface. Transport errors
  // collapse to null the same way.
  if (!isServerLit(result)) return null

  const panel = (
    // UI R2: the Card primitive owns the chrome (accent tone = the modules identity).
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
                    the same real have-count hint); a lacking ingredient wears the danger tone. */}
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
          {result.instances.map((m) => (
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
              {/* S6: fit/unfit moved to the Fitting tab's per-ship detail — this list is the
                  crafted inventory only. */}
            </li>
          ))}
        </ul>
      ) : (
        <p data-testid="modules-instances-none" className="mt-2 border-t border-edge pt-2 text-[10px] text-ink-muted">
          No modules crafted yet.
        </p>
      )}
    </Card>
  )

  // WORKSHOP: label + panel as ONE rail child. No label prop → the bare Card.
  if (sectionLabel == null) return panel
  return (
    <div>
      <SectionLabel>{sectionLabel}</SectionLabel>
      {panel}
    </div>
  )
}
