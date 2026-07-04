// MODULES-P13 — PURE, framework-free types + player-facing copy for the dark module-crafting
// surface.
//
// Mirrors the server contracts exactly: craft_module's wrapper envelope (migration 0109) and
// get_my_module_instances' rows (0110), plus the two PUBLIC-READ Reference/Config catalogs the
// client selects directly (module_types / module_recipe_ingredients, 0107 — the item_types/
// hull-types direct-select convention; deliberately NO catalog RPC, see the 0110 header) and the
// caller's own player_inventory rows (the 0039 own-row grant). No React/DOM/fetch here (the
// miningTypes.ts idiom). DARK: the server rejects every crafting RPC while
// module_crafting_enabled is false; the panel renders nothing on that envelope — the UI is never
// the control (fail-closed law), and no client-side flag constant gates visibility (server-driven).

/** One row of get_my_module_instances() (0110). Newest first. */
export interface ModuleInstance {
  instance_id: string
  module_type_id: string
  name: string
  slot_type: string
  created_at: string
}

export type GetMyModuleInstancesResult =
  | { ok: true; instances: ModuleInstance[] }
  | { ok: false; reason: string }

// The server's narrow craft result contract (mirrors craft_module's wrapper, 0109).
// item_id/have/need are REAL server data, present only on the 'insufficient_items' failure.
export type CraftModuleResult =
  | {
      ok: true
      idempotent_replay: boolean
      receipt_id: string
      instance_id: string
      module_type_id: string
      crafted_at: string
    }
  | { ok: false; code: string; message: string; item_id?: string; have?: number; need?: number }

/** One module_types catalog row (0107; public read — direct client select). */
export interface ModuleTypeRow {
  id: string
  name: string
  slot_type: string
  description: string
}

/** One module_recipe_ingredients row (0107; public read — direct client select). */
export interface ModuleRecipeIngredientRow {
  module_type_id: string
  item_id: string
  qty: number
}

/** A catalog entry paired with its recipe rows (assembled client-side from the two selects). */
export interface ModuleCatalogEntry extends ModuleTypeRow {
  ingredients: { item_id: string; qty: number }[]
}

// Player-facing copy for the narrow code set craft_module's wrapper can return (0109), same tone
// as the exploration/mining command copy. The server's message is preferred when present; this
// map is the client-side fallback.
const CRAFT_ERROR_COPY: Record<string, string> = {
  feature_disabled: 'Module crafting is not available yet.',
  invalid_request: 'Invalid command request.',
  unknown_module: 'Unknown module design.',
  no_recipe: 'This module design cannot be crafted yet.',
  insufficient_items: 'Not enough materials to craft this module.',
  not_authenticated: 'You must be signed in.',
  unavailable: 'Module crafting is unavailable right now.',
}
export function craftModuleErrorMessage(code: string): string {
  return CRAFT_ERROR_COPY[code] ?? CRAFT_ERROR_COPY.unavailable
}
