import { supabase } from '../../lib/supabase'
import type { GroupRow } from './teamRoster'

// TEAM-COMMAND Slice A — owner-scoped reads for team/group data (DARK).
//
// These run ONLY from the TeamRosterPanel, which is mounted behind the compile-time TEAM_COMMAND_ENABLED gate
// (false) — so while dark the panel is never mounted and NEITHER read below ever executes in production.
// That is deliberate: `group_id` does not exist on main_ship_instances until migration 0160 deploys, and these
// reads must not run against a DB that predates it. They read the tables DIRECTLY via owner-select RLS (the
// same pattern as useMainShipSelection) — the roster's ship LIST + selection still come from the ONE shell
// selection (shellState.selection); this only supplies the group metadata + membership the shell doesn't carry.

// The player's teams (backend: ship_groups rows), owner-read, ordered by the deterministic slot.
export async function fetchMyShipGroups(): Promise<GroupRow[]> {
  const { data, error } = await supabase
    .from('ship_groups')
    .select('group_id, group_index, name')
    .order('group_index', { ascending: true })
  if (error || !data) return []
  return data as GroupRow[]
}

// Membership map: main_ship_id → group_id (null = ungrouped). Owner-read; merged onto the shell's ship list
// (which does not carry group_id) so the shell stays the single selection source.
export async function fetchMyShipGroupMap(): Promise<Record<string, string | null>> {
  const { data, error } = await supabase.from('main_ship_instances').select('main_ship_id, group_id')
  if (error || !data) return {}
  const map: Record<string, string | null> = {}
  for (const r of data as { main_ship_id: string; group_id: string | null }[]) {
    map[r.main_ship_id] = r.group_id ?? null
  }
  return map
}
