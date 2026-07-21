// E4 — COMBAT CONTENT: the PURE typed-error mapper. It turns a WorldEditorCommandFailure from any of the
// E0-E2 owner RPCs into a friendly, no-jargon surface: ONE banner + per-field messages. NO React, NO
// supabase, NO network — unit-testable directly (tests/combatErrorMap.spec.ts). The server is the sole
// authority; this only translates the codes it returns into words a non-engineer owner understands.
//
// Banner rules:
//   • default          → describeWorldEditorError(error) (the shared vocabulary).
//   • not_enabled      → names the EXACT flag chain the owner must light for THIS entity's tier (E0/E1/E2).
//   • stale_revision   → "Someone or something changed this since you opened it - reload and redo."
// Field rules: each details[].code maps to a plain-language message keyed by its field. conflict's
// duplicate_key points at the key field; duplicate_binding points at the encounter picker.
import { describeWorldEditorError, type WorldEditorCommandFailure } from './commandContract'

/** The three fail-closed feature tiers (each adds one flag to the chain the owner must enable). */
export type CombatTier = 'E0' | 'E1' | 'E2'

/** The friendly surface a CombatErrorNotices renders: a banner + field-keyed messages. */
export interface CombatErrorView {
  readonly banner: string
  /** field name → plain-language message. `key` and `encounter_profile_id` map to their pickers. */
  readonly fieldErrors: Record<string, string>
}

/** Plain-language copy for every server detail code across E0-E2 (validation_failed + conflict). */
const DETAIL_MESSAGES: Record<string, string> = {
  // E0 reward_profile / enemy_archetype
  duplicate_key: 'That key is already used - pick a different one.',
  invalid_resource_grants: 'Check the reward amounts - only metal (a base amount and the reward multiplier) is allowed.',
  invalid_unit_type: 'Pick a valid enemy unit type (player-ship types are not allowed).',
  invalid_reward_profile: 'Pick an active reward profile.',
  base_difficulty_invalid: 'Base difficulty must be between 0 and 1000.',
  // E1 fleet_template members
  invalid_archetype_ref: 'One of the chosen enemies no longer exists - reselect it.',
  archetype_inactive: 'One of the chosen enemies is disabled - pick an active one.',
  invalid_count_range: 'Counts must be 0 to 100, and the low count cannot exceed the high count.',
  invalid_elite_chance: 'Elite chance must be between 0 and 1.',
  duplicate_member: 'The same entry is listed twice - remove the duplicate.',
  members_required: 'Add at least one entry.',
  // E1 encounter_profile
  invalid_fleet_ref: 'One of the chosen fleets no longer exists - reselect it.',
  fleet_inactive: 'One of the chosen fleets is disabled - pick an active one.',
  invalid_reward_override: 'Pick an active reward profile, or use the archetype default.',
  invalid_difficulty: 'Difficulty must be between 1 and 1000.',
  invalid_encounter_cap: 'The active limit must be between 1 and 100.',
  invalid_cooldown: 'Cooldown must be between 0 and 86400 seconds.',
  // E2 location_encounter_binding
  invalid_location: 'Pick a location that exists.',
  invalid_encounter_ref: 'Pick an encounter that exists.',
  encounter_inactive: 'Pick an active encounter.',
  invalid_weight: 'Weight must be more than 0 and at most 1000.',
  duplicate_binding: 'This location is already bound to that encounter.',
}

/** Fallback field name when the server omits one, so a detail always lands somewhere visible. */
const DEFAULT_FIELD_FOR_CODE: Record<string, string> = {
  duplicate_key: 'key',
  duplicate_binding: 'encounter_profile_id',
}

/** The flag chain the owner must light, per tier — named plainly in the not_enabled banner. */
const NOT_ENABLED_BANNER: Record<CombatTier, string> = {
  E0: 'This is turned off. An owner must enable enemy_content_registry_enabled first.',
  E1: 'This is turned off. An owner must enable enemy_content_registry_enabled and encounter_authoring_enabled first.',
  E2: 'This is turned off. An owner must enable enemy_content_registry_enabled, encounter_authoring_enabled and encounter_binding_authoring_enabled first.',
}

const STALE_BANNER = 'Someone or something changed this since you opened it - reload and redo.'

/** Map a typed command failure to a friendly banner + field errors for THIS entity's tier. */
export function mapCombatError(failure: WorldEditorCommandFailure, tier: CombatTier): CombatErrorView {
  const banner =
    failure.error === 'not_enabled'
      ? NOT_ENABLED_BANNER[tier]
      : failure.error === 'stale_revision'
        ? STALE_BANNER
        : describeWorldEditorError(failure.error)

  const fieldErrors: Record<string, string> = {}
  for (const detail of failure.details ?? []) {
    const field = detail.field ?? DEFAULT_FIELD_FOR_CODE[detail.code] ?? detail.code
    const message = DETAIL_MESSAGES[detail.code] ?? detail.message ?? 'This value was rejected - please review it.'
    // First message per field wins (server lists most-specific first); never overwrite with a later one.
    if (!(field in fieldErrors)) fieldErrors[field] = message
  }
  return { banner, fieldErrors }
}
