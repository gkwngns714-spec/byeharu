import { supabase } from './supabase'

// Shared reference data (Reference/Config system, read-only on the client).
// Unit stats come from the server; the client mirrors them only for display/preview.

export interface UnitType {
  id: string
  name: string
  attack: number
  defense: number
  hull: number
  speed: number
  cargo: number
  power_score: number
  build_time_seconds: number
  status: string
}

export async function fetchUnitTypes(): Promise<UnitType[]> {
  const { data, error } = await supabase
    .from('unit_types')
    .select('*')
    .eq('status', 'active')
    .order('power_score', { ascending: true })
  if (error) throw new Error(error.message)
  return (data as UnitType[]) ?? []
}

// Public read-only tunables (server is authority; client uses these for display,
// e.g. the retreat countdown length).
export async function fetchGameConfig(): Promise<Record<string, number>> {
  const { data, error } = await supabase.from('game_config').select('key, value')
  if (error) throw new Error(error.message)
  const out: Record<string, number> = {}
  for (const row of (data as Array<{ key: string; value: number }>) ?? []) {
    out[row.key] = Number(row.value)
  }
  return out
}
