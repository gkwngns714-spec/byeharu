import { test, expect } from '@playwright/test'
import {
  aggregateCargo,
  captainsForShip,
  cargoUsedM3,
  fittedSlotsUsed,
  fittingsForShip,
  formatM3,
} from '../src/features/ship/shipDossierView'
import type { ShipFittingRow } from '../src/features/modules/modulesTypes'
import type { CaptainInstance } from '../src/features/captains/captainsTypes'
import type { ShipCargoLot } from '../src/features/map/tradeApi'

// SHIP-DOSSIER — pure-logic specs for the dossier selectors (no app/Supabase). Display-side
// arithmetic only: the slot math must equal ModulesPanel's picker arithmetic, the m³ sum must
// equal MarketPanel's lot-sum formula — the server (fitting_apply / market_buy) stays the enforcer.

const fitting = (over: Partial<ShipFittingRow>): ShipFittingRow => ({
  module_instance_id: 'mi-1',
  main_ship_id: 'ship-a',
  fitted_at: '2026-07-01T00:00:00Z',
  module_type_id: 'autocannon_battery',
  name: 'Autocannon Battery',
  slot_type: 'weapon',
  slot_cost: 1,
  ...over,
})

const captain = (over: Partial<CaptainInstance>): CaptainInstance => ({
  instance_id: 'ci-1',
  captain_type_id: 'veteran_gunner',
  name: 'Rhee',
  specialization: 'combat',
  stats_json: {},
  main_ship_id: 'ship-a',
  created_at: '2026-07-01T00:00:00Z',
  ...over,
})

const lot = (over: Partial<ShipCargoLot>): ShipCargoLot => ({
  lot_id: 'lot-1',
  good_id: 'textiles',
  qty: 10,
  unit_cost_basis: 5,
  acquired_at: '2026-07-01T00:00:00Z',
  unit_volume_m3: 0.5,
  ...over,
})

// ── fittingsForShip — the per-ship subset, server order kept ─────────────────────────────────────
test('fittingsForShip: keeps only the given ship, in the read order', () => {
  const rows = [
    fitting({ module_instance_id: 'a', main_ship_id: 'ship-a' }),
    fitting({ module_instance_id: 'b', main_ship_id: 'ship-b' }),
    fitting({ module_instance_id: 'c', main_ship_id: 'ship-a' }),
  ]
  expect(fittingsForShip(rows, 'ship-a').map((f) => f.module_instance_id)).toEqual(['a', 'c'])
  expect(fittingsForShip(rows, 'ship-c')).toEqual([])
  expect(fittingsForShip([], 'ship-a')).toEqual([])
})

// ── fittedSlotsUsed — Σ slot_cost (the ModulesPanel picker arithmetic) ───────────────────────────
test('fittedSlotsUsed: sums slot_cost; empty loadout is 0', () => {
  expect(fittedSlotsUsed([])).toBe(0)
  expect(fittedSlotsUsed([fitting({ slot_cost: 1 }), fitting({ slot_cost: 2 })])).toBe(3)
})

// ── captainsForShip — ASSIGNED-to-this-ship only ─────────────────────────────────────────────────
test('captainsForShip: excludes unassigned (null) and other-ship captains', () => {
  const rows = [
    captain({ instance_id: 'x', main_ship_id: 'ship-a' }),
    captain({ instance_id: 'y', main_ship_id: null }), // unassigned — never on a ship's dossier
    captain({ instance_id: 'z', main_ship_id: 'ship-b' }),
  ]
  expect(captainsForShip(rows, 'ship-a').map((c) => c.instance_id)).toEqual(['x'])
  expect(captainsForShip([], 'ship-a')).toEqual([])
})

// ── aggregateCargo — lots merged per good, FIFO first-seen order ─────────────────────────────────
test('aggregateCargo: merges a good\'s lots (qty + m³), first-seen order preserved', () => {
  const lots = [
    lot({ lot_id: '1', good_id: 'textiles', qty: 10, unit_volume_m3: 0.5 }),
    lot({ lot_id: '2', good_id: 'machinery', qty: 2, unit_volume_m3: 2 }),
    lot({ lot_id: '3', good_id: 'textiles', qty: 4, unit_volume_m3: 0.5 }),
  ]
  expect(aggregateCargo(lots)).toEqual([
    { good_id: 'textiles', qty: 14, m3: 7 },
    { good_id: 'machinery', qty: 2, m3: 4 },
  ])
  expect(aggregateCargo([])).toEqual([])
})

// ── cargoUsedM3 — the MarketPanel lot-sum formula, identically ───────────────────────────────────
test('cargoUsedM3: Σ qty·unit_volume_m3 over all lots; empty hold is 0', () => {
  expect(cargoUsedM3([])).toBe(0)
  const lots = [
    lot({ qty: 10, unit_volume_m3: 0.5 }), // 5
    lot({ lot_id: 'lot-2', good_id: 'machinery', qty: 3, unit_volume_m3: 2 }), // 6
  ]
  expect(cargoUsedM3(lots)).toBe(11)
  // the aggregate view and the total must agree (same volume model, two projections)
  expect(aggregateCargo(lots).reduce((s, g) => s + g.m3, 0)).toBe(cargoUsedM3(lots))
})

// ── formatM3 — the MarketPanel two-decimal convention ────────────────────────────────────────────
test('formatM3: two decimals, MarketPanel-style', () => {
  expect(formatM3(0)).toBe('0.00')
  expect(formatM3(12.5)).toBe('12.50')
  expect(formatM3(3.14159)).toBe('3.14')
})
