import { supabase } from '../../lib/supabase'
import type {
  AssignCaptainResult,
  CaptainRecipe,
  GetMyCaptainInstancesResult,
  RecipeIngredient,
  RecruitCaptainResult,
  UnassignCaptainResult,
} from './captainsTypes'

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
 *  on ownership/slots/settled-safe). request_id is TEXT. Transport error → { ok:false, reason:'unavailable' }. */
export async function assignCaptainToShip(
  requestId: string,
  captainInstanceId: string,
  mainShipId: string,
): Promise<AssignCaptainResult> {
  const { data, error } = await supabase.rpc('assign_captain_to_ship', {
    p_request_id: requestId,
    p_captain_instance_id: captainInstanceId,
    p_main_ship_id: mainShipId,
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
