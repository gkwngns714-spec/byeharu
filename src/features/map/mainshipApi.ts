import { supabase } from '../../lib/supabase'

// Phase 10B (revised) — READ-ONLY main-ship view. Shows the player's persistent main ship and
// its base stats only. No support craft, no support capacity, no loadout. Pure reads
// (owner-read instance + public hull); never writes.
//
// NOTE: support capacity / support craft is DEPRECATED (see docs/MAINSHIP_TRANSITION.md). The
// backend get_my_expedition_preview / calculate_expedition_stats / support_craft_types remain
// in place but DORMANT and are no longer used by the UI.

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
