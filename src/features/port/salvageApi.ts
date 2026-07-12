import { supabase } from '../../lib/supabase'
import type { PortItemDemandRow } from './salvageMarket'

// SALVAGE-2 — typed client API for the dark salvage market: the flag/config read (public-read
// game_config, 0003 — the getCommissionConfigRows direct-select posture), the port buy-list read
// (public-read `port_item_demand`, 0174 — Reference/Config like market_offers/module_types;
// DELIBERATELY no read RPC exists, so the catalog posture is a direct table select, the
// fetchModuleCatalog convention), and the ONE sell command (sell_item_at_port, 0174). Mirrors
// haulApi.ts conventions: thin wrappers; on a transport/DB error resolve to a normalized
// fail-closed value (never throw a raw error into the render path). The command is idempotent on
// (main_ship_id, request_id) — the client passes a fresh crypto.randomUUID() per intentional
// submit. DARK: the server rejects the sell RPC while salvage_market_enabled is false
// (salvage_market_disabled, gate FIRST before any read); the demand rows are technically readable
// pre-flip (public Reference/Config), but the panel gates itself on the SAME server flag read
// honestly from game_config — flag false → the panel renders null and never selects demand.

/** Read the salvage gate + the wallet-honesty seed from PUBLIC-READ game_config (one select —
 *  the getCommissionConfigRows shape). Error → [] so salvageConfigFromRows fails closed (dark). */
export async function getSalvageConfigRows(): Promise<Array<{ key: string; value: unknown }>> {
  const { data, error } = await supabase
    .from('game_config')
    .select('key, value')
    .in('key', ['salvage_market_enabled', 'starting_credits'])
  if (error) return []
  return (data ?? []) as Array<{ key: string; value: unknown }>
}

/** Read this port's ACTIVE item buy-list (direct select on public-read `port_item_demand` —
 *  no read RPC exists, 0174). numeric arrives as string → coerced. Error → null (fail-closed;
 *  the panel degrades to an honest unavailable line, never a silent empty). */
export async function getPortItemDemand(locationId: string): Promise<PortItemDemandRow[] | null> {
  const { data, error } = await supabase
    .from('port_item_demand')
    .select('item_id, unit_price')
    .eq('location_id', locationId)
    .eq('active', true)
  if (error) return null
  return ((data ?? []) as Array<{ item_id: string; unit_price: number | string }>).map((r) => ({
    item_id: r.item_id,
    unit_price: Number(r.unit_price) || 0,
  }))
}

// sell_item_at_port envelope (0174): success carries the receipted sale (+ idempotent_replay on a
// same (ship, request_id) replay — replayed VERBATIM, no re-spend/re-credit); failure is
// REASON-keyed (salvageReasonMessage maps the full vocabulary; insufficient_items also carries
// have/need). Discriminated union so ok narrows cleanly.
export type SellItemResult =
  | {
      ok: true
      idempotent_replay?: boolean
      receipt_id: string
      item_id: string
      qty: number
      unit_price: number
      total_price: number
      location_id: string | null
    }
  | { ok: false; reason?: string; item_id?: string; have?: number; need?: number }

/** Sell whole items to the docked port (server-authoritative on flag/dock/demand/balance;
 *  inventory_spend + wallet_credit + receipt atomic under the per-ship lock). Transport error →
 *  { ok:false, reason:'unavailable' } (fail-closed). */
export async function sellItemAtPort(
  mainShipId: string,
  itemId: string,
  quantity: number,
  requestId: string,
): Promise<SellItemResult> {
  const { data, error } = await supabase.rpc('sell_item_at_port', {
    p_main_ship_id: mainShipId,
    p_item_id: itemId,
    p_quantity: quantity,
    p_request_id: requestId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as SellItemResult
}
