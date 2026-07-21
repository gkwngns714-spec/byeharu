import { test, expect } from '@playwright/test'
import {
  rewardProfileLayerAdapter,
  enemyArchetypeLayerAdapter,
  type RegistryReadAdapter,
} from '../src/features/worldeditor/enemyRegistryAdapters'
import type { EnemyRegistryData } from '../src/features/worldeditor/enemyRegistryData'

// ENEMY CONTENT REGISTRY (0257) — pure proofs for the two read-only registry adapters. No browser/DB:
// the adapters are pure (rows in → typed items/fields out). The tables are DARK; these READ only.
// Run: `npx playwright test enemyRegistryAdapters.spec.ts`.

const DATA: EnemyRegistryData = {
  rewardProfiles: [
    {
      id: 'rp-1',
      key: 'pirate_standard',
      display_name: 'Standard Pirate Bounty',
      resource_grants: { metal: { base: 10, danger_coeff: 0.25, multiplier_ref: 'reward_multiplier' } },
      active: true,
      revision: 1,
      notes: null,
    },
    {
      id: 'rp-2',
      key: 'pirate_retired',
      display_name: 'Retired Bounty',
      resource_grants: {},
      active: false,
      revision: 3,
      notes: 'soft-disabled',
    },
  ],
  enemyArchetypes: [
    {
      id: 'ea-1',
      key: 'pirate_light',
      display_name: 'Light Pirate',
      faction: 'pirate',
      unit_type_id: 'pirate_synthetic',
      behavior_key: 'spatial_synthetic',
      base_difficulty: 10,
      default_reward_profile_id: 'rp-1',
      difficulty_rating: 1,
      stat_overrides: {},
      active: true,
      revision: 1,
      notes: null,
    },
  ],
}

// ── Reward profiles adapter ───────────────────────────────────────────────────────────────────────
test('reward profiles: readItems resolves key/label/active; inspect exposes typed authoring fields', () => {
  const items = rewardProfileLayerAdapter.readItems(DATA)
  expect(items).toHaveLength(2)
  expect(items[0]).toEqual({ registry: 'reward_profiles', id: 'pirate_standard', label: 'Standard Pirate Bounty', active: true })
  expect(items[1].active).toBe(false) // a soft-disabled row still appears (no hard delete)

  const fields = rewardProfileLayerAdapter.inspect(DATA, 'pirate_standard')
  expect(fields).not.toBeNull()
  const byLabel = Object.fromEntries(fields!.map((f) => [f.label, f.value]))
  expect(byLabel['Key']).toBe('pirate_standard')
  expect(byLabel['Resources']).toBe('metal')
  expect(byLabel['Active']).toBe('yes')
  expect(byLabel['Revision']).toBe('1')
  expect(byLabel['Notes']).toBe('—')
  expect(rewardProfileLayerAdapter.inspect(DATA, 'nope')).toBeNull()
})

// ── Enemy archetypes adapter ──────────────────────────────────────────────────────────────────────
test('enemy archetypes: readItems resolves key/label; inspect exposes the template fields, no runtime state', () => {
  const items = enemyArchetypeLayerAdapter.readItems(DATA)
  expect(items).toHaveLength(1)
  expect(items[0]).toEqual({ registry: 'enemy_archetypes', id: 'pirate_light', label: 'Light Pirate', active: true })

  const fields = enemyArchetypeLayerAdapter.inspect(DATA, 'pirate_light')!
  const byLabel = Object.fromEntries(fields.map((f) => [f.label, f.value]))
  expect(byLabel['Faction']).toBe('pirate')
  expect(byLabel['Unit type']).toBe('pirate_synthetic')
  expect(byLabel['Behavior']).toBe('spatial_synthetic')
  expect(byLabel['Base difficulty']).toBe('10')
  expect(byLabel['Difficulty rating']).toBe('1')
  // GROUNDED HONESTY: no runtime-instance field (hp/position/target/status/encounter_id) is invented.
  const labels = fields.map((f) => f.label)
  for (const forbidden of ['HP', 'Position', 'Target', 'Status', 'Encounter']) {
    expect(labels).not.toContain(forbidden)
  }
  expect(enemyArchetypeLayerAdapter.inspect(DATA, 'nope')).toBeNull()
})

// ── READ-ONLY guarantee: the adapters expose read/resolve/inspect ONLY, no mutation seam ────────────
test('registry adapters are strictly read-only — no create/edit/publish/enable/disable method exists', () => {
  const adapters: RegistryReadAdapter<EnemyRegistryData>[] = [rewardProfileLayerAdapter, enemyArchetypeLayerAdapter]
  const forbidden = ['create', 'edit', 'publish', 'enable', 'disable', 'archive', 'save', 'update', 'delete', 'mutate', 'setActive']
  for (const a of adapters) {
    expect(Object.keys(a).sort()).toEqual(['id', 'inspect', 'readItems', 'title'])
    for (const op of forbidden) expect(op in a).toBe(false)
  }
})
