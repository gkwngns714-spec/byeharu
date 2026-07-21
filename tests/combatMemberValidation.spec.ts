import { test, expect } from '@playwright/test'
import {
  validateFleetMembers,
  validateEncounterMembers,
} from '../src/features/worldeditor/combatMemberValidation'
import type { EncounterMemberForm, FleetMemberForm } from '../src/features/worldeditor/combatPayloads'

// E4 — COMBAT MEMBER VALIDATION: pure advisory-bounds unit tests. The mirror FLAGS bad rows (issues[]) but
// NEVER clamps or mutates — the input array is untouched. Bounds mirror the 0258 server proof.
// Run: `npx playwright test combatMemberValidation.spec.ts`.

const fleetMember = (over: Partial<FleetMemberForm> = {}): FleetMemberForm => ({
  enemy_archetype_id: 'arch-a',
  min_count: 1,
  max_count: 1,
  weight: 1,
  elite_chance: 0,
  ...over,
})

const has = (issues: { code: string }[], code: string) => issues.some((i) => i.code === code)

test('a valid fleet member set produces no issues', () => {
  expect(validateFleetMembers([fleetMember()])).toEqual([])
})

test('empty fleet members is members_required', () => {
  expect(has(validateFleetMembers([]), 'members_required')).toBe(true)
})

test('min > max is invalid_count_range', () => {
  expect(has(validateFleetMembers([fleetMember({ min_count: 2, max_count: 1 })]), 'invalid_count_range')).toBe(true)
})

test('max above 100 is invalid_count_range', () => {
  expect(has(validateFleetMembers([fleetMember({ min_count: 1, max_count: 101 })]), 'invalid_count_range')).toBe(true)
})

test('weight 0 and weight 1001 are invalid_weight', () => {
  expect(has(validateFleetMembers([fleetMember({ weight: 0 })]), 'invalid_weight')).toBe(true)
  expect(has(validateFleetMembers([fleetMember({ weight: 1001 })]), 'invalid_weight')).toBe(true)
})

test('elite_chance above 1 is invalid_elite_chance', () => {
  expect(has(validateFleetMembers([fleetMember({ elite_chance: 1.5 })]), 'invalid_elite_chance')).toBe(true)
})

test('a duplicate archetype ref is duplicate_member', () => {
  const issues = validateFleetMembers([fleetMember({ enemy_archetype_id: 'x' }), fleetMember({ enemy_archetype_id: 'x' })])
  expect(has(issues, 'duplicate_member')).toBe(true)
})

test('validation FLAGS, never clamps — the input array is untouched', () => {
  const members = [fleetMember({ min_count: 5, max_count: 2, weight: 9999, elite_chance: 4 })]
  const snapshot = JSON.parse(JSON.stringify(members))
  const issues = validateFleetMembers(members)
  expect(issues.length).toBeGreaterThan(0)
  expect(members).toEqual(snapshot) // no mutation, no clamp
})

// ── encounter members ────────────────────────────────────────────────────────────────────────────────
const encMember = (over: Partial<EncounterMemberForm> = {}): EncounterMemberForm => ({
  fleet_template_id: 'fleet-a',
  weight: 1,
  ...over,
})

test('a valid encounter member set produces no issues', () => {
  expect(validateEncounterMembers([encMember()])).toEqual([])
})

test('empty encounter members is members_required', () => {
  expect(has(validateEncounterMembers([]), 'members_required')).toBe(true)
})

test('a duplicate fleet ref is duplicate_member; weight 0 is invalid_weight', () => {
  expect(has(validateEncounterMembers([encMember({ fleet_template_id: 'f' }), encMember({ fleet_template_id: 'f' })]), 'duplicate_member')).toBe(true)
  expect(has(validateEncounterMembers([encMember({ weight: 0 })]), 'invalid_weight')).toBe(true)
})
