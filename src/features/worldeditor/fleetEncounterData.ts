// FLEET TEMPLATES + ENCOUNTER PROFILES (0258) — the READ-ONLY data snapshot for the four net-new
// owner-authored tables (enemy_fleet_templates + its members child; encounter_profiles + its members
// child). Mirrors enemyRegistryData.ts: it composes SELECT-only reads of the public-read catalogs into
// ONE typed object each adapter reads a slice of, embedding each parent's normalized members via a
// PostgREST embedded child select. NO write RPC, NO game_config write, NO mutation. Each source fails
// CLOSED to [] on any transport error (the mapApi.ts never-throw-into-render convention) — the surface
// renders honestly-empty rather than throwing. The tables are DARK: authoring goes through the
// owner-gated 0258 RPCs behind the fail-closed enemy_content_registry_enabled + encounter_authoring_enabled
// flags; this module only READS the resulting rows.
//
// PURE-ish IO boundary: like enemyRegistryData.ts this is the ONE module that issues the catalog
// SELECTs; the adapters (fleetEncounterAdapters.ts) that project these rows into typed fields are pure.
import { supabase } from '../../lib/supabase'

/** One enemy_fleet_template_members row as the editor reads it (a member = archetype ref + numerics). */
export interface FleetTemplateMemberRow {
  readonly enemy_archetype_id: string
  readonly min_count: number
  readonly max_count: number
  readonly weight: number
  readonly elite_chance: number
}

/** One enemy_fleet_templates row (authoring fields only; public-read catalog) + its members. */
export interface FleetTemplateRow {
  readonly id: string
  readonly key: string
  readonly display_name: string
  readonly active: boolean
  readonly revision: number
  readonly notes: string | null
  readonly members: FleetTemplateMemberRow[]
}

/** One encounter_profile_members row as the editor reads it (a member = fleet ref + weight). */
export interface EncounterProfileMemberRow {
  readonly fleet_template_id: string
  readonly weight: number
}

/** One encounter_profiles row (authoring fields only) + its members. reward_override_id is nullable. */
export interface EncounterProfileRow {
  readonly id: string
  readonly key: string
  readonly display_name: string
  readonly difficulty: number
  readonly active_encounter_cap: number
  readonly cooldown_seconds: number
  readonly reward_override_id: string | null
  readonly active: boolean
  readonly revision: number
  readonly notes: string | null
  readonly members: EncounterProfileMemberRow[]
}

/** The unified read-only snapshot (both parents, each with members). Each adapter reads a slice of THIS. */
export interface FleetEncounterData {
  readonly fleetTemplates: FleetTemplateRow[]
  readonly encounterProfiles: EncounterProfileRow[]
}

/** SELECT-only read of enemy_fleet_templates + embedded members (public read, 0258). Fails CLOSED to []. */
export async function getFleetTemplates(): Promise<FleetTemplateRow[]> {
  const { data, error } = await supabase
    .from('enemy_fleet_templates')
    .select(
      'id, key, display_name, active, revision, notes, ' +
        'members:enemy_fleet_template_members(enemy_archetype_id, min_count, max_count, weight, elite_chance)',
    )
  if (error || !Array.isArray(data)) return []
  // PostgREST returns [] for an empty embedded to-many and null for null columns — the row shape already
  // matches FleetTemplateRow; cast through unknown to shed the embedded-select union (as enemyRegistryData.ts).
  return data as unknown as FleetTemplateRow[]
}

/** SELECT-only read of encounter_profiles + embedded members (public read, 0258). Fails CLOSED to []. */
export async function getEncounterProfiles(): Promise<EncounterProfileRow[]> {
  const { data, error } = await supabase
    .from('encounter_profiles')
    .select(
      'id, key, display_name, difficulty, active_encounter_cap, cooldown_seconds, reward_override_id, ' +
        'active, revision, notes, members:encounter_profile_members(fleet_template_id, weight)',
    )
  if (error || !Array.isArray(data)) return []
  return data as unknown as EncounterProfileRow[]
}

/** Fetch both composition catalogs in parallel. Read-only throughout — no argument mutates state. */
export async function fetchFleetEncounterData(): Promise<FleetEncounterData> {
  const [fleetTemplates, encounterProfiles] = await Promise.all([
    getFleetTemplates(),
    getEncounterProfiles(),
  ])
  return { fleetTemplates, encounterProfiles }
}
