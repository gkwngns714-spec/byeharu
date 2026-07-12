import { itemLabel } from '../../components/items'

// SALVAGE-2 — PURE, framework-free types + client mirrors for the port salvage market (dark UI).
//
// Mirrors the server contracts exactly: the `port_item_demand` public-read buy-list and the
// `sell_item_at_port` reject ORDER (migration 0174). No React/DOM/fetch here (the haulBoard.ts /
// teamSend.ts idiom). DISPLAY-ONLY: the server stays authoritative and re-checks the gate,
// docking, demand, quantity shape, and the inventory balance (inventory_spend's own FOR UPDATE) —
// these mirrors only let the panel disable/annotate an affordance and fail closed without a
// round-trip. Reason names reuse the SERVER vocabulary (0174) so the availability hints flow
// through the ONE salvageReasonMessage mapper (the haulBoard/haulReasonMessage precedent).
// Unit-tested in tests/salvageMarket.spec.ts.

/** One ACTIVE row of this port's `port_item_demand` buy-list (0174 — Reference/Config,
 *  public-read, migration-seeded only; read via direct select, no read RPC exists). */
export interface PortItemDemandRow {
  item_id: string
  unit_price: number
}

/** A displayable buy-list row: the port's demand merged with the caller's own balance. */
export interface SalvageEntry {
  item_id: string
  unit_price: number
  /** The caller's sellable stock (player_inventory own-row read); missing item → 0. */
  balance: number
}

// ── config fold (public-read game_config rows → the dark gate + wallet-honesty seed) ─────────────
// The ONLY salvage read surface the server lit is data-shaped, not RPC-shaped: 0174 made
// `port_item_demand` public-read Reference/Config (the market_offers posture) and gave the sell
// RPC — but NO read RPC — the salvage_market_enabled check. So the panel's dark gate is the flag
// itself, read honestly from PUBLIC-READ game_config (0003: game_config_public_read policy +
// `grant select … to anon, authenticated`; the getCommissionConfigRows/commissionContextFromConfig
// precedent). STRICT boolean (the commissionContextFromConfig posture): the value is jsonb and the
// activation scripts write jsonb `true` via set_game_config — anything else (absent row, jsonb
// 'true' the STRING, read error → []) reads as DARK. The mirror can never be more permissive than
// the server: while the flag is false the sell RPC rejects salvage_market_disabled BEFORE any read.
export interface SalvageConfig {
  enabled: boolean
  /** The 0093 lazy-wallet seed — a no-wallet-row player's EFFECTIVE balance (null = unknown). */
  startingCredits: number | null
}

/**
 * Sticky-lit render gate (hostile-review M1). FIRST MOUNT: dark until a POSITIVE strict flag read
 * (fail closed — the dark-leak guarantee: pre-flip production renders nothing, byte-identical).
 * ONCE LIT within a mount, a later failed/dark config re-read (error → [] → enabled:false) must
 * NOT unmount the panel mid-interaction — a successful sale's own refresh would otherwise vanish
 * the success note it just set. The panel stays rendered (the MarketPanel stay-rendered posture;
 * the data reads degrade to their honest unavailable notes) and the SERVER remains the control:
 * while genuinely dark every sell rejects salvage_market_disabled before any read.
 */
export function salvageStickyLit(everLitThisMount: boolean, readEnabled: boolean): boolean {
  return readEnabled || everLitThisMount
}

export function salvageConfigFromRows(rows: Array<{ key: string; value: unknown }>): SalvageConfig {
  const byKey = new Map(rows.map((r) => [r.key, r.value]))
  const sc = byKey.get('starting_credits')
  const n = sc === null || sc === undefined || sc === '' ? NaN : Number(sc)
  return {
    // strict boolean: anything but jsonb true (including 'true' the string) reads as DARK.
    enabled: byKey.get('salvage_market_enabled') === true,
    startingCredits: Number.isFinite(n) ? n : null,
  }
}

// ── wallet display (the getWalletBalance sentinel semantics, incl. 'error') ──────────────────────
// getWalletBalance returns number (seeded wallet) | null (genuinely NO row — the wallet is LAZY,
// 0093: the player is still on starting credits, so 0 would be a FALSE claim) | 'error' (transient
// read failure — unknown, so neither 0 nor a starting-credits claim). undefined = not read yet.
export function salvageWalletDisplay(
  balance: number | null | 'error' | undefined,
  startingCredits: number | null,
): string {
  if (balance === 'error' || balance === undefined) return '—' // unknown — never a false number
  if (balance === null) {
    // no wallet row yet → the effective balance is the server-config seed (CommissionShipPanel's
    // wallet-honesty posture); seed unknown (config read failed) → honest '—'.
    return startingCredits !== null ? `${startingCredits.toLocaleString('en-US')} (starting credits)` : '—'
  }
  return balance.toLocaleString('en-US')
}

// ── sell availability mirror (the 0174 reject order) ─────────────────────────────────────────────
export type SalvageSellReason =
  | 'ok'
  | 'salvage_market_disabled'
  | 'invalid_quantity'
  | 'ship_not_found'
  | 'not_docked'
  | 'no_demand'
  | 'insufficient_items'

// DISPLAY-ONLY mirror of sell_item_at_port's reject order (0174): gate FIRST (before ANY read) →
// input validation (invalid_quantity: items are INTEGER quantities — player_inventory.quantity is
// integer, 0039 — so null/non-positive/fractional reject, never round; the 1e6 magnitude cap) →
// ship resolved → docked → an ACTIVE demand row at this port → enough items (balance null =
// balances unreadable → SKIP the precheck and let the server answer insufficient_items itself —
// the haulAcceptAvailability null-cap idiom) → ok. The server-only guards (not_authenticated,
// invalid_request, invalid_item, idempotent_replay) are NOT mirrored — the client always submits a
// fresh uuid and an item id taken FROM a demand row, and the server owns replay semantics.
export function salvageSellAvailability(input: {
  flagOn: boolean
  quantity: number
  shipResolved: boolean
  docked: boolean
  demandActive: boolean
  balance: number | null
}): { canSell: boolean; reason: SalvageSellReason } {
  if (!input.flagOn) return { canSell: false, reason: 'salvage_market_disabled' }
  if (
    !Number.isFinite(input.quantity) ||
    input.quantity <= 0 ||
    !Number.isInteger(input.quantity) ||
    input.quantity > 1_000_000
  ) {
    return { canSell: false, reason: 'invalid_quantity' }
  }
  if (!input.shipResolved) return { canSell: false, reason: 'ship_not_found' }
  if (!input.docked) return { canSell: false, reason: 'not_docked' }
  if (!input.demandActive) return { canSell: false, reason: 'no_demand' }
  if (input.balance !== null && input.balance < input.quantity) {
    return { canSell: false, reason: 'insufficient_items' }
  }
  return { canSell: true, reason: 'ok' }
}

/**
 * Which mirrored verdicts hard-DISABLE the Sell button vs advise-only (hostile-review M2).
 * `insufficient_items` ADVISES instead of blocking: the docked lifecycleKey does not tick when
 * out-of-band loot settles into inventory mid-dock, so a known balance may be STALE-LOW — a hard
 * disable would block a genuinely-affordable sale. The hint still shows through the ONE reason
 * mapper, and the SERVER is the enforcement (inventory_spend's FOR UPDATE; its insufficient_items
 * reject comes back mapped). Everything structural still blocks: the dark gate, quantity shape
 * (< 1 / fractional / > 1e6), no ship, not docked, no demand row. `canSell` stays the pure
 * would-the-server-accept mirror verdict — this predicate is only the button-disable policy.
 */
export function salvageSellBlocks(reason: SalvageSellReason): boolean {
  return reason !== 'ok' && reason !== 'insufficient_items'
}

/**
 * Clamp a stepper/input quantity into the sellable band 1..balance (whole items — fractional
 * input floors, never rounds up; the 0174 integer posture). Non-finite input → 1. balance null
 * (own balances unreadable) → no upper clamp (the server answers insufficient_items itself);
 * balance < 1 → the floor stays 1 (the stepper never shows 0 — the shortfall surfaces as the
 * availability mirror's advisory hint, and the server enforces).
 */
export function clampSellQty(raw: number, balance: number | null): number {
  let n = Number.isFinite(raw) ? Math.floor(raw) : 1
  if (n < 1) n = 1
  if (balance !== null) {
    const cap = Math.max(1, Math.floor(balance))
    if (n > cap) n = cap
  }
  return n
}

/** Display price math: qty × unit price (what the sale WOULD credit — the server computes the
 *  authoritative total under its own lock). Non-finite or negative inputs → 0 (never NaN). */
export function sellTotal(qty: number, unitPrice: number): number {
  if (!Number.isFinite(qty) || !Number.isFinite(unitPrice) || qty < 0 || unitPrice < 0) return 0
  return qty * unitPrice
}

/**
 * The displayable buy-list: each ACTIVE demand row merged with the caller's balance (missing item
 * → 0 — a zero-stock row still shows, the port's buy-list is the subject), sorted by the
 * player-facing display name (itemLabel — unknown ids degrade to title-case, never crash) with
 * the raw id as the deterministic tiebreaker (the inventoryEntries idiom). Progression items
 * never appear BY CONSTRUCTION: the server seeds no demand row for them (0174's self-assert pins
 * it) — no client-side filter, the server list is the truth.
 */
export function salvageEntries(
  rows: PortItemDemandRow[],
  balances: Record<string, number> | null,
): SalvageEntry[] {
  return rows
    .map((r) => ({ item_id: r.item_id, unit_price: r.unit_price, balance: balances?.[r.item_id] ?? 0 }))
    .sort(
      // locale PINNED ('en') so the buy-list order never varies by user locale (review nit; the
      // formatCredits 'en-US' determinism posture).
      (a, b) =>
        itemLabel(a.item_id, 'item').localeCompare(itemLabel(b.item_id, 'item'), 'en') ||
        a.item_id.localeCompare(b.item_id, 'en'),
    )
}
