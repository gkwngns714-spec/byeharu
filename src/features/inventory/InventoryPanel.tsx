import { useCallback, useEffect, useState } from 'react'
import { useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { fetchItemCatalog, fetchMyItemBalances } from '../modules/modulesApi'
import type { ItemTypeRow } from '../modules/modulesTypes'
import { inventoryEntries } from './inventoryView'
import { Card, CardHeader, Skeleton } from '../../components/ui'
import { ItemTile } from '../../components/items'

/** Title-case a bare catalog token (category/rarity) for display. */
const cap = (s: string) => s.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())

// INVENTORY-PANEL (SHIP-DOSSIER slice) — the player's item inventory, finally VISIBLE (owner
// order: "…with inventory as well — I should be able to SEE this"). player_inventory rendered
// NOWHERE before this panel except as 'have n' recipe hints inside ModulesPanel. READ-ONLY: the
// EXISTING read is reused verbatim (modulesApi.fetchMyItemBalances — the 0039 own-row
// player_inventory select; no new server surface), shown as the ItemTile grid.
//
// NOT server-lit gated: player_inventory has no feature flag — it is live player data (combat
// salvage already lands here in production), so the panel always renders (a flagged-dark posture
// would hide real belongings). Read failure degrades to an honest unavailable line (the
// ModulesPanel catalog-unavailable idiom), never a silent empty.
//
// Home: the Ship screen's aside rail — items are crafting/recruiting materials, consumed by the
// ModulesPanel (main rail) and RecruitCaptainPanel (aside) on this same screen.

export function InventoryPanel({
  // Re-reads on main-ship lifecycle transitions AND after an item-consuming command elsewhere on
  // the screen (craft/recruit — ShipScreen bumps its loadout revision into this key).
  refreshKey,
}: {
  refreshKey: string
}) {
  // null = first load pending · 'error' = read failed · Record = the server's balances.
  const [balances, setBalances] = useState<Record<string, number> | 'error' | null>(null)
  // The public item_types display catalog (name/category/rarity/description/stackable) — powers the
  // tap-to-info panel. null while loading / on read error → tiles stay non-interactive (no info to
  // show), never a crash: the balances grid is the always-present surface.
  const [catalog, setCatalog] = useState<ItemTypeRow[] | null>(null)
  // The item id whose info panel is open (only one at a time); tap again to collapse.
  const [openItem, setOpenItem] = useState<string | null>(null)

  // Mounted guard — the shared idiom home (read-only panel: no submit guards needed).
  const { activeRef } = useActivityPanelGuards()

  const refresh = useCallback(async () => {
    const [res, cat] = await Promise.all([fetchMyItemBalances(), fetchItemCatalog()])
    if (!activeRef.current) return
    setBalances(res ?? 'error')
    setCatalog(cat)
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule

  // refreshKey is a deliberate re-fetch trigger (the ModulesPanel lifecycleKey dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, refreshKey])

  const entries = balances !== null && balances !== 'error' ? inventoryEntries(balances) : null
  const byId = catalog ? new Map(catalog.map((c) => [c.item_id, c])) : null
  const toggle = (id: string) => setOpenItem((cur) => (cur === id ? null : id))
  const openInfo = openItem != null ? byId?.get(openItem) : undefined

  return (
    <Card data-testid="inventory-panel" aria-busy={balances === null || undefined}>
      <CardHeader title="Inventory" subtitle="Items you carry — crafting & recruiting materials." className="mb-2" />
      {balances === null ? (
        <>
          <Skeleton className="mt-2 h-8 w-full rounded-lg" />
          <Skeleton className="mt-2 h-8 w-2/3 rounded-lg" />
          <span className="sr-only">Checking your inventory…</span>
        </>
      ) : balances === 'error' ? (
        <p data-testid="inventory-unavailable" className="mt-2 text-sm text-ink-muted">
          Inventory unavailable right now.
        </p>
      ) : entries && entries.length > 0 ? (
        <>
          <div data-testid="inventory-grid" className="mt-2 grid grid-cols-2 gap-2">
            {entries.map((e) => {
              const info = byId?.get(e.item_id)
              return (
                <ItemTile
                  key={e.item_id}
                  id={e.item_id}
                  kind="item"
                  qty={e.quantity}
                  label={info?.name}
                  // Tappable only when the catalog has this item's info to reveal.
                  onSelect={info ? () => toggle(e.item_id) : undefined}
                  expanded={openItem === e.item_id}
                  selected={openItem === e.item_id}
                />
              )
            })}
          </div>
          {openInfo && (
            <div
              data-testid={`inventory-info-${openInfo.item_id}`}
              className="mt-2 rounded-lg border border-edge bg-surface-2/50 px-3 py-2"
            >
              <div className="flex items-baseline justify-between gap-2">
                <span className="truncate text-sm text-ink">{openInfo.name}</span>
                <span className="flex shrink-0 flex-wrap justify-end gap-1.5">
                  <span className="rounded bg-surface-2 px-1.5 py-0.5 text-[10px] text-ink-muted">
                    {cap(openInfo.category)}
                  </span>
                  <span className="rounded bg-accent/15 px-1.5 py-0.5 text-[10px] text-accent">
                    {cap(openInfo.rarity)}
                  </span>
                </span>
              </div>
              {openInfo.description && (
                <p className="mt-0.5 text-[10px] text-ink-faint">{openInfo.description}</p>
              )}
              <p className="mt-1 text-[10px] text-ink-muted">
                {openInfo.stackable ? 'Stackable' : 'Not stackable'}
              </p>
            </div>
          )}
        </>
      ) : (
        <p data-testid="inventory-empty" className="mt-2 text-sm text-ink-faint">
          No items yet — hunt pirates to salvage materials.
        </p>
      )}
    </Card>
  )
}
