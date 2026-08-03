import { itemLabel } from '../../components/items'

// ITEMS-HAVE-A-PLACE (0332) — PURE, framework-free model of THE SHIP'S HOLD and of a transfer
// between the hold and the docked port's storage. No React/DOM/fetch here (the dockStore.ts mold).
// Specs: tests/hold.spec.ts.
//
// THE ONE RULE THIS FILE OBEYS: it never COMPUTES a capacity or an occupancy. Both numbers arrive
// from the server (get_my_hold → hold_capacity_m3 / hold_used_m3, migration 0332) and this file
// only validates, formats and compares them. A client-side second copy of the capacity formula
// would be a second authority for "how full is my hold", which is the exact defect the migration
// exists to prevent. `stackFits` below is a DISPLAY precheck over server-supplied numbers — the
// server refuses over-capacity itself, and its refusal is the enforcement.

export interface HoldItem {
  itemId: string
  /** Whole units carried (player_inventory.quantity is integer). */
  quantity: number
  /** Catalog volume of ONE unit, from item_types.volume_m3. Always > 0 server-side. */
  volumeM3: number
  /** quantity × volumeM3, as the server computed it. Never recomputed here. */
  stackM3: number
}

export interface Hold {
  /** false = not signed in / read failed / malformed — nothing renders, nothing is invented. */
  ok: boolean
  items: HoldItem[]
  usedM3: number
  capacityM3: number
  freeM3: number
  /** usedM3 > capacityM3. A legal state, not an error: loot and refunds never refuse. */
  overCapacity: boolean
}

/** Safe default for loading / error / signed-out / malformed: an empty, zero-capacity hold. */
export const HOLD_EMPTY: Hold = {
  ok: false,
  items: [],
  usedM3: 0,
  capacityM3: 0,
  freeM3: 0,
  overCapacity: false,
}

/** A finite non-negative number, or null. Rejects NaN/Infinity/strings/negatives. */
function finiteNonNegative(raw: unknown): number | null {
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw < 0) return null
  return raw
}

function parseHoldItem(raw: unknown): HoldItem[] {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return []
  const o = raw as Record<string, unknown>
  const itemId = typeof o.item_id === 'string' && o.item_id.length > 0 ? o.item_id : null
  const quantity = finiteNonNegative(o.quantity)
  const volumeM3 = finiteNonNegative(o.volume_m3)
  const stackM3 = finiteNonNegative(o.stack_m3)
  if (itemId === null || quantity === null || volumeM3 === null || stackM3 === null) return []
  // A zero-volume item is unrepresentable server-side (NOT NULL + CHECK > 0); if one ever arrives
  // it is malformed data, and dropping it is safer than rendering a stack that costs nothing.
  if (volumeM3 <= 0) return []
  return [{ itemId, quantity, volumeM3, stackM3 }]
}

/**
 * Strict validator for the raw get_my_hold() jsonb. Returns a sanitized Hold, or HOLD_EMPTY for
 * ANY not-ok / malformed shape. Never throws, never invents a capacity.
 */
export function parseHold(raw: unknown): Hold {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return HOLD_EMPTY
  const o = raw as Record<string, unknown>
  if (o.ok !== true) return HOLD_EMPTY
  const usedM3 = finiteNonNegative(o.used_m3)
  const capacityM3 = finiteNonNegative(o.capacity_m3)
  const freeM3 = finiteNonNegative(o.free_m3)
  if (usedM3 === null || capacityM3 === null || freeM3 === null) return HOLD_EMPTY
  const items = Array.isArray(o.items) ? o.items.flatMap(parseHoldItem) : []
  return {
    ok: true,
    items,
    usedM3,
    capacityM3,
    freeM3,
    // The server's own verdict is authoritative; the comparison is only a fallback for a payload
    // that predates the key.
    overCapacity: typeof o.over_capacity === 'boolean' ? o.over_capacity : usedM3 > capacityM3,
  }
}

/**
 * The displayable hold: zero/negative stacks dropped (a fully-spent item is not "carried"), sorted
 * by the player-facing display name (itemLabel — unknown ids degrade to title-case, never crash)
 * with the raw id as the deterministic tiebreaker.
 *
 * This REPLACES inventoryView.inventoryEntries, which built the same list from a bare
 * Record<id, qty> and is deleted in this slice — two entry-list builders over one hold would be
 * exactly the duplication the no-spaghetti law forbids. The ordering rule is carried over verbatim.
 */
export function holdEntries(hold: Hold): HoldItem[] {
  return hold.items
    .filter((i) => i.quantity > 0)
    .sort(
      (a, b) =>
        itemLabel(a.itemId, 'item').localeCompare(itemLabel(b.itemId, 'item')) ||
        a.itemId.localeCompare(b.itemId),
    )
}

export interface HoldMeter {
  /** 0–100, clamped; 100 when capacity is 0 and anything is carried (a full-and-then-some hold). */
  pct: number
  tone: 'accent' | 'danger' | 'neutral'
  /** "22.7 / 250 m³" — the one place the pair is formatted. */
  label: string
}

/** Format a volume for display: whole numbers bare, fractions to at most 2 decimals, no trailing zeros. */
export function formatM3(m3: number): string {
  if (!Number.isFinite(m3)) return '0'
  const rounded = Math.round(m3 * 100) / 100
  return Number.isInteger(rounded) ? String(rounded) : String(rounded).replace(/0+$/, '').replace(/\.$/, '')
}

/**
 * The hold's fullness, ready to render. A cap the player cannot see is a trap, so this always
 * produces a label — including the zero-capacity case, which is what a player with no ship sees.
 */
export function holdMeter(hold: Hold): HoldMeter {
  const { usedM3, capacityM3 } = hold
  const pct = capacityM3 > 0 ? Math.min(100, (usedM3 / capacityM3) * 100) : usedM3 > 0 ? 100 : 0
  const tone = hold.overCapacity ? 'danger' : capacityM3 > 0 ? 'accent' : 'neutral'
  return { pct, tone, label: `${formatM3(usedM3)} / ${formatM3(capacityM3)} m³` }
}

/**
 * Display precheck for a withdrawal: would `qty` units of a `volumeM3` item fit in the free space?
 * The SERVER refuses over-capacity (hold_over_capacity) and that refusal is the enforcement — this
 * only decides whether to grey the button and say why first.
 */
export function stackFits(hold: Hold, volumeM3: number, qty: number): boolean {
  if (!hold.ok || !Number.isFinite(volumeM3) || volumeM3 <= 0) return false
  if (!Number.isInteger(qty) || qty <= 0) return false
  return hold.usedM3 + qty * volumeM3 <= hold.capacityM3
}

/**
 * The largest whole number of a `volumeM3` item that still fits, capped at `available`.
 * Used to prefill the mover, never to silently reduce a player's request — the server refuses
 * rather than clamps, and so does the UI.
 */
export function maxUnitsThatFit(hold: Hold, volumeM3: number, available: number): number {
  if (!hold.ok || !Number.isFinite(volumeM3) || volumeM3 <= 0) return 0
  if (!Number.isFinite(available) || available <= 0) return 0
  const room = hold.capacityM3 - hold.usedM3
  if (room <= 0) return 0
  return Math.max(0, Math.min(Math.floor(available), Math.floor(room / volumeM3)))
}

/** A whole-number quantity in [1, available], or null when the input cannot be moved. */
export function normalizeMoveQty(raw: string, available: number): number | null {
  const n = Number(raw.trim())
  if (!Number.isFinite(n) || !Number.isInteger(n) || n <= 0) return null
  if (!Number.isFinite(available) || available <= 0) return null
  return Math.min(n, Math.floor(available))
}
