import { test, expect } from '@playwright/test'
import {
  buildRewardProfileCreate,
  buildRewardProfileUpdate,
  buildEnemyArchetypeCreate,
  buildEnemyArchetypeUpdate,
  buildFleetTemplateCreate,
  buildFleetTemplateUpdate,
  buildEncounterProfileCreate,
  buildEncounterProfileUpdate,
  buildLocationBindingCreate,
  buildLocationBindingUpdate,
  buildSetActive,
  type EnemyArchetypeForm,
  type EncounterProfileForm,
  type FleetTemplateForm,
  type LocationBindingForm,
  type RewardProfileForm,
} from '../src/features/worldeditor/combatPayloads'

// E4 — COMBAT PAYLOADS: pure builder unit tests. Each of the 15 command kinds must produce the exact
// commandType + payload the already-built E0-E2 owner RPCs accept — mirroring the authoritative envelopes
// in enemyRegistry/fleetEncounter/locationEncounterBinding contract specs. Key invariants asserted:
//   • create is a flat content object; +members for E1; {location_id,encounter_profile_id,weight} for E2.
//   • member refs are the UUID id (enemy_archetype_id / fleet_template_id), never the human key.
//   • update carries {target_id, expected_revision}: target_id = the natural KEY for E0/E1, the binding
//     UUID for E2. set_active is {target_id, expected_revision, active}.
// Run: `npx playwright test combatPayloads.spec.ts`.

// ── E0 · reward_profile ─────────────────────────────────────────────────────────────────────────────
const REWARD_FORM: RewardProfileForm = {
  key: 'pirate_standard',
  display_name: 'Standard',
  resource_grants: { metal: { base: 10, multiplier_ref: 'reward_multiplier' } },
  notes: null,
}

test('reward_profile_create: flat {key,display_name,resource_grants}, notes omitted when null', () => {
  expect(buildRewardProfileCreate(REWARD_FORM)).toEqual({
    commandType: 'reward_profile_create',
    payload: {
      key: 'pirate_standard',
      display_name: 'Standard',
      resource_grants: { metal: { base: 10, multiplier_ref: 'reward_multiplier' } },
    },
  })
})

test('reward_profile_create: notes included when present', () => {
  const cmd = buildRewardProfileCreate({ ...REWARD_FORM, notes: 'seed reward' })
  expect(cmd.payload.notes).toBe('seed reward')
})

test('reward_profile_update: carries target_id (=key) + expected_revision, no key field', () => {
  expect(buildRewardProfileUpdate('pirate_standard', 3, { ...REWARD_FORM, display_name: 'v2' })).toEqual({
    commandType: 'reward_profile_update',
    payload: {
      target_id: 'pirate_standard',
      expected_revision: 3,
      display_name: 'v2',
      resource_grants: { metal: { base: 10, multiplier_ref: 'reward_multiplier' } },
    },
  })
})

test('reward_profile_set_active: {target_id,expected_revision,active}', () => {
  expect(buildSetActive('reward_profile_set_active', 'pirate_standard', 3, false)).toEqual({
    commandType: 'reward_profile_set_active',
    payload: { target_id: 'pirate_standard', expected_revision: 3, active: false },
  })
})

// ── E0 · enemy_archetype ────────────────────────────────────────────────────────────────────────────
const ARCH_FORM: EnemyArchetypeForm = {
  key: 'pirate_light',
  display_name: 'Light Pirate',
  faction: '',
  unit_type_id: 'pirate_synthetic',
  behavior_key: '',
  base_difficulty: 15,
  default_reward_profile_id: 'rp-uuid-1',
  difficulty_rating: 2,
  stat_overrides: {},
  notes: null,
}

test('enemy_archetype_create: flat content, optional faction/behavior/stat_overrides/notes omitted when empty', () => {
  expect(buildEnemyArchetypeCreate(ARCH_FORM)).toEqual({
    commandType: 'enemy_archetype_create',
    payload: {
      key: 'pirate_light',
      display_name: 'Light Pirate',
      unit_type_id: 'pirate_synthetic',
      base_difficulty: 15,
      difficulty_rating: 2,
      default_reward_profile_id: 'rp-uuid-1',
    },
  })
})

test('enemy_archetype_create: optional fields included when present', () => {
  const cmd = buildEnemyArchetypeCreate({
    ...ARCH_FORM,
    faction: 'pirate',
    behavior_key: 'spatial_synthetic',
    stat_overrides: { shield: 5 },
  })
  expect(cmd.payload).toMatchObject({ faction: 'pirate', behavior_key: 'spatial_synthetic', stat_overrides: { shield: 5 } })
})

test('enemy_archetype_update: target_id (=key) + expected_revision, reward ref is the UUID', () => {
  const cmd = buildEnemyArchetypeUpdate('pirate_light', 1, ARCH_FORM)
  expect(cmd.commandType).toBe('enemy_archetype_update')
  expect(cmd.payload.target_id).toBe('pirate_light')
  expect(cmd.payload.expected_revision).toBe(1)
  expect(cmd.payload.default_reward_profile_id).toBe('rp-uuid-1')
  expect(cmd.payload).not.toHaveProperty('key')
})

test('enemy_archetype_set_active: {target_id,expected_revision,active}', () => {
  expect(buildSetActive('enemy_archetype_set_active', 'pirate_light', 1, false)).toEqual({
    commandType: 'enemy_archetype_set_active',
    payload: { target_id: 'pirate_light', expected_revision: 1, active: false },
  })
})

// ── E1 · enemy_fleet_template ───────────────────────────────────────────────────────────────────────
const FLEET_FORM: FleetTemplateForm = {
  key: 'pirate_light_solo',
  display_name: 'Solo Light Pirate',
  notes: null,
  members: [{ enemy_archetype_id: 'arch-uuid-a', min_count: 1, max_count: 1, weight: 1, elite_chance: 0 }],
}

test('enemy_fleet_template_create: content + members; member ref is the archetype UUID', () => {
  expect(buildFleetTemplateCreate(FLEET_FORM)).toEqual({
    commandType: 'enemy_fleet_template_create',
    payload: {
      key: 'pirate_light_solo',
      display_name: 'Solo Light Pirate',
      members: [{ enemy_archetype_id: 'arch-uuid-a', min_count: 1, max_count: 1, weight: 1, elite_chance: 0 }],
    },
  })
})

test('enemy_fleet_template_update: target_id (=key) + expected_revision + REPLACE-ALL members', () => {
  const cmd = buildFleetTemplateUpdate('pirate_light_solo', 2, FLEET_FORM)
  expect(cmd.commandType).toBe('enemy_fleet_template_update')
  expect(cmd.payload).toMatchObject({ target_id: 'pirate_light_solo', expected_revision: 2 })
  expect(cmd.payload.members).toEqual([{ enemy_archetype_id: 'arch-uuid-a', min_count: 1, max_count: 1, weight: 1, elite_chance: 0 }])
})

test('enemy_fleet_template_set_active: {target_id,expected_revision,active}', () => {
  expect(buildSetActive('enemy_fleet_template_set_active', 'pirate_light_solo', 2, true)).toEqual({
    commandType: 'enemy_fleet_template_set_active',
    payload: { target_id: 'pirate_light_solo', expected_revision: 2, active: true },
  })
})

// ── E1 · encounter_profile ──────────────────────────────────────────────────────────────────────────
const ENC_FORM: EncounterProfileForm = {
  key: 'pirate_ambush',
  display_name: 'Pirate Ambush',
  difficulty: 1,
  active_encounter_cap: 1,
  cooldown_seconds: 0,
  reward_override_id: null,
  notes: null,
  members: [{ fleet_template_id: 'fleet-uuid-f', weight: 1 }],
}

test('encounter_profile_create: content + members; reward_override omitted for archetype default (null)', () => {
  expect(buildEncounterProfileCreate(ENC_FORM)).toEqual({
    commandType: 'encounter_profile_create',
    payload: {
      key: 'pirate_ambush',
      display_name: 'Pirate Ambush',
      difficulty: 1,
      active_encounter_cap: 1,
      cooldown_seconds: 0,
      members: [{ fleet_template_id: 'fleet-uuid-f', weight: 1 }],
    },
  })
})

test('encounter_profile_create: reward_override_id sent when chosen', () => {
  const cmd = buildEncounterProfileCreate({ ...ENC_FORM, reward_override_id: 'rp-uuid-9' })
  expect(cmd.payload.reward_override_id).toBe('rp-uuid-9')
})

test('encounter_profile_update: reward_override_id ALWAYS sent (null clears it), member ref is the fleet UUID', () => {
  const cmd = buildEncounterProfileUpdate('pirate_ambush', 2, ENC_FORM)
  expect(cmd.commandType).toBe('encounter_profile_update')
  expect(cmd.payload).toMatchObject({ target_id: 'pirate_ambush', expected_revision: 2, reward_override_id: null })
  expect(cmd.payload.members).toEqual([{ fleet_template_id: 'fleet-uuid-f', weight: 1 }])
})

test('encounter_profile_set_active: {target_id,expected_revision,active}', () => {
  expect(buildSetActive('encounter_profile_set_active', 'pirate_ambush', 2, false)).toEqual({
    commandType: 'encounter_profile_set_active',
    payload: { target_id: 'pirate_ambush', expected_revision: 2, active: false },
  })
})

// ── E2 · location_encounter_binding (target_id = the binding UUID) ───────────────────────────────────
const BINDING_FORM: LocationBindingForm = {
  location_id: 'loc-uuid-a',
  encounter_profile_id: 'ep-uuid-a',
  weight: 1,
}

test('location_encounter_binding_create: {location_id,encounter_profile_id,weight}', () => {
  expect(buildLocationBindingCreate(BINDING_FORM)).toEqual({
    commandType: 'location_encounter_binding_create',
    payload: { location_id: 'loc-uuid-a', encounter_profile_id: 'ep-uuid-a', weight: 1 },
  })
})

test('location_encounter_binding_update: target_id is the BINDING UUID + expected_revision, only weight mutates', () => {
  expect(buildLocationBindingUpdate('binding-uuid-1', 4, { ...BINDING_FORM, weight: 5 })).toEqual({
    commandType: 'location_encounter_binding_update',
    payload: { target_id: 'binding-uuid-1', expected_revision: 4, weight: 5 },
  })
})

test('location_encounter_binding_set_active: target_id is the BINDING UUID', () => {
  expect(buildSetActive('location_encounter_binding_set_active', 'binding-uuid-1', 4, false)).toEqual({
    commandType: 'location_encounter_binding_set_active',
    payload: { target_id: 'binding-uuid-1', expected_revision: 4, active: false },
  })
})
