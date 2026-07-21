// E4 — COMBAT CONTENT: the PURE payload builders. ONE authority for the exact command envelope each
// authoring form ships to the already-built E0-E2 owner RPCs. NO React, NO supabase, NO network — every
// builder is a total function from a form value to a {commandType, payload} envelope, so the whole
// address/optimistic-concurrency contract is unit-testable directly (tests/combatPayloads.spec.ts) and
// mirrors the authoritative server envelopes proven by the three contract specs.
//
// Addressing law (mirrors the E0-E2 proofs + contract specs):
//   • create   → flat content {key, display_name, …}; +members for E1; {location_id, encounter_profile_id, weight} for E2.
//   • update   → {target_id, expected_revision, …mutable}. target_id = the natural KEY for E0/E1, the
//                binding UUID for E2. expected_revision = the live row.revision (optimistic concurrency).
//   • set_active → {target_id, expected_revision, active}.
//   • every member ref is the UUID `id` of the referenced row (enemy_archetype_id / fleet_template_id),
//     NEVER the human key.
// Optional fields are omitted when empty (a clean minimal payload the server reads as its default) —
// EXCEPT an update's reward_override_id, which is always sent (including null) so the owner can CLEAR it.
import type { WorldEditorCommandType } from './commandContract'

/** A ready-to-issue command: the kind + its exact server payload. The hook (useCombatAuthoring) is the
 *  ONLY thing that hands this to the command client — this module never touches the network. */
export interface CombatCommand {
  readonly commandType: WorldEditorCommandType
  readonly payload: Record<string, unknown>
}

// ── form value shapes (what the authoring sub-panels hold) ──────────────────────────────────────────
export interface RewardProfileForm {
  readonly key: string
  readonly display_name: string
  readonly resource_grants: Record<string, unknown>
  readonly notes: string | null
}

export interface EnemyArchetypeForm {
  readonly key: string
  readonly display_name: string
  readonly faction: string
  readonly unit_type_id: string
  readonly behavior_key: string
  readonly base_difficulty: number
  readonly default_reward_profile_id: string
  readonly difficulty_rating: number
  readonly stat_overrides: Record<string, unknown>
  readonly notes: string | null
}

/** A fleet member = an enemy-archetype UUID ref + count/weight/elite numerics (REPLACE-ALL on save). */
export interface FleetMemberForm {
  readonly enemy_archetype_id: string
  readonly min_count: number
  readonly max_count: number
  readonly weight: number
  readonly elite_chance: number
}

export interface FleetTemplateForm {
  readonly key: string
  readonly display_name: string
  readonly notes: string | null
  readonly members: readonly FleetMemberForm[]
}

/** An encounter member = a fleet-template UUID ref + weight (REPLACE-ALL on save). */
export interface EncounterMemberForm {
  readonly fleet_template_id: string
  readonly weight: number
}

export interface EncounterProfileForm {
  readonly key: string
  readonly display_name: string
  readonly difficulty: number
  readonly active_encounter_cap: number
  readonly cooldown_seconds: number
  /** null = "archetype default" (no override). Sent as null on UPDATE to clear a prior override. */
  readonly reward_override_id: string | null
  readonly notes: string | null
  readonly members: readonly EncounterMemberForm[]
}

export interface LocationBindingForm {
  readonly location_id: string
  readonly encounter_profile_id: string
  readonly weight: number
}

// ── helpers: include an optional field only when it carries meaning (clean minimal payloads) ─────────
const withNotes = (notes: string | null): Record<string, unknown> =>
  notes && notes.trim() !== '' ? { notes } : {}
const withText = (field: string, value: string): Record<string, unknown> =>
  value.trim() !== '' ? { [field]: value } : {}
const withObject = (field: string, value: Record<string, unknown>): Record<string, unknown> =>
  Object.keys(value).length > 0 ? { [field]: value } : {}

const fleetMemberPayload = (m: FleetMemberForm): Record<string, unknown> => ({
  enemy_archetype_id: m.enemy_archetype_id,
  min_count: m.min_count,
  max_count: m.max_count,
  weight: m.weight,
  elite_chance: m.elite_chance,
})
const encounterMemberPayload = (m: EncounterMemberForm): Record<string, unknown> => ({
  fleet_template_id: m.fleet_template_id,
  weight: m.weight,
})

// ── E0 · reward_profile ─────────────────────────────────────────────────────────────────────────────
export function buildRewardProfileCreate(form: RewardProfileForm): CombatCommand {
  return {
    commandType: 'reward_profile_create',
    payload: {
      key: form.key,
      display_name: form.display_name,
      resource_grants: form.resource_grants,
      ...withNotes(form.notes),
    },
  }
}

export function buildRewardProfileUpdate(
  targetId: string,
  expectedRevision: number,
  form: RewardProfileForm,
): CombatCommand {
  return {
    commandType: 'reward_profile_update',
    payload: {
      target_id: targetId,
      expected_revision: expectedRevision,
      display_name: form.display_name,
      resource_grants: form.resource_grants,
      ...withNotes(form.notes),
    },
  }
}

// ── E0 · enemy_archetype ────────────────────────────────────────────────────────────────────────────
export function buildEnemyArchetypeCreate(form: EnemyArchetypeForm): CombatCommand {
  return {
    commandType: 'enemy_archetype_create',
    payload: {
      key: form.key,
      display_name: form.display_name,
      unit_type_id: form.unit_type_id,
      base_difficulty: form.base_difficulty,
      difficulty_rating: form.difficulty_rating,
      default_reward_profile_id: form.default_reward_profile_id,
      ...withText('faction', form.faction),
      ...withText('behavior_key', form.behavior_key),
      ...withObject('stat_overrides', form.stat_overrides),
      ...withNotes(form.notes),
    },
  }
}

export function buildEnemyArchetypeUpdate(
  targetId: string,
  expectedRevision: number,
  form: EnemyArchetypeForm,
): CombatCommand {
  return {
    commandType: 'enemy_archetype_update',
    payload: {
      target_id: targetId,
      expected_revision: expectedRevision,
      display_name: form.display_name,
      unit_type_id: form.unit_type_id,
      base_difficulty: form.base_difficulty,
      difficulty_rating: form.difficulty_rating,
      default_reward_profile_id: form.default_reward_profile_id,
      ...withText('faction', form.faction),
      ...withText('behavior_key', form.behavior_key),
      ...withObject('stat_overrides', form.stat_overrides),
      ...withNotes(form.notes),
    },
  }
}

// ── E1 · enemy_fleet_template ───────────────────────────────────────────────────────────────────────
export function buildFleetTemplateCreate(form: FleetTemplateForm): CombatCommand {
  return {
    commandType: 'enemy_fleet_template_create',
    payload: {
      key: form.key,
      display_name: form.display_name,
      members: form.members.map(fleetMemberPayload),
      ...withNotes(form.notes),
    },
  }
}

export function buildFleetTemplateUpdate(
  targetId: string,
  expectedRevision: number,
  form: FleetTemplateForm,
): CombatCommand {
  return {
    commandType: 'enemy_fleet_template_update',
    payload: {
      target_id: targetId,
      expected_revision: expectedRevision,
      display_name: form.display_name,
      members: form.members.map(fleetMemberPayload),
      ...withNotes(form.notes),
    },
  }
}

// ── E1 · encounter_profile ──────────────────────────────────────────────────────────────────────────
export function buildEncounterProfileCreate(form: EncounterProfileForm): CombatCommand {
  return {
    commandType: 'encounter_profile_create',
    payload: {
      key: form.key,
      display_name: form.display_name,
      difficulty: form.difficulty,
      active_encounter_cap: form.active_encounter_cap,
      cooldown_seconds: form.cooldown_seconds,
      members: form.members.map(encounterMemberPayload),
      // create: omit when "archetype default" (null) — the server reads absence as no override.
      ...(form.reward_override_id ? { reward_override_id: form.reward_override_id } : {}),
      ...withNotes(form.notes),
    },
  }
}

export function buildEncounterProfileUpdate(
  targetId: string,
  expectedRevision: number,
  form: EncounterProfileForm,
): CombatCommand {
  return {
    commandType: 'encounter_profile_update',
    payload: {
      target_id: targetId,
      expected_revision: expectedRevision,
      display_name: form.display_name,
      difficulty: form.difficulty,
      active_encounter_cap: form.active_encounter_cap,
      cooldown_seconds: form.cooldown_seconds,
      members: form.members.map(encounterMemberPayload),
      // update: ALWAYS sent (including null) so the owner can CLEAR an override to "archetype default".
      reward_override_id: form.reward_override_id,
      ...withNotes(form.notes),
    },
  }
}

// ── E2 · location_encounter_binding (target_id = the binding UUID on update/set_active) ──────────────
export function buildLocationBindingCreate(form: LocationBindingForm): CombatCommand {
  return {
    commandType: 'location_encounter_binding_create',
    payload: {
      location_id: form.location_id,
      encounter_profile_id: form.encounter_profile_id,
      weight: form.weight,
    },
  }
}

export function buildLocationBindingUpdate(
  targetId: string,
  expectedRevision: number,
  form: LocationBindingForm,
): CombatCommand {
  return {
    commandType: 'location_encounter_binding_update',
    payload: {
      target_id: targetId,
      expected_revision: expectedRevision,
      weight: form.weight,
    },
  }
}

// ── set_active (shared shape across all five entities) ───────────────────────────────────────────────
export function buildSetActive(
  commandType: WorldEditorCommandType,
  targetId: string,
  expectedRevision: number,
  active: boolean,
): CombatCommand {
  return {
    commandType,
    payload: { target_id: targetId, expected_revision: expectedRevision, active },
  }
}
