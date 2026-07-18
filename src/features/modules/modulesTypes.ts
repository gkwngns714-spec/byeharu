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

/** One module_types catalog row (0107 identity + 0111 slot_cost/stats_json + 0229 combat
 *  attributes; all public read — direct client select). numeric columns (range/projectile_speed/
 *  power/cooldown_seconds) arrive as strings over PostgREST; slot_cost/ammo_per_shot are integers. */
export interface ModuleTypeRow {
  id: string
  name: string
  slot_type: string
  description: string
  /** Σ-slot-cost this module consumes when fitted (0111; integer ≥ 1). */
  slot_cost: number
  /** Fitted stat contributions — keys attack/defense/repair/cargo/scan/mining/evasion/
   *  speed_mult_bonus (0111; the trait/adapter input vocabulary). */
  stats_json: unknown
  /** COMBAT-S0 (0229) spatial/combat attributes. NULL = the module has none of that reach. */
  range: number | string | null
  projectile_speed: number | string | null
  power: number | string | null
  ammo_type: string | null
  ammo_per_shot: number
  cooldown_seconds: number | string
}

/** One item_types catalog row (0039; Reference/Config public read — display fields for item info). */
export interface ItemTypeRow {
  item_id: string
  name: string
  category: string
  rarity: string
  description: string | null
  stackable: boolean
  icon_key: string | null
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

// ── FITTING-P14 — types for the dark module-fitting surface (0112–0116) ─────────────────────────
// Same posture as the crafting types above: the server rejects every fitting RPC while
// module_fitting_enabled is false; the read reason 'module_fitting_disabled' is handled by
// FAIL-CLOSED rendering (the fitting section renders nothing), never by copy.

/** One row of get_my_ship_fittings() (0116) — the seven shipped fields, fitted_at desc. */
export interface ShipFittingRow {
  module_instance_id: string
  main_ship_id: string
  fitted_at: string
  module_type_id: string
  name: string
  slot_type: string
  slot_cost: number
}

export type GetMyShipFittingsResult =
  | { ok: true; fittings: ShipFittingRow[] }
  | { ok: false; reason: string }

// The fit/unfit wrapper envelopes (0113 wrappers → 0114 mapper). Success passes the writer's
// envelope through (fitted/unfitted + slot facts) plus the replay flag; failure carries the mapped
// code/message with REAL server context on insufficient_slots ({used, cost, limit} — the
// insufficient_items idiom) and already_fitted ({main_ship_id}).
export type FittingCommandResult =
  | {
      ok: true
      idempotent_replay: boolean
      module_instance_id: string
      main_ship_id: string
      fitted?: boolean
      unfitted?: boolean
      slot_cost?: number
      slots_used?: number
      slots_limit?: number
      fitted_at?: string
    }
  | {
      ok: false
      code: string
      message: string
      used?: number
      cost?: number
      limit?: number
      main_ship_id?: string
    }

// Player-facing copy for the code set the 0113/0114 wrappers can return, same tone as the craft
// map above. The server's message is preferred when present; this map is the client-side fallback.
const FITTING_ERROR_COPY: Record<string, string> = {
  feature_disabled: 'Module fitting is not available yet.',
  invalid_request: 'Invalid command request.',
  ship_not_settled: 'The ship must be settled at home or docked at a location to change its module loadout.',
  module_not_owned: 'That module is not in your possession.',
  ship_not_owned: 'That ship is not yours.',
  already_fitted: 'That module is already fitted to a ship. Unfit it first.',
  not_fitted: 'That module is not fitted to any ship.',
  insufficient_slots: 'Not enough free module slots on this ship.',
  not_authenticated: 'You must be signed in.',
  unavailable: 'Module fitting is unavailable right now.',
}
export function fittingErrorMessage(code: string): string {
  return FITTING_ERROR_COPY[code] ?? FITTING_ERROR_COPY.unavailable
}
