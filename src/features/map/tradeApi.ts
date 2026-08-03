import { supabase } from '../../lib/supabase'

// TRADE-UI-1 — typed client API for the TRADE-MARKET-1 surface (get-offers / buy / sell), the priced
// add-ship RPC, and the owner-read wallet + per-ship cargo reads. LIVE: MarketPanel renders this module on
// PortScreen (TRADE_MARKET_ENABLED, flipped 2026-08-03) and the server flags (trade_market_enabled /
// mainship_additional_commission_enabled) are both lit in production. The double fail-closed structure stands —
// each layer still rejects on its own — but neither is dark any more.
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

// ── commission display context (public-read game_config rows) ───────────────────────────────────
export interface GameConfigRow {
  key: string
  value: unknown
}

/**
 * Read the four public-read game_config knobs the commission affordance mirrors/displays
 * (server flag, ship cap, price, starting credits — all display-only; the server re-checks every
 * one). starting_credits rides the SAME single select (no extra fetch): the wallet is lazy (0093
 * seeds it at first debit), so a no-row player's effective balance is this knob, and the display
 * must source it from server config, never a hardcode. Error → [] so the pure coercion
 * (commissionContextFromConfig) falls back to its fail-closed defaults.
 */
export async function getCommissionConfigRows(): Promise<GameConfigRow[]> {
  const { data, error } = await supabase
    .from('game_config')
    .select('key, value')
    .in('key', [
      'mainship_additional_commission_enabled',
      'max_main_ships_per_player',
      'main_ship_price',
      'starting_credits',
    ])
  if (error || !data) return []
  return data as GameConfigRow[]
}

// ── owner-read wallet balance (player_wallet) ────────────────────────────────────────────────────
/**
 * Read the caller's credit balance (owner-read RLS). The wallet row is LAZY (0093: seeded with
 * starting_credits at first debit/credit), so "no row" does NOT mean broke — it means "still on
 * starting credits". Returns null when no row exists (or the read failed) so callers can render
 * the effective starting balance honestly instead of a false 0. numeric arrives as string.
 */
export async function getWalletBalance(): Promise<number | null | 'error'> {
  const { data, error } = await supabase.from('player_wallet').select('balance').maybeSingle()
  if (error) return 'error' // transient read failure — NOT "no row"; callers must not infer starting credits
  if (!data) return null // genuinely no wallet row (lazy 0093 seed pending) → effective starting balance
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
  main_ship_id: string
  lot_id: string
  good_id: string
  qty: number | string
  unit_cost_basis: number | string
  acquired_at: string
  trade_goods: { unit_volume_m3: number | string } | { unit_volume_m3: number | string }[] | null
}

/**
 * Read cargo lots for a SET of owned ships (owner-read RLS via the ship join), embedding each
 * good's unit_volume_m3 so the UI can compute occupied volume as sum(qty * unit_volume_m3) — the
 * authoritative volume model. Oldest-first (FIFO order). numeric columns arrive as strings →
 * coerced.
 *
 * ASSETS-TAB widened this from one ship to many so the ledger can show every ship's cargo without
 * a second read of `ship_cargo_lots` beside the panels' one; `getShipCargoLots` below composes it
 * for the single-ship callers. Each row carries `main_ship_id` back because the many-ship caller
 * has to attribute a lot to the ship that is carrying it — and therefore to the port that ship is
 * standing in, which is the only port whose prices may be applied to it.
 * An EMPTY id list short-circuits to `[]` with no round trip.
 */
export async function getCargoLotsForShips(
  mainShipIds: readonly string[],
): Promise<Array<ShipCargoLot & { main_ship_id: string }>> {
  if (mainShipIds.length === 0) return []
  const { data, error } = await supabase
    .from('ship_cargo_lots')
    .select('main_ship_id, lot_id, good_id, qty, unit_cost_basis, acquired_at, trade_goods(unit_volume_m3)')
    .in('main_ship_id', [...mainShipIds])
    .order('acquired_at', { ascending: true })
  if (error || !data) return []
  return (data as RawCargoLotRow[]).map((r) => {
    const tg = Array.isArray(r.trade_goods) ? r.trade_goods[0] : r.trade_goods
    return {
      main_ship_id: r.main_ship_id,
      lot_id: r.lot_id,
      good_id: r.good_id,
      qty: Number(r.qty) || 0,
      unit_cost_basis: Number(r.unit_cost_basis) || 0,
      acquired_at: r.acquired_at,
      unit_volume_m3: Number(tg?.unit_volume_m3 ?? 0) || 0,
    }
  })
}

/** Read ONE ship's cargo lots — the panels' shape, composed from the one read above so there is no
 *  second query for the same fact. Oldest-first (FIFO order). Error → [] (unchanged behaviour). */
export async function getShipCargoLots(mainShipId: string): Promise<ShipCargoLot[]> {
  return getCargoLotsForShips([mainShipId])
}

// ── the GOODS price list, per port (market_offers — public-read Reference/Config) ────────────────
// ASSETS-TAB. `market_offers` prices TRADE GOODS (`trade_goods` ⇄ `ship_cargo_lots`). It does NOT
// price ITEMS (`item_types` ⇄ `base_items`/`fleet_items`), even though the two namespaces share the
// string `ore` — `trade_goods.ore` is "Raw Ore" at 1.00 m³ and `item_types.ore` is "Ore" at 2.00
// m³, two different things. Valuing a held item off this table because the id matched would be a
// cross-namespace fabrication; the ledger keeps the two row sets apart and never concatenates them.
//
// getMarketOffers (above) is the DOCKED station's gated read for the trade panel — it needs a ship
// and the server rejects it while dark. This is the flat Reference/Config select the ledger needs
// to price cargo sitting at ports the player is not currently docked at (the `port_item_demand`
// posture, and the same shape as getPortItemDemandFor). `buy_price` is used, not `sell_price`:
// what the station PAYS is what the cargo is worth to the player.
export async function getMarketBuyPricesFor(
  locationIds: readonly string[],
): Promise<Array<{ location_id: string; good_id: string; buy_price: number }> | null> {
  if (locationIds.length === 0) return []
  const { data, error } = await supabase
    .from('market_offers')
    .select('location_id, good_id, buy_price')
    .in('location_id', [...locationIds])
    .eq('active', true)
  if (error) return null
  return (
    (data ?? []) as Array<{ location_id: string; good_id: string; buy_price: number | string }>
  ).map((r) => ({
    location_id: r.location_id,
    good_id: r.good_id,
    buy_price: Number(r.buy_price) || 0,
  }))
}
