import { test, expect } from '@playwright/test'
import { assembleLedger, type CargoTarget, type HoldTarget } from '../src/features/assets/assembleLedger'
import { NO_PRICE_HERE, totalLabel, type PriceRow } from '../src/features/assets/assetLedger'
import type { Hold } from '../src/features/inventory/hold'
import type { PortStockRow } from '../src/features/assets/assetsApi'

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// ASSETS-TAB — the ASSEMBLY, which is the part that used to be untested.
//
// assetLedger.spec.ts proves the rules ("a missing price is null"). assetsLedger.uispec.ts proves
// the screen renders them. This proves the middle: that the right pile lands in the right city,
// that the right catalogue prices it, and that nothing is counted twice. Those are the mistakes
// that would produce a WRONG number rather than a missing one — which is worse, because a wrong
// number looks exactly like a right one.
//
// Every fixture is built here. Nothing asserts a seeded catalogue or an ambient default.
// ═══════════════════════════════════════════════════════════════════════════════════════════════

const HAVEN = 'loc-haven'
const SLAG = 'loc-slag'

const ITEM_PRICES: PriceRow[] = [
  { locationId: HAVEN, refId: 'scrap', unitPrice: 5, active: true },
  { locationId: SLAG, refId: 'scrap', unitPrice: 8, active: true },
  { locationId: HAVEN, refId: 'weapon_parts', unitPrice: 15, active: true },
]
// A DIFFERENT namespace that shares the string `ore` with item_types and means something else.
const GOODS_PRICES: PriceRow[] = [
  { locationId: HAVEN, refId: 'ore', unitPrice: 16, active: true },
  { locationId: HAVEN, refId: 'textiles', unitPrice: 8, active: true },
]

const NAMES = new Map([
  [HAVEN, 'Haven'],
  [SLAG, 'Slagworks'],
])
const VOLUMES = new Map([
  ['scrap', 0.5],
  ['weapon_parts', 0.2],
  ['ore', 2],
  ['crystal', 1],
])

function base(over: Partial<Parameters<typeof assembleLedger>[0]> = {}) {
  return assembleLedger({
    stock: [],
    volumeByItem: VOLUMES,
    itemPrices: ITEM_PRICES,
    goodsPrices: GOODS_PRICES,
    holds: new Map(),
    holdTargets: [],
    cargo: [],
    nameByLocation: NAMES,
    unnamedPort: 'Unnamed port',
    ...over,
  })
}

const stock = (locationId: string, itemId: string, quantity: number, baseId = 'b1'): PortStockRow => ({
  baseId,
  locationId,
  itemId,
  quantity,
})

const hold = (over: Partial<Hold> = {}): Hold => ({
  ok: true,
  items: [],
  usedM3: 0,
  capacityM3: 250,
  freeM3: 250,
  overCapacity: false,
  ...over,
})

// ── PORT STORAGE ────────────────────────────────────────────────────────────────────────────────

test('storage lands in ITS OWN city, priced at THAT city — not pooled and not cross-priced', () => {
  const l = base({ stock: [stock(HAVEN, 'scrap', 100), stock(SLAG, 'scrap', 100, 'b2')] })
  expect(l.placeCount).toBe(2)
  const haven = l.places.find((p) => p.locationId === HAVEN)!
  const slag = l.places.find((p) => p.locationId === SLAG)!
  expect(haven.total.valued).toBe(500) // 100 x 5
  expect(slag.total.valued).toBe(800) // 100 x 8 — the same goods, worth more over there
  expect(l.total.valued).toBe(1300)
})

test('TWO BASES AT ONE PORT ARE ONE PILE — the same item is never shown or counted twice', () => {
  // A player with two bases at one port would otherwise get two "Port storage" cards in one city,
  // each with its own partial total, and the card would stop answering "how much do I have HERE".
  const l = base({ stock: [stock(HAVEN, 'scrap', 60, 'b1'), stock(HAVEN, 'scrap', 40, 'b2')] })
  expect(l.placeCount).toBe(1)
  expect(l.places[0].holdings).toHaveLength(1)
  expect(l.places[0].holdings[0].stacks).toHaveLength(1)
  expect(l.places[0].holdings[0].stacks[0].quantity).toBe(100)
  expect(l.places[0].total.valued).toBe(500) // 100 x 5, counted ONCE
})

test('an item this port does not buy lands unpriced, and drags the city total’s caveat with it', () => {
  const l = base({ stock: [stock(HAVEN, 'scrap', 100), stock(HAVEN, 'crystal', 10)] })
  const haven = l.places[0]
  expect(haven.total).toEqual({ valued: 500, pricedKinds: 1, unpricedKinds: 1 })
  expect(totalLabel(haven.total)).toBe('500 cr · 1 kind not priced here')
  const crystal = haven.holdings[0].stacks.find((s) => s.refId === 'crystal')!
  expect(crystal.stackValue).toBeNull()
  expect(crystal.unitPrice).toBeNull()
})

test('catalog volume is applied per unit; an unknown item gets 0, never an invented size', () => {
  const l = base({ stock: [stock(HAVEN, 'scrap', 100), stock(HAVEN, 'mystery', 10)] })
  const stacks = l.places[0].holdings[0].stacks
  expect(stacks.find((s) => s.refId === 'scrap')!.stackM3).toBe(50) // 100 x 0.5
  expect(stacks.find((s) => s.refId === 'mystery')!.stackM3).toBe(0)
})

test('a port whose name did not resolve keeps its OWN group and its OWN prices', () => {
  const l = base({ stock: [stock('loc-unknown', 'scrap', 10)] })
  expect(l.places[0].locationName).toBe('Unnamed port')
  expect(l.places[0].locationId).toBe('loc-unknown')
  // It is NOT merged into another city, and it is not priced off one either.
  expect(l.places[0].holdings[0].stacks[0].unitPrice).toBeNull()
})

// ── FLEET HOLDS ─────────────────────────────────────────────────────────────────────────────────

const fleetAt = (id: string, locationId: string | null, locationName: string): HoldTarget => ({
  id,
  title: `Fleet ${id}`,
  locationId,
  locationName,
})

test('a fleet’s hold lands under the city the FLEET is docked in, priced there', () => {
  const l = base({
    holdTargets: [fleetAt('1', SLAG, 'Slagworks')],
    holds: new Map([
      ['1', hold({ items: [{ itemId: 'scrap', quantity: 10, volumeM3: 0.5, stackM3: 5 }], usedM3: 5 })],
    ]),
  })
  expect(l.places[0].locationId).toBe(SLAG)
  expect(l.places[0].holdings[0].kind).toBe('hold')
  expect(l.places[0].holdings[0].total.valued).toBe(80) // Slagworks' own 8/unit, not Haven's 5
})

test('A FLEET NOT AT A PORT IS PRICED AT NOTHING — and never at some other city’s price', () => {
  const l = base({
    holdTargets: [fleetAt('9', null, 'Not at a port')],
    holds: new Map([
      ['9', hold({ items: [{ itemId: 'scrap', quantity: 1000, volumeM3: 0.5, stackM3: 500 }], usedM3: 500 })],
    ]),
  })
  expect(l.places[0].locationId).toBeNull()
  expect(l.places[0].total).toEqual({ valued: 0, pricedKinds: 0, unpricedKinds: 1 })
  expect(totalLabel(l.places[0].total)).toBe('No prices here · 1 kind')
})

test('THE SERVER’S OWN CAPACITY NUMBERS RIDE THROUGH UNTOUCHED — none is recomputed', () => {
  const l = base({
    holdTargets: [fleetAt('1', HAVEN, 'Haven')],
    holds: new Map([
      [
        '1',
        hold({
          items: [{ itemId: 'scrap', quantity: 10, volumeM3: 0.5, stackM3: 5 }],
          usedM3: 300,
          capacityM3: 250,
          overCapacity: true,
        }),
      ],
    ]),
  })
  // usedM3 is 300 even though the stacks only add to 5 — the server said 300, so it says 300. A
  // client that recomputed occupancy from the stacks would quietly contradict the server here.
  expect(l.places[0].holdings[0].capacity).toEqual({
    usedM3: 300,
    capacityM3: 250,
    overCapacity: true,
  })
})

test('an EMPTY or unreadable hold produces no card at all — never an empty pile', () => {
  const l = base({
    holdTargets: [fleetAt('1', HAVEN, 'Haven'), fleetAt('2', HAVEN, 'Haven')],
    holds: new Map([
      ['1', hold({ items: [] })],
      ['2', { ...hold(), ok: false }],
    ]),
  })
  expect(l.places).toEqual([])
})

test('a fleet whose hold was never read is simply absent — not rendered as empty', () => {
  const l = base({ holdTargets: [fleetAt('1', HAVEN, 'Haven')], holds: new Map() })
  expect(l.places).toEqual([])
})

test('storage and a hold in the SAME city share one card, as two piles', () => {
  const l = base({
    stock: [stock(HAVEN, 'scrap', 100)],
    holdTargets: [fleetAt('1', HAVEN, 'Haven')],
    holds: new Map([
      ['1', hold({ items: [{ itemId: 'scrap', quantity: 20, volumeM3: 0.5, stackM3: 10 }], usedM3: 10 })],
    ]),
  })
  expect(l.placeCount).toBe(1)
  expect(l.places[0].holdings.map((h) => h.kind)).toEqual(['storage', 'hold'])
  expect(l.places[0].total.valued).toBe(600) // 500 + 100 — both at Haven's price
})

// ── TRADE CARGO, AND THE NAMESPACE THAT LOOKS LIKE A MATCH ──────────────────────────────────────

const cargoAt = (
  shipId: string,
  locationId: string | null,
  locationName: string,
  lots: CargoTarget['lots'],
): CargoTarget => ({ shipId, shipName: `Ship ${shipId}`, locationId, locationName, lots })

test('trade cargo is priced off the GOODS catalogue, at the port its ship stands in', () => {
  const l = base({
    cargo: [cargoAt('s1', HAVEN, 'Haven', [{ goodId: 'textiles', qty: 10, unitVolumeM3: 0.25 }])],
  })
  expect(l.places[0].holdings[0].kind).toBe('cargo')
  expect(l.places[0].total.valued).toBe(80) // 10 x 8
})

test('THE `ore` TRAP: the item catalogue never prices a trade good, and vice versa', () => {
  // `ore` exists in BOTH namespaces and means different things. The goods catalogue prices it (16);
  // the item catalogue does not price it at all. An assembler that shared one index would silently
  // value held ITEM ore at the trade-good price — a fabricated number that looks entirely real.
  const l = base({
    stock: [stock(HAVEN, 'ore', 100)], // an ITEM. Priced by nothing.
    cargo: [cargoAt('s1', HAVEN, 'Haven', [{ goodId: 'ore', qty: 100, unitVolumeM3: 1 }])], // a GOOD.
  })
  const haven = l.places[0]
  const storage = haven.holdings.find((h) => h.kind === 'storage')!
  const cargo = haven.holdings.find((h) => h.kind === 'cargo')!
  // Same string, two answers — because they are two different things.
  expect(storage.stacks[0].unitPrice).toBeNull()
  expect(storage.stacks[0].stackValue).toBeNull()
  expect(cargo.stacks[0].unitPrice).toBe(16)
  expect(cargo.stacks[0].stackValue).toBe(1600)
  // The city total carries the priced half AND says the other half is missing.
  expect(haven.total).toEqual({ valued: 1600, pricedKinds: 1, unpricedKinds: 1 })
})

test('multiple lots of one good on one ship are summed into a single stack', () => {
  const l = base({
    cargo: [
      cargoAt('s1', HAVEN, 'Haven', [
        { goodId: 'textiles', qty: 10, unitVolumeM3: 0.25 },
        { goodId: 'textiles', qty: 5, unitVolumeM3: 0.25 },
      ]),
    ],
  })
  const stacks = l.places[0].holdings[0].stacks
  expect(stacks).toHaveLength(1)
  expect(stacks[0].quantity).toBe(15)
  expect(stacks[0].stackValue).toBe(120) // 15 x 8
})

test('cargo on a ship in deep space is unpriced, exactly like a hold there', () => {
  const l = base({
    cargo: [cargoAt('s1', null, 'Not at a port', [{ goodId: 'textiles', qty: 10, unitVolumeM3: 0.25 }])],
  })
  expect(l.places[0].locationId).toBeNull()
  expect(l.places[0].holdings[0].stacks[0].stackValue).toBeNull()
})

// ── THE WHOLE PICTURE ───────────────────────────────────────────────────────────────────────────

test('nothing owned anywhere assembles to an empty ledger, not to a zero', () => {
  const l = base()
  expect(l.places).toEqual([])
  expect(l.total).toEqual({ valued: 0, pricedKinds: 0, unpricedKinds: 0 })
})

test('UNREADABLE PRICE CATALOGUES VALUE NOTHING — and value it as unknown, not as zero', () => {
  // Both catalogues arrive EMPTY, which is what a failed read looks like to the assembler.
  const l = base({
    stock: [stock(HAVEN, 'scrap', 100)],
    itemPrices: [],
    goodsPrices: [],
  })
  const stackValue = l.places[0].holdings[0].stacks[0]
  expect(stackValue.stackValue).toBeNull()
  expect(l.total).toEqual({ valued: 0, pricedKinds: 0, unpricedKinds: 1 })
  expect(totalLabel(l.total)).toBe(`No prices here · 1 kind`)
  expect(totalLabel(l.total)).not.toContain('0 cr')
  // The quantity is still the truth — the goods are there, only the value is unknown.
  expect(stackValue.quantity).toBe(100)
})

test('a realistic ledger orders cities by value with "not at a port" last', () => {
  const l = base({
    stock: [stock(HAVEN, 'scrap', 100), stock(SLAG, 'scrap', 100, 'b2')],
    holdTargets: [fleetAt('9', null, 'Not at a port')],
    holds: new Map([
      ['9', hold({ items: [{ itemId: 'scrap', quantity: 5000, volumeM3: 0.5, stackM3: 2500 }] })],
    ]),
  })
  expect(l.places.map((p) => p.locationName)).toEqual(['Slagworks', 'Haven', 'Not at a port'])
  expect(l.total).toEqual({ valued: 1300, pricedKinds: 2, unpricedKinds: 1 })
})

test('the no-price wording the screen shows is the one this module produced — one vocabulary', () => {
  const l = base({ stock: [stock(HAVEN, 'crystal', 10)] })
  const s = l.places[0].holdings[0].stacks[0]
  expect(s.stackValue).toBeNull()
  // The screen renders NO_PRICE_HERE for exactly this shape; pinning the link so a future edit to
  // one cannot drift from the other.
  expect(NO_PRICE_HERE).toBe('No price here')
})
