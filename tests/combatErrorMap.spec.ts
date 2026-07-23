import { test, expect } from '@playwright/test'
import { mapCombatError, type CombatTier } from '../src/features/worldeditor/combatErrorMap'
import type { WorldEditorCommandFailure } from '../src/features/worldeditor/commandContract'

// E4 — COMBAT ERROR MAP: pure mapper unit tests. Every server detail code across E0-E2 must resolve to a
// non-empty, plain-language field message; the distinct banners (stale_revision / not_enabled / conflict /
// not_found) must read differently; and not_enabled must name the correct flag chain per tier (E0/E1/E2).
// Run: `npx playwright test combatErrorMap.spec.ts`.

const fail = (
  error: WorldEditorCommandFailure['error'],
  details?: WorldEditorCommandFailure['details'],
): WorldEditorCommandFailure => ({ ok: false, requestId: 'req-x', error, details })

// Every details[].code the E0-E2 RPCs can emit (from the three proof scripts / contract specs).
const ALL_DETAIL_CODES = [
  'duplicate_key',
  'duplicate_binding',
  'invalid_unit_type',
  'invalid_reward_profile',
  'invalid_resource_grants',
  'base_difficulty_invalid',
  'invalid_archetype_ref',
  'archetype_inactive',
  'invalid_count_range',
  'invalid_elite_chance',
  'duplicate_member',
  'members_required',
  'invalid_fleet_ref',
  'fleet_inactive',
  'invalid_reward_override',
  'invalid_difficulty',
  'invalid_encounter_cap',
  'invalid_cooldown',
  'invalid_location',
  'invalid_encounter_ref',
  'encounter_inactive',
  'invalid_weight',
]

test('every details[].code maps to a non-empty field message', () => {
  for (const code of ALL_DETAIL_CODES) {
    const view = mapCombatError(fail('validation_failed', [{ code, field: 'f' }]), 'E1')
    expect(Object.keys(view.fieldErrors).length, `${code} produced no field error`).toBeGreaterThan(0)
    for (const message of Object.values(view.fieldErrors)) {
      expect(message.length, `${code} message empty`).toBeGreaterThan(0)
    }
  }
})

test('conflict duplicate_key points at the key field; duplicate_binding at the encounter picker', () => {
  const dupKey = mapCombatError(fail('conflict', [{ code: 'duplicate_key' }]), 'E0')
  expect(dupKey.fieldErrors['key']).toBeTruthy()
  const dupBinding = mapCombatError(fail('conflict', [{ code: 'duplicate_binding' }]), 'E2')
  expect(dupBinding.fieldErrors['encounter_profile_id']).toBeTruthy()
})

test('stale_revision / not_enabled / conflict / not_found are distinct banners', () => {
  const banners = [
    mapCombatError(fail('stale_revision'), 'E0').banner,
    mapCombatError(fail('not_enabled'), 'E0').banner,
    mapCombatError(fail('conflict'), 'E0').banner,
    mapCombatError(fail('not_found'), 'E0').banner,
  ]
  for (const b of banners) expect(b.length).toBeGreaterThan(0)
  expect(new Set(banners).size).toBe(banners.length)
})

test('stale_revision banner says reload-and-redo', () => {
  expect(mapCombatError(fail('stale_revision'), 'E1').banner).toMatch(/reload/i)
})

test('not_enabled names the correct flag chain per tier', () => {
  const e0 = mapCombatError(fail('not_enabled'), 'E0').banner
  const e1 = mapCombatError(fail('not_enabled'), 'E1').banner
  const e2 = mapCombatError(fail('not_enabled'), 'E2').banner

  expect(e0).toMatch(/enemy_content_registry_enabled/)
  expect(e0).not.toMatch(/encounter_authoring_enabled/)

  expect(e1).toMatch(/enemy_content_registry_enabled/)
  expect(e1).toMatch(/encounter_authoring_enabled/)
  expect(e1).not.toMatch(/encounter_binding_authoring_enabled/)

  expect(e2).toMatch(/enemy_content_registry_enabled/)
  expect(e2).toMatch(/encounter_authoring_enabled/)
  expect(e2).toMatch(/encounter_binding_authoring_enabled/)

  const tiers: CombatTier[] = ['E0', 'E1', 'E2']
  expect(new Set(tiers.map((t) => mapCombatError(fail('not_enabled'), t).banner)).size).toBe(3)
})

test('an unknown code falls back to the server message, never empty', () => {
  const view = mapCombatError(fail('validation_failed', [{ code: 'some_new_code', field: 'x', message: 'server said no' }]), 'E1')
  expect(view.fieldErrors['x']).toBe('server said no')
})
