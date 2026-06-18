import { supabase } from '../../lib/supabase'

// Main-ship client API.
//
// Phase 10B (revised) — READ-ONLY main-ship view (fetchMyMainShip): name, hull, base stats.
// No support craft, no support capacity, no loadout. NOTE: support capacity / support craft is
// DEPRECATED (see docs/MAINSHIP_TRANSITION.md); the dormant backend stays but the UI never uses it.
//
// Phase 10D — thin client wrappers over the VERIFIED 10C non-combat write path
// (send_main_ship_expedition / request_main_ship_return) + a small owner-read of the active
// linked fleet for live status. The client only REQUESTS; the server validates and decides.
// Main ships are NOT old fleet_units: the linked fleet carries zero units and is only used here
// to read status (moving/present/returning) and to address the return RPC by fleet id.

export interface MainShipRow {
  name: string
  status: string
  hp: number
  max_hp: number
  cargo_capacity: number
  captain_slots: number
  module_slots: number
  hull_type_id: string
}

export interface HullRow {
  hull_type_id: string
  name: string
  base_hp: number
  base_speed: number
  base_cargo_capacity: number
  base_captain_slots: number
  base_module_slots: number
}

export interface MainShipView {
  has_ship: boolean
  ship?: MainShipRow
  hull?: HullRow
}

const HULL_COLS = 'hull_type_id, name, base_hp, base_speed, base_cargo_capacity, base_captain_slots, base_module_slots'

async function fetchHull(hullTypeId: string): Promise<HullRow | undefined> {
  const { data } = await supabase.from('main_ship_hull_types').select(HULL_COLS).eq('hull_type_id', hullTypeId).maybeSingle()
  return (data as HullRow) ?? undefined
}

/** Read the caller's own main ship (owner-read RLS) + its hull. No writes; no support data. */
export async function fetchMyMainShip(): Promise<MainShipView> {
  const { data: ship, error } = await supabase
    .from('main_ship_instances')
    .select('name, status, hp, max_hp, cargo_capacity, captain_slots, module_slots, hull_type_id')
    .maybeSingle() // owner-read RLS → the caller's single ship, or null
  if (error) throw new Error(error.message)

  if (ship) {
    const hull = await fetchHull((ship as MainShipRow).hull_type_id)
    return { has_ship: true, ship: ship as MainShipRow, hull }
  }
  // no ship commissioned yet → read-only starter-hull teaser
  return { has_ship: false, hull: await fetchHull('starter_frigate') }
}

// ── Phase 10D: main-ship send/return + live status ────────────────────────────────

export type MainShipDisplayStatus = 'home' | 'traveling' | 'present' | 'returning'

/** The active fleet linked to a main ship (zero units; status drives the UI). */
export interface MainShipFleet {
  id: string
  status: string // 'moving' | 'present' | 'returning'
}

const ACTIVE_FLEET_STATUSES = ['moving', 'present', 'returning']

/**
 * Owner-read the caller's active main-ship fleet (the one tagged with this ship), if any.
 * Returns null when the ship is idle at home (no in-flight linked fleet).
 */
export async function fetchActiveMainShipFleet(mainShipId: string): Promise<MainShipFleet | null> {
  const { data, error } = await supabase
    .from('fleets')
    .select('id, status')
    .eq('main_ship_id', mainShipId)
    .in('status', ACTIVE_FLEET_STATUSES)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) return null // non-fatal: treat as no active fleet (home)
  return (data as MainShipFleet) ?? null
}

/**
 * Display status derived from the active linked fleet (the main ship's own status row stays
 * 'traveling' while the fleet is 'present', so the fleet is the source of truth here):
 *   no fleet → home · moving → traveling · present → present · returning → returning
 */
export function deriveMainShipStatus(fleet: MainShipFleet | null): MainShipDisplayStatus {
  if (!fleet) return 'home'
  if (fleet.status === 'present') return 'present'
  if (fleet.status === 'returning') return 'returning'
  return 'traveling' // 'moving'
}

export interface MainShipSendResult {
  fleet_id: string
  movement_id: string
  main_ship_id: string
  arrive_at: string
}

/** Send the main ship on a NON-COMBAT expedition (10C RPC; server re-validates everything). */
export async function sendMainShipExpedition(shipId: string, locationId: string): Promise<MainShipSendResult> {
  const { data, error } = await supabase.rpc('send_main_ship_expedition', {
    p_ships: [shipId],
    p_location: locationId,
  })
  if (error) throw new Error(error.message)
  return data as MainShipSendResult
}

/** Recall a main-ship fleet that is currently present at a location (10C RPC). */
export async function requestMainShipReturn(fleetId: string): Promise<{ return_movement_id: string; main_ship_id: string }> {
  const { data, error } = await supabase.rpc('request_main_ship_return', { p_fleet: fleetId })
  if (error) throw new Error(error.message)
  return data as { return_movement_id: string; main_ship_id: string }
}
