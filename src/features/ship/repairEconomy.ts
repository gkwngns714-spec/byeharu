import { strictConfigFlag } from '../../lib/gameConfigFold'
import { foldStartingCredits, salvageStickyLit, salvageWalletDisplay } from '../port/salvageMarket'
import { repairReasonMessage } from './repairReasonMessage'
import type { FleetPosition } from '../map/mainshipApi'

// REPAIR-ECON — PURE, framework-free types + client mirrors for the paid hull-repair desk (dark UI).
//
// Mirrors the server contracts exactly: the repair_economy_enabled dark gate + the repair_credits_per_hp
// cost knob (public-read game_config, 0003) and the `repair_ship_hull_at_port` reject ORDER (migration
// 0201). No React/DOM/fetch here (the salvageMarket.ts / haulBoard.ts idiom). DISPLAY-ONLY: the server
// stays authoritative and re-checks the gate, ownership, the destroyed seam, docking, the missing hull,
// the knob, and the wallet (wallet_debit's own conditional) — these mirrors only let the panel
// disable/annotate an affordance and fail closed without a round-trip. Reason names reuse the SERVER
// vocabulary (0201) so hints flow through the ONE repairReasonMessage mapper. The sticky-lit gate,
// starting-credits fold, and wallet-honesty display are REUSED verbatim from salvageMarket.ts (they are
// generic, not salvage-specific) — no second copy. Unit-tested in tests/repairEconomy.spec.ts.

export { salvageStickyLit as repairStickyLit, salvageWalletDisplay as repairWalletDisplay }

// ── config fold (public-read game_config rows → the dark gate + the cost knob + wallet-honesty seed) ──
// The ONLY repair read surface the server lit is data-shaped, not RPC-shaped: 0201 gave the repair RPC
// the repair_economy_enabled check but NO read RPC. So the panel's dark gate is the flag itself, read
// honestly from PUBLIC-READ game_config (the SalvageMarketPanel posture). STRICT boolean via the ONE
// shared fold (strictConfigFlag): only jsonb `true` lights; 'true' the string / absent / read error → []
// all read DARK. The mirror can never be more permissive than the server: while the flag is false the
// repair RPC rejects repair_economy_disabled BEFORE any read.
export interface RepairConfig {
  enabled: boolean
  /** The repair_credits_per_hp knob (0201) for cost DISPLAY; null = absent/unreadable/non-positive
   *  ("cost unknown — make no claim"; the server recomputes the authoritative charge). */
  creditsPerHp: number | null
  /** The 0093 lazy-wallet seed — a no-wallet-row player's EFFECTIVE balance (null = unknown). */
  startingCredits: number | null
}

/** Fold a public-read numeric game_config value (jsonb number or numeric string) → a POSITIVE number,
 *  or null when absent/unreadable/junk/non-positive (a repair rate must be > 0 to price anything). */
export function foldRepairRate(value: unknown): number | null {
  const n = value === null || value === undefined || value === '' ? NaN : Number(value)
  return Number.isFinite(n) && n > 0 ? n : null
}

export function repairConfigFromRows(rows: Array<{ key: string; value: unknown }>): RepairConfig {
  const byKey = new Map(rows.map((r) => [r.key, r.value]))
  return {
    enabled: strictConfigFlag(rows, 'repair_economy_enabled'),
    creditsPerHp: foldRepairRate(byKey.get('repair_credits_per_hp')),
    startingCredits: foldStartingCredits(byKey.get('starting_credits')),
  }
}

// ── hull math ────────────────────────────────────────────────────────────────────────────────────────
/** The ship's owner-read hull snapshot (main_ship_instances: hp, max_hp, status — 0043/0201). */
export interface ShipHull {
  hp: number
  maxHp: number
  status: string
}

/** A ship is DESTROYED (the free-safelock subject, not the paid path) iff status='destroyed'. */
export function isDestroyed(hull: ShipHull): boolean {
  return hull.status === 'destroyed'
}

/** Missing hull hp (never negative; a full/over-full hull → 0). Non-finite inputs → 0 (no claim). */
export function missingHull(hull: ShipHull): number {
  if (!Number.isFinite(hull.hp) || !Number.isFinite(hull.maxHp)) return 0
  return Math.max(0, Math.floor(hull.maxHp) - Math.floor(hull.hp))
}

/** Clamp a stepper/input repair amount into the whole band 1..missing (fractional floors, never rounds
 *  up — the 0201 integer posture). Non-finite → 1; missing < 1 → floor stays 1 (the desk never shows 0;
 *  a nothing-to-repair state is handled by the availability mirror, and the server enforces). */
export function clampRepairHp(raw: number, missing: number): number {
  let n = Number.isFinite(raw) ? Math.floor(raw) : 1
  if (n < 1) n = 1
  const cap = Math.max(1, Math.floor(Number.isFinite(missing) ? missing : 1))
  if (n > cap) n = cap
  return n
}

/** Display cost math: hp × credits_per_hp (what the repair WOULD debit — the server computes the
 *  authoritative charge under its own lock). Unknown rate → null; non-positive hp → null. */
export function repairCostFor(hpAmount: number, creditsPerHp: number | null): number | null {
  if (creditsPerHp === null || !Number.isFinite(hpAmount) || hpAmount <= 0) return null
  return hpAmount * creditsPerHp
}

/**
 * The paid mend's dockedness read, folded from the ship's ONE position row (get_my_fleet_positions
 * — the projection the shell already polls; NEVER a second dockedness read). Four honest states,
 * because they carry three DIFFERENT truths the surface must not conflate:
 *   · 'docked'  — a present fleet at a port: the ONLY state the server accepts. The RPC takes no
 *     location argument (0201) and resolves the dock itself via mainship_resolve_docked_location
 *     (live head 0210:278-306): state='at_location' plus a fleet row status='present' AND
 *     location_mode='location' through mainship_resolve_fleet. This deliberately DIFFERS from
 *     fittingEditability (which also accepts 'berthed'): fitting is settled-safe, the paid mend
 *     is docked-fleet-only.
 *   · 'berthed' — the ship IS at a port (the location line reads "Docked at <port>") but has no
 *     fleet, so it resolves to state='home' (0221) and the RPC would answer not_docked. The
 *     blocker is the missing FLEET, not the place — "take it to a port" would be a lie here.
 *   · 'away'    — transit / open space: genuinely not at a port; the not_docked copy is true.
 *   · 'unknown' — no row (projection dark, or the read failed and collapsed to []) or the
 *     server's own 'hidden' place: we do NOT know where the ship is, so the surface must make NO
 *     dock claim either way (fetchMyFleetPositions returns [] on ANY error — a confident
 *     "take it to a port" over a read failure would assert a falsehood about a docked ship).
 * This is an INPUT fold for repairAvailability + the line source below, not a second gate.
 */
export type RepairDockState = 'docked' | 'berthed' | 'away' | 'unknown'

export function repairDockState(pos: Pick<FleetPosition, 'place'> | undefined): RepairDockState {
  if (!pos || pos.place === 'hidden') return 'unknown'
  if (pos.place === 'docked') return 'docked'
  if (pos.place === 'berthed') return 'berthed'
  return 'away' // 'transit' | 'in_space'
}

/**
 * The ONE line the condition surface shows for a damaged ship that cannot mend where it is —
 * null when there is nothing honest to say ('docked' → the mend renders instead; 'unknown' →
 * never guess a claim). 'away' reuses the server's own not_docked copy verbatim (ONE sentence
 * source for that reason — a real server reject shows the same words); 'berthed' names the real
 * blocker (no fleet) and where to fix it, instead of contradicting the "Docked at <port>"
 * location line rendered right above the panel.
 */
export function repairDockStateLine(state: RepairDockState): string | null {
  switch (state) {
    case 'docked':
    case 'unknown':
      return null
    case 'away':
      return repairReasonMessage('not_docked')
    case 'berthed':
      return 'Add this ship to a fleet on the Fleet tab to mend its hull here.'
  }
}

// ── repair availability mirror (the 0201 reject order) ─────────────────────────────────────────────────
export type RepairReason =
  | 'ok'
  | 'repair_economy_disabled'
  | 'invalid_amount'
  | 'ship_not_found'
  | 'ship_destroyed'
  | 'not_docked'
  | 'nothing_to_repair'
  | 'insufficient_credits'

// DISPLAY-ONLY mirror of repair_ship_hull_at_port's reject order (0201): gate FIRST (before ANY read) →
// invalid_amount (hull hp is INTEGER — main_ship_instances.hp is integer, 0043 — so null/non-positive/
// fractional reject, never round; the 1e6 magnitude cap) → ship resolved → NOT destroyed (the safelock
// seam: a destroyed ship uses the FREE repair_main_ship) → docked → something to repair (missing > 0) →
// affordable (affordable null = wallet unreadable → SKIP the precheck and let the server answer
// insufficient_credits — the salvage null-cap idiom) → ok. Server-only guards (not_authenticated,
// invalid_request, idempotent_replay, repair_misconfigured) are NOT mirrored — the client submits a
// fresh uuid, and the server owns replay + knob-misconfig semantics.
export function repairAvailability(input: {
  flagOn: boolean
  amount: number
  shipResolved: boolean
  destroyed: boolean
  docked: boolean
  missing: number
  affordable: boolean | null
}): { canRepair: boolean; reason: RepairReason } {
  if (!input.flagOn) return { canRepair: false, reason: 'repair_economy_disabled' }
  if (
    !Number.isFinite(input.amount) ||
    input.amount <= 0 ||
    !Number.isInteger(input.amount) ||
    input.amount > 1_000_000
  ) {
    return { canRepair: false, reason: 'invalid_amount' }
  }
  if (!input.shipResolved) return { canRepair: false, reason: 'ship_not_found' }
  if (input.destroyed) return { canRepair: false, reason: 'ship_destroyed' }
  if (!input.docked) return { canRepair: false, reason: 'not_docked' }
  if (!Number.isFinite(input.missing) || input.missing <= 0) {
    return { canRepair: false, reason: 'nothing_to_repair' }
  }
  if (input.affordable === false) return { canRepair: false, reason: 'insufficient_credits' }
  return { canRepair: true, reason: 'ok' }
}

/**
 * Which mirrored verdicts hard-DISABLE the Repair button vs advise-only (the salvage M2 posture).
 * `insufficient_credits` ADVISES instead of blocking: the wallet display can be transiently unknown or
 * lag a just-earned credit, and the SERVER is the enforcement (wallet_debit's atomic conditional; its
 * insufficient_credits reject comes back mapped). Everything structural still blocks: the dark gate,
 * amount shape, no ship, a destroyed ship (→ free recovery), not docked, nothing to repair. `canRepair`
 * stays the pure would-the-server-accept mirror verdict — this predicate is only the disable policy.
 */
export function repairBlocks(reason: RepairReason): boolean {
  return reason !== 'ok' && reason !== 'insufficient_credits'
}
