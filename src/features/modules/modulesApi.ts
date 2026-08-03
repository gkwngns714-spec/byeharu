import { supabase } from '../../lib/supabase'
import {
  craftModuleErrorMessage,
  fittingErrorMessage,
  type CraftModuleResult,
  type FittingCommandResult,
  type GetMyModuleInstancesResult,
  type GetMyShipFittingsResult,
  type ItemTypeRow,
  type ModuleCatalogEntry,
  type ModuleRecipeIngredientRow,
  type ModuleTypeRow,
} from './modulesTypes'

// MODULES-P13 — typed client API for the dark module-crafting surface: the craft command (0109)
// and the instances read (0110), plus direct selects of the PUBLIC-READ catalogs (0107) and the
// caller's own inventory balances (0039 own-row grant). Mirrors miningApi.ts/explorationApi.ts
// conventions: thin supabase.rpc wrappers; on a transport/DB error resolve to a normalized
// failure (never throw a raw error into the render path). The catalog/balance selects follow the
// mainshipApi.ts direct-select convention for public/owner-read tables — deliberately NO catalog
// RPC exists (0110 header). DARK: the server rejects BOTH RPCs while module_crafting_enabled is
// false (feature_disabled / module_crafting_disabled) — visibility is server-driven, no client
// flag constant.

/**
 * Craft one module instance (idempotent on requestId; server-rejected while dark).
 *
 * 0333 - LAW 3: crafting consumes the DOCKED PORT'S storage, so the command carries the ship whose
 * dock names that port. It is the ship, never a location: the server derives the port itself, so
 * "craft from a port I am not standing in" is not a request this surface can express. Passing null
 * falls back to the server's sole-ship shim.
 */
export async function craftModule(
  requestId: string,
  moduleType: string,
  mainShipId: string | null,
): Promise<CraftModuleResult> {
  const { data, error } = await supabase.rpc('craft_module', {
    p_request_id: requestId,
    p_module_type: moduleType,
    p_main_ship_id: mainShipId,
  })
  if (error) return { ok: false, code: 'unavailable', message: craftModuleErrorMessage('unavailable') }
  return data as CraftModuleResult
}

/** Read the caller's own crafted instances (server-rejected with module_crafting_disabled while dark). */
export async function getMyModuleInstances(): Promise<GetMyModuleInstancesResult> {
  const { data, error } = await supabase.rpc('get_my_module_instances', {})
  if (error) return { ok: false, reason: 'unavailable' }
  return data as GetMyModuleInstancesResult
}

/**
 * Read the public module catalog + recipes (0107; Reference/Config public read — direct selects,
 * the mainshipApi hull-types convention) and pair each type with its ingredient rows.
 * Returns null on a transport/DB error (the caller degrades gracefully; never throws).
 */
export async function fetchModuleCatalog(): Promise<ModuleCatalogEntry[] | null> {
  const [types, recipes] = await Promise.all([
    supabase
      .from('module_types')
      .select(
        'id, name, slot_type, description, slot_cost, stats_json, range, projectile_speed, power, ammo_type, ammo_per_shot, cooldown_seconds',
      )
      .order('name'),
    supabase.from('module_recipe_ingredients').select('module_type_id, item_id, qty').order('item_id'),
  ])
  if (types.error || recipes.error) return null
  const rows = (recipes.data ?? []) as ModuleRecipeIngredientRow[]
  return ((types.data ?? []) as ModuleTypeRow[]).map((t) => ({
    ...t,
    ingredients: rows
      .filter((r) => r.module_type_id === t.id)
      .map((r) => ({ item_id: r.item_id, qty: r.qty })),
  }))
}

/**
 * Read the public item_types catalog display fields (0039; Reference/Config public read — the SAME
 * direct-select convention fetchModuleCatalog uses). Powers inventory item-info (name, category,
 * rarity, description, stackable). No existing reader exposes these display fields — captainsApi's
 * item_types select pulls only item_id/name for recipe labels — so this is a new, additive reader.
 * Returns null on a transport/DB error (the caller degrades gracefully; never throws).
 */
export async function fetchItemCatalog(): Promise<ItemTypeRow[] | null> {
  const { data, error } = await supabase
    .from('item_types')
    .select('item_id, name, category, rarity, description, stackable, icon_key, volume_m3')
    .order('name')
  if (error) return null
  // ASSETS-TAB: volume_m3 (0333) rides this ONE catalog read rather than a second select on the
  // same table. PostgREST hands numeric back as a STRING, so it is coerced here — the one place
  // it enters the client — and a malformed value lands as 0, which every consumer treats as
  // "unknown volume" rather than a free stack.
  return ((data ?? []) as Array<Omit<ItemTypeRow, 'volume_m3'> & { volume_m3: number | string }>).map(
    (r) => ({ ...r, volume_m3: Number(r.volume_m3) || 0 }),
  )
}

// ── FITTING-P14 — the dark module-fitting surface (0113/0114 commands + 0116 read) ──────────────
// Same conventions as the crafting wrappers above; the server rejects all three while
// module_fitting_enabled is false (feature_disabled / module_fitting_disabled).

/** Read the caller's own fittings (server-rejected with module_fitting_disabled while dark). */
export async function getMyShipFittings(): Promise<GetMyShipFittingsResult> {
  const { data, error } = await supabase.rpc('get_my_ship_fittings', {})
  if (error) return { ok: false, reason: 'unavailable' }
  return data as GetMyShipFittingsResult
}

/** Fit an owned module instance to an owned, settled ship (idempotent on requestId). */
export async function fitModuleToShip(
  moduleInstanceId: string,
  mainShipId: string,
  requestId: string,
): Promise<FittingCommandResult> {
  const { data, error } = await supabase.rpc('fit_module_to_ship', {
    p_module_instance_id: moduleInstanceId,
    p_main_ship_id: mainShipId,
    p_request_id: requestId,
  })
  if (error) return { ok: false, code: 'unavailable', message: fittingErrorMessage('unavailable') }
  return data as FittingCommandResult
}

/** Unfit a fitted module instance (idempotent on requestId). */
export async function unfitModuleFromShip(
  moduleInstanceId: string,
  requestId: string,
): Promise<FittingCommandResult> {
  const { data, error } = await supabase.rpc('unfit_module_from_ship', {
    p_module_instance_id: moduleInstanceId,
    p_request_id: requestId,
  })
  if (error) return { ok: false, code: 'unavailable', message: fittingErrorMessage('unavailable') }
  return data as FittingCommandResult
}

/**
 * Read what THIS PORT is holding for the caller - the numbers every "have / need" line in a port
 * panel is measured against.
 *
 * 0333 - items LIVE in port storage, so there is no player-wide balance to read any more and the
 * global `player_inventory` table this used to select from is GONE. The ONE authority for "how much
 * do I have HERE" is `get_my_docked_store`, the same read the hangar renders; this folds its items
 * array into the flat map the panels already consume. Undocked (or storeless) resolves to an EMPTY
 * map rather than null - you genuinely have nothing available where you are standing, and that is a
 * fact, not a failure. Returns null only on a transport/DB error.
 */
export async function fetchPortItemBalances(
  mainShipId: string | null,
): Promise<Record<string, number> | null> {
  const { data, error } = await supabase.rpc('get_my_docked_store', { p_main_ship_id: mainShipId ?? null })
  if (error) return null
  const items = (data as { items?: unknown } | null)?.items
  const balances: Record<string, number> = {}
  if (Array.isArray(items)) {
    for (const raw of items) {
      const row = raw as { item_id?: unknown; quantity?: unknown }
      if (typeof row?.item_id === 'string' && typeof row?.quantity === 'number') {
        balances[row.item_id] = row.quantity
      }
    }
  }
  return balances
}
