import { test, expect } from '@playwright/test'
import {
  fleetTemplateLayerAdapter,
  encounterProfileLayerAdapter,
  type RegistryReadAdapter,
} from '../src/features/worldeditor/fleetEncounterAdapters'
import type { FleetEncounterData } from '../src/features/worldeditor/fleetEncounterData'

// FLEET TEMPLATES + ENCOUNTER PROFILES (0258) — pure proofs for the two read-only adapters. No browser/DB:
// the adapters are pure (rows in → typed items/fields out). The tables are DARK; these READ only.
// Run: `npx playwright test fleetEncounterAdapters.spec.ts`.

const DATA: FleetEncounterData = {
  fleetTemplates: [
    {
      id: 'ft-1',
      key: 'pirate_light_solo',
      display_name: 'Solo Light Pirate',
      active: true,
      revision: 1,
      notes: null,
      members: [
        { enemy_archetype_id: 'ea-1', min_count: 1, max_count: 1, weight: 1, elite_chance: 0 },
      ],
    },
    {
      id: 'ft-2',
      key: 'pirate_retired_fleet',
      display_name: 'Retired Fleet',
      active: false,
      revision: 4,
      notes: 'soft-disabled',
      members: [],
    },
  ],
  encounterProfiles: [
    {
      id: 'ep-1',
      key: 'pirate_basic',
      display_name: 'Basic Pirate Encounter',
      difficulty: 1,
      active_encounter_cap: 1,
      cooldown_seconds: 0,
      reward_override_id: null,
      active: true,
      revision: 1,
      notes: null,
      members: [{ fleet_template_id: 'ft-1', weight: 1 }],
    },
  ],
}

// ── Fleet templates adapter ───────────────────────────────────────────────────────────────────────
test('fleet templates: readItems resolves key/label/active; inspect exposes fields incl a members summary', () => {
  const items = fleetTemplateLayerAdapter.readItems(DATA)
  expect(items).toHaveLength(2)
  expect(items[0]).toEqual({ registry: 'enemy_fleet_templates', id: 'pirate_light_solo', label: 'Solo Light Pirate', active: true })
  expect(items[1].active).toBe(false) // a soft-disabled row still appears (no hard delete)

  const fields = fleetTemplateLayerAdapter.inspect(DATA, 'pirate_light_solo')
  expect(fields).not.toBeNull()
  const byLabel = Object.fromEntries(fields!.map((f) => [f.label, f.value]))
  expect(byLabel['Key']).toBe('pirate_light_solo')
  expect(byLabel['Members']).toBe('1')
  expect(byLabel['Composition']).toContain('ea-1')
  expect(byLabel['Active']).toBe('yes')
  expect(byLabel['Revision']).toBe('1')
  expect(byLabel['Notes']).toBe('—')
  expect(fleetTemplateLayerAdapter.inspect(DATA, 'nope')).toBeNull()
})

// ── Encounter profiles adapter ────────────────────────────────────────────────────────────────────
test('encounter profiles: readItems resolves key/label; inspect exposes scalars + a members summary', () => {
  const items = encounterProfileLayerAdapter.readItems(DATA)
  expect(items).toHaveLength(1)
  expect(items[0]).toEqual({ registry: 'encounter_profiles', id: 'pirate_basic', label: 'Basic Pirate Encounter', active: true })

  const fields = encounterProfileLayerAdapter.inspect(DATA, 'pirate_basic')!
  const byLabel = Object.fromEntries(fields.map((f) => [f.label, f.value]))
  expect(byLabel['Difficulty']).toBe('1')
  expect(byLabel['Active cap']).toBe('1')
  expect(byLabel['Cooldown (s)']).toBe('0')
  expect(byLabel['Reward override']).toBe('archetype default') // null ⇒ falls back to archetype default
  expect(byLabel['Members']).toBe('1')
  expect(byLabel['Fleets']).toContain('ft-1')
  // GROUNDED HONESTY: no runtime-instance field (hp/position/target/status/encounter_id) is invented.
  const labels = fields.map((f) => f.label)
  for (const forbidden of ['HP', 'Position', 'Target', 'Status', 'Encounter']) {
    expect(labels).not.toContain(forbidden)
  }
  expect(encounterProfileLayerAdapter.inspect(DATA, 'nope')).toBeNull()
})

// ── READ-ONLY guarantee: the adapters expose read/inspect ONLY, no mutation seam ────────────────────
test('fleet/encounter adapters are strictly read-only — no create/edit/publish/enable/disable method exists', () => {
  const adapters: RegistryReadAdapter<FleetEncounterData>[] = [fleetTemplateLayerAdapter, encounterProfileLayerAdapter]
  const forbidden = ['create', 'edit', 'publish', 'enable', 'disable', 'archive', 'save', 'update', 'delete', 'mutate', 'setActive']
  for (const a of adapters) {
    expect(Object.keys(a).sort()).toEqual(['id', 'inspect', 'readItems', 'title'])
    for (const op of forbidden) expect(op in a).toBe(false)
  }
})
