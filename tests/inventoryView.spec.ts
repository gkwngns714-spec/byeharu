import { test, expect } from '@playwright/test'
import { inventoryEntries } from '../src/features/inventory/inventoryView'

// INVENTORY-PANEL (SHIP-DOSSIER slice) — pure-logic specs for the inventory view model (no
// app/Supabase). Input is the balances Record the existing player_inventory read produces;
// the view drops spent items and sorts by the player-facing label.

test('entries: drops zero and negative balances (spent items are not "carried")', () => {
  expect(
    inventoryEntries({ scrap: 3, crystal: 0, pirate_alloy: -1 }).map((e) => e.item_id),
  ).toEqual(['scrap'])
})

test('entries: sorts by the DISPLAY label, not the raw id', () => {
  // raw-id order would be: engine_parts < pirate_alloy < scrap < weapon_parts — labels agree here,
  // so include crystal ('Crystal' < 'Engine Parts') to prove label ordering is in force.
  expect(
    inventoryEntries({ weapon_parts: 1, scrap: 2, engine_parts: 3, crystal: 4, pirate_alloy: 5 }).map(
      (e) => e.item_id,
    ),
  ).toEqual(['crystal', 'engine_parts', 'pirate_alloy', 'scrap', 'weapon_parts'])
})

test('entries: carries the exact server quantity through', () => {
  expect(inventoryEntries({ scrap: 42 })).toEqual([{ item_id: 'scrap', quantity: 42 }])
})

test('entries: unknown ids never crash — they sort by their honest title-case label', () => {
  // 'future_widget' → 'Future Widget' (itemLabel fallback): between 'Engine Parts' and 'Scrap'.
  expect(
    inventoryEntries({ scrap: 1, future_widget: 2, engine_parts: 3 }).map((e) => e.item_id),
  ).toEqual(['engine_parts', 'future_widget', 'scrap'])
})

test('entries: empty record → empty list (the panel shows the salvage hint copy)', () => {
  expect(inventoryEntries({})).toEqual([])
})
