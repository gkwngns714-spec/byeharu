import {
  buildLedger,
  buildPriceIndex,
  makeHolding,
  priceAt,
  valueStack,
  type AssetLedger,
  type Holding,
  type PriceRow,
} from '../../src/features/assets/assetLedger'

// ASSETS-TAB — fixtures for the rendered ledger proof. Every one is BUILT HERE, so no assertion in
// assetsLedger.uispec.ts depends on a seeded catalogue, a live price, or any ambient default. They
// are SHAPED like production (measured read-only 2026-08-04) so the proof exercises the coverage
// the owner will actually meet on day one, but the numbers are the fixture's own.

const HAVEN = 'loc-haven'
const SLAG = 'loc-slag'

/** The item price list (port_item_demand): the same item at a different price in each city, one
 *  item priced in only one of them, and two items priced nowhere at all. */
const ITEM_PRICES: PriceRow[] = [
  { locationId: HAVEN, refId: 'scrap', unitPrice: 5, active: true },
  { locationId: SLAG, refId: 'scrap', unitPrice: 8, active: true },
  { locationId: HAVEN, refId: 'weapon_parts', unitPrice: 13, active: true },
  // scan_data: the port genuinely pays nothing. Zero is a PRICE, not a missing one.
  { locationId: HAVEN, refId: 'scan_data', unitPrice: 0, active: true },
  // crystal + ore: priced by no port anywhere. (`ore` is priced in market_offers, but that
  // catalogue prices trade_goods — a different namespace that merely shares the string.)
]

const idx = buildPriceIndex(ITEM_PRICES)

function stack(location: string | null, refId: string, quantity: number, volumeM3 = 0.5) {
  return valueStack({ refId, quantity, volumeM3, unitPrice: priceAt(idx, location, refId) })
}

function placed(locationId: string | null, locationName: string, holding: Holding) {
  return { ...holding, locationId, locationName }
}

/** The realistic ledger: two cities, a hold, and a fleet stranded in deep space. */
export function mixedLedger(): AssetLedger {
  return buildLedger([
    placed(
      HAVEN,
      'Haven Reach',
      makeHolding('storage', 'storage-haven', 'Port storage', [
        stack(HAVEN, 'scrap', 126), // 630
        stack(HAVEN, 'weapon_parts', 31), // 403
        stack(HAVEN, 'crystal', 367, 1), // NO PRICE
        stack(HAVEN, 'ore', 370, 2), // NO PRICE
        stack(HAVEN, 'scan_data', 40, 0.01), // 0 — a real price
      ]),
    ),
    placed(HAVEN, 'Haven Reach', {
      ...makeHolding('hold', 'hold-fleet1', 'Fleet 1 — carrying', [stack(HAVEN, 'scrap', 20)]),
      capacity: { usedM3: 10, capacityM3: 250, overCapacity: false },
    }),
    placed(
      SLAG,
      'Slagworks',
      makeHolding('storage', 'storage-slag', 'Port storage', [
        stack(SLAG, 'scrap', 200), // 1600 — the SAME item, this city's own price
      ]),
    ),
    placed(null, 'Not at a port', {
      ...makeHolding('hold', 'hold-fleet9', 'Fleet 9 — carrying', [stack(null, 'scrap', 1000)]),
      capacity: { usedM3: 500, capacityM3: 250, overCapacity: true },
    }),
  ])
}

/** A ledger in which NOTHING can be priced — the state the "never show 0" rule is really about. */
export function unpricedLedger(): AssetLedger {
  return buildLedger([
    placed(
      SLAG,
      'Slagworks',
      makeHolding('storage', 'storage-slag', 'Port storage', [
        stack(SLAG, 'crystal', 367, 1),
        stack(SLAG, 'weapon_parts', 31),
      ]),
    ),
  ])
}

/** A ledger in which everything IS priced — the caveat must then be absent, not merely quiet. */
export function fullyPricedLedger(): AssetLedger {
  return buildLedger([
    placed(
      HAVEN,
      'Haven Reach',
      makeHolding('storage', 'storage-haven', 'Port storage', [stack(HAVEN, 'scrap', 100)]),
    ),
  ])
}

/** Nothing owned anywhere. */
export function emptyLedger(): AssetLedger {
  return buildLedger([])
}
