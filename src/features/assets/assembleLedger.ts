import type { Hold } from '../inventory/hold'
import {
  buildLedger,
  buildPriceIndex,
  makeHolding,
  priceAt,
  valueStack,
  type AssetLedger,
  type Holding,
  type PriceRow,
  type ValuedStack,
} from './assetLedger'
import type { PortStockRow } from './assetsApi'

// ASSETS-TAB — the PURE assembly step: server answers in, one finished ledger out.
//
// Extracted from useAssetLedger so it can be SPECCED (tests/assembleLedger.spec.ts). The hook
// around it now does only two things — issue reads, and hand their results to this function — so
// the part that decides what the owner sees is testable without React, Supabase or a browser.
// Before the extraction, assetLedger.ts's rules were proven and the SCREEN was proven, but the
// wiring between them — which pile lands in which city, whose price is applied to it, whether two
// bases at one port double-count — was the untested middle.
//
// Nothing here reads, fetches, or decides freshness. It is a function of its arguments.

/** A fleet (or lone ship) whose hold was read, and the port it stands in. */
export interface HoldTarget {
  /** Fleet id for a grouped fleet, ship id for a lone one — the ledger row's stable key. */
  id: string
  title: string
  /** null = not at a port, and therefore unpriceable BY TYPE. */
  locationId: string | null
  locationName: string
}

/** One ship's trade cargo, already summed per good, with where that ship stands. */
export interface CargoTarget {
  shipId: string
  shipName: string
  locationId: string | null
  locationName: string
  lots: Array<{ goodId: string; qty: number; unitVolumeM3: number }>
}

export interface AssembleInput {
  /** Owner-scoped (port, item, quantity) rows from bases ⋈ base_items. */
  stock: readonly PortStockRow[]
  /** item_id → catalog unit volume. A miss is 0 — never an invented size. */
  volumeByItem: ReadonlyMap<string, number>
  /** port_item_demand rows. Prices ITEMS. */
  itemPrices: readonly PriceRow[]
  /** market_offers rows. Prices TRADE GOODS. A DIFFERENT namespace — never merged with the above. */
  goodsPrices: readonly PriceRow[]
  /** Each fleet's hold, by HoldTarget.id. */
  holds: ReadonlyMap<string, Hold>
  holdTargets: readonly HoldTarget[]
  cargo: readonly CargoTarget[]
  /** location id → display name. A miss shows the honest placeholder, never another city's name. */
  nameByLocation: ReadonlyMap<string, string>
  /** The label for a port whose name did not resolve. */
  unnamedPort: string
}

/**
 * Assemble the ledger. Every price lookup goes through `priceAt` against the catalogue that owns
 * that id namespace, and every value through `valueStack` — so the "a missing price is null, never
 * 0" rule holds here by construction rather than by care.
 *
 * Empty piles are dropped: a holding with nothing in it is not a thing the player owns, and a card
 * for it would be noise.
 */
export function assembleLedger(input: AssembleInput): AssetLedger {
  // A price catalogue that failed to read arrives EMPTY, which makes every stack "No price here" —
  // the honest answer. There is no path here that falls back to a stale or borrowed number.
  const itemIndex = buildPriceIndex(input.itemPrices)
  const goodsIndex = buildPriceIndex(input.goodsPrices)
  const placed: Array<Holding & { locationId: string | null; locationName: string }> = []
  const portName = (id: string) => input.nameByLocation.get(id) ?? input.unnamedPort

  // ── port storage, one holding per PORT ────────────────────────────────────────────────────────
  const byPort = new Map<string, PortStockRow[]>()
  for (const r of input.stock) {
    const list = byPort.get(r.locationId) ?? []
    list.push(r)
    byPort.set(r.locationId, list)
  }
  for (const [locationId, rows] of byPort) {
    // One base per port is the normal shape, but a player with TWO bases at one port would
    // otherwise show two piles of the same thing side by side, each with its own partial total.
    // Summing per item first is what makes the card answer "how much do I have HERE".
    const qtyByItem = new Map<string, number>()
    for (const r of rows) qtyByItem.set(r.itemId, (qtyByItem.get(r.itemId) ?? 0) + r.quantity)
    const stacks: ValuedStack[] = [...qtyByItem].map(([itemId, quantity]) =>
      valueStack({
        refId: itemId,
        quantity,
        volumeM3: input.volumeByItem.get(itemId) ?? 0,
        unitPrice: priceAt(itemIndex, locationId, itemId),
      }),
    )
    placed.push({
      ...makeHolding('storage', `storage-${locationId}`, 'Port storage', stacks),
      locationId,
      locationName: portName(locationId),
    })
  }

  // ── fleet holds, one per FLEET, priced where that fleet stands ────────────────────────────────
  for (const t of input.holdTargets) {
    const hold = input.holds.get(t.id)
    if (!hold || !hold.ok || hold.items.length === 0) continue
    const stacks = hold.items.map((i) =>
      valueStack({
        refId: i.itemId,
        quantity: i.quantity,
        // The hold read carries its OWN volume, from the same catalog the server measured the
        // capacity with — preferred over the client catalog so the hold's numbers are the
        // server's numbers throughout.
        volumeM3: i.volumeM3,
        unitPrice: priceAt(itemIndex, t.locationId, i.itemId),
      }),
    )
    placed.push({
      ...makeHolding('hold', `hold-${t.id}`, `${t.title} — carrying`, stacks),
      // The server's own used/capacity numbers, passed through untouched.
      capacity: { usedM3: hold.usedM3, capacityM3: hold.capacityM3, overCapacity: hold.overCapacity },
      locationId: t.locationId,
      locationName: t.locationName,
    })
  }

  // ── trade cargo, one per SHIP, priced off the GOODS catalogue ─────────────────────────────────
  for (const c of input.cargo) {
    const qtyByGood = new Map<string, { qty: number; volume: number }>()
    for (const l of c.lots) {
      const cur = qtyByGood.get(l.goodId)
      qtyByGood.set(l.goodId, {
        qty: (cur?.qty ?? 0) + l.qty,
        volume: cur?.volume ?? l.unitVolumeM3,
      })
    }
    const stacks = [...qtyByGood].map(([goodId, v]) =>
      valueStack({
        refId: goodId,
        quantity: v.qty,
        volumeM3: v.volume,
        // GOODS index. Using the ITEM index here would price a trade good off the item catalogue
        // (and vice versa) — the cross-namespace fabrication assetLedger.ts's header describes.
        unitPrice: priceAt(goodsIndex, c.locationId, goodId),
      }),
    )
    placed.push({
      ...makeHolding('cargo', `cargo-${c.shipId}`, `${c.shipName} — trade cargo`, stacks),
      locationId: c.locationId,
      locationName: c.locationName,
    })
  }

  return buildLedger(placed.filter((h) => h.stacks.length > 0))
}
