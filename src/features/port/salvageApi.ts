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

/**
 * Read the ACTIVE item buy-list for a SET of ports (direct select on public-read
 * `port_item_demand` — no read RPC exists, 0174). THE ONE read of item prices in the client:
 * `getPortItemDemand` below is the single-port caller, the Assets ledger is the many-port one.
 * Two callers of one query, not two queries for one fact.
 *
 * ASSETS-TAB widened this from one location to many rather than adding a second select beside it.
 * The row carries `location_id` back BECAUSE the many-port caller must keep the answers apart:
 * prices are per-port, and flattening them into one price per item would be exactly the
 * extrapolation the asset ledger refuses to make.
 *
 * numeric arrives as string → coerced. An EMPTY id list short-circuits to `[]` with no round trip.
 * Error → null (fail-closed; callers degrade to an honest unavailable line, never a silent empty —
 * which would read as "this port buys nothing", a different and wrong claim).
 */
export async function getPortItemDemandFor(
  locationIds: readonly string[],
): Promise<Array<PortItemDemandRow & { location_id: string }> | null> {
  if (locationIds.length === 0) return []
  const { data, error } = await supabase
    .from('port_item_demand')
    .select('location_id, item_id, unit_price')
    .in('location_id', [...locationIds])
    .eq('active', true)
  if (error) return null
  return (
    (data ?? []) as Array<{ location_id: string; item_id: string; unit_price: number | string }>
  ).map((r) => ({
    location_id: r.location_id,
    item_id: r.item_id,
    unit_price: Number(r.unit_price) || 0,
  }))
}

/** Read ONE port's ACTIVE item buy-list — the salvage panel's shape, composed from the one read
 *  above. numeric already coerced there. Error → null (fail-closed; the panel degrades to an
 *  honest unavailable line, never a silent empty). */
export async function getPortItemDemand(locationId: string): Promise<PortItemDemandRow[] | null> {
  const rows = await getPortItemDemandFor([locationId])
  if (rows === null) return null
  return rows.map((r) => ({ item_id: r.item_id, unit_price: r.unit_price }))
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
