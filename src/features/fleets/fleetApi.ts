import { supabase } from '../../lib/supabase'
import type { DispatchResult, Fleet, FleetMovement, FleetUnit, LocationPresence } from './fleetTypes'
import { isMainShipFleet } from './fleetGuards'

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

// Legacy fleet leave/return. Phase 10E defense-in-depth: the caller MUST pass the fleet behind
// the presence, and this refuses to run for a main-ship fleet even if a future panel forgets to
// filter (see fleetGuards.isMainShipFleet). Main ships recall via request_main_ship_return only.
export async function requestLeaveLocation(
  presenceId: string,
  fleet: Pick<Fleet, 'main_ship_id'>,
): Promise<{ return_movement_id: string }> {
  if (isMainShipFleet(fleet)) {
    throw new Error('requestLeaveLocation: refusing the legacy leave path for a main-ship fleet — recall it from the Galaxy Map 🛰 overlay instead.')
  }
  const { data, error } = await supabase.rpc('request_leave_location', { p_presence: presenceId })
  if (error) throw new Error(error.message)
  return data as { return_movement_id: string }
}
