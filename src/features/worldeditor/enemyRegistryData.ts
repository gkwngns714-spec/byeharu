// ENEMY CONTENT REGISTRY (0257) — the READ-ONLY data snapshot for the two net-new owner-authored
// catalog tables (reward_profiles + enemy_archetypes). Mirrors worldEditorData.ts: it composes
// SELECT-only reads of the public-read catalogs into ONE typed object each adapter reads a slice of.
// NO write RPC, NO game_config write, NO mutation. Each source fails CLOSED to [] on any transport
// error (the mapApi.ts never-throw-into-render convention) — the registry renders honestly-empty
// rather than throwing. The tables are DARK: authoring goes through the owner-gated 0257 RPCs behind
// the fail-closed enemy_content_registry_enabled flag; this module only READS the resulting rows.
//
// PURE-ish IO boundary: like worldEditorData.ts this is the ONE module that issues the catalog
// SELECTs; the adapters (enemyRegistryAdapters.ts) that project these rows into typed fields are pure.
import { supabase } from '../../lib/supabase'

/** One reward_profiles row as the editor reads it (authoring fields only; public-read catalog). */
export interface RewardProfileRow {
  readonly id: string
  readonly key: string
  readonly display_name: string
  readonly resource_grants: Record<string, unknown>
  readonly active: boolean
  readonly revision: number
  readonly notes: string | null
}

/** One enemy_archetypes row as the editor reads it (authoring fields only; NO runtime-instance state). */
export interface EnemyArchetypeRow {
  readonly id: string
  readonly key: string
  readonly display_name: string
  readonly faction: string
  readonly unit_type_id: string
  readonly behavior_key: string
  readonly base_difficulty: number
  readonly default_reward_profile_id: string
  readonly difficulty_rating: number
  readonly stat_overrides: Record<string, unknown>
  readonly active: boolean
  readonly revision: number
  readonly notes: string | null
}

/** The unified read-only registry snapshot (both catalogs). Each adapter reads a slice of THIS. */
export interface EnemyRegistryData {
  readonly rewardProfiles: RewardProfileRow[]
  readonly enemyArchetypes: EnemyArchetypeRow[]
}

/** SELECT-only read of reward_profiles (public read, 0257). Fails CLOSED to [] on any error. */
export async function getRewardProfiles(): Promise<RewardProfileRow[]> {
  const { data, error } = await supabase
    .from('reward_profiles')
    .select('id, key, display_name, resource_grants, active, revision, notes')
  if (error || !Array.isArray(data)) return []
  return data as RewardProfileRow[]
}

/** SELECT-only read of enemy_archetypes (public read, 0257). Fails CLOSED to [] on any error. */
export async function getEnemyArchetypes(): Promise<EnemyArchetypeRow[]> {
  const { data, error } = await supabase
    .from('enemy_archetypes')
    .select('id, key, display_name, faction, unit_type_id, behavior_key, base_difficulty, default_reward_profile_id, difficulty_rating, stat_overrides, active, revision, notes')
  if (error || !Array.isArray(data)) return []
  return data as EnemyArchetypeRow[]
}

/** Fetch both registry catalogs in parallel. Read-only throughout — no argument mutates state. */
export async function fetchEnemyRegistryData(): Promise<EnemyRegistryData> {
  const [rewardProfiles, enemyArchetypes] = await Promise.all([
    getRewardProfiles(),
    getEnemyArchetypes(),
  ])
  return { rewardProfiles, enemyArchetypes }
}
