import { supabase } from '../../lib/supabase'

// COMBAT-S2 TELEGRAPH — client reads for the pre-combat warning beat.
// get_my_pending_encounter() returns the caller's soonest still-telegraphed encounter (or null);
// combat_flee_pending withdraws the fleet home before combat starts. Both are owner-scoped RPCs.
// While the server flag combat_telegraph_enabled is dark the table is empty → the read is always null →
// the banner never mounts (fail-closed by data, no compile gate needed).

export interface PendingEncounter {
  pending_id: string
  fleet_id: string
  location_id: string | null
  location_name: string | null
  activity: string
  trigger_at: string
}

export async function fetchMyPendingEncounter(): Promise<PendingEncounter | null> {
  const { data, error } = await supabase.rpc('get_my_pending_encounter')
  if (error) throw new Error(error.message)
  return (data as PendingEncounter | null) ?? null
}

export async function fleePending(fleetId: string): Promise<void> {
  const { data, error } = await supabase.rpc('combat_flee_pending', { p_fleet_id: fleetId })
  if (error) throw new Error(error.message)
  const res = data as { ok?: boolean; reason?: string } | null
  if (res && res.ok === false) throw new Error(res.reason ?? 'flee_failed')
}
