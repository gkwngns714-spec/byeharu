import { supabase } from '../../lib/supabase'
import type { CombatEncounter, CombatEvent, CombatReport, CombatTick, CombatUnit } from './combatTypes'

// Combat client API — read-only reads + the retreat request. The client never
// triggers combat resolution (process_combat_ticks is cron-only and locked down).

export async function fetchActiveEncounters(): Promise<CombatEncounter[]> {
  const { data, error } = await supabase
    .from('combat_encounters')
    .select('*')
    .in('status', ['active', 'retreating'])
    .order('created_at', { ascending: false })
  if (error) throw new Error(error.message)
  return (data as CombatEncounter[]) ?? []
}

export async function fetchCombatEvents(encounterIds: string[]): Promise<CombatEvent[]> {
  if (encounterIds.length === 0) return []
  const { data, error } = await supabase
    .from('combat_events')
    .select('*')
    .in('encounter_id', encounterIds)
    .order('id', { ascending: false })
    .limit(60)
  if (error) throw new Error(error.message)
  return (data as CombatEvent[]) ?? []
}

export async function fetchCombatUnits(encounterIds: string[]): Promise<CombatUnit[]> {
  if (encounterIds.length === 0) return []
  const { data, error } = await supabase.from('combat_units').select('*').in('encounter_id', encounterIds)
  if (error) throw new Error(error.message)
  return (data as CombatUnit[]) ?? []
}

export async function fetchRecentTicks(encounterIds: string[]): Promise<CombatTick[]> {
  if (encounterIds.length === 0) return []
  const { data, error } = await supabase
    .from('combat_ticks')
    .select('*')
    .in('encounter_id', encounterIds)
    .order('id', { ascending: false })
    .limit(40)
  if (error) throw new Error(error.message)
  return (data as CombatTick[]) ?? []
}

export async function fetchCombatReports(): Promise<CombatReport[]> {
  const { data, error } = await supabase.rpc('get_combat_reports')
  if (error) throw new Error(error.message)
  return (data as CombatReport[]) ?? []
}

// M6: full per-tick log for ONE past encounter (drives the report-page round log).
// Read-only; RLS (combat_ticks_select_own) ensures only the caller's own ticks load.
// No service-role key — this runs as the authenticated player.
export async function fetchTicksForEncounter(encounterId: string): Promise<CombatTick[]> {
  const { data, error } = await supabase
    .from('combat_ticks')
    .select('*')
    .eq('encounter_id', encounterId)
    .order('tick_number', { ascending: true })
  if (error) throw new Error(error.message)
  return (data as CombatTick[]) ?? []
}

export async function requestRetreat(presenceId: string): Promise<void> {
  const { error } = await supabase.rpc('request_retreat', { p_presence: presenceId })
  if (error) throw new Error(error.message)
}
