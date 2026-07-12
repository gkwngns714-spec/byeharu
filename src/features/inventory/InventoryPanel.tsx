import { useCallback, useEffect, useState } from 'react'
import { useActivityPanelGuards } from '../../lib/useActivityPanelGuards'
import { fetchMyItemBalances } from '../modules/modulesApi'
import { inventoryEntries } from './inventoryView'
import { Card, CardHeader, Skeleton } from '../../components/ui'
import { ItemTile } from '../../components/items'

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

  // Mounted guard — the shared idiom home (read-only panel: no submit guards needed).
  const { activeRef } = useActivityPanelGuards()

  const refresh = useCallback(async () => {
    const res = await fetchMyItemBalances()
    if (!activeRef.current) return
    setBalances(res ?? 'error')
  }, [activeRef]) // ref identity is stable — dep satisfies the lint rule

  // refreshKey is a deliberate re-fetch trigger (the ModulesPanel lifecycleKey dep idiom).
  useEffect(() => {
    void refresh()
  }, [refresh, refreshKey])

  const entries = balances !== null && balances !== 'error' ? inventoryEntries(balances) : null

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
        <div data-testid="inventory-grid" className="mt-2 grid grid-cols-2 gap-2">
          {entries.map((e) => (
            <ItemTile key={e.item_id} id={e.item_id} kind="item" qty={e.quantity} />
          ))}
        </div>
      ) : (
        <p data-testid="inventory-empty" className="mt-2 text-sm text-ink-faint">
          No items yet — hunt pirates to salvage materials.
        </p>
      )}
    </Card>
  )
}
