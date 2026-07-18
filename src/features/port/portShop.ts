import { salvageWalletDisplay, clampSellQty } from './salvageMarket'

// PORT-SHOP — PURE, framework-free types + client mirrors for the port outfitter (dark UI).
//
// Mirrors the server contracts exactly: the get_port_shop gated read + the buy_shop_offer_at_port
// reject ORDER (migration 0235). No React/DOM/fetch here (the salvageMarket.ts / repairEconomy.ts
// idiom). DISPLAY-ONLY: the server stays authoritative and re-checks the gate, ownership, docking,
// the offer, and the wallet (wallet_debit's own conditional) — these mirrors only let the panel
// disable/annotate an affordance and fail closed without a round-trip. Reason names reuse the SERVER
// vocabulary (0235) so hints flow through the ONE portShopReasonMessage mapper. The wallet-honesty
// display + the whole-quantity clamp are REUSED verbatim from salvageMarket.ts (generic, not
// salvage-specific) — no second copy.

export { salvageWalletDisplay as shopWalletDisplay, clampSellQty as clampBuyQty }

/** One offer from get_port_shop (0235): a module (mint an instance on buy) or an item (deposit).
 *  Catalog display fields are joined server-side; the module-only / item-only fields are null on
 *  the other kind. */
export interface ShopOffer {
  kind: 'module' | 'item'
  ref_id: string
  price: number
  name: string | null
  // module-only
  slot_type: string | null
  slot_cost: number | null
  stats_json: Record<string, number> | null
  range: number | null
  power: number | null
  ammo_type: string | null
  // item-only
  category: string | null
  rarity: string | null
  // shared
  description: string | null
}

// ── stat display (compact, point-of-sale) ────────────────────────────────────────────────────────
// Human labels for the module stats_json contribution keys the fitting adapter reads (0111/0183/
// 0202: attack/defense/repair/cargo/scan/mining/evasion + speed_mult_bonus). Matched to the
// player-facing meaning (defense contributes to SURVIVAL, mining to MINING YIELD — the adapter
// output names) so the shop label reads the same as the fitting preview.
const STAT_LABELS: Record<string, string> = {
  attack: 'Attack',
  defense: 'Survival',
  repair: 'Repair',
  cargo: 'Cargo',
  scan: 'Scan',
  mining: 'Mining yield',
  evasion: 'Evasion',
}

/** Compact effect chips for an offer: the module's stat contributions + its combat reach, or the
 *  item's category — the attributes the outfitter surfaces at point of sale (the coordinator's
 *  "surface those same attributes"). Pure; deterministic order. */
export function offerStatChips(offer: ShopOffer): string[] {
  const chips: string[] = []
  const stats = offer.stats_json ?? {}
  for (const key of Object.keys(STAT_LABELS)) {
    const v = stats[key]
    if (typeof v === 'number' && v !== 0) chips.push(`${STAT_LABELS[key]} ${v > 0 ? '+' : ''}${v}`)
  }
  // speed_mult_bonus is a fraction of hull base speed (0111) → show as a percent.
  const spd = stats['speed_mult_bonus']
  if (typeof spd === 'number' && spd !== 0) {
    chips.push(`Speed ${spd > 0 ? '+' : ''}${Math.round(spd * 100)}%`)
  }
  if (typeof offer.range === 'number' && offer.range > 0) chips.push(`Range ${offer.range}`)
  if (typeof offer.power === 'number' && offer.power > 0) chips.push(`Power ${offer.power}`)
  return chips
}

// ── buy availability mirror (the 0235 reject order) ──────────────────────────────────────────────
export type BuyReason =
  | 'ok'
  | 'port_shop_disabled'
  | 'invalid_quantity'
  | 'ship_not_found'
  | 'not_docked'
  | 'no_offer'
  | 'module_qty_must_be_one'
  | 'insufficient_credits'

// DISPLAY-ONLY mirror of buy_shop_offer_at_port's reject order (0235): gate FIRST → invalid_quantity
// (units are INTEGER; null/non-positive/fractional/>1e6 reject, never round) → ship resolved →
// docked → an offer exists → a module buy is exactly one instance → affordable (affordable null =
// wallet unreadable → SKIP the precheck and let the server answer insufficient_credits — the salvage
// null-cap idiom) → ok. Server-only guards (not_authenticated, invalid_request, invalid_ref,
// idempotent_replay) are NOT mirrored — the client submits a fresh uuid and a ref taken FROM an offer.
export function buyAvailability(input: {
  flagOn: boolean
  quantity: number
  isModule: boolean
  shipResolved: boolean
  docked: boolean
  offerExists: boolean
  affordable: boolean | null
}): { canBuy: boolean; reason: BuyReason } {
  if (!input.flagOn) return { canBuy: false, reason: 'port_shop_disabled' }
  if (
    !Number.isFinite(input.quantity) ||
    input.quantity <= 0 ||
    !Number.isInteger(input.quantity) ||
    input.quantity > 1_000_000
  ) {
    return { canBuy: false, reason: 'invalid_quantity' }
  }
  if (!input.shipResolved) return { canBuy: false, reason: 'ship_not_found' }
  if (!input.docked) return { canBuy: false, reason: 'not_docked' }
  if (!input.offerExists) return { canBuy: false, reason: 'no_offer' }
  if (input.isModule && input.quantity !== 1) return { canBuy: false, reason: 'module_qty_must_be_one' }
  if (input.affordable === false) return { canBuy: false, reason: 'insufficient_credits' }
  return { canBuy: true, reason: 'ok' }
}

/** Which mirrored verdicts hard-DISABLE the Buy button vs advise-only (the salvage/repair M2
 *  posture). insufficient_credits ADVISES: the wallet display can be transiently unknown or lag a
 *  just-earned credit, and the SERVER is the enforcement (wallet_debit's atomic conditional).
 *  Everything structural blocks: the dark gate, quantity shape, no ship, not docked, no offer,
 *  a module qty != 1. */
export function buyBlocks(reason: BuyReason): boolean {
  return reason !== 'ok' && reason !== 'insufficient_credits'
}

/** Display price math: qty × unit price (what the buy WOULD debit — the server computes the
 *  authoritative total under its own lock). Non-finite/negative → 0 (never NaN). */
export function buyTotal(qty: number, unitPrice: number): number {
  if (!Number.isFinite(qty) || !Number.isFinite(unitPrice) || qty < 0 || unitPrice < 0) return 0
  return qty * unitPrice
}

// ── the ONE reason → player message mapper (the repairReasonMessage/salvageReasonMessage idiom) ──
const MESSAGES: Record<string, string> = {
  port_shop_disabled: 'The outfitter is not open yet.',
  not_authenticated: 'You must be signed in.',
  invalid_request: 'Invalid purchase request.',
  invalid_ref: 'Unknown item.',
  invalid_quantity: 'Choose a whole quantity of at least 1.',
  ship_not_found: 'You do not have a ship here.',
  not_docked: 'Dock at the port to buy.',
  no_offer: 'This port does not stock that.',
  module_qty_must_be_one: 'Modules are bought one at a time.',
  insufficient_credits: 'Not enough credits for this purchase.',
  unavailable: 'The outfitter is unavailable right now.',
}

export function portShopReasonMessage(reason: string): string {
  return MESSAGES[reason] ?? MESSAGES.unavailable
}
