import { test, expect } from '@playwright/test'
import {
  BLANK_ARCHETYPE_DRAFT,
  archetypeDraftFromRow,
  archetypeDraftToForm,
} from '../src/features/worldeditor/enemyArchetypeDraft'
import type { EnemyArchetypeRow } from '../src/features/worldeditor/enemyRegistryData'

// M3 — the archetype EDIT FORK must round-trip free-form stat_overrides intact. The pre-M3 code hardcoded
// `stat_overrides: {}` in toForm, so editing a row that carried overrides silently WIPED them on save.
// Run: `npx playwright test enemyArchetypeDraft.spec.ts`.

const row = (over: Partial<EnemyArchetypeRow> = {}): EnemyArchetypeRow => ({
  id: 'arch-uuid-1',
  key: 'pirate_light',
  display_name: 'Pirate Light',
  faction: 'pirate',
  unit_type_id: 'pirate_synthetic',
  behavior_key: 'spatial_synthetic',
  base_difficulty: 10,
  default_reward_profile_id: 'reward-uuid-1',
  difficulty_rating: 3,
  stat_overrides: {},
  active: true,
  revision: 4,
  notes: null,
  ...over,
})

test('the edit fork preserves a non-empty stat_overrides through row -> draft -> form', () => {
  const overrides = { hp_mult: 1.5, shield: { max: 200 } }
  const form = archetypeDraftToForm(archetypeDraftFromRow(row({ stat_overrides: overrides })))
  expect(form.stat_overrides).toEqual(overrides)
})

test('a stale null stat_overrides forks to an empty object (never undefined)', () => {
  // enemyRegistryData types stat_overrides as an object, but harden against a null slipping through.
  const form = archetypeDraftToForm(archetypeDraftFromRow(row({ stat_overrides: null as unknown as Record<string, unknown> })))
  expect(form.stat_overrides).toEqual({})
})

test('the edit fork carries the scalar authoring fields through unchanged', () => {
  const form = archetypeDraftToForm(archetypeDraftFromRow(row()))
  expect(form).toMatchObject({
    key: 'pirate_light',
    display_name: 'Pirate Light',
    unit_type_id: 'pirate_synthetic',
    base_difficulty: 10,
    difficulty_rating: 3,
    default_reward_profile_id: 'reward-uuid-1',
    behavior_key: 'spatial_synthetic',
    faction: 'pirate',
  })
})

test('a blank draft carries an empty stat_overrides (a fresh create wipes nothing)', () => {
  expect(archetypeDraftToForm(BLANK_ARCHETYPE_DRAFT).stat_overrides).toEqual({})
})
