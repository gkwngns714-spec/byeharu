import type { ShipFittingRow } from '../modules/modulesTypes'
import type { CaptainInstance } from '../captains/captainsTypes'
import type { ShipCargoLot } from '../map/tradeApi'

// SHIP-DOSSIER — PURE selectors for the per-ship dossier card (no React/DOM/fetch — the
// shipName.ts mold). The dossier renders three already-readable surfaces AT the ship they
// belong to (fitted modules · assigned captains · cargo hold); these helpers are the
// display-side arithmetic only — every number the server also enforces stays server-enforced
// (fitting_apply's slot cap, market_buy's volume cap). Specs: tests/shipDossier.spec.ts.

/** The fittings rows belonging to ONE ship, server order preserved (0116 returns fitted_at desc). */
export function fittingsForShip(fittings: ShipFittingRow[], mainShipId: string): ShipFittingRow[] {
  return fittings.filter((f) => f.main_ship_id === mainShipId)
}

/** Σ slot_cost over a per-ship fittings subset — the same display-only slot arithmetic
 *  ModulesPanel's ship picker shows ('2/3 slots'); fitting_apply's hard cap is the enforcer. */
export function fittedSlotsUsed(fittings: ShipFittingRow[]): number {
  return fittings.reduce((sum, f) => sum + f.slot_cost, 0)
}

/** The captains ASSIGNED to one ship (0123 rows carry main_ship_id | null; unassigned and
 *  other-ship captains are excluded — this is the ship's roster, not the player's). */
export function captainsForShip(captains: CaptainInstance[], mainShipId: string): CaptainInstance[] {
  return captains.filter((c) => c.main_ship_id === mainShipId)
}

/** One displayable cargo stack: a good's lots merged (the hold shows WHAT is aboard, not the
 *  FIFO cost-basis lots — that accounting stays MarketPanel's concern). */
export interface CargoStack {
  good_id: string
  qty: number
  m3: number // this stack's occupied volume (Σ qty·unit_volume_m3 over its lots)
}

/** Merge lots per good, first-seen (FIFO) order preserved — oldest cargo leads, like the hold. */
export function aggregateCargo(lots: ShipCargoLot[]): CargoStack[] {
  const byGood = new Map<string, CargoStack>()
  for (const lot of lots) {
    let stack = byGood.get(lot.good_id)
    if (!stack) {
      stack = { good_id: lot.good_id, qty: 0, m3: 0 }
      byGood.set(lot.good_id, stack)
    }
    stack.qty += lot.qty
    stack.m3 += lot.qty * lot.unit_volume_m3
  }
  return [...byGood.values()]
}

/** Occupied hold volume = Σ qty·unit_volume_m3 over ALL lots — the authoritative volume model,
 *  the exact MarketPanel lot-sum formula (kept identical so the two surfaces can never disagree). */
export function cargoUsedM3(lots: ShipCargoLot[]): number {
  return lots.reduce((sum, lot) => sum + lot.qty * lot.unit_volume_m3, 0)
}

/** m³ display format — two decimals, the MarketPanel convention ('12.50'). */
export function formatM3(n: number): string {
  return n.toFixed(2)
}

// ── SHIP-POWER — the per-ship stats strip parser ─────────────────────────────────────────────────
// get_my_expedition_preview (0049, resolver-swapped 0159) → the strip's display shape. PURE (no
// fetch); the thin RPC wrapper (mainshipApi.fetchMyExpeditionPreview) hands the raw jsonb envelope
// here. Normalize-don't-throw: every malformed/dark/no-ship input collapses to a quiet variant —
// the strip fails CLOSED (hidden), never crashes the dossier. The numbers are the 0122 adapter's
// (clamped ≥0 server-side); a non-finite/absent field still degrades per-field to null ('—').

/** The strip's four numbers (0122 adapter keys). null = absent/malformed field (renders as —). */
export interface ShipStatsStrip {
  combat_power: number | null
  survival: number | null
  speed: number | null
  cargo_capacity: number | null
}

export type ShipStatsPreviewParse =
  | { kind: 'stats'; stats: ShipStatsStrip } // has_ship && valid → render the strip
  | { kind: 'invalid'; error: string | null } // has_ship && !valid (adapter raise / selection required)
  | { kind: 'hidden' } // no-ship teaser, transport null, or malformed → render nothing

const finiteOrNull = (v: unknown): number | null =>
  typeof v === 'number' && Number.isFinite(v) ? v : null

export function parseShipStatsPreview(data: unknown): ShipStatsPreviewParse {
  if (typeof data !== 'object' || data === null || Array.isArray(data)) return { kind: 'hidden' }
  const d = data as Record<string, unknown>
  // No-ship starter-hull teaser (has_ship:false) — the status card owns that story, not the strip.
  if (d.has_ship !== true) return { kind: 'hidden' }
  if (d.valid !== true) return { kind: 'invalid', error: typeof d.error === 'string' ? d.error : null }
  const stats = (typeof d.stats === 'object' && d.stats !== null ? d.stats : {}) as Record<string, unknown>
  return {
    kind: 'stats',
    stats: {
      combat_power: finiteOrNull(stats.combat_power),
      survival: finiteOrNull(stats.survival),
      speed: finiteOrNull(stats.speed),
      cargo_capacity: finiteOrNull(stats.cargo_capacity),
    },
  }
}

/** One ship's power from a raw preview envelope, or null (invalid/dark/no-ship) — the roster's
 *  per-ungrouped-ship chip value. A null chip is simply omitted (fail quiet, never '—' noise). */
export function shipPowerFromPreview(data: unknown): number | null {
  const parsed = parseShipStatsPreview(data)
  return parsed.kind === 'stats' ? parsed.stats.combat_power : null
}

// The invalid-envelope error → player copy map (the teamReasonMessage mold — that map's
// vocabulary is the TEAM RPCs' reject reasons, not this envelope's, so it can't be reused
// directly). The 0159 envelope's `error` is either the one structured token below or a raw
// Postgres sqlerrm (internal function names, e.g. 'calculate_expedition_stats: …') — the raw
// string must NEVER reach the DOM; anything unmapped degrades to the generic line.
const STATS_ERROR_MESSAGES: Record<string, string> = {
  ship_selection_required: 'Select a ship to see its stats.',
}

/** Short player-facing copy for an invalid stats envelope; unknown/raw-sqlerrm/null → generic. */
export function shipStatsErrorMessage(error: string | null): string {
  return (error !== null ? STATS_ERROR_MESSAGES[error] : undefined) ?? 'Ship stats unavailable right now.'
}
