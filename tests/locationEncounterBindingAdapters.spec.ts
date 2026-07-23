import { test, expect } from '@playwright/test'
import {
  locationEncounterBindingLayerAdapter,
  type RegistryReadAdapter,
} from '../src/features/worldeditor/locationEncounterBindingAdapters'
import type { LocationEncounterBindingData } from '../src/features/worldeditor/locationEncounterBindingData'

// LOCATION → ENCOUNTER BINDINGS (0259) — pure proofs for the read-only adapter. No browser/DB: the adapter
// is pure (rows in → typed items/fields out). The table is DARK; this READS only.
// Run: `npx playwright test locationEncounterBindingAdapters.spec.ts`.

const DATA: LocationEncounterBindingData = {
  bindings: [
    {
      id: 'b-1',
      location_id: 'loc-1',
      encounter_profile_id: 'ep-1',
      weight: 5,
      active: true,
      revision: 2,
      notes: 'primary wave',
    },
    {
      id: 'b-2',
      location_id: 'loc-1',
      encounter_profile_id: 'ep-2',
      weight: 1,
      active: false, // a soft-disabled row still appears (no hard delete)
      revision: 3,
      notes: null,
    },
  ],
}

// ── read + inspect ──────────────────────────────────────────────────────────────────────────────────
test('bindings: readItems resolves id/label/active; inspect exposes the grounded authoring fields', () => {
  const items = locationEncounterBindingLayerAdapter.readItems(DATA)
  expect(items).toHaveLength(2)
  expect(items[0]).toEqual({
    registry: 'location_encounter_bindings',
    id: 'b-1',
    label: 'loc-1 → ep-1',
    active: true,
  })
  expect(items[1].active).toBe(false)

  const fields = locationEncounterBindingLayerAdapter.inspect(DATA, 'b-1')
  expect(fields).not.toBeNull()
  const byLabel = Object.fromEntries(fields!.map((f) => [f.label, f.value]))
  expect(byLabel['Location']).toBe('loc-1')
  expect(byLabel['Encounter profile']).toBe('ep-1')
  expect(byLabel['Weight']).toBe('5')
  expect(byLabel['Active']).toBe('yes')
  expect(byLabel['Revision']).toBe('2')
  expect(byLabel['Notes']).toBe('primary wave')

  // a null notes renders as an em dash, not the string 'null'.
  const f2 = locationEncounterBindingLayerAdapter.inspect(DATA, 'b-2')!
  expect(Object.fromEntries(f2.map((f) => [f.label, f.value]))['Notes']).toBe('—')

  // GROUNDED HONESTY: no runtime-instance field (hp/position/target/status/encounter_id) is invented.
  const labels = fields!.map((f) => f.label)
  for (const forbidden of ['HP', 'Position', 'Target', 'Status', 'Encounter id']) {
    expect(labels).not.toContain(forbidden)
  }
  expect(locationEncounterBindingLayerAdapter.inspect(DATA, 'nope')).toBeNull()
})

// ── READ-ONLY guarantee: the adapter exposes read/inspect ONLY, no mutation seam ────────────────────
test('binding adapter is strictly read-only — no create/edit/publish/enable/disable method exists', () => {
  const adapters: RegistryReadAdapter<LocationEncounterBindingData>[] = [locationEncounterBindingLayerAdapter]
  const forbidden = ['create', 'edit', 'publish', 'enable', 'disable', 'archive', 'save', 'update', 'delete', 'mutate', 'setActive']
  for (const a of adapters) {
    expect(Object.keys(a).sort()).toEqual(['id', 'inspect', 'readItems', 'title'])
    for (const op of forbidden) expect(op in a).toBe(false)
  }
})
