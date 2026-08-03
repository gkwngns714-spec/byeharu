// SHIP RECOVERY — the PURE view-model + copy for a DISABLED ship (migration 0297).
//
// 0297 made the free repair (repair_main_ship) POSITION-GATED: a wrecked ship is repaired in a city,
// never adrift. Because a gate with no way out is a softlock, the same migration added the free
// always-available tow (mainship_emergency_tow), which berths a wreck at the nearest port. This
// module is the ONE place that decides which of the two a disabled ship should be offered, and the
// ONE place the server's reason codes become player words — a raw code must never reach the screen.
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
 * repair concept a ship's state gets. Mirrors the server's mutual exclusion exactly (the free
 * repair_main_ship gates on status='destroyed'; the paid repair_ship_hull_at_port REJECTS
 * destroyed with ship_destroyed, 0201) — exactly one concept per state, never both, never
 * neither. Both mount sites in FittingDetail read THIS value; neither carries its own status
 * comparison, so the two surfaces can only flip together. Feed it the freshest status available
 * (the screen's refetched shared read, falling back to the selection row) — a stale selection
 * status here is what turns a mid-session destruction into a dead end.
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
 * back with the server's ship_not_at_port reject, that outranks any (possibly stale or unavailable)
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
    // ONE NAME PER STATE: a destroyed ship is "wrecked" everywhere (badge, notes, errors) — never
    // "disabled", which collided with the disabled buttons beside it. No emoji in copy (chrome law).
    case 'adrift':
      return 'This ship is wrecked and adrift. Ships are only repaired in port — tow it in first.'
    case 'at_port':
    case 'unknown':
      return 'This ship is wrecked. Repair it to get moving again.'
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

const REPAIR_FALLBACK = 'Repairs are unavailable right now. Try again in a moment.'
const TOW_FALLBACK = 'The tow is unavailable right now. Try again in a moment.'

/**
 * repair_main_ship RAISES (it has always thrown, and its client wrapper re-throws the message), so
 * its "reason codes" arrive as substrings of an error message. This is the ONE place they are
 * recognised; every branch returns player words, never the raw text.
 */
export function repairErrorMessage(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err ?? '')
  if (raw.includes('ship_not_at_port')) {
    return 'This ship is adrift. Tow it to a port, then repair it there.'
  }
  if (raw.includes('ship is not disabled')) {
    return "This ship isn't wrecked — there's nothing to repair."
  }
  if (raw.includes('no main ship found')) {
    return 'That ship could not be found.'
  }
  if (raw.includes('not authenticated')) {
    return "You're signed out. Sign in again to repair this ship."
  }
  if (raw.includes('invalid max_hp')) {
    return "This ship's hull record is broken — it cannot be repaired."
  }
  return REPAIR_FALLBACK
}

/** True when a failed repair was the 0297 position gate — the caller then offers the tow. */
export function isAdriftError(err: unknown): boolean {
  const raw = err instanceof Error ? err.message : String(err ?? '')
  return raw.includes('ship_not_at_port')
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
