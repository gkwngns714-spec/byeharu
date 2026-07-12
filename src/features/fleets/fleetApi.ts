import { supabase } from '../../lib/supabase'
import type { Fleet, FleetMovement, FleetUnit, LocationPresence } from './fleetTypes'

// Fleet/Movement/Presence client API. The client only REQUESTS actions through
// RPCs and reads owner-scoped state; the server validates and decides results.

export async function fetchFleets(): Promise<Fleet[]> {
  const { data, error } = await supabase
    .from('fleets')
    .select('*')
    .order('created_at', { ascending: false })
  if (error) throw new Error(error.message)
  return (data as Fleet[]) ?? []
}

export async function fetchFleetUnits(): Promise<FleetUnit[]> {
  const { data, error } = await supabase.from('fleet_units').select('*')
  if (error) throw new Error(error.message)
  return (data as FleetUnit[]) ?? []
}

export async function fetchActiveMovements(): Promise<FleetMovement[]> {
  // TEAMMAP-0: embed the parent fleet's informational group_id tag (0168 display-only law) and
  // flatten it onto each row — additive: every existing consumer sees the same row shape plus the
  // optional tag. Plain (left) embed: both tables are owner-scoped by RLS, and a missing fleet row
  // just yields group_id null (never drops the movement).
  //
  // `!fleet_id` (the COLUMN hint) is REQUIRED, not decoration: fleet_movements↔fleets has TWO
  // relationships (fleet_movements.fleet_id → fleets.id AND fleets.active_movement_id →
  // fleet_movements.id, both from migration 20260616000007), so a bare `fleets(group_id)` embed
  // is AMBIGUOUS and PostgREST rejects the whole query at runtime with PGRST201 — which would
  // throw here and error-state the map AND dashboard for every player. Do not simplify it away.
  const { data, error } = await supabase
    .from('fleet_movements')
    .select('*, fleets!fleet_id(group_id)')
    .eq('status', 'moving')
  if (error) throw new Error(error.message)
  const rows = (data ?? []) as (FleetMovement & { fleets?: { group_id: string | null } | null })[]
  return rows.map(({ fleets, ...m }) => ({ ...m, group_id: fleets?.group_id ?? null }))
}

export async function fetchActivePresences(): Promise<LocationPresence[]> {
  const { data, error } = await supabase.from('location_presence').select('*').eq('status', 'active')
  if (error) throw new Error(error.message)
  return (data as LocationPresence[]) ?? []
}
