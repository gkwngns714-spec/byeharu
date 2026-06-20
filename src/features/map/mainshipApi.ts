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

// OSN-2 spatial-mode selector (migration 0054). NULL on every row today (legacy): no writer sets
// a non-null value yet. Position for NULL rows still comes from the base/fleet/movement/presence
// model; only 'in_space' (a future OSN-3/4 writer) carries ship-owned coordinates.
export type SpatialState = 'home' | 'at_location' | 'in_transit' | 'in_space' | 'destroyed'

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
  current_location_id: string | null // set when present (used to exclude the current location)
}

const ACTIVE_FLEET_STATUSES = ['moving', 'present', 'returning']

/**
 * Owner-read the caller's active main-ship fleet (the one tagged with this ship), if any.
 * Returns null when the ship is idle at home (no in-flight linked fleet).
 */
export async function fetchActiveMainShipFleet(mainShipId: string): Promise<MainShipFleet | null> {
  const { data, error } = await supabase
    .from('fleets')
    .select('id, status, current_location_id')
    .eq('main_ship_id', mainShipId)
    .in('status', ACTIVE_FLEET_STATUSES)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) return null // non-fatal: treat as no active fleet (home)
  return (data as MainShipFleet) ?? null
}

// The active location-presence row for a main-ship fleet (owner-read). Used ONLY to validate a
// named-location marker per the OSN-2b deterministic rule (fleet present ∧ current_location_id ∧
// matching ACTIVE presence). Read-only; no new polling — fetched inside the existing map poll.
export interface MainShipPresence {
  fleet_id: string
  location_id: string | null
  status: string // 'active' is the only state that validates a present-at-location marker
}

/**
 * Owner-read the ACTIVE location-presence row for a main-ship fleet, if any. Returns null when the
 * fleet has no active presence (e.g. moving/returning, or none). No RPC; owner-read RLS on
 * location_presence already grants SELECT to the authenticated owner.
 */
export async function fetchActiveMainShipPresence(fleetId: string): Promise<MainShipPresence | null> {
  const { data, error } = await supabase
    .from('location_presence')
    .select('fleet_id, location_id, status')
    .eq('fleet_id', fleetId)
    .eq('status', 'active')
    .order('entered_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) return null // non-fatal: treat as no active presence
  return (data as MainShipPresence) ?? null
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

// Move a PRESENT main-ship fleet directly from its current location to another valid non-combat
// location — no forced return home (move_main_ship_to_location RPC). Server re-validates present +
// non-combat + not-the-current-location.
export interface MainShipMoveResult {
  fleet_id: string
  movement_id: string
  main_ship_id: string
  from_location_id: string
  to_location_id: string
  arrive_at: string
}
export async function moveMainShipToLocation(fleetId: string, locationId: string): Promise<MainShipMoveResult> {
  const { data, error } = await supabase.rpc('move_main_ship_to_location', { p_fleet: fleetId, p_location: locationId })
  if (error) throw new Error(error.message)
  return data as MainShipMoveResult
}

// Phase 10F — repair a disabled main ship (status='destroyed' = disabled/needs-repair for a
// PERSISTENT ship; never deletion). The only normal player recovery path; instant + free, restores
// hp=max_hp and status='home'. Not routed through any legacy fleet API.
export async function repairMainShip(): Promise<{ main_ship_id: string; status: string; hp: number; max_hp: number }> {
  const { data, error } = await supabase.rpc('repair_main_ship', {})
  if (error) throw new Error(error.message)
  return data as { main_ship_id: string; status: string; hp: number; max_hp: number }
}
