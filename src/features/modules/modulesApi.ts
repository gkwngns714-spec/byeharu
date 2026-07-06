import { supabase } from '../../lib/supabase'
import {
  craftModuleErrorMessage,
  fittingErrorMessage,
  type CraftModuleResult,
  type FittingCommandResult,
  type GetMyModuleInstancesResult,
  type GetMyShipFittingsResult,
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

/** Craft one module instance (idempotent on requestId; server-rejected while dark). */
export async function craftModule(requestId: string, moduleType: string): Promise<CraftModuleResult> {
  const { data, error } = await supabase.rpc('craft_module', {
    p_request_id: requestId,
    p_module_type: moduleType,
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
    supabase.from('module_types').select('id, name, slot_type, description').order('name'),
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
 * Read the caller's own item balances (player_inventory own-row select, the 0039 grant — the
 * existing Inventory read path; no new server surface). Returns null on error.
 */
export async function fetchMyItemBalances(): Promise<Record<string, number> | null> {
  const { data, error } = await supabase.from('player_inventory').select('item_id, quantity')
  if (error) return null
  const balances: Record<string, number> = {}
  for (const row of (data ?? []) as { item_id: string; quantity: number }[]) {
    balances[row.item_id] = row.quantity
  }
  return balances
}
