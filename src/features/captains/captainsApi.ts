import { supabase } from '../../lib/supabase'
import type {
  AssignCaptainResult,
  CaptainRecipe,
  ConfigureRoomResult,
  GetMyCaptainInstancesResult,
  GetShipRoomSlotsResult,
  RecipeIngredient,
  RecruitCaptainResult,
  UnassignCaptainResult,
} from './captainsTypes'
import type { ShipStation } from './deckStations'

// CAPTAIN-P15 (post-audit UI, panel 3 of 4) — typed client API for the dark Captains surface: the roster
// read (get_my_captain_instances, 0123) + the two assign/unassign commands (0120/0121). Mirrors
// miningApi.ts conventions: thin supabase.rpc wrappers; on a transport/DB error resolve to a normalized
// fail-closed value (never throw a raw error into the render path). Reads ONLY the roster RPC and submits
// ONLY the two existing commands — NO new server authority. The wrapper request_id param is TEXT, so the
// client passes a crypto.randomUUID() STRING (36 chars — inside the server's length cap). DARK: the
// server rejects every RPC while captain_assignment_enabled is false (captain_assignment_disabled).

/** Read the caller's captain roster (each row carries its assigned main_ship_id or null). Dark →
 *  { ok:false, reason:'captain_assignment_disabled' }; transport error → { ok:false } (fail-closed). */
export async function getMyCaptainInstances(): Promise<GetMyCaptainInstancesResult> {
  const { data, error } = await supabase.rpc('get_my_captain_instances', {})
  if (error) return { ok: false }
  return data as GetMyCaptainInstancesResult
}

/** Assign a captain to the player's main ship (idempotent on (player, request_id); server-authoritative
 *  on ownership/slots/settled-safe/stations). request_id is TEXT. DECKS-2: `station` is the optional
 *  deck station id (ship_stations) — omitted/null lets the server auto-assign the lowest-sort free
 *  station (0189). p_station is only SENT when a station was picked, so the default call keeps the
 *  exact pre-0189 wire shape (defaulted param server-side — deploy-order safe). Transport error →
 *  { ok:false, reason:'unavailable' }. */
export async function assignCaptainToShip(
  requestId: string,
  captainInstanceId: string,
  mainShipId: string,
  station?: string | null,
): Promise<AssignCaptainResult> {
  const { data, error } = await supabase.rpc('assign_captain_to_ship', {
    p_request_id: requestId,
    p_captain_instance_id: captainInstanceId,
    p_main_ship_id: mainShipId,
    ...(station != null ? { p_station: station } : {}),
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as AssignCaptainResult
}

/** Unassign a captain from its ship (idempotent on (player, request_id)). request_id is TEXT.
 *  Transport error → { ok:false, reason:'unavailable' } (fail-closed). */
export async function unassignCaptainFromShip(
  requestId: string,
  captainInstanceId: string,
): Promise<UnassignCaptainResult> {
  const { data, error } = await supabase.rpc('unassign_captain_from_ship', {
    p_request_id: requestId,
    p_captain_instance_id: captainInstanceId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as UnassignCaptainResult
}

// ── DECKS-2: the deck-station catalog read ──────────────────────────────────────────────────────────

/**
 * Read the six-station deck catalog (ship_stations, 0189) by DIRECT public-read select — the exact
 * catalog convention getCaptainRecipes uses for captain_types/item_types; NO new server RPC. Ordered
 * by sort (the server's auto-assign walk). Fail-closed: any error → [] (the decks board and the
 * station picker simply don't render — the captains section falls back to its pre-DECKS shape).
 */
export async function getShipStations(): Promise<ShipStation[]> {
  const { data, error } = await supabase
    .from('ship_stations')
    .select('station_id, name, sort, affinity_specialization')
    .order('sort', { ascending: true })
  if (error || !data) return []
  return data as ShipStation[]
}

// ── ROOMS-8 (0203): the configurable room-slot read + config command ────────────────────────────────

/** Read ONE owned ship's 8 configurable room-slots (get_my_ship_room_slots, 0203; owner-scoped,
 *  dark-gated on the SAME captain flag). Dark → { ok:false, reason:'captain_assignment_disabled' };
 *  transport error → { ok:false } (fail-closed — the board simply doesn't render). */
export async function getMyShipRoomSlots(mainShipId: string): Promise<GetShipRoomSlotsResult> {
  const { data, error } = await supabase.rpc('get_my_ship_room_slots', { p_main_ship_id: mainShipId })
  if (error) return { ok: false }
  return data as GetShipRoomSlotsResult
}

/** Configure which room type occupies a ship's slot (configure_ship_room, 0203; server-authoritative
 *  on ownership / settled-safe / distinct-room / a room a captain still staffs). Naturally
 *  idempotent (setting a slot to its current room is a no-op success). Transport error →
 *  { ok:false, reason:'unavailable' } (fail-closed). */
export async function configureShipRoom(
  mainShipId: string,
  slotIndex: number,
  roomTypeId: string,
): Promise<ConfigureRoomResult> {
  const { data, error } = await supabase.rpc('configure_ship_room', {
    p_main_ship_id: mainShipId,
    p_slot_index: slotIndex,
    p_room_type_id: roomTypeId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as ConfigureRoomResult
}

// ── CAPTAIN-P16 (post-audit UI, panel 4 of 4): recruitment (progression) ───────────────────────────

/** Recruit a captain of the given type (items-only cost; idempotent on (player, request_id); the server
 *  is the AUTHORITATIVE captain_progression_enabled gate — returns feature_disabled while dark). The
 *  request_id is a crypto.randomUUID() STRING (the wrapper's TEXT param). Transport error →
 *  { ok:false, code:'unavailable' } (fail-closed). */
export async function recruitCaptain(
  requestId: string,
  captainType: string,
): Promise<RecruitCaptainResult> {
  const { data, error } = await supabase.rpc('recruit_captain', {
    p_request_id: requestId,
    p_captain_type: captainType,
  })
  if (error) return { ok: false, code: 'unavailable' }
  return data as RecruitCaptainResult
}

/**
 * Read the recruitable captain recipes by DIRECT public-read selects over the shipped catalogs
 * (captain_recipe_ingredients + captain_types + item_types — the same direct-select convention the app
 * already uses for captain_types/item_types), assembled client-side into per-type recipes with display
 * names. NO new server RPC. Fail-closed: any error on any select → [] (the panel simply shows no recipes).
 */
export async function getCaptainRecipes(): Promise<CaptainRecipe[]> {
  const [recipes, types, items] = await Promise.all([
    supabase.from('captain_recipe_ingredients').select('captain_type_id, item_id, qty'),
    supabase.from('captain_types').select('id, name, specialization'),
    supabase.from('item_types').select('item_id, name'),
  ])
  if (recipes.error || types.error || items.error || !recipes.data || !types.data || !items.data) return []

  const recData = recipes.data as RecipeIngredient[]
  const typeData = types.data as { id: string; name: string; specialization: string }[]
  const itemData = items.data as { item_id: string; name: string }[]

  const typeById = new Map(typeData.map((t) => [t.id, t]))
  const itemName = new Map(itemData.map((i) => [i.item_id, i.name]))

  const byType = new Map<string, CaptainRecipe>()
  for (const r of recData) {
    const t = typeById.get(r.captain_type_id)
    if (!t) continue // an ingredient with no catalog type (should not happen) is skipped, not shown
    let rec = byType.get(r.captain_type_id)
    if (!rec) {
      rec = { captain_type_id: r.captain_type_id, name: t.name, specialization: t.specialization, ingredients: [] }
      byType.set(r.captain_type_id, rec)
    }
    rec.ingredients.push({ item_id: r.item_id, item_name: itemName.get(r.item_id) ?? r.item_id, qty: r.qty })
  }
  return [...byType.values()]
}
