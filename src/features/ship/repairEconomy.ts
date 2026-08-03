import { strictConfigFlag } from '../../lib/gameConfigFold'
import { foldStartingCredits, salvageStickyLit, salvageWalletDisplay } from '../port/salvageMarket'
import { repairReasonMessage } from './repairReasonMessage'
import type { FleetPosition } from '../map/mainshipApi'

// REPAIR-ECON — PURE, framework-free types + client mirrors for the hull-repair desk.
//
// Mirrors the server contract exactly: the repair_economy_enabled gate + the repair_credits_per_hp
// cost knob (public-read game_config, 0003) and `repair_ship_hull`'s reject ORDER (migration 0335,
// which replaced 0201's repair_ship_hull_at_port and 0297's repair_main_ship with ONE verb). No
// React/DOM/fetch here (the salvageMarket.ts / haulBoard.ts idiom). DISPLAY-ONLY: the server stays
// authoritative and re-checks the gate, ownership, position, the missing hull, the knob, and the
// wallet (wallet_debit's own conditional) — these mirrors only let the panel disable/annotate an
// affordance and fail closed without a round-trip. Reason names reuse the SERVER vocabulary so hints
// flow through the ONE repairReasonMessage mapper. The sticky-lit gate, starting-credits fold, and
// wallet-honesty display are REUSED verbatim from salvageMarket.ts (they are generic, not
// salvage-specific) — no second copy. Unit-tested in tests/repairEconomy.spec.ts.

export { salvageStickyLit as repairStickyLit, salvageWalletDisplay as repairWalletDisplay }

// ── config fold (public-read game_config rows → the gate + the cost knob + wallet-honesty seed) ──
// The ONLY repair read surface the server lit is data-shaped, not RPC-shaped: 0201 gave the repair RPC
// the repair_economy_enabled check but NO read RPC. So the panel's gate is the flag itself, read
// honestly from PUBLIC-READ game_config (the SalvageMarketPanel posture). STRICT boolean via the ONE
// shared fold (strictConfigFlag): only jsonb `true` lights; 'true' the string / absent / read error → []
// all read DARK. The mirror can never be more permissive than the server: while the flag is false the
// server rejects repair_economy_disabled for every priced mend. (Wreck RECOVERY is never gated by this
// flag on either side — it does not render through this panel at all; see shipRecovery.ts.)
export interface RepairConfig {
  enabled: boolean
  /** The repair_credits_per_hp knob for cost DISPLAY; null = absent/unreadable/junk/NEGATIVE
   *  ("cost unknown — make no claim"; the server recomputes the authoritative charge). ZERO is a
   *  real, valid rate meaning FREE, and folds to 0 — not to null. */
  creditsPerHp: number | null
  /** The 0093 lazy-wallet seed — a no-wallet-row player's EFFECTIVE balance (null = unknown). */
  startingCredits: number | null
}

/**
 * Fold a public-read numeric game_config value (jsonb number or numeric string) → a NON-NEGATIVE
 * number, or null when absent/unreadable/junk/negative.
 *
 * ZERO IS A PRICE, AND IT MEANS FREE. This fold used to require `n > 0`, which mirrored 0201's
 * server-side `v_per_hp <= 0 → repair_misconfigured`. Both were wrong the moment the owner set
 * repair_credits_per_hp = 0 to make repairs free: the server refused every mend and the desk showed
 * no price. 0335 fixed the server (only null/negative fails closed) and this is the client half of
 * that same correction — they must agree, or the panel lies about a repair the server would accept.
 */
export function foldRepairRate(value: unknown): number | null {
  const n = value === null || value === undefined || value === '' ? NaN : Number(value)
  return Number.isFinite(n) && n >= 0 ? n : null
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
 * The mend's POSITION read, folded from the ship's ONE position row (get_my_fleet_positions — the
 * projection the shell already polls; NEVER a second position read). THREE states, because the
 * server now asks exactly one question — is this ship at a port? — through exactly one authority:
 *   · 'at_port' — a present fleet at a port, OR a berthed ship. Both are accepted, because 0335
 *     routes the mend through mainship_port_of_ship (0297 §1, extended by 0334): fleet dock, then
 *     group dock, then berth. This is the fold's real change. It used to distinguish 'docked' from
 *     'berthed' because 0201 gated on mainship_resolve_docked_location, which additionally demands
 *     a PRESENT FLEET and so answered not_docked for a ship plainly tied up at a port — forcing
 *     the panel to carry a whole extra sentence ("Add this ship to a fleet…") that existed only to
 *     explain a split that should never have existed. One authority, one state, no sentence.
 *   · 'away'    — transit / open space: genuinely not at a port; the not_at_port copy is true.
 *   · 'unknown' — no row (projection dark, or the read failed and collapsed to []) or the server's
 *     own 'hidden' place: we do NOT know where the ship is, so the surface must make NO position
 *     claim either way (fetchMyFleetPositions returns [] on ANY error — a confident "take it to a
 *     port" over a read failure would assert a falsehood about a docked ship).
 * This is an INPUT fold for repairAvailability + the line source below, not a second gate.
 */
export type RepairDockState = 'at_port' | 'away' | 'unknown'

export function repairDockState(pos: Pick<FleetPosition, 'place'> | undefined): RepairDockState {
  if (!pos || pos.place === 'hidden') return 'unknown'
  if (pos.place === 'docked' || pos.place === 'berthed') return 'at_port'
  return 'away' // 'transit' | 'in_space'
}

/**
 * The ONE line the condition surface shows for a damaged ship that cannot be repaired where it is —
 * null when there is nothing honest to say ('at_port' → the mend renders instead; 'unknown' → never
 * guess a claim). 'away' reuses the server's own not_at_port copy verbatim (ONE sentence source for
 * that reason — a real server reject shows the same words).
 */
export function repairDockStateLine(state: RepairDockState): string | null {
  switch (state) {
    case 'at_port':
    case 'unknown':
      return null
    case 'away':
      return repairReasonMessage('not_at_port')
  }
}

// ── repair availability mirror (the 0335 reject order) ─────────────────────────────────────────────────
export type RepairReason =
  | 'ok'
  | 'repair_economy_disabled'
  | 'invalid_amount'
  | 'ship_not_found'
  | 'not_at_port'
  | 'nothing_to_repair'
  | 'insufficient_credits'

// DISPLAY-ONLY mirror of repair_ship_hull's reject order (0335): invalid_amount (hull hp is INTEGER —
// main_ship_instances.hp is integer, 0043 — so non-positive/fractional reject, never round; the 1e6
// magnitude cap) → ship resolved → AT A PORT (one authority: mainship_port_of_ship) → something to
// repair (missing > 0) → the economy gate → affordable (affordable null = wallet unreadable → SKIP the
// precheck and let the server answer insufficient_credits — the salvage null-cap idiom) → ok.
//
// TWO deliberate divergences from the server's own order, both because this mirror is only ever
// consulted for a LIVING hull (the panel renders under repairConcept === 'paid_mend'):
//   · `ship_destroyed` is gone. It was 0201's "this is the other function's job" reject; 0335 has no
//     other function, and a wreck reaching this surface is a stale-status race the panel states
//     honestly instead of mirroring.
//   · the economy gate is mirrored AFTER position/missing rather than first, matching the order a
//     player reads the card in. The server owns the real order and rejects either way.
// Server-only guards (not_authenticated, invalid_request, hull_unrepairable, idempotent_replay,
// repair_misconfigured) are NOT mirrored — the client submits a fresh uuid, and the server owns
// replay + knob-misconfig semantics.
export function repairAvailability(input: {
  flagOn: boolean
  amount: number
  shipResolved: boolean
  atPort: boolean
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
  if (!input.atPort) return { canRepair: false, reason: 'not_at_port' }
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
 * insufficient_credits reject comes back mapped). Everything structural still blocks: the economy gate,
 * amount shape, no ship, not at a port, nothing to repair. `canRepair` stays the pure
 * would-the-server-accept mirror verdict — this predicate is only the disable policy.
 */
export function repairBlocks(reason: RepairReason): boolean {
  return reason !== 'ok' && reason !== 'insufficient_credits'
}
