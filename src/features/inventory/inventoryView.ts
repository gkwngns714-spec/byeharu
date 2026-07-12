import { itemLabel } from '../../components/items'

// INVENTORY-PANEL (SHIP-DOSSIER slice) — PURE view model for the player-inventory grid (no
// React/DOM/fetch — the shipName.ts mold). Input is the balances Record the existing read
// already produces (modulesApi.fetchMyItemBalances — the 0039 own-row player_inventory select);
// output is the displayable entry list. Specs: tests/inventoryView.spec.ts.

export interface InventoryEntry {
  item_id: string
  quantity: number
}

/**
 * The displayable inventory: zero/negative balances dropped (a fully-spent item is not "carried"),
 * sorted by the player-facing display name (itemLabel — unknown ids degrade to title-case, never
 * crash) with the raw id as the deterministic tiebreaker.
 */
export function inventoryEntries(balances: Record<string, number>): InventoryEntry[] {
  return Object.entries(balances)
    .filter(([, quantity]) => quantity > 0)
    .map(([item_id, quantity]) => ({ item_id, quantity }))
    .sort(
      (a, b) =>
        itemLabel(a.item_id, 'item').localeCompare(itemLabel(b.item_id, 'item')) ||
        a.item_id.localeCompare(b.item_id),
    )
}
