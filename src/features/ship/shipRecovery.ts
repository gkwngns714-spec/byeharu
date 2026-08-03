import { repairReasonMessage } from './repairReasonMessage'
import { repairDockState, type RepairDockState } from './repairEconomy'
import type { FleetPosition } from '../map/mainshipApi'

// SHIP RECOVERY — the PURE view-model + copy for a DISABLED ship (migration 0297, unified by 0335).
//
// 0297 made the free repair POSITION-GATED: a wrecked ship is repaired in a city, never adrift.
// Because a gate with no way out is a softlock, the same migration added the free always-available
// tow (mainship_emergency_tow), which berths a wreck at the nearest port. This module is the ONE
// place that decides which of the two a disabled ship should be offered.
//
// ONE SURFACE (this slice) — WHAT THIS MODULE STOPPED OWNING. 0335 unified the SERVER (one verb,
// repair_ship_hull, whose only wreck/dent difference is the policy it applies) but the client kept
// TWO repair blocks in FittingDetail and therefore kept the machinery to choose between them:
//   · `repairConcept` — a SECOND decider beside `repairGate`, existing only to pick a mount. Two
//     deciders over one fact need a spec asserting they agree, and tests/shipRecovery.spec.ts had
//     exactly that. Both are deleted: `repairGate` is the one decider.
//   · `canRepair` / `canTow` — a private two-valued action vocabulary, superseded by the ONE
//     position vocabulary below ('away' is the tow; everything else is Repair).
//   · `repairGateNote` — the WRECK half of a copy pair whose DENT half (repairDockStateLine) lived
//     in repairEconomy.ts. One surface, one sentence source: `repairPositionLine`.
//
// 0335 REMOVED THIS MODULE'S SECOND JOB. It used to own a private reason vocabulary, because
// repair_main_ship RAISED and its "reason codes" arrived as substrings of an exception message
// (repairErrorMessage / isAdriftError matched them with String.includes). That function is gone; the
// one surviving repair verb returns the same {ok, reason} envelope the mend always used, so every
// repair message in the game now comes from repairReasonMessage and this file carries only the GATE
// — which action, and the sentence that explains the gate state itself.
//
// FAIL OPEN, ON PURPOSE. When the readiness read is unavailable (transport error, or the client
// deployed ahead of the migration) the gate answers 'unknown' and the caller renders exactly what it
// rendered before 0297: the Repair button, enabled. The SERVER is the enforcer; the UI only explains.
// The one thing that must never happen is a client that hides recovery from a player whose ship the
// server would happily repair.
//
// Specs: tests/shipRecovery.spec.ts.

/** One row of get_my_disabled_ships() (0297 §4) — the caller's own wrecks and where they are. */
export interface DisabledShipRow {
  main_ship_id: string
  name: string
  /** true when mainship_port_of_ship resolved a port for this wreck — repair is unlocked there. */
  at_port: boolean
  /** the port id when at_port, else null. */
  location_id: string | null
}

/**
 * The ONE freshest-status resolution feeding every state read of a ship (the repair surface's
 * wreck policy and its gate, the roster rows' danger tone): prefer the REFETCHED shared read
 * (fetchMyMainShips — re-read on every refresh-key tick and after every command), fall back to the
 * never-repolled selection row. One leaf composed at its sites — inline copies of
 * `row?.status ?? sel.status` were exactly the two-sites-one-comparison shape that produced the
 * rev.1 dead end.
 *
 * HONEST LIMIT: the fallback is not only "pre-load". fetchMyMainShips collapses ANY read error to
 * [] (the repo-wide fail-soft API posture), so a failed shared read also lands here and the stale
 * selection status wins until the next good wave. Distinguishing error from genuinely-empty would
 * mean changing that API contract for every reader — out of this slice; this note states the
 * window instead of claiming it away.
 */
export function freshestShipStatus(
  refetched: { status: string } | null | undefined,
  selectionRow: { status: string },
): string {
  return refetched?.status ?? selectionRow.status
}

export type RepairGate =
  /** Not disabled — no recovery surface at all. */
  | { kind: 'not_disabled' }
  /** Disabled, but we could not read where it is → offer Repair anyway; the server decides. */
  | { kind: 'unknown' }
  /** Disabled and in port → Repair. */
  | { kind: 'at_port'; locationId: string | null }
  /** Disabled and at no port → Tow first, Repair disabled with the reason. */
  | { kind: 'adrift' }

/**
 * The ONE gate decision. `serverSaidAdrift` is the authoritative override: if a repair attempt came
 * back with the server's not_at_port reject, that outranks any (possibly stale or unavailable)
 * readiness read — the player is shown the tow immediately rather than a button that just failed.
 */
export function repairGate(
  status: string,
  rows: DisabledShipRow[] | null,
  shipId: string,
  serverSaidAdrift = false,
): RepairGate {
  if (status !== 'destroyed') return { kind: 'not_disabled' }
  if (serverSaidAdrift) return { kind: 'adrift' }
  if (rows === null) return { kind: 'unknown' }
  const row = rows.find((r) => r.main_ship_id === shipId)
  if (!row) return { kind: 'unknown' } // read succeeded but this ship is not in it (stale wave)
  return row.at_port ? { kind: 'at_port', locationId: row.location_id } : { kind: 'adrift' }
}

/**
 * ██ THE ONE POSITION ANSWER for the repair surface — a wreck and a dent alike. ██
 *
 * The server asks exactly one position question through exactly one authority
 * (mainship_port_of_ship — 0335). The client needs TWO READS to cover every hull, because the two
 * projections cover DISJOINT ship sets and neither can answer for the other:
 *   · get_my_fleet_positions EXCLUDES destroyed ships outright (see shipRecoveryApi.ts's header) —
 *     so a wreck has NO row, and a fold over `place` alone would answer 'unknown' for every wreck
 *     forever, and the tow could never appear;
 *   · get_my_disabled_ships contains ONLY destroyed ships — so it can say nothing about a dent.
 * They are complementary, not duplicated. This fold is where they become ONE value, so the surface
 * renders from a single position vocabulary and the panel carries no wreck/dent branch of its own
 * for "where is it".
 *
 * The gate WINS for a wreck: if a positions row for a destroyed ship ever appeared (a stale wave,
 * a server change), the readiness read is the authority the server's own gate agrees with.
 */
export function repairPosition(
  gate: RepairGate,
  pos: Pick<FleetPosition, 'place'> | undefined,
): RepairDockState {
  switch (gate.kind) {
    case 'not_disabled':
      return repairDockState(pos) // a living hull: its own fleet-positions row
    case 'at_port':
      return 'at_port'
    case 'adrift':
      return 'away'
    case 'unknown':
      return 'unknown' // NOT 'away' — the tow never displaces a Repair we cannot rule out
  }
}

/**
 * ██ THE ONE SENTENCE SOURCE for the repair surface. ██ Replaces the copy PAIR that existed only
 * because there were two blocks (repairGateNote here + repairDockStateLine in repairEconomy.ts),
 * keyed instead on the two facts that actually decide the sentence.
 *
 * A WRECK always gets a line, whatever its position — its recovery must be named on screen even
 * when the readiness read failed (NO-SOFTLOCK). A DENT speaks only when it cannot be mended where
 * it is, and then in the SERVER'S OWN WORDS (repairReasonMessage('not_at_port') verbatim, so a
 * display precheck and a real reject read identically); at a port the mend itself renders instead,
 * and on an unknown position no claim either way is honest.
 */
export function repairPositionLine(wreck: boolean, state: RepairDockState): string | null {
  if (wreck) {
    return state === 'away'
      ? 'This ship is wrecked and adrift. Ships are only repaired in port — tow it in first.'
      : 'This ship is wrecked. Repair it to get moving again.'
  }
  return state === 'away' ? repairReasonMessage('not_at_port') : null
}

export const REPAIR_LABEL = 'Repair ship'
export const TOW_LABEL = 'Tow to the nearest port'

const TOW_FALLBACK = 'The tow is unavailable right now. Try again in a moment.'

/**
 * The ONE recovery-specific sentence: a wreck rejected for POSITION is told about the tow, not
 * about ports in the abstract. Every other reason falls through to repairReasonMessage — the same
 * map the priced mend uses — because after 0335 there is one server verb and one vocabulary.
 *
 * This is not a second mapper: it overrides exactly one key, for the one surface where the generic
 * "Take this ship to a port to repair it." would be useless advice (a wreck cannot move itself).
 */
export function recoveryReasonMessage(reason: string): string {
  if (reason === 'not_at_port') {
    return 'This ship is adrift. Tow it to a port, then repair it there.'
  }
  return repairReasonMessage(reason)
}

/** mainship_emergency_tow returns an envelope; every reason maps to player words. */
export function towReasonMessage(reason: string): string {
  switch (reason) {
    case 'not_authenticated':
      return "You're signed out. Sign in again to call for a tow."
    case 'ship_not_found':
      return 'That ship could not be found.'
    case 'ship_not_disabled':
      return "This ship isn't wrecked — it doesn't need a tow."
    case 'already_at_port':
      return 'This ship is already in port. Repair it here.'
    case 'no_port_available':
      return 'No port can take this ship right now.'
    default:
      return TOW_FALLBACK
  }
}

/** The line shown after a tow lands. */
export function towSuccessMessage(portName: string | null): string {
  return portName ? `Towed to ${portName}. Repair it here.` : 'Towed to port. Repair it here.'
}
