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

// ── THE SAFETY LINE, PER FIGHT (0310) ──────────────────────────────────────────────────────────────
// `ship_groups.auto_exit_enabled` / `auto_exit_hp_pct` decide whether a fleet pulls itself out, and
// they decided real production fights with nothing on screen saying so. The combat surfaces address
// an ENCOUNTER, not a group, so this resolves the hop the client never had: encounter.fleet_id →
// fleets.group_id → ship_groups' two columns. Both reads are owner-RLS'd plain selects (the same
// posture as teamApi.fetchMyGroupAutoExit, which is the FLEET screen's reader of the same columns;
// this one is keyed by encounter and belongs with the combat reads).
//
// FAIL CLOSED, NEVER FAIL LOUD. A pre-0310 database — or any read error — yields {} and every
// surface then says NOTHING about auto-retreat: it must never imply "there is no line" from a failed
// read. It is deliberately OFF the quiet path too: useCombat asks for it only while a fight exists,
// so a map with no battle issues no extra request at all.
export interface EncounterFleetRef {
  id: string
  fleet_id: string
}

export async function fetchAutoExitByEncounter(
  encounters: readonly EncounterFleetRef[],
): Promise<Record<string, { enabled: boolean; pct: number }>> {
  const fleetIds = [...new Set(encounters.map((e) => e.fleet_id).filter(Boolean))]
  if (fleetIds.length === 0) return {}
  const fleets = await supabase.from('fleets').select('id, group_id').in('id', fleetIds)
  if (fleets.error || !fleets.data) return {}
  const groupByFleet = new Map<string, string>()
  for (const row of fleets.data as { id: string; group_id: string | null }[]) {
    if (row.group_id) groupByFleet.set(row.id, row.group_id)
  }
  const groupIds = [...new Set(groupByFleet.values())]
  if (groupIds.length === 0) return {}
  const groups = await supabase
    .from('ship_groups')
    .select('group_id, auto_exit_enabled, auto_exit_hp_pct')
    .in('group_id', groupIds)
  if (groups.error || !groups.data) return {}
  const settingByGroup = new Map<string, { enabled: boolean; pct: number }>()
  for (const row of groups.data as {
    group_id: string
    auto_exit_enabled: boolean | null
    auto_exit_hp_pct: number | string | null
  }[]) {
    // numeric arrives as a string over PostgREST; a malformed row is skipped, never fabricated.
    const pct = typeof row.auto_exit_hp_pct === 'string' ? Number(row.auto_exit_hp_pct) : row.auto_exit_hp_pct
    if (typeof row.auto_exit_enabled !== 'boolean' || typeof pct !== 'number' || !Number.isFinite(pct)) continue
    settingByGroup.set(row.group_id, { enabled: row.auto_exit_enabled, pct })
  }
  const out: Record<string, { enabled: boolean; pct: number }> = {}
  for (const e of encounters) {
    const gid = groupByFleet.get(e.fleet_id)
    const setting = gid ? settingByGroup.get(gid) : undefined
    if (setting) out[e.id] = setting
  }
  return out
}
