import { supabase } from '../../lib/supabase'
import type { WorldMap } from './mapTypes'

/**
 * Read-only fetch of the static world map via the get_world_map() RPC.
 * The Map system is purely structural; this call never mutates game state.
 */
export async function fetchWorldMap(): Promise<WorldMap> {
  const { data, error } = await supabase.rpc('get_world_map')
  if (error) throw new Error(error.message)
  return (data as WorldMap) ?? { sectors: [] }
}
