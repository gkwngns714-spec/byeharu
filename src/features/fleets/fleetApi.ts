import { supabase } from '../../lib/supabase'
import type { DispatchResult, Fleet, FleetMovement, FleetUnit, LocationPresence } from './fleetTypes'

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
  const { data, error } = await supabase.from('fleet_movements').select('*').eq('status', 'moving')
  if (error) throw new Error(error.message)
  return (data as FleetMovement[]) ?? []
}

export async function fetchActivePresences(): Promise<LocationPresence[]> {
  const { data, error } = await supabase.from('location_presence').select('*').eq('status', 'active')
  if (error) throw new Error(error.message)
  return (data as LocationPresence[]) ?? []
}

export interface SelectedUnit {
  unit_type_id: string
  quantity: number
}

export async function sendFleetToLocation(
  baseId: string,
  locationId: string,
  units: SelectedUnit[],
): Promise<DispatchResult> {
  const { data, error } = await supabase.rpc('send_fleet_to_location', {
    p_base: baseId,
    p_location: locationId,
    p_units: units,
  })
  if (error) throw new Error(error.message)
  return data as DispatchResult
}

export async function requestLeaveLocation(presenceId: string): Promise<{ return_movement_id: string }> {
  const { data, error } = await supabase.rpc('request_leave_location', { p_presence: presenceId })
  if (error) throw new Error(error.message)
  return data as { return_movement_id: string }
}
