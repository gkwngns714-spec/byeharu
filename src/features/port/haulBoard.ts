// HAUL-3 — PURE, framework-free types + client mirrors for the port bulletin board (dark UI).
//
// Mirrors the server contracts exactly: get_port_contracts (migration 0181 — the gated bulletin
// read) and the accept/deliver reject ORDERS of haul_accept_contract / haul_deliver_contract
// (0179). No React/DOM/fetch here (the teamSend.ts / dockServices.ts idiom). DISPLAY-ONLY: the
// server stays authoritative and re-checks the gate, docking, contract state, the active cap, the
// deadline, and the cargo balance — these mirrors only let the panel disable/annotate an
// affordance and fail closed without a round-trip. Reason names reuse the SERVER vocabulary
// (0179/0181) so the availability hints flow through the ONE haulReasonMessage mapper (the
// teamCaptains ship_not_settled precedent). Unit-tested in tests/haulBoard.spec.ts.

/** One row of get_port_contracts().offered (0181) — this port's fresh bulletin. */
export interface PortContractOffer {
  contract_id: string
  good_id: string
  quantity: number
  reward_credits: number
  offered_at: string
  expires_at: string
  dest_location_id: string
  dest_name: string | null
}

/** One row of get_port_contracts().mine (0181) — the caller's accepted contracts (all ports). */
export interface MyHaulContract {
  contract_id: string
  good_id: string
  quantity: number
  reward_credits: number
  origin_location_id: string
  origin_name: string | null
  dest_location_id: string
  dest_name: string | null
  accepted_at: string
  deliver_by: string
}

// get_port_contracts envelope (0181): lit → { ok:true, … }; dark → { ok:false,
// reason:'haul_contracts_disabled' }; not-authed → { ok:false, reason:'not_authenticated' };
// transport error → { ok:false }. Discriminated union so isServerLit() narrows cleanly; the
// arrays/cap optional so defensive `?? []` / null reads are well-typed.
export type GetPortContractsResult =
  | { ok: true; location_id: string; max_active?: number; offered?: PortContractOffer[]; mine?: MyHaulContract[] }
  | { ok: false; reason?: string }

export type HaulAcceptReason =
  | 'ok'
  | 'haul_contracts_disabled'
  | 'ship_not_found'
  | 'not_docked'
  | 'contract_not_found'
  | 'too_many_active'

// DISPLAY-ONLY mirror of haul_accept_contract's reject order (0179): gate FIRST → ship resolved →
// docked (at the offer's origin — the bulletin is port-scoped, so the board's own port IS the
// origin) → fresh offer (a stale 'offered' row folds into the server's contract_not_found — the
// 0179 §3 fail-closed posture, mirrored by name) → the active cap (maxActive null = unknown →
// skip the precheck and let the server answer too_many_active itself) → ok. The server-only
// guards (already_accepted/_other races, idempotency) are NOT mirrored — the server owns them.
export function haulAcceptAvailability(input: {
  serverLit: boolean
  shipResolved: boolean
  dockedAtOrigin: boolean
  offerFresh: boolean
  activeCount: number
  maxActive: number | null
}): { canAccept: boolean; reason: HaulAcceptReason } {
  if (!input.serverLit) return { canAccept: false, reason: 'haul_contracts_disabled' }
  if (!input.shipResolved) return { canAccept: false, reason: 'ship_not_found' }
  if (!input.dockedAtOrigin) return { canAccept: false, reason: 'not_docked' }
  if (!input.offerFresh) return { canAccept: false, reason: 'contract_not_found' }
  if (input.maxActive !== null && input.activeCount >= input.maxActive) {
    return { canAccept: false, reason: 'too_many_active' }
  }
  return { canAccept: true, reason: 'ok' }
}

export type HaulDeliverReason =
  | 'ok'
  | 'haul_contracts_disabled'
  | 'ship_not_found'
  | 'not_docked'
  | 'wrong_port'
  | 'deadline_passed'
  | 'insufficient_cargo'

// DISPLAY-ONLY mirror of haul_deliver_contract's reject order (0179): gate FIRST → ship resolved →
// docked → at the DESTINATION port (wrong_port) → deadline ahead (deadline_passed; the cancel flip
// stays the generator's — this only disables the button) → enough cargo aboard (the client-side
// cargo check is DISPLAY-ONLY: the server's under-lock lot-sum is the truth) → ok. The state fold
// (contract_not_found for not-mine/terminal) is not mirrored — `mine` rows are accepted-by-me by
// construction of the 0181 read.
export function haulDeliverAvailability(input: {
  serverLit: boolean
  shipResolved: boolean
  docked: boolean
  atDestination: boolean
  deadlineAhead: boolean
  hasCargo: boolean
}): { canDeliver: boolean; reason: HaulDeliverReason } {
  if (!input.serverLit) return { canDeliver: false, reason: 'haul_contracts_disabled' }
  if (!input.shipResolved) return { canDeliver: false, reason: 'ship_not_found' }
  if (!input.docked) return { canDeliver: false, reason: 'not_docked' }
  if (!input.atDestination) return { canDeliver: false, reason: 'wrong_port' }
  if (!input.deadlineAhead) return { canDeliver: false, reason: 'deadline_passed' }
  if (!input.hasCargo) return { canDeliver: false, reason: 'insufficient_cargo' }
  return { canDeliver: true, reason: 'ok' }
}

/**
 * Deadline label for a bulletin/contract timestamp, computed against an INJECTED now (pure,
 * testable — the caller passes Date.now()). Missing/invalid → '—' (the lib/time posture);
 * elapsed → 'overdue'; ≥1h → 'Hh MMm'; ≥1m → 'Mm SSs'; else 'Ss'. Remaining time is ceiled to
 * the second so a deadline never reads '0s' while still ahead.
 */
export function haulDeadlineLabel(ts: string | null | undefined, nowMs: number): string {
  if (!ts) return '—'
  const t = new Date(ts).getTime()
  if (Number.isNaN(t)) return '—'
  const remaining = Math.ceil((t - nowMs) / 1000)
  if (remaining <= 0) return 'overdue'
  const h = Math.floor(remaining / 3600)
  const m = Math.floor((remaining % 3600) / 60)
  const s = remaining % 60
  if (h > 0) return `${h}h ${m.toString().padStart(2, '0')}m`
  if (m > 0) return `${m}m ${s.toString().padStart(2, '0')}s`
  return `${s}s`
}
