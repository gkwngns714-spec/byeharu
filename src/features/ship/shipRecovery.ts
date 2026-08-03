import { repairReasonMessage } from './repairReasonMessage'

// SHIP RECOVERY — the PURE view-model + copy for a DISABLED ship (migration 0297, unified by 0335).
//
// 0297 made the free repair POSITION-GATED: a wrecked ship is repaired in a city, never adrift.
// Because a gate with no way out is a softlock, the same migration added the free always-available
// tow (mainship_emergency_tow), which berths a wreck at the nearest port. This module is the ONE
// place that decides which of the two a disabled ship should be offered.
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
 * REPAIR-WHERE-YOU-ARE — the ONE mount decision for the Fitting detail's condition block: which
 * repair SURFACE a ship's state gets. Since 0335 both surfaces command the same RPC
 * (repair_ship_hull); what differs is what the player is shown — a wreck gets a single free
 * "Repair ship" / "Tow" action, a living hull gets the priced stepper desk. Exactly one surface per
 * state, never both, never neither. Both mount sites in FittingDetail read THIS value; neither
 * carries its own status comparison, so the two surfaces can only flip together. Feed it the
 * freshest status available (the screen's refetched shared read, falling back to the selection row)
 * — a stale selection status here is what turns a mid-session destruction into a dead end.
 */
export type RepairConcept = 'paid_mend' | 'free_recovery'

export function repairConcept(status: string): RepairConcept {
  return status === 'destroyed' ? 'free_recovery' : 'paid_mend'
}

/**
 * The ONE freshest-status resolution feeding every recovery decision (repairConcept, repairGate,
 * the roster rows' isDisabled): prefer the REFETCHED shared read (fetchMyMainShips — re-read on
 * every refresh-key tick and after every command), fall back to the never-repolled selection row.
 * One leaf composed at its three sites — three inline copies of `row?.status ?? sel.status` was
 * exactly the two-sites-one-comparison shape that produced the rev.1 dead end.
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

/** Plain-language line above the action, per gate state. Says what is true and what to do. */
export function repairGateNote(gate: RepairGate): string | null {
  switch (gate.kind) {
    case 'not_disabled':
      return null
    case 'adrift':
      return '🛠 This ship is wrecked and adrift. Ships are only repaired in port — tow it in first.'
    case 'at_port':
    case 'unknown':
      return '🛠 This ship is disabled. Repair it to get moving again.'
  }
}

/** Whether the Repair action can be pressed for this gate state. */
export function canRepair(gate: RepairGate): boolean {
  return gate.kind === 'at_port' || gate.kind === 'unknown'
}

/** Whether the Tow action should be offered instead. */
export function canTow(gate: RepairGate): boolean {
  return gate.kind === 'adrift'
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
