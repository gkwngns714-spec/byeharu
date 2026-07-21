// E4 — COMBAT CONTENT: the ONE read-only snapshot the Combat Content panel renders from. It composes
// the THREE already-built read adapters (enemyRegistryData 0257, fleetEncounterData 0258,
// locationEncounterBindingData 0259) into ONE typed object each sub-panel reads a slice of. Like
// worldEditorData.ts it is the read-only IO boundary: SELECT-only reads through those adapters, NO
// write RPC, NO .insert/.update/.rpc, NO game_config write, NO mutation. Every source already fails
// CLOSED to [] (the mapApi never-throw-into-render convention), so this snapshot is honestly-empty
// rather than throwing when the DARK tables are unreadable / the flags are off.
import {
  fetchEnemyRegistryData,
  type EnemyArchetypeRow,
  type RewardProfileRow,
} from './enemyRegistryData'
import {
  fetchFleetEncounterData,
  type EncounterProfileRow,
  type FleetTemplateRow,
} from './fleetEncounterData'
import {
  fetchLocationEncounterBindingData,
  type LocationEncounterBindingRow,
} from './locationEncounterBindingData'

/** The unified read-only combat-content snapshot. Each sub-panel reads exactly one slice of THIS. */
export interface CombatContentData {
  readonly rewardProfiles: RewardProfileRow[]
  readonly enemyArchetypes: EnemyArchetypeRow[]
  readonly fleetTemplates: FleetTemplateRow[]
  readonly encounterProfiles: EncounterProfileRow[]
  readonly bindings: LocationEncounterBindingRow[]
}

/** Fetch all three combat-content catalogs in parallel into ONE snapshot. Read-only throughout —
 *  it only calls the three read adapters, never a write path. Fails CLOSED to empty per source. */
export async function fetchCombatContentData(): Promise<CombatContentData> {
  const [registry, fleetEncounter, bindingData] = await Promise.all([
    fetchEnemyRegistryData(),
    fetchFleetEncounterData(),
    fetchLocationEncounterBindingData(),
  ])
  return {
    rewardProfiles: registry.rewardProfiles,
    enemyArchetypes: registry.enemyArchetypes,
    fleetTemplates: fleetEncounter.fleetTemplates,
    encounterProfiles: fleetEncounter.encounterProfiles,
    bindings: bindingData.bindings,
  }
}
