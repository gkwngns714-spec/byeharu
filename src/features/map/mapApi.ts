import { supabase } from '../../lib/supabase'
import type { LocationState, WorldMap } from './mapTypes'

/**
 * Read-only fetch of the static world map via the get_world_map() RPC.
 * The Map system is purely structural; this call never mutates game state.
 */
export async function fetchWorldMap(): Promise<WorldMap> {
  const { data, error } = await supabase.rpc('get_world_map')
  if (error) throw new Error(error.message)
  return (data as WorldMap) ?? { sectors: [] }
}

/**
 * M5: read-only fetch of live World State (location_state is public-read). Keyed
 * by location_id for easy lookup beside the static map. Display-only; the client
 * never writes world state.
 */
export async function fetchLocationStates(): Promise<Record<string, LocationState>> {
  const { data, error } = await supabase
    .from('location_state')
    .select('location_id, pressure, danger_modifier, active_fleets')
  if (error) throw new Error(error.message)
  const byId: Record<string, LocationState> = {}
  for (const row of (data ?? []) as LocationState[]) byId[row.location_id] = row
  return byId
}
