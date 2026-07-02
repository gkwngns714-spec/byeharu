import { supabase } from '../../lib/supabase'

// TRADE-UI-1 — typed client API for the TRADE-MARKET-1 surface (get-offers / buy / sell), the priced
// add-ship RPC, and the owner-read wallet + per-ship cargo reads. DARK: this module is the API foundation
// only; NOTHING renders it yet, and the compile-time gates TRADE_MARKET_ENABLED / MAINSHIP_ADDITIONAL_ENABLED
// (osnReleaseGates.ts) plus the server flags (trade_market_enabled / mainship_additional_commission_enabled)
// both fail closed — double fail-closed until a human flips them.
//
// The client ALWAYS passes the EXPLICIT selected ship id (p_main_ship_id) — the server-side sole-ship shim is
// a transition compat only; the UI addresses a chosen ship. The server derives the player from auth.uid(),
// validates ownership + docked state, and owns all price/volume/credit truth; the client only REQUESTS and
// displays. Mirrors mainshipApi.ts conventions: thin supabase.rpc wrappers; on a transport/DB error, resolve
// to a normalized {ok:false, reason:'unavailable'} (never throw a raw error into the render path); reads
// collapse to a safe empty/zero default.

// ── market offers (get_market_offers) ────────────────────────────────────────────────────────────
export interface MarketOffer {
  offer_id: string
  good_id: string
  buy_price: number // credits the station PAYS when the player SELLS to it
  sell_price: number // credits the player PAYS when BUYING from the station
}
export type GetMarketOffersResult =
  | { ok: true; main_ship_id: string; location_id: string; offers: MarketOffer[] }
  | { ok: false; reason: string }

/** Read the docked station's active offers for the selected ship. Server-rejected (reason) while dark. */
export async function getMarketOffers(mainShipId: string): Promise<GetMarketOffersResult> {
  const { data, error } = await supabase.rpc('get_market_offers', { p_main_ship_id: mainShipId })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as GetMarketOffersResult
}

// ── buy (market_buy) ─────────────────────────────────────────────────────────────────────────────
export type MarketBuyResult =
  | {
      ok: true
      idempotent_replay?: boolean
      receipt_id: string
      lot_id?: string
      side: 'buy'
      good_id: string
      qty: number
      unit_price: number
      total_price: number
      location_id: string
    }
  | { ok: false; reason: string; price?: number; used_m3?: number; capacity_m3?: number; delta_m3?: number }

/** Buy qty of a good at the selected ship's docked station (atomic; idempotent on requestId). */
export async function marketBuy(
  mainShipId: string,
  goodId: string,
  qty: number,
  requestId: string,
): Promise<MarketBuyResult> {
  const { data, error } = await supabase.rpc('market_buy', {
    p_main_ship_id: mainShipId,
    p_good_id: goodId,
    p_qty: qty,
    p_request_id: requestId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as MarketBuyResult
}

// ── sell (market_sell) ───────────────────────────────────────────────────────────────────────────
export type MarketSellResult =
  | {
      ok: true
      idempotent_replay?: boolean
      receipt_id: string
      side: 'sell'
      good_id: string
      qty: number
      unit_price: number
      total_price: number
      location_id: string
      cost_basis_consumed?: number
      realized_margin?: number
    }
  | { ok: false; reason: string; available?: number }

/** Sell qty of a good (FIFO consume) at the selected ship's docked station (atomic; idempotent on requestId). */
export async function marketSell(
  mainShipId: string,
  goodId: string,
  qty: number,
  requestId: string,
): Promise<MarketSellResult> {
  const { data, error } = await supabase.rpc('market_sell', {
    p_main_ship_id: mainShipId,
    p_good_id: goodId,
    p_qty: qty,
    p_request_id: requestId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as MarketSellResult
}

// ── priced add-ship (commission_additional_main_ship) ────────────────────────────────────────────
export type CommissionAdditionalResult =
  | { ok: true; created: boolean; docked: boolean; main_ship_id: string; location_id: string; price: number }
  | { ok: false; reason: string; price?: number; cap?: number }

/** Commission an additional main ship (the credit sink; server debits main_ship_price). Dark until flags on. */
export async function commissionAdditionalMainShip(): Promise<CommissionAdditionalResult> {
  const { data, error } = await supabase.rpc('commission_additional_main_ship', {})
  if (error) return { ok: false, reason: 'unavailable' }
  return data as CommissionAdditionalResult
}

// ── owner-read wallet balance (player_wallet) ────────────────────────────────────────────────────
/** Read the caller's credit balance (owner-read RLS). Lazy: no row yet → 0. numeric arrives as string. */
export async function getWalletBalance(): Promise<number> {
  const { data, error } = await supabase.from('player_wallet').select('balance').maybeSingle()
  if (error || !data) return 0
  return Number((data as { balance: number | string }).balance) || 0
}

// ── owner-read per-ship cargo lots + unit volume (ship_cargo_lots ⋈ trade_goods) ─────────────────
export interface ShipCargoLot {
  lot_id: string
  good_id: string
  qty: number
  unit_cost_basis: number
  acquired_at: string
  unit_volume_m3: number // from trade_goods; lets the UI compute occupied volume as the lot sum
}

interface RawCargoLotRow {
  lot_id: string
  good_id: string
  qty: number | string
  unit_cost_basis: number | string
  acquired_at: string
  trade_goods: { unit_volume_m3: number | string } | { unit_volume_m3: number | string }[] | null
}

/**
 * Read the selected ship's cargo lots (owner-read RLS via the ship join), embedding each good's
 * unit_volume_m3 so the UI can compute occupied volume as sum(qty * unit_volume_m3) — the authoritative
 * volume model. Oldest-first (FIFO order). numeric columns arrive as strings → coerced.
 */
export async function getShipCargoLots(mainShipId: string): Promise<ShipCargoLot[]> {
  const { data, error } = await supabase
    .from('ship_cargo_lots')
    .select('lot_id, good_id, qty, unit_cost_basis, acquired_at, trade_goods(unit_volume_m3)')
    .eq('main_ship_id', mainShipId)
    .order('acquired_at', { ascending: true })
  if (error || !data) return []
  return (data as RawCargoLotRow[]).map((r) => {
    const tg = Array.isArray(r.trade_goods) ? r.trade_goods[0] : r.trade_goods
    return {
      lot_id: r.lot_id,
      good_id: r.good_id,
      qty: Number(r.qty) || 0,
      unit_cost_basis: Number(r.unit_cost_basis) || 0,
      acquired_at: r.acquired_at,
      unit_volume_m3: Number(tg?.unit_volume_m3 ?? 0) || 0,
    }
  })
}
