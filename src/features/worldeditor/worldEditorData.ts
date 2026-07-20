// WORLD EDITOR — the ONE read-only data snapshot the shell fetches (§WE.13 phase 1/2: "unified
// read-only world view"). It composes the EXISTING read sources, every one SELECT/read-RPC only:
//   • locations   — get_world_map (mapApi.fetchWorldMap), flattened once
//   • zoneRefs     — the SAME get_world_map response, flattened to (zone_id, names) — the raw tree
//                    already carries zone uuids; the create-location zone picker reads THIS slice
//                    (0252 location_create), so NO additional server read exists for zones
//   • mining       — get_active_mining_fields (miningApi.getActiveMiningFields), [] while mining dark
//   • exploration  — exploration_sites SELECT (explorationApi.getVisibleExplorationSites), [] under RLS
//   • zones        — get_danger_zones (pirateApi.fetchDangerZones), [] while intercept dark
// NO write RPC, NO game_config write, NO mutation. Each source already fails CLOSED to an empty
// result, so the editor renders honestly-sparse rather than throwing into the render path.
import { fetchWorldMap } from '../map/mapApi'
import { flattenWorldMapLocations, flattenWorldMapZones, type MapLocation, type WorldMapZoneRef } from '../map/mapTypes'
import { getActiveMiningFields } from '../mining/miningApi'
import type { MiningField } from '../mining/miningTypes'
import { getVisibleExplorationSites, type ExplorationSiteLite } from '../exploration/explorationApi'
import { fetchDangerZones, type DangerZoneLite } from '../map/pirateApi'

/** The unified read-only snapshot. Every adapter reads a slice of THIS one object (§WE.2). */
export interface WorldEditorData {
  readonly locations: MapLocation[]
  /** The zone references (uuid + names) from the SAME get_world_map fetch — the create-location
   *  zone picker's source (0252). Distinct from `zones` (the danger-zone display layer). */
  readonly zoneRefs: WorldMapZoneRef[]
  readonly miningFields: MiningField[]
  readonly explorationSites: ExplorationSiteLite[]
  readonly zones: DangerZoneLite[]
}

/** Fetch every layer's read source in parallel. Read-only throughout — no argument mutates state. */
export async function fetchWorldEditorData(): Promise<WorldEditorData> {
  const [world, miningFields, explorationSites, zones] = await Promise.all([
    fetchWorldMap(),
    getActiveMiningFields(),
    getVisibleExplorationSites(),
    fetchDangerZones(),
  ])
  return {
    locations: flattenWorldMapLocations(world),
    zoneRefs: flattenWorldMapZones(world),
    miningFields,
    explorationSites,
    zones,
  }
}
