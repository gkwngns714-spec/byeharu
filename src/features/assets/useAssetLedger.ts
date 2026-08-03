import { useEffect, useMemo, useState } from 'react'
import { fetchMyHold } from '../inventory/holdApi'
import type { Hold } from '../inventory/hold'
import { fetchItemCatalog } from '../modules/modulesApi'
import type { ItemTypeRow } from '../modules/modulesTypes'
import { getPortItemDemandFor } from '../port/salvageApi'
import { getCargoLotsForShips, getMarketBuyPricesFor, type ShipCargoLot } from '../map/tradeApi'
import { fetchMyShipGroups, fetchMyShipGroupMap, type ShipGroupMapEntry } from '../command/teamApi'
import { buildTeamRoster, type GroupRow, type RosterShip } from '../command/teamRoster'
import type { FleetPosition } from '../map/mainshipApi'
import type { MapLocation } from '../map/mapTypes'
import { fetchMyPortStock, type PortStockRow } from './assetsApi'
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

// ASSETS-TAB — the React adapter that ASSEMBLES the ledger out of reads that already exist.
//
// Every fact here comes from an authority that predates this slice; nothing is re-derived:
//   · what is in a port's storage      → bases ⋈ base_items (assetsApi — the one cross-port read)
//   · what a fleet is CARRYING         → get_my_hold, composed once per FLEET (holdApi.fetchMyHold)
//   · which ships form which fleet     → buildTeamRoster over fetchMyShipGroups/…GroupMap — the
//                                        SAME fold ShipScreen and FleetScreen use, never a second
//                                        grouping implementation
//   · where a fleet/ship IS            → map.fleetPositions (already polled by the shell: 0 new reads)
//   · what an item is worth at a port  → port_item_demand (salvageApi.getPortItemDemandFor)
//   · what trade cargo is worth        → market_offers buy_price (tradeApi.getMarketBuyPricesFor)
//   · item names + unit volumes        → fetchItemCatalog (the one item_types read)
//
// ── THE HOLD IS READ PER FLEET, NOT PER SHIP ───────────────────────────────────────────────────
// `fleet_items` is keyed on the fleet (0333) and `mainship_resolve_fleet` answers for BOTH shapes —
// a grouped fleet's shared row and a lone ship's own one — so a grouped fleet has exactly ONE hold
// no matter how many ships are in it. Reading `get_my_hold` per SHIP would therefore count a
// four-ship fleet's cargo four times. So the read is issued once per fleet (one representative
// ship) plus once per genuinely ungrouped ship, which is exactly the partition buildTeamRoster
// already produces. Fan-out measured against prod 2026-08-04: 3 fleets exist game-wide and 71 of
// 77 ships are in none, i.e. a handful of calls per player, all in one Promise.all wave.
//
// ── AND IT IS PRICED WHERE IT STANDS ───────────────────────────────────────────────────────────
// A hold is priced at the port its fleet is DOCKED at. A fleet in transit or in deep space is
// priced at NOTHING — `priceAt(index, null, …)` returns null by construction, so there is no code
// path that could reach for "the nearest port's price" or a global average. That is not a
// limitation being worked around; it is the per-port law showing through.

/** Everything the screen needs, including the honest failure states. */
export interface AssetLedgerState {
  /** null while the first wave is in flight. */
  ledger: AssetLedger | null
  /** true when a read failed — the screen says so rather than showing a confident empty ledger. */
  unavailable: boolean
  /** true when prices could not be read at all: values are unknown, not zero. */
  pricesUnavailable: boolean
  /** Ships the player owns, for the summary row. */
  shipCount: number
  /** Fleets the player owns, for the summary row. */
  fleetCount: number
}

/** A fleet (or lone ship) whose hold we intend to read, and where it stands. */
interface HoldTarget {
  /** Fleet id for a grouped fleet, ship id for a lone one — the ledger row's stable key. */
  id: string
  title: string
  /** The ship the hold read is addressed to (any member; the server resolves the fleet). */
  probeShipId: string
  locationId: string | null
  locationName: string
}

/** Where a ship is, as a (port id, port name) pair the ledger can group and price by. NOT docked
 *  (in transit / deep space / hidden / unknown) → a null port, which is unpriceable BY TYPE. */
function placeOfShip(
  pos: FleetPosition | undefined,
  locationsById: ReadonlyMap<string, MapLocation>,
): { locationId: string | null; locationName: string } {
  const atPort = pos && (pos.place === 'docked' || pos.place === 'berthed') && pos.location_id
  if (!atPort) return { locationId: null, locationName: NOT_AT_A_PORT }
  const name = locationsById.get(pos.location_id as string)?.name
  // A port we hold stock at but cannot name (hidden/unreleased, or the world read has not landed)
  // still gets its own group and its own prices — the id is what the price is keyed on. It shows
  // an honest placeholder rather than being merged into some other city.
  return { locationId: pos.location_id as string, locationName: name ?? UNNAMED_PORT }
}

/** The label for holdings that are not at any port. Exported so the specs and the screen agree. */
export const NOT_AT_A_PORT = 'Not at a port'
/** The label for a port whose name has not resolved. Never blank, never another city's name. */
export const UNNAMED_PORT = 'Unnamed port'

export function useAssetLedger(
  refreshKey: string,
  fleetPositions: readonly FleetPosition[],
  locations: readonly MapLocation[],
  ships: readonly { main_ship_id: string; name: string; status: string }[],
): AssetLedgerState {
  const [stock, setStock] = useState<PortStockRow[] | null | 'error'>(null)
  const [catalog, setCatalog] = useState<ItemTypeRow[] | null>(null)
  const [itemPrices, setItemPrices] = useState<PriceRow[] | null | 'error'>(null)
  const [goodsPrices, setGoodsPrices] = useState<PriceRow[] | null | 'error'>(null)
  const [holds, setHolds] = useState<Map<string, Hold>>(new Map())
  const [lots, setLots] = useState<Array<ShipCargoLot & { main_ship_id: string }>>([])
  const [groups, setGroups] = useState<GroupRow[]>([])
  const [groupMap, setGroupMap] = useState<Record<string, ShipGroupMapEntry>>({})

  const locationsById = useMemo(() => new Map(locations.map((l) => [l.id, l])), [locations])
  const posByShip = useMemo(
    () => new Map(fleetPositions.map((p) => [p.main_ship_id, p])),
    [fleetPositions],
  )

  // ── wave 1: the facts that do not depend on knowing the fleets ────────────────────────────────
  // Keyed on a plain string so the effect cannot re-fire on every render from an unstable array
  // identity (ships/positions arrive from a poll and are new objects each tick).
  const shipKey = ships.map((s) => s.main_ship_id).join(',')

  useEffect(() => {
    let active = true
    void (async () => {
      const [s, c, g, m, l] = await Promise.all([
        fetchMyPortStock(),
        fetchItemCatalog(),
        fetchMyShipGroups(),
        fetchMyShipGroupMap(),
        getCargoLotsForShips(ships.map((sh) => sh.main_ship_id)),
      ])
      if (!active) return
      setStock(s ?? 'error')
      setCatalog(c)
      setGroups(g)
      setGroupMap(m)
      setLots(l)
    })()
    return () => {
      active = false
    }
    // shipKey stands in for `ships` (see above); refreshKey is a deliberate re-fetch trigger.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [shipKey, refreshKey])

  // ── the fleets, and where each stands (pure — no read of its own) ─────────────────────────────
  const holdTargets = useMemo<HoldTarget[]>(() => {
    const rosterShips: RosterShip[] = ships.map((s) => ({
      main_ship_id: s.main_ship_id,
      name: s.name,
      status: s.status,
      group_id: groupMap[s.main_ship_id]?.group_id ?? null,
    }))
    const { teams, ungrouped } = buildTeamRoster(groups, rosterShips)
    const targets: HoldTarget[] = []
    for (const t of teams) {
      // A fleet with no ships has no hold to read and no place to stand.
      const probe = t.ships[0]
      if (!probe) continue
      // The fleet stands where its ships stand. Members of one fleet are in one place by
      // construction (a fleet moves as one — the combat design law), so the first member's place is
      // the fleet's place; there is deliberately no reconciliation of four per-ship answers here.
      targets.push({
        id: t.group.group_id,
        title: t.group.name,
        probeShipId: probe.main_ship_id,
        ...placeOfShip(posByShip.get(probe.main_ship_id), locationsById),
      })
    }
    for (const s of ungrouped) {
      targets.push({
        id: s.main_ship_id,
        title: s.name,
        probeShipId: s.main_ship_id,
        ...placeOfShip(posByShip.get(s.main_ship_id), locationsById),
      })
    }
    return targets
  }, [ships, groups, groupMap, posByShip, locationsById])

  // ── wave 2: one hold read per fleet ───────────────────────────────────────────────────────────
  const holdKey = holdTargets.map((t) => `${t.id}:${t.probeShipId}`).join(',')
  useEffect(() => {
    let active = true
    void (async () => {
      const results = await Promise.all(
        holdTargets.map(async (t) => [t.id, await fetchMyHold(t.probeShipId)] as const),
      )
      if (!active) return
      setHolds(new Map(results))
    })()
    return () => {
      active = false
    }
    // holdKey stands in for holdTargets' identity; refreshKey is a deliberate trigger.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [holdKey, refreshKey])

  // ── wave 3: the prices, for exactly the ports something of ours sits in ───────────────────────
  // Both catalogues are read for the SAME port set and kept in SEPARATE state. They are never
  // concatenated: `port_item_demand` prices item_types, `market_offers` prices trade_goods, and the
  // two namespaces share the string `ore` while meaning different things (see assetLedger.ts).
  const portIds = useMemo(() => {
    const ids = new Set<string>()
    if (stock !== null && stock !== 'error') for (const r of stock) ids.add(r.locationId)
    for (const t of holdTargets) if (t.locationId) ids.add(t.locationId)
    for (const s of ships) {
      const p = placeOfShip(posByShip.get(s.main_ship_id), locationsById)
      if (p.locationId) ids.add(p.locationId)
    }
    return [...ids].sort()
  }, [stock, holdTargets, ships, posByShip, locationsById])

  const portKey = portIds.join(',')
  useEffect(() => {
    let active = true
    void (async () => {
      const [items, goods] = await Promise.all([
        getPortItemDemandFor(portIds),
        getMarketBuyPricesFor(portIds),
      ])
      if (!active) return
      setItemPrices(
        items === null
          ? 'error'
          : items.map((r) => ({
              locationId: r.location_id,
              refId: r.item_id,
              unitPrice: r.unit_price,
              active: true,
            })),
      )
      setGoodsPrices(
        goods === null
          ? 'error'
          : goods.map((r) => ({
              locationId: r.location_id,
              refId: r.good_id,
              unitPrice: r.buy_price,
              active: true,
            })),
      )
    })()
    return () => {
      active = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [portKey, refreshKey])

  // ── the fold ──────────────────────────────────────────────────────────────────────────────────
  return useMemo<AssetLedgerState>(() => {
    const stockRows = stock === 'error' || stock === null ? null : stock
    const itemRows = itemPrices === 'error' || itemPrices === null ? null : itemPrices
    const goodsRows = goodsPrices === 'error' || goodsPrices === null ? null : goodsPrices
    const shipCount = ships.length
    const fleetCount = groups.length

    if (stockRows === null) {
      return {
        ledger: null,
        unavailable: stock === 'error',
        pricesUnavailable: itemPrices === 'error' || goodsPrices === 'error',
        shipCount,
        fleetCount,
      }
    }

    // A price catalogue that failed to READ is an empty index, which makes every stack render
    // "No price here" — the honest answer. It must never fall back to a stale or invented number,
    // and `pricesUnavailable` tells the screen to say WHY the prices are missing.
    const itemIndex = buildPriceIndex(itemRows ?? [])
    const goodsIndex = buildPriceIndex(goodsRows ?? [])
    const volumeOf = new Map((catalog ?? []).map((c) => [c.item_id, c.volume_m3]))

    const placed: Array<Holding & { locationId: string | null; locationName: string }> = []

    // ── port storage, one holding per port ──────────────────────────────────────────────────────
    const byPort = new Map<string, PortStockRow[]>()
    for (const r of stockRows) {
      const list = byPort.get(r.locationId) ?? []
      list.push(r)
      byPort.set(r.locationId, list)
    }
    for (const [locationId, rows] of byPort) {
      // One base per port is the normal shape, but a player with two bases at one port would
      // otherwise show two piles of the same thing: sum the quantities per item first.
      const qtyByItem = new Map<string, number>()
      for (const r of rows) qtyByItem.set(r.itemId, (qtyByItem.get(r.itemId) ?? 0) + r.quantity)
      const stacks: ValuedStack[] = [...qtyByItem].map(([itemId, quantity]) =>
        valueStack({
          refId: itemId,
          quantity,
          volumeM3: volumeOf.get(itemId) ?? 0,
          unitPrice: priceAt(itemIndex, locationId, itemId),
        }),
      )
      placed.push({
        ...makeHolding('storage', `storage-${locationId}`, 'Port storage', stacks),
        locationId,
        locationName: locationsById.get(locationId)?.name ?? UNNAMED_PORT,
      })
    }

    // ── fleet holds, one holding per fleet, priced where the fleet stands ───────────────────────
    for (const t of holdTargets) {
      const hold = holds.get(t.id)
      if (!hold || !hold.ok || hold.items.length === 0) continue
      const stacks = hold.items.map((i) =>
        valueStack({
          refId: i.itemId,
          quantity: i.quantity,
          // The hold read carries its OWN volume from the same catalog the server used; prefer it
          // over the client catalog so the hold's numbers are the server's numbers.
          volumeM3: i.volumeM3,
          unitPrice: priceAt(itemIndex, t.locationId, i.itemId),
        }),
      )
      placed.push({
        ...makeHolding('hold', `hold-${t.id}`, `${t.title} — carrying`, stacks),
        // The server's own used/capacity numbers, passed through untouched.
        capacity: {
          usedM3: hold.usedM3,
          capacityM3: hold.capacityM3,
          overCapacity: hold.overCapacity,
        },
        locationId: t.locationId,
        locationName: t.locationName,
      })
    }

    // ── trade cargo, one holding per ship that carries any ──────────────────────────────────────
    const lotsByShip = new Map<string, Array<ShipCargoLot & { main_ship_id: string }>>()
    for (const l of lots) {
      const list = lotsByShip.get(l.main_ship_id) ?? []
      list.push(l)
      lotsByShip.set(l.main_ship_id, list)
    }
    for (const [shipId, shipLots] of lotsByShip) {
      const ship = ships.find((s) => s.main_ship_id === shipId)
      const place = placeOfShip(posByShip.get(shipId), locationsById)
      const qtyByGood = new Map<string, { qty: number; volume: number }>()
      for (const l of shipLots) {
        const cur = qtyByGood.get(l.good_id) ?? { qty: 0, volume: l.unit_volume_m3 }
        qtyByGood.set(l.good_id, { qty: cur.qty + l.qty, volume: l.unit_volume_m3 })
      }
      const stacks = [...qtyByGood].map(([goodId, v]) =>
        valueStack({
          refId: goodId,
          quantity: v.qty,
          volumeM3: v.volume,
          // GOODS index, never the item index — the two namespaces are not interchangeable.
          unitPrice: priceAt(goodsIndex, place.locationId, goodId),
        }),
      )
      placed.push({
        ...makeHolding('cargo', `cargo-${shipId}`, `${ship?.name ?? 'Ship'} — trade cargo`, stacks),
        ...place,
      })
    }

    return {
      ledger: buildLedger(placed.filter((h) => h.stacks.length > 0)),
      unavailable: false,
      pricesUnavailable: itemPrices === 'error' || goodsPrices === 'error',
      shipCount,
      fleetCount,
    }
  }, [
    stock,
    catalog,
    itemPrices,
    goodsPrices,
    holds,
    holdTargets,
    lots,
    groups,
    ships,
    posByShip,
    locationsById,
  ])
}
