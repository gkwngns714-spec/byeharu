import { test, expect } from '@playwright/test'
import {
  validateFleetMembers,
  validateEncounterMembers,
  fleetAdvisories,
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

// ── advisory (non-blocking) notes — runtime unit-cap + elite-inert ─────────────────────────────────────
test('summed max_count > 6 yields the runtime_unit_cap advisory but NO blocking issue', () => {
  // two valid distinct members, max_count 4 + 4 = 8 (> the E3 wave cap of 6).
  const members = [
    fleetMember({ enemy_archetype_id: 'a', max_count: 4 }),
    fleetMember({ enemy_archetype_id: 'b', max_count: 4 }),
  ]
  expect(validateFleetMembers(members)).toEqual([]) // no BLOCKING issue — Save is not gated
  const advisories = fleetAdvisories(members)
  expect(has(advisories, 'runtime_unit_cap')).toBe(true)
  expect(advisories.every((a) => a.severity === 'advisory')).toBe(true)
})

test('summed max_count <= 6 yields no runtime_unit_cap advisory', () => {
  const members = [
    fleetMember({ enemy_archetype_id: 'a', max_count: 3 }),
    fleetMember({ enemy_archetype_id: 'b', max_count: 3 }),
  ]
  expect(has(fleetAdvisories(members), 'runtime_unit_cap')).toBe(false)
})

test('elite_chance > 0 yields the elite_inert advisory; elite_chance 0 does not', () => {
  const elite = fleetAdvisories([fleetMember({ elite_chance: 0.25 })])
  expect(has(elite, 'elite_inert')).toBe(true)
  expect(elite.find((a) => a.code === 'elite_inert')?.index).toBe(0)
  expect(has(fleetAdvisories([fleetMember({ elite_chance: 0 })]), 'elite_inert')).toBe(false)
})

test('advisories are advisory-severity and never appear as blocking validation issues', () => {
  const members = [fleetMember({ elite_chance: 0.5, max_count: 5 }), fleetMember({ enemy_archetype_id: 'b', max_count: 5 })]
  // blocking validator carries neither advisory code
  expect(has(validateFleetMembers(members), 'runtime_unit_cap')).toBe(false)
  expect(has(validateFleetMembers(members), 'elite_inert')).toBe(false)
})

// ── M2: fleet-member weight is inert (the E5 resolver never reads it) ───────────────────────────────────
test('a fleet-member weight != 1 yields the fleet_weight_inert advisory bound to that row', () => {
  const notes = fleetAdvisories([fleetMember({ weight: 5 })])
  expect(has(notes, 'fleet_weight_inert')).toBe(true)
  expect(notes.find((a) => a.code === 'fleet_weight_inert')?.index).toBe(0)
  expect(notes.find((a) => a.code === 'fleet_weight_inert')?.severity).toBe('advisory')
})

test('a neutral fleet-member weight of 1 yields no fleet_weight_inert advisory', () => {
  expect(has(fleetAdvisories([fleetMember({ weight: 1 })]), 'fleet_weight_inert')).toBe(false)
})

test('fleet_weight_inert is advisory-only — never a blocking validation issue, never gates Save', () => {
  const members = [fleetMember({ weight: 7 })]
  expect(has(validateFleetMembers(members), 'fleet_weight_inert')).toBe(false)
  // a weight in (0,1000] is valid; the note is a heads-up, not a rejection
  expect(validateFleetMembers(members)).toEqual([])
})
