import { supabase } from '../../lib/supabase'
import type { BuildOrderRow, HullBuildRecipeRow, HullRecipeIngredientRow } from './shipyard'

// SHIPYARD-3 — typed client API for the dark shipyard order surface: the flag/config read
// (public-read game_config, 0003 — the getSalvageConfigRows direct-select posture), the recipe
// catalog reads (public-read `hull_build_recipes` + `hull_recipe_ingredients`, 0185 —
// Reference/Config like port_item_demand/module_types; DELIBERATELY no read RPC exists, so the
// catalog posture is direct table selects), the hull display-name register read (public
// `main_ship_hull_types` catalog rows, 0043/0185), the owner build_orders read (0036's
// build_orders_select_own policy + select grant; 0188 added the hull columns), and the ONE order
// command (start_hull_build, 0188). Mirrors salvageApi.ts conventions: thin wrappers; on a
// transport/DB error resolve to a normalized fail-closed value (never throw a raw error into the
// render path). The command is idempotent on (player_id, request_id) — the client passes a fresh
// crypto.randomUUID() per intentional submit. DARK: the server rejects the order RPC while
// shipyard_enabled is false (feature_disabled, gate FIRST before any read, in BOTH its layers);
// the catalog rows are technically readable pre-flip (public Reference/Config), but the panel
// gates itself on the SAME server flag read honestly from game_config — flag false → the panel
// renders null and never selects the catalog.

/** Read the shipyard gate + the wallet-honesty seed + the shared queue cap from PUBLIC-READ
 *  game_config (one select — the getSalvageConfigRows shape). Error → [] so
 *  shipyardConfigFromRows fails closed (dark). */
export async function getShipyardConfigRows(): Promise<Array<{ key: string; value: unknown }>> {
  const { data, error } = await supabase
    .from('game_config')
    .select('key, value')
    .in('key', ['shipyard_enabled', 'starting_credits', 'max_build_orders'])
  if (error) return []
  return (data ?? []) as Array<{ key: string; value: unknown }>
}

/** Read the build-recipe headers (direct select on public-read `hull_build_recipes` — no read RPC
 *  exists, 0185). numeric arrives as string → coerced. Error → null (fail-closed; the panel
 *  degrades to an honest unavailable line, never a silent empty catalog). */
export async function getHullBuildRecipes(): Promise<HullBuildRecipeRow[] | null> {
  const { data, error } = await supabase
    .from('hull_build_recipes')
    .select('hull_type_id, credits_cost, build_seconds, required_hull_type_id, required_captain_level')
  if (error) return null
  return (
    (data ?? []) as Array<{
      hull_type_id: string
      credits_cost: number | string
      build_seconds: number
      required_hull_type_id: string | null
      required_captain_level: number | null
    }>
  ).map((r) => ({
    hull_type_id: r.hull_type_id,
    credits_cost: Number(r.credits_cost) || 0,
    build_seconds: r.build_seconds,
    required_hull_type_id: r.required_hull_type_id,
    required_captain_level: r.required_captain_level,
  }))
}

/** Read the recipe bills (direct select on public-read `hull_recipe_ingredients`, 0185). numeric
 *  qty arrives as string → coerced (integral by the 0188 catalog law). Error → null. */
export async function getHullRecipeIngredients(): Promise<HullRecipeIngredientRow[] | null> {
  const { data, error } = await supabase.from('hull_recipe_ingredients').select('hull_type_id, item_id, qty')
  if (error) return null
  return ((data ?? []) as Array<{ hull_type_id: string; item_id: string; qty: number | string }>).map((r) => ({
    hull_type_id: r.hull_type_id,
    item_id: r.item_id,
    qty: Number(r.qty) || 0,
  }))
}

/** Read the hull display-name register (public `main_ship_hull_types` catalog rows — the
 *  mainshipApi fetchHull source, whole-register here for the catalog cards). Error → {} — names
 *  are COSMETIC (entries degrade to the honest title-cased id), never a blocked catalog. */
export async function getHullTypeNames(): Promise<Record<string, string>> {
  const { data, error } = await supabase.from('main_ship_hull_types').select('hull_type_id, name')
  if (error) return {}
  const names: Record<string, string> = {}
  for (const row of (data ?? []) as Array<{ hull_type_id: string; name: string }>) {
    names[row.hull_type_id] = row.name
  }
  return names
}

/** Read the caller's own NON-TERMINAL build orders — BOTH kinds (owner-read RLS, 0036): the hull
 *  rows feed the MY ORDERS strip (hullOrderViews filters), the full count feeds the shared
 *  queue-cap advisory (activeOrderCount — one queue, one cap, 0188 §7). Error → null (strip
 *  hidden, cap precheck skipped — the server answers queue_full itself). */
export async function getMyActiveBuildOrders(): Promise<BuildOrderRow[] | null> {
  const { data, error } = await supabase
    .from('build_orders')
    .select('id, hull_type_id, status, queued_at')
    .in('status', ['waiting', 'active'])
  if (error) return null
  return (data ?? []) as BuildOrderRow[]
}

// start_hull_build envelope (0188 §(d)): success carries the RECEIPTED order (credits_spent + the
// exact ingredient bill + queued_at; + idempotent_replay on a same (player, request_id) replay —
// the ORIGINAL envelope rebuilt verbatim from the receipt, no re-spend/re-debit); failure is
// CODE-keyed (`code`, NOT the salvage-style `reason` — the 0188 wrapper maps its writer's reasons
// to a public code vocabulary; shipyardReasonMessage maps the full set) with a server `message`
// and per-code context pass-throughs (item shortfall have/need, gate identities, the cap, the
// credit need). Discriminated union so ok narrows cleanly.
export type StartHullBuildResult =
  | {
      ok: true
      idempotent_replay?: boolean
      receipt_id: string
      order_id: string | null
      hull_type_id: string
      credits_spent: number
      ingredients_spent: Array<{ item_id: string; quantity: number }>
      queued_at: string
    }
  | {
      ok: false
      code?: string
      message?: string
      item_id?: string
      have?: number
      need?: number
      required_hull_type_id?: string
      required_captain_level?: number
      max?: number
    }

/** Enqueue a hull build (server-authoritative on flag/catalog/gates/cap/ingredients/credits;
 *  wallet_debit + inventory_spend + order + receipt atomic under the per-player lock — 0188).
 *  Exact param names from 0188: p_request_id (uuid) + p_hull_type_id. Transport error →
 *  { ok:false, code:'unavailable' } (fail-closed; 'unavailable' is deliberately unmapped →
 *  the generic message). */
export async function startHullBuild(requestId: string, hullTypeId: string): Promise<StartHullBuildResult> {
  const { data, error } = await supabase.rpc('start_hull_build', {
    p_request_id: requestId,
    p_hull_type_id: hullTypeId,
  })
  if (error) return { ok: false, code: 'unavailable' }
  return data as StartHullBuildResult
}
