import { supabase } from '../../lib/supabase'
import type { ShopOffer } from './portShop'

// PORT-SHOP — typed client API for the port outfitter (buy entry-level fitting modules + ammo for
// credits; migration 0235). Mirrors salvageApi.ts / repairApi.ts conventions: thin wrappers; on a
// transport/DB error resolve to a normalized fail-closed value (never throw a raw error into the
// render path). Unlike salvage, the visibility gate + the catalog are ONE gated RPC (get_port_shop)
// — it rejects port_shop_disabled while dark (gate FIRST, before any read), so the panel reads its
// dark/lit signal straight from the RPC (the get_my_ship_fittings 0116 gated-read posture), no
// separate game_config fold needed. The buy command is idempotent on (main_ship_id, request_id) —
// the client passes a fresh crypto.randomUUID() per intentional submit. DARK: while
// port_shop_enabled is false BOTH RPCs reject before any read; the panel renders null.

/** get_port_shop envelope (0235): the port's active offers, or a reason while dark/invalid. */
export type PortShopResult =
  | { ok: true; location_id: string; offers: ShopOffer[] }
  | { ok: false; reason?: string }

/** Read this port's active shop offers via the gated RPC. Transport error → { ok:false,
 *  reason:'unavailable' } (fail-closed — the panel shows an honest unavailable line). While dark
 *  the server itself answers { ok:false, reason:'port_shop_disabled' } and the panel renders null. */
export async function getPortShop(locationId: string): Promise<PortShopResult> {
  const { data, error } = await supabase.rpc('get_port_shop', { p_location_id: locationId })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as PortShopResult
}

// buy_shop_offer_at_port envelope (0235): success carries the receipted purchase (+ idempotent_replay
// on a same (ship, request_id) replay — replayed VERBATIM, no re-debit/re-grant); failure is
// REASON-keyed (portShopReasonMessage maps the full vocabulary; insufficient_credits also carries
// price/quantity). Discriminated union so ok narrows cleanly.
export type BuyShopResult =
  | {
      ok: true
      idempotent_replay?: boolean
      receipt_id: string
      main_ship_id: string
      kind: 'module' | 'item'
      ref_id: string
      quantity: number
      unit_price: number
      total_price: number
      instance_id: string | null
      location_id: string | null
    }
  | { ok: false; reason?: string; price?: number; quantity?: number; unit_price?: number }

/** Buy one shop offer at the docked port (server-authoritative on flag/ownership/dock/offer/wallet;
 *  wallet_debit + mint-instance OR inventory-deposit + receipt atomic under the per-ship lock).
 *  A module buy is always quantity 1 (one instance); items (ammo) may buy in bulk. Transport error
 *  → { ok:false, reason:'unavailable' } (fail-closed). */
export async function buyShopOfferAtPort(
  mainShipId: string,
  refId: string,
  quantity: number,
  requestId: string,
): Promise<BuyShopResult> {
  const { data, error } = await supabase.rpc('buy_shop_offer_at_port', {
    p_main_ship_id: mainShipId,
    p_ref_id: refId,
    p_quantity: quantity,
    p_request_id: requestId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as BuyShopResult
}
