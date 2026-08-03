import { test, expect } from '@playwright/test'
import {
  HOLD_EMPTY,
  formatM3,
  holdEntries,
  holdMeter,
  maxUnitsThatFit,
  normalizeMoveQty,
  parseHold,
  stackFits,
  type Hold,
} from '../src/features/inventory/hold'
import { parseDockedStore, DOCK_STORE_EMPTY } from '../src/features/map/dockStore'
import { transferReasonMessage } from '../src/features/inventory/transferReasonMessage'

// ITEMS-HAVE-A-PLACE (0332) — pure-logic specs for the hold model, the docked-store item
// projection and the transfer reason map (no app/Supabase). These assert the CLIENT half of the
// owner's laws: items have a volume, the hold has a visible cap, over-capacity is a legal state
// that only blocks LOADING, and the surface never invents or recomputes a capacity.
// Run: `npx playwright test hold.spec.ts`.
//
// This file also carries forward every ordering property the deleted inventoryView.spec.ts owned
// (display-name sort, id tiebreak, unknown-id degradation, zero/negative dropped) — the module was
// superseded by holdEntries in this slice, and its coverage moved here rather than being lost.

const holdOf = (over: Partial<Hold> = {}): Hold => ({
  ok: true,
  items: [],
  usedM3: 0,
  capacityM3: 50,
  freeM3: 50,
  overCapacity: false,
  ...over,
})

const rawItem = (item_id: string, quantity: number, volume_m3: number) => ({
  item_id,
  quantity,
  volume_m3,
  stack_m3: quantity * volume_m3,
})

// ── parseHold — fail-closed, never invents a capacity ────────────────────────────────────────────

test('parseHold: a real ok payload sanitizes into a Hold', () => {
  const h = parseHold({
    ok: true,
    items: [rawItem('scrap', 28, 0.5), rawItem('ore', 3, 2)],
    used_m3: 20,
    capacity_m3: 50,
    free_m3: 30,
    over_capacity: false,
  })
  expect(h.ok).toBe(true)
  expect(h.items).toHaveLength(2)
  expect(h.usedM3).toBe(20)
  expect(h.capacityM3).toBe(50)
  expect(h.freeM3).toBe(30)
  expect(h.overCapacity).toBe(false)
})

test('parseHold: ok:false / null / array / garbage all collapse to HOLD_EMPTY', () => {
  for (const raw of [null, undefined, 42, 'nope', [], { ok: false, reason: 'not_authenticated' }]) {
    expect(parseHold(raw)).toEqual(HOLD_EMPTY)
  }
})

test('parseHold: a non-finite or negative capacity is refused outright, never coerced', () => {
  expect(parseHold({ ok: true, items: [], used_m3: 0, capacity_m3: Number.NaN, free_m3: 0 })).toEqual(HOLD_EMPTY)
  expect(parseHold({ ok: true, items: [], used_m3: 0, capacity_m3: Number.POSITIVE_INFINITY, free_m3: 0 })).toEqual(HOLD_EMPTY)
  expect(parseHold({ ok: true, items: [], used_m3: -1, capacity_m3: 50, free_m3: 51 })).toEqual(HOLD_EMPTY)
  expect(parseHold({ ok: true, items: [], used_m3: 0, capacity_m3: '50', free_m3: 50 })).toEqual(HOLD_EMPTY)
})

test('parseHold: a zero/absent-volume item is DROPPED, never rendered as weightless', () => {
  const h = parseHold({
    ok: true,
    items: [rawItem('scrap', 5, 0.5), rawItem('ghost', 9, 0), { item_id: 'novol', quantity: 2 }],
    used_m3: 2.5,
    capacity_m3: 50,
    free_m3: 47.5,
  })
  expect(h.items.map((i) => i.itemId)).toEqual(['scrap'])
})

test('parseHold: over_capacity comes from the SERVER, not from a client comparison', () => {
  // The server says false even though used > capacity — the server's verdict wins.
  const h = parseHold({ ok: true, items: [], used_m3: 60, capacity_m3: 50, free_m3: 0, over_capacity: false })
  expect(h.overCapacity).toBe(false)
  // Only when the key is absent does the comparison act as a fallback.
  const legacy = parseHold({ ok: true, items: [], used_m3: 60, capacity_m3: 50, free_m3: 0 })
  expect(legacy.overCapacity).toBe(true)
})

// ── holdEntries — the ordering contract carried over from inventoryView ──────────────────────────

test('holdEntries: zero and negative stacks are not carried', () => {
  const h = holdOf({
    items: [
      { itemId: 'scrap', quantity: 3, volumeM3: 0.5, stackM3: 1.5 },
      { itemId: 'crystal', quantity: 0, volumeM3: 1, stackM3: 0 },
      { itemId: 'pirate_alloy', quantity: -1, volumeM3: 0.5, stackM3: -0.5 },
    ],
  })
  expect(holdEntries(h).map((e) => e.itemId)).toEqual(['scrap'])
})

test('holdEntries: sorted by DISPLAY NAME, not by raw id', () => {
  const h = holdOf({
    items: [
      { itemId: 'weapon_parts', quantity: 1, volumeM3: 0.2, stackM3: 0.2 },
      { itemId: 'scrap', quantity: 2, volumeM3: 0.5, stackM3: 1 },
      { itemId: 'engine_parts', quantity: 3, volumeM3: 0.3, stackM3: 0.9 },
      { itemId: 'crystal', quantity: 4, volumeM3: 1, stackM3: 4 },
      { itemId: 'pirate_alloy', quantity: 5, volumeM3: 0.5, stackM3: 2.5 },
    ],
  })
  expect(holdEntries(h).map((e) => e.itemId)).toEqual([
    'crystal',
    'engine_parts',
    'pirate_alloy',
    'scrap',
    'weapon_parts',
  ])
})

test('holdEntries: an unknown item id degrades to a title-cased label and still sorts', () => {
  const h = holdOf({
    items: [
      { itemId: 'scrap', quantity: 1, volumeM3: 0.5, stackM3: 0.5 },
      { itemId: 'future_widget', quantity: 2, volumeM3: 1, stackM3: 2 },
      { itemId: 'engine_parts', quantity: 3, volumeM3: 0.3, stackM3: 0.9 },
    ],
  })
  expect(holdEntries(h).map((e) => e.itemId)).toEqual(['engine_parts', 'future_widget', 'scrap'])
})

test('holdEntries: an empty hold is an empty list, never a throw', () => {
  expect(holdEntries(HOLD_EMPTY)).toEqual([])
})

// ── holdMeter — a cap the player cannot see is a trap ────────────────────────────────────────────

test('holdMeter: a normal hold reads as a percentage with both numbers', () => {
  const m = holdMeter(holdOf({ usedM3: 22.7, capacityM3: 250, freeM3: 227.3 }))
  expect(m.label).toBe('22.7 / 250 m³')
  expect(Math.round(m.pct)).toBe(9)
  expect(m.tone).toBe('accent')
})

test('holdMeter: ZERO capacity with items — the shipless player — still gets an honest label', () => {
  const m = holdMeter(holdOf({ usedM3: 0.5, capacityM3: 0, freeM3: 0, overCapacity: true }))
  expect(m.label).toBe('0.5 / 0 m³')
  expect(m.pct).toBe(100)
  expect(m.tone).toBe('danger')
})

test('holdMeter: an empty, capacity-less hold is neutral and empty, not an error', () => {
  const m = holdMeter(HOLD_EMPTY)
  expect(m.label).toBe('0 / 0 m³')
  expect(m.pct).toBe(0)
  expect(m.tone).toBe('neutral')
})

test('holdMeter: the bar is clamped at 100 even when over capacity', () => {
  expect(holdMeter(holdOf({ usedM3: 500, capacityM3: 50, overCapacity: true })).pct).toBe(100)
})

// ── formatM3 ─────────────────────────────────────────────────────────────────────────────────────

test('formatM3: whole numbers bare, fractions trimmed, junk → 0', () => {
  expect(formatM3(250)).toBe('250')
  expect(formatM3(22.7)).toBe('22.7')
  expect(formatM3(0.05)).toBe('0.05')
  expect(formatM3(1.5)).toBe('1.5')
  expect(formatM3(Number.NaN)).toBe('0')
})

// ── stackFits / maxUnitsThatFit — DISPLAY prechecks over SERVER numbers ──────────────────────────

test('stackFits: exactly filling the hold fits; one more unit does not', () => {
  const h = holdOf({ usedM3: 48, capacityM3: 50, freeM3: 2 })
  expect(stackFits(h, 2, 1)).toBe(true)   // 48 + 2 = 50
  expect(stackFits(h, 2, 2)).toBe(false)  // 48 + 4 > 50
})

test('stackFits: a zero-capacity hold fits nothing at all', () => {
  expect(stackFits(holdOf({ usedM3: 0.5, capacityM3: 0, freeM3: 0 }), 0.5, 1)).toBe(false)
})

test('stackFits: a not-ok hold, a fractional qty and a zero volume all refuse', () => {
  expect(stackFits(HOLD_EMPTY, 1, 1)).toBe(false)
  expect(stackFits(holdOf(), 1, 1.5)).toBe(false)
  expect(stackFits(holdOf(), 0, 1)).toBe(false)
  expect(stackFits(holdOf(), 1, 0)).toBe(false)
})

test('maxUnitsThatFit: floors to whole units and never exceeds what is available', () => {
  const h = holdOf({ usedM3: 45, capacityM3: 50, freeM3: 5 })
  expect(maxUnitsThatFit(h, 2, 100)).toBe(2)   // 5 m³ free / 2 m³ = 2.5 → 2
  expect(maxUnitsThatFit(h, 2, 1)).toBe(1)     // capped by availability
  expect(maxUnitsThatFit(h, 10, 100)).toBe(0)  // nothing fits
})

test('maxUnitsThatFit: an over-capacity hold can take nothing more', () => {
  expect(maxUnitsThatFit(holdOf({ usedM3: 60, capacityM3: 50, overCapacity: true }), 0.5, 10)).toBe(0)
})

// ── normalizeMoveQty — refuse, never silently reshape ────────────────────────────────────────────

test('normalizeMoveQty: whole numbers in range pass; junk and fractions refuse', () => {
  expect(normalizeMoveQty('3', 10)).toBe(3)
  expect(normalizeMoveQty(' 7 ', 10)).toBe(7)
  expect(normalizeMoveQty('2.5', 10)).toBeNull()
  expect(normalizeMoveQty('0', 10)).toBeNull()
  expect(normalizeMoveQty('-4', 10)).toBeNull()
  expect(normalizeMoveQty('', 10)).toBeNull()
  expect(normalizeMoveQty('abc', 10)).toBeNull()
})

test('normalizeMoveQty: asking for more than you hold is capped at what you hold', () => {
  expect(normalizeMoveQty('99', 10)).toBe(10)
})

test('normalizeMoveQty: nothing available → nothing movable', () => {
  expect(normalizeMoveQty('1', 0)).toBeNull()
})

// ── parseDockedStore — the port's item projection ────────────────────────────────────────────────

test('parseDockedStore: the docked envelope carries this port items with their volumes', () => {
  const s = parseDockedStore({
    state: 'at_location',
    docked: true,
    location_id: 'loc-1',
    location_name: 'Haven',
    store_id: 'store-1',
    resources: [{ resource_code: 'metal', amount: 12 }],
    units: [{ unit_type_id: 'scout', quantity: 100 }],
    items: [rawItem('ore', 4, 2), rawItem('scrap', 10, 0.5)],
  })
  expect(s.docked).toBe(true)
  expect(s.items.map((i) => [i.itemId, i.quantity, i.volumeM3, i.stackM3])).toEqual([
    ['ore', 4, 2, 8],
    ['scrap', 10, 0.5, 5],
  ])
})

test('parseDockedStore: a payload with NO items key is an empty item list, never a crash', () => {
  const s = parseDockedStore({
    state: 'at_location',
    docked: true,
    location_id: 'loc-1',
    location_name: 'Haven',
    store_id: 'store-1',
    resources: [],
    units: [],
  })
  expect(s.items).toEqual([])
})

test('parseDockedStore: not-docked / dark envelopes stay empty — including items', () => {
  for (const state of ['disabled', 'no_main_ship', 'in_transit', 'in_space', 'incoherent_or_unavailable']) {
    expect(parseDockedStore({ state, docked: false, items: [rawItem('ore', 4, 2)] })).toEqual(DOCK_STORE_EMPTY)
  }
})

test('parseDockedStore: a weightless stored item is dropped, like in the hold', () => {
  const s = parseDockedStore({
    state: 'at_location',
    docked: true,
    location_id: 'loc-1',
    location_name: 'Haven',
    store_id: 'store-1',
    resources: [],
    units: [],
    items: [rawItem('ghost', 1, 0), rawItem('ore', 1, 2)],
  })
  expect(s.items.map((i) => i.itemId)).toEqual(['ore'])
})

// ── transferReasonMessage — every server reason has plain words; nothing leaks a raw code ────────

test('transferReasonMessage: the full 0332 reject vocabulary is mapped', () => {
  for (const reason of [
    'not_authenticated',
    'station_storage_disabled',
    'invalid_request',
    'invalid_direction',
    'invalid_item',
    'invalid_quantity',
    'ship_not_found',
    'not_docked',
    'port_has_no_storage',
    'insufficient_items',
    'insufficient_stored',
    'hold_over_capacity',
  ]) {
    const msg = transferReasonMessage(reason)
    expect(msg).not.toBe('Move unavailable.')
    // never a raw code, never a Postgres string
    expect(msg).not.toContain('_')
  }
})

test('transferReasonMessage: law 3 is stated in the player’s words', () => {
  expect(transferReasonMessage('not_docked')).toBe('Dock at the port to reach its storage.')
})

test('transferReasonMessage: the transport fallback and any unknown code degrade generically', () => {
  expect(transferReasonMessage('unavailable')).toBe('Move unavailable.')
  expect(transferReasonMessage('some_new_server_reason')).toBe('Move unavailable.')
})
