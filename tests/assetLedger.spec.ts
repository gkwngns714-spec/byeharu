import { test, expect } from '@playwright/test'
import {
  EMPTY_TOTAL,
  NO_PRICE_HERE,
  buildLedger,
  buildPriceIndex,
  formatValue,
  makeHolding,
  orderStacks,
  priceAt,
  stackValueLabel,
  sumTotals,
  totalIsPartial,
  totalLabel,
  totalParts,
  totalStacks,
  unitPriceLabel,
  valueStack,
  type Holding,
  type PriceRow,
  type ValuedStack,
} from '../src/features/assets/assetLedger'

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// ASSETS-TAB — the proof that the ledger NEVER INVENTS A VALUATION.
//
// The owner asked for a screen that tells them what they own and what it is worth. The worst
// possible defect in that screen is not a missing feature — it is a number that looks real and
// is not, because a fabricated valuation is indistinguishable from a measured one and they will
// act on it. So the load-bearing properties, proven below over a table of coverage cases, are:
//
//   1. an item with no offer renders as words ("No price here") — NEVER as 0, and never as any
//      numeral at all;
//   2. a total never silently includes an unpriced stack, and never claims to be complete when it
//      is not;
//   3. the SAME item in two cities values at each city's OWN price — no global price, no average,
//      no nearest-port fallback;
//   4. a price of exactly ZERO is a real price and stays distinguishable from "no price".
//
// PRECONDITIONS ARE SET HERE, NEVER ASSUMED. Every fixture below is built by the test — nothing
// asserts a seeded catalogue, a live price, or an ambient default, so none of these can go red
// because production changed. The prod numbers quoted in comments are context for the reader, not
// inputs to an assertion.
// ═══════════════════════════════════════════════════════════════════════════════════════════════

const HAVEN = 'loc-haven'
const SLAG = 'loc-slag'
const DRIFT = 'loc-drift'

/** The ITEM price catalogue (port_item_demand). Shaped like prod 2026-08-04, where the same item
 *  really does carry a different price at each of the three ports. */
const ITEM_PRICES: PriceRow[] = [
  { locationId: HAVEN, refId: 'scrap', unitPrice: 5, active: true },
  { locationId: SLAG, refId: 'scrap', unitPrice: 8, active: true },
  { locationId: DRIFT, refId: 'scrap', unitPrice: 6, active: true },
  { locationId: HAVEN, refId: 'weapon_parts', unitPrice: 13, active: true },
  // A genuinely FREE-to-the-port item: 0 is a price, not a missing one.
  { locationId: SLAG, refId: 'scan_data', unitPrice: 0, active: true },
  // An INACTIVE row is not a price at all.
  { locationId: HAVEN, refId: 'crystal', unitPrice: 99, active: false },
]

// ── 1. THE PRICE LOOKUP ─────────────────────────────────────────────────────────────────────────

test('a priced item at a priced port returns that port’s number', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  expect(priceAt(idx, HAVEN, 'scrap')).toBe(5)
})

test('THE SAME ITEM IN TWO CITIES VALUES AT EACH CITY’S OWN PRICE — never one global number', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  expect(priceAt(idx, HAVEN, 'scrap')).toBe(5)
  expect(priceAt(idx, SLAG, 'scrap')).toBe(8)
  expect(priceAt(idx, DRIFT, 'scrap')).toBe(6)
  // …and the ledger built over the same index carries all three side by side, unreconciled.
  const at = (loc: string) =>
    valueStack({ refId: 'scrap', quantity: 10, volumeM3: 0.5, unitPrice: priceAt(idx, loc, 'scrap') })
  expect([at(HAVEN).stackValue, at(SLAG).stackValue, at(DRIFT).stackValue]).toEqual([50, 80, 60])
})

test('a price of ZERO is a real price and is NOT confused with no price', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  const zero = priceAt(idx, SLAG, 'scan_data')
  expect(zero).toBe(0)
  expect(zero).not.toBeNull()
  const stack = valueStack({ refId: 'scan_data', quantity: 7, volumeM3: 0.01, unitPrice: zero })
  expect(stack.stackValue).toBe(0)
  // It renders as a number — the port really does pay nothing — and NOT as the no-price wording.
  expect(stackValueLabel(stack)).toBe('0 cr')
  expect(stackValueLabel(stack)).not.toBe(NO_PRICE_HERE)
  // A zero-priced stack still COUNTS as priced: the total is complete, not partial.
  expect(totalStacks([stack])).toEqual({ valued: 0, pricedKinds: 1, unpricedKinds: 0 })
  expect(totalIsPartial(totalStacks([stack]))).toBe(false)
})

test('an INACTIVE offer is not a price — the ledger will not quote what the port would refuse', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  expect(priceAt(idx, HAVEN, 'crystal')).toBeNull()
})

test('a port that does not buy this at all has NO price — null, never 0', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  expect(priceAt(idx, SLAG, 'weapon_parts')).toBeNull()
  expect(priceAt(idx, DRIFT, 'weapon_parts')).toBeNull()
})

test('NO NEAREST-PORT FALLBACK: a price at one city never leaks into another', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  // weapon_parts is priced at Haven and nowhere else. The other two ports stay null — the lookup
  // has no code path that could reach across cities, and this pins that.
  expect(priceAt(idx, HAVEN, 'weapon_parts')).toBe(13)
  expect(priceAt(idx, SLAG, 'weapon_parts')).toBeNull()
})

test('NO PORT UNDER YOU MEANS NO PRICE: a null location prices nothing (a fleet in deep space)', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  expect(priceAt(idx, null, 'scrap')).toBeNull()
})

test('a malformed or negative price is dropped, never rendered as a valuation', () => {
  const idx = buildPriceIndex([
    { locationId: HAVEN, refId: 'a', unitPrice: Number.NaN, active: true },
    { locationId: HAVEN, refId: 'b', unitPrice: Number.POSITIVE_INFINITY, active: true },
    { locationId: HAVEN, refId: 'c', unitPrice: -5, active: true },
  ])
  expect(priceAt(idx, HAVEN, 'a')).toBeNull()
  expect(priceAt(idx, HAVEN, 'b')).toBeNull()
  expect(priceAt(idx, HAVEN, 'c')).toBeNull()
})

test('a duplicate (port, item) is resolved deterministically — the first row wins, not row order luck', () => {
  const idx = buildPriceIndex([
    { locationId: HAVEN, refId: 'scrap', unitPrice: 5, active: true },
    { locationId: HAVEN, refId: 'scrap', unitPrice: 500, active: true },
  ])
  expect(priceAt(idx, HAVEN, 'scrap')).toBe(5)
})

// ── 2. THE COVERAGE TABLE — every shape a held stack can be in ──────────────────────────────────

interface CoverageCase {
  name: string
  location: string | null
  refId: string
  quantity: number
  expectUnitPrice: number | null
  expectStackValue: number | null
  expectValueLabel: string
  expectPriceLabel: string
}

// The six item kinds actually held in production on 2026-08-04, plus the two edge prices. Four of
// the six are priced by port_item_demand; `crystal` and `ore` are priced by NOTHING (ore appears in
// market_offers, but that catalogue prices trade_goods — a DIFFERENT namespace that merely shares
// the string, so it must not be reached for here). The table encodes that reality as behaviour.
const COVERAGE: CoverageCase[] = [
  {
    name: 'priced here — a real valuation',
    location: HAVEN,
    refId: 'scrap',
    quantity: 100,
    expectUnitPrice: 5,
    expectStackValue: 500,
    expectValueLabel: '500 cr',
    expectPriceLabel: '5 cr each',
  },
  {
    name: 'priced here, different city, different number',
    location: SLAG,
    refId: 'scrap',
    quantity: 100,
    expectUnitPrice: 8,
    expectStackValue: 800,
    expectValueLabel: '800 cr',
    expectPriceLabel: '8 cr each',
  },
  {
    name: 'this port does not buy it — NO PRICE, never 0',
    location: SLAG,
    refId: 'weapon_parts',
    quantity: 31,
    expectUnitPrice: null,
    expectStackValue: null,
    expectValueLabel: NO_PRICE_HERE,
    expectPriceLabel: NO_PRICE_HERE,
  },
  {
    name: 'nobody anywhere buys it (crystal) — NO PRICE, never 0',
    location: HAVEN,
    refId: 'crystal',
    quantity: 367,
    expectUnitPrice: null,
    expectStackValue: null,
    expectValueLabel: NO_PRICE_HERE,
    expectPriceLabel: NO_PRICE_HERE,
  },
  {
    name: 'an ITEM whose id also names a TRADE GOOD (ore) is NOT priced off the goods catalogue',
    location: HAVEN,
    refId: 'ore',
    quantity: 370,
    expectUnitPrice: null,
    expectStackValue: null,
    expectValueLabel: NO_PRICE_HERE,
    expectPriceLabel: NO_PRICE_HERE,
  },
  {
    name: 'not at a port at all — NO PRICE, never 0',
    location: null,
    refId: 'scrap',
    quantity: 12,
    expectUnitPrice: null,
    expectStackValue: null,
    expectValueLabel: NO_PRICE_HERE,
    expectPriceLabel: NO_PRICE_HERE,
  },
  {
    name: 'the port pays literally zero — that IS a price',
    location: SLAG,
    refId: 'scan_data',
    quantity: 40,
    expectUnitPrice: 0,
    expectStackValue: 0,
    expectValueLabel: '0 cr',
    expectPriceLabel: '0 cr each',
  },
]

for (const c of COVERAGE) {
  test(`COVERAGE — ${c.name}`, () => {
    const idx = buildPriceIndex(ITEM_PRICES)
    const stack = valueStack({
      refId: c.refId,
      quantity: c.quantity,
      volumeM3: 0.5,
      unitPrice: priceAt(idx, c.location, c.refId),
    })
    expect(stack.unitPrice).toBe(c.expectUnitPrice)
    expect(stack.stackValue).toBe(c.expectStackValue)
    expect(stackValueLabel(stack)).toBe(c.expectValueLabel)
    expect(unitPriceLabel(stack)).toBe(c.expectPriceLabel)
    // THE HARD ONE: an unpriced stack must not render ANY digit. Not "0", not "0 cr", not "—0".
    if (c.expectStackValue === null) {
      expect(stackValueLabel(stack)).not.toMatch(/\d/)
      expect(unitPriceLabel(stack)).not.toMatch(/\d/)
    }
  })
}

// ── 3. TOTALS THAT CANNOT LIE ABOUT WHAT THEY LEFT OUT ──────────────────────────────────────────

/** Build the mixed pile the coverage table describes: two priced, two not. */
function mixedStacks(): ValuedStack[] {
  const idx = buildPriceIndex(ITEM_PRICES)
  const at = (loc: string | null, refId: string, qty: number) =>
    valueStack({ refId, quantity: qty, volumeM3: 0.5, unitPrice: priceAt(idx, loc, refId) })
  return [
    at(HAVEN, 'scrap', 100), // 500
    at(HAVEN, 'weapon_parts', 10), // 130
    at(HAVEN, 'crystal', 367), // no price
    at(HAVEN, 'ore', 370), // no price
  ]
}

test('A TOTAL NEVER SILENTLY ABSORBS AN UNPRICED STACK', () => {
  const total = totalStacks(mixedStacks())
  // 500 + 130 only. The two unpriced stacks contributed NOTHING — not zero-added, simply not summed.
  expect(total.valued).toBe(630)
  expect(total.pricedKinds).toBe(2)
  expect(total.unpricedKinds).toBe(2)
})

test('A TOTAL NEVER CLAIMS TO BE COMPLETE WHEN IT IS NOT — the caveat is part of the string', () => {
  const total = totalStacks(mixedStacks())
  expect(totalIsPartial(total)).toBe(true)
  expect(totalLabel(total)).toBe('630 cr · 2 kinds not priced here')
  // There is no way to render the bare number: the label function is the only formatter, and it
  // has no argument that suppresses the caveat.
  expect(totalLabel(total)).not.toBe('630 cr')
})

test('a fully priced total says so plainly, with no caveat noise', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  const total = totalStacks([
    valueStack({ refId: 'scrap', quantity: 100, volumeM3: 0.5, unitPrice: priceAt(idx, HAVEN, 'scrap') }),
  ])
  expect(totalIsPartial(total)).toBe(false)
  expect(totalLabel(total)).toBe('500 cr')
})

test('A PILE WITH NOTHING PRICED SAYS "NO PRICES HERE" — it does NOT say "0 cr"', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  const total = totalStacks([
    valueStack({ refId: 'crystal', quantity: 5, volumeM3: 1, unitPrice: priceAt(idx, HAVEN, 'crystal') }),
    valueStack({ refId: 'ore', quantity: 5, volumeM3: 2, unitPrice: priceAt(idx, HAVEN, 'ore') }),
    valueStack({ refId: 'nothing', quantity: 5, volumeM3: 1, unitPrice: priceAt(idx, HAVEN, 'nothing') }),
  ])
  expect(total.valued).toBe(0)
  expect(total.pricedKinds).toBe(0)
  expect(totalLabel(total)).toBe('No prices here · 3 kinds')
  expect(totalLabel(total)).not.toContain('0 cr')
})

test('the caveat is singular for one kind and plural for more — it reads as English, not a counter', () => {
  expect(totalLabel({ valued: 10, pricedKinds: 1, unpricedKinds: 1 })).toBe('10 cr · 1 kind not priced here')
  expect(totalLabel({ valued: 10, pricedKinds: 1, unpricedKinds: 2 })).toBe('10 cr · 2 kinds not priced here')
  expect(totalLabel({ valued: 0, pricedKinds: 0, unpricedKinds: 1 })).toBe('No prices here · 1 kind')
})

test('totalParts splits the same answer in two WITHOUT making the caveat optional', () => {
  // The layout needs the number and the caveat on separate lines on a 320px phone. Splitting them
  // must not create a way to render the number alone, so the caveat is a REQUIRED field of the
  // result — present as a string when there is one, explicitly null when there is not.
  expect(totalParts({ valued: 630, pricedKinds: 2, unpricedKinds: 2 })).toEqual({
    value: '630 cr',
    caveat: '2 kinds not priced here',
  })
  expect(totalParts({ valued: 500, pricedKinds: 1, unpricedKinds: 0 })).toEqual({
    value: '500 cr',
    caveat: null,
  })
  expect(totalParts({ valued: 0, pricedKinds: 0, unpricedKinds: 3 })).toEqual({
    value: 'No prices here',
    caveat: '3 kinds',
  })
  // Singular reads as English here too.
  expect(totalParts({ valued: 10, pricedKinds: 1, unpricedKinds: 1 }).caveat).toBe(
    '1 kind not priced here',
  )
})

test('totalParts agrees with totalLabel — two renderings, one answer, never a third', () => {
  const cases = [
    { valued: 630, pricedKinds: 2, unpricedKinds: 2 },
    { valued: 500, pricedKinds: 1, unpricedKinds: 0 },
    { valued: 0, pricedKinds: 0, unpricedKinds: 3 },
    { valued: 0, pricedKinds: 1, unpricedKinds: 0 },
  ]
  for (const t of cases) {
    const { value, caveat } = totalParts(t)
    // The one-line label is exactly the two pieces joined — so a reader of either sees the same
    // facts, and a future edit to one that forgets the other fails here.
    expect(totalLabel(t)).toBe(caveat === null ? value : `${value} · ${caveat}`)
    // And the caveat is present exactly when the total is partial.
    expect(caveat !== null).toBe(totalIsPartial(t))
  }
})

test('an unpriced total NEVER renders a digit as its value, in either rendering', () => {
  const t = { valued: 0, pricedKinds: 0, unpricedKinds: 2 }
  expect(totalParts(t).value).not.toMatch(/\d/)
  expect(totalLabel(t)).not.toContain('0 cr')
})

test('combining totals keeps the caveat — a grand total cannot launder a missing price', () => {
  const priced = { valued: 500, pricedKinds: 1, unpricedKinds: 0 }
  const partial = { valued: 130, pricedKinds: 1, unpricedKinds: 2 }
  const sum = sumTotals([priced, partial])
  expect(sum).toEqual({ valued: 630, pricedKinds: 2, unpricedKinds: 2 })
  expect(totalIsPartial(sum)).toBe(true)
  // Summing a partial into a complete one must never produce a complete-looking answer.
  expect(totalLabel(sum)).toContain('not priced here')
})

test('summing nothing is the empty total, not a claim about anything', () => {
  expect(sumTotals([])).toEqual(EMPTY_TOTAL)
  expect(totalStacks([])).toEqual(EMPTY_TOTAL)
  expect(totalIsPartial(EMPTY_TOTAL)).toBe(false)
  expect(totalLabel(EMPTY_TOTAL)).toBe('0 cr')
})

// ── 4. STACK HYGIENE ────────────────────────────────────────────────────────────────────────────

test('a spent stack is not held — zero and negative quantities drop out of the display list', () => {
  const stacks = [
    valueStack({ refId: 'scrap', quantity: 0, volumeM3: 0.5, unitPrice: 5 }),
    valueStack({ refId: 'ore', quantity: -3, volumeM3: 2, unitPrice: 5 }),
    valueStack({ refId: 'crystal', quantity: 2, volumeM3: 1, unitPrice: null }),
  ]
  expect(orderStacks(stacks).map((s) => s.refId)).toEqual(['crystal'])
})

test('stack volume is quantity × the catalog unit volume, and a missing volume is 0 not invented', () => {
  expect(valueStack({ refId: 'x', quantity: 4, volumeM3: 0.25, unitPrice: null }).stackM3).toBe(1)
  expect(valueStack({ refId: 'x', quantity: 4, volumeM3: 0, unitPrice: null }).stackM3).toBe(0)
  expect(valueStack({ refId: 'x', quantity: 4, volumeM3: Number.NaN, unitPrice: null }).stackM3).toBe(0)
})

test('ordering is by display name with the id as a deterministic tiebreaker, locale-pinned', () => {
  const s = (refId: string) => valueStack({ refId, quantity: 1, volumeM3: 1, unitPrice: null })
  const ordered = orderStacks([s('weapon_parts'), s('crystal'), s('ore'), s('scrap')])
  // itemLabel title-cases unknown ids, so the order is by the words the player actually sees.
  expect(ordered.map((x) => x.label)).toEqual(['Crystal', 'Ore', 'Scrap', 'Weapon Parts'])
})

// ── 5. THE LEDGER: GROUPED BY CITY, WITH "NOWHERE" LAST ─────────────────────────────────────────

function placed(
  locationId: string | null,
  locationName: string,
  holding: Holding,
): Holding & { locationId: string | null; locationName: string } {
  return { ...holding, locationId, locationName }
}

test('holdings collapse into one entry per CITY — location is the top-level grouping', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  const scrapAt = (loc: string, qty: number) =>
    valueStack({ refId: 'scrap', quantity: qty, volumeM3: 0.5, unitPrice: priceAt(idx, loc, 'scrap') })
  const ledger = buildLedger([
    placed(HAVEN, 'Haven Reach', makeHolding('storage', 's1', 'Port storage', [scrapAt(HAVEN, 100)])),
    placed(HAVEN, 'Haven Reach', makeHolding('hold', 'h1', 'Fleet 1 — carrying', [scrapAt(HAVEN, 10)])),
    placed(SLAG, 'Slagworks', makeHolding('storage', 's2', 'Port storage', [scrapAt(SLAG, 100)])),
  ])
  expect(ledger.placeCount).toBe(2)
  expect(ledger.places.map((p) => p.locationName)).toEqual(['Slagworks', 'Haven Reach'])
  // Slagworks first because it is worth more (800 > 550) — the answer to "where is my stuff" leads.
  expect(ledger.places[0].total.valued).toBe(800)
  expect(ledger.places[1].total.valued).toBe(550)
  expect(ledger.places[1].holdings).toHaveLength(2)
  expect(ledger.total.valued).toBe(1350)
})

test('"NOT AT A PORT" ALWAYS SORTS LAST — the unpriceable group never heads the ledger', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  const ledger = buildLedger([
    placed(
      null,
      'Not at a port',
      makeHolding('hold', 'h9', 'Fleet 9 — carrying', [
        valueStack({ refId: 'scrap', quantity: 1000, volumeM3: 0.5, unitPrice: priceAt(idx, null, 'scrap') }),
      ]),
    ),
    placed(
      HAVEN,
      'Haven Reach',
      makeHolding('storage', 's1', 'Port storage', [
        valueStack({ refId: 'scrap', quantity: 1, volumeM3: 0.5, unitPrice: priceAt(idx, HAVEN, 'scrap') }),
      ]),
    ),
  ])
  // The nowhere group holds 1000 units and the port holds 1 — yet the PORT leads, because nothing
  // in the nowhere group can be valued and a valueless group at the top would read as "you own
  // nothing worth anything".
  expect(ledger.places.map((p) => p.locationId)).toEqual([HAVEN, null])
  expect(ledger.places[1].total).toEqual({ valued: 0, pricedKinds: 0, unpricedKinds: 1 })
  expect(totalLabel(ledger.places[1].total)).toBe('No prices here · 1 kind')
})

test('the grand total over a mixed ledger stays partial and stays honest', () => {
  const idx = buildPriceIndex(ITEM_PRICES)
  const ledger = buildLedger([
    placed(
      HAVEN,
      'Haven Reach',
      makeHolding('storage', 's1', 'Port storage', [
        valueStack({ refId: 'scrap', quantity: 100, volumeM3: 0.5, unitPrice: priceAt(idx, HAVEN, 'scrap') }),
        valueStack({ refId: 'crystal', quantity: 367, volumeM3: 1, unitPrice: priceAt(idx, HAVEN, 'crystal') }),
      ]),
    ),
  ])
  expect(ledger.total).toEqual({ valued: 500, pricedKinds: 1, unpricedKinds: 1 })
  expect(totalLabel(ledger.total)).toBe('500 cr · 1 kind not priced here')
})

test('an empty ledger is empty — it does not invent a place or a number', () => {
  const ledger = buildLedger([])
  expect(ledger.places).toEqual([])
  expect(ledger.placeCount).toBe(0)
  expect(ledger.total).toEqual(EMPTY_TOTAL)
})

test('credits are grouped and locale-pinned so the same ledger reads the same everywhere', () => {
  expect(formatValue(1234567)).toBe('1,234,567')
  expect(formatValue(0)).toBe('0')
})
