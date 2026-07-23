// E4 — COMBAT CONTENT: the PURE row⇄draft⇄form mapping for enemy_archetypes authoring. Extracted from
// EnemyArchetypeAuthoring.tsx so the edit-fork round-trip is unit-testable directly (no React import).
// ONE authority for how a live row seeds the edit draft and how the draft ships as an EnemyArchetypeForm.
// NO React, NO supabase, NO network.
//
// M3 — stat_overrides is FREE-FORM jsonb the form has no field for; the edit fork MUST round-trip it
// intact. The pre-M3 toForm hardcoded `stat_overrides: {}`, so editing an archetype that carried overrides
// SILENTLY WIPED them on the next save (buildEnemyArchetypeUpdate omits an empty object). We carry the
// row's value straight through instead.
import type { EnemyArchetypeForm } from './combatPayloads'
import type { EnemyArchetypeRow } from './enemyRegistryData'

/** The archetype authoring draft (form-local edit state). Mirrors EnemyArchetypeForm minus the derived
 *  `notes: null` normalization, plus `stat_overrides` carried opaquely for round-trip. */
export interface ArchetypeDraft {
  key: string
  display_name: string
  faction: string
  unit_type_id: string
  behavior_key: string
  base_difficulty: number
  difficulty_rating: number
  default_reward_profile_id: string
  /** Free-form jsonb the UI does NOT edit — carried through the edit fork unchanged (M3). */
  stat_overrides: Record<string, unknown>
  notes: string
}

export const BLANK_ARCHETYPE_DRAFT: ArchetypeDraft = {
  key: '', display_name: '', faction: '', unit_type_id: '', behavior_key: '',
  base_difficulty: Number.NaN, difficulty_rating: Number.NaN,
  default_reward_profile_id: '', stat_overrides: {}, notes: '',
}

/** Seed an edit draft from a live row. Carries stat_overrides through so a later save can't wipe it (M3). */
export function archetypeDraftFromRow(row: EnemyArchetypeRow): ArchetypeDraft {
  return {
    key: row.key,
    display_name: row.display_name,
    faction: row.faction ?? '',
    unit_type_id: row.unit_type_id,
    behavior_key: row.behavior_key ?? '',
    base_difficulty: row.base_difficulty,
    difficulty_rating: row.difficulty_rating,
    default_reward_profile_id: row.default_reward_profile_id,
    stat_overrides: row.stat_overrides ?? {},
    notes: row.notes ?? '',
  }
}

/** Project a draft into the payload form. stat_overrides passes through unchanged (M3 — was `{}`). */
export function archetypeDraftToForm(d: ArchetypeDraft): EnemyArchetypeForm {
  return {
    key: d.key,
    display_name: d.display_name,
    faction: d.faction,
    unit_type_id: d.unit_type_id,
    behavior_key: d.behavior_key,
    base_difficulty: d.base_difficulty,
    default_reward_profile_id: d.default_reward_profile_id,
    difficulty_rating: d.difficulty_rating,
    stat_overrides: d.stat_overrides,
    notes: d.notes.trim() === '' ? null : d.notes,
  }
}
