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
  const { data, error } = await supabase.from('fleet_movements').select('*').eq('status', 'moving')
  if (error) throw new Error(error.message)
  return (data as FleetMovement[]) ?? []
}

export async function fetchActivePresences(): Promise<LocationPresence[]> {
  const { data, error } = await supabase.from('location_presence').select('*').eq('status', 'active')
  if (error) throw new Error(error.message)
  return (data as LocationPresence[]) ?? []
}
