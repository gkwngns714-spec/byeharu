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
