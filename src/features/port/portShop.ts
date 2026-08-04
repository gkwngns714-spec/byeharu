import { salvageWalletDisplay, clampSellQty } from './salvageMarket'
import {
  LEGACY_MARKER,
  standingOfCatalogKey,
  statByCatalogKey,
  type StatStanding,
} from '../stats/statLifecycle'

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
// THE RULING THIS OBEYS (owner, 2026-08-04): "A dormant stat must not be represented as an effective
// player benefit," and for this surface in particular: "A player must not spend resources on a
// benefit the engine does not apply."
//
// SPAGHETTI, NAMED AND RIPPED OUT: this file used to carry STAT_LABELS — a second, hand-written
// vocabulary of stat names, with `mining: 'Mining yield'` advertising a stat NOTHING in the game
// reads. Both the NAME and the LIFECYCLE now come from the ONE registry projection of migration
// 0340's stat_definitions (src/features/stats/statLifecycle.ts), joined on catalog_key — the key a
// module's stats_json actually writes (0340:271-273). A key the registry does not know is UNKNOWN
// and fails closed exactly like a dormant one: it is not shown as a benefit.
//
// WHAT THIS DOES NOT DO: it activates nothing, changes no price, no ownership, no fitted module and
// no inventory, and it invents no replacement behaviour. It stops the shop CLAIMING an effect.

/** One effect chip at point of sale. `standing` is the registry's lifecycle verdict, so the panel
 *  can mark a legacy value without re-deciding what legacy means. */
export interface OfferChip {
  readonly key: string
  readonly label: string
  readonly standing: StatStanding
}

/** Format one stat contribution. speed_mult_bonus is a FRACTION of hull base speed (0111) → percent;
 *  every other registered key is a flat signed number. */
function chipLabel(catalogKey: string, name: string, value: number): string {
  if (catalogKey === 'speed_mult_bonus') {
    return `${name} ${value > 0 ? '+' : ''}${Math.round(value * 100)}%`
  }
  return `${name} ${value > 0 ? '+' : ''}${value}`
}

/** Compact effect chips for an offer: the module's stat contributions + its combat reach, or the
 *  item's category — the attributes the outfitter surfaces at point of sale. Pure; deterministic
 *  order (the registry's display_order, then the non-stat attributes).
 *
 *  DORMANT AND UNKNOWN CONTRIBUTIONS ARE OMITTED. They are not hidden to make the row look better —
 *  a chip IS the claim, and the game applies nothing for them. Range and Power are NOT stats (0340
 *  deliberately registers no range stat, :512-515) and are unaffected. */
export function offerStatChips(offer: ShopOffer): OfferChip[] {
  const chips: OfferChip[] = []
  for (const [catalogKey, value] of statContributions(offer)) {
    const def = statByCatalogKey(catalogKey)
    const standing = standingOfCatalogKey(catalogKey)
    // Fail closed: no registry row → no name we are entitled to invent, and no claim we may make.
    if (def === null || standing === 'dormant' || standing === 'unknown') continue
    chips.push({ key: catalogKey, label: chipLabel(catalogKey, def.displayName, value), standing })
  }
  if (typeof offer.range === 'number' && offer.range > 0) {
    chips.push({ key: 'range', label: `Range ${offer.range}`, standing: 'effective' })
  }
  if (typeof offer.power === 'number' && offer.power > 0) {
    chips.push({ key: 'power', label: `Power ${offer.power}`, standing: 'effective' })
  }
  return chips
}

/** The offer's non-zero stats_json contributions, in the registry's display_order. Unregistered
 *  keys sort last, deterministically by key, and are still YIELDED — the caller decides what to do
 *  with an unknown, so "fail closed" happens in exactly one place. */
function statContributions(offer: ShopOffer): [string, number][] {
  const stats = offer.stats_json ?? {}
  const out: [string, number][] = []
  for (const [key, value] of Object.entries(stats)) {
    if (typeof value !== 'number' || !Number.isFinite(value) || value === 0) continue
    out.push([key, value])
  }
  const order = (k: string) => statByCatalogKey(k)?.displayOrder ?? Number.MAX_SAFE_INTEGER
  return out.sort((a, b) => order(a[0]) - order(b[0]) || a[0].localeCompare(b[0], 'en'))
}

/** Whether an offer's advertised effects are things the engine actually applies.
 *
 *   'ok'               — at least one claimed effect is live (an active or legacy stat), OR the
 *                        offer surfaces a non-stat attribute the engine reads, OR it claims no stat
 *                        effect at all (ammo and other plain items).
 *   'no_live_effect'   — the offer claims at least one stat effect and EVERY one of them is dormant
 *                        or unknown. Nothing the player buys it for will happen.
 *
 * SCOPE, deliberately narrow (the owner's rule 2): an offer with any other live effect is NEVER
 * marked — a module is not withdrawn because one of its chips went quiet. Today that distinction is
 * load-bearing on the live catalog, verified against production on 2026-08-04:
 *   · mining_rig_extension  stats_json {"mining": 8} → DORMANT, but range 120 is READ: mining_extract
 *     takes the radius from max(mt.range) over fitted mining modules
 *     (20260618000229_module_combat_attributes.sql:309-321) and module_range_attributes_enabled is
 *     TRUE in production (lit by 20260618000300_lights_on.sql:53). It keeps its live effect, so only
 *     its dormant chip disappears — it stays on sale.
 *   · deep_scan_sensor_array  stats_json {"scan": 8} → `scouting`, DORMANT, with range and power
 *     explicitly NULL (0229:134). Its only claimed effect is dormant, and it changes no scan radius:
 *     every scan reads the flat cfg key exploration_scan_radius (0099:176, 0146:136, 0172:149,
 *     0221:642) and no module contributes to it. This is the offer rule 3 is about. */
export type OfferEffectStanding = 'ok' | 'no_live_effect'

export function offerEffectStanding(offer: ShopOffer): OfferEffectStanding {
  const contributions = statContributions(offer)
  if (contributions.length === 0) return 'ok'
  const hasLiveAttribute =
    (typeof offer.range === 'number' && offer.range > 0) ||
    (typeof offer.power === 'number' && offer.power > 0)
  if (hasLiveAttribute) return 'ok'
  for (const [key] of contributions) {
    const standing = standingOfCatalogKey(key)
    if (standing === 'effective' || standing === 'legacy') return 'ok'
  }
  return 'no_live_effect'
}

/** The marker a chip carries when its stat is legacy. Re-exported so the panel never spells it. */
export { LEGACY_MARKER }

/** The line shown on an offer whose only claimed effects are dormant. Existing product language
 *  (the shop's other honest-unavailability lines are plain sentences, not codes) and no jargon. */
export const NO_LIVE_EFFECT_NOTE = 'Not currently implemented — this does nothing in the game yet.'

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
  port_shop_disabled: 'The shop is not open here yet.',
  not_authenticated: 'You must be signed in.',
  invalid_request: 'Invalid purchase request.',
  invalid_ref: 'Unknown item.',
  invalid_quantity: 'Choose a whole quantity of at least 1.',
  ship_not_found: 'You do not have a ship here.',
  not_docked: 'Dock at the port to buy.',
  no_offer: 'This port does not stock that.',
  module_qty_must_be_one: 'Modules are bought one at a time.',
  insufficient_credits: 'Not enough credits for this purchase.',
  // get_port_shop's own argument guard (0235:340-341) — the offers READ was asked for no port at all.
  invalid_location: 'No port to shop at — open a port first.',
  unavailable: 'The shop is unavailable right now.',
}

export function portShopReasonMessage(reason: string): string {
  return MESSAGES[reason] ?? MESSAGES.unavailable
}
