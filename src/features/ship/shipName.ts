// SHIP-IDENTITY — pure ship-rename logic (no React/DOM/IO; the commissionShip.ts module pattern).
//
// Client-side mirror of rename_main_ship_self's validation (migration 0184, which itself mirrors
// the 0043 server rename: btrim → non-empty → length ≤ 40). Display-only: the SERVER re-validates
// and owns the write; this mirror only lets the inline rename form disable Save + hint honestly
// before a doomed round-trip. Composed by ShipStatusCard; unit-tested in tests/shipRename.spec.ts.

/** The server's name length cap (0043/0184: `length(v_clean) > 40 → reject`). */
export const SHIP_NAME_MAX = 40

/** The server normalization (0184: `btrim(coalesce(p_name, ''))`). */
export function normalizeShipName(raw: string): string {
  return raw.trim()
}

export type ShipNameProblem = 'name_empty' | 'name_too_long'

/** The server's reject, mirrored in the server's own order; null → the name would be accepted. */
export function shipNameProblem(raw: string): ShipNameProblem | null {
  const clean = normalizeShipName(raw)
  if (clean.length === 0) return 'name_empty'
  if (clean.length > SHIP_NAME_MAX) return 'name_too_long'
  return null
}

// reason → player copy (the commissionReasonMessage pattern): the ACTUAL server reject strings of
// rename_main_ship_self (0184) + the transport fallback ('unavailable'). Unknown → a generic
// line; never a raw code, never a throw.
const REASON_MESSAGES: Record<string, string> = {
  not_authenticated: 'Sign in to rename your ship.',
  name_empty: 'Give your ship a name.',
  name_too_long: `Ship names can be at most ${SHIP_NAME_MAX} characters.`,
  no_ship: 'No ship to rename.',
  unavailable: 'Renaming is unavailable right now.',
}

/** Short player-facing message for a rename reason; unknown → generic (never a raw code). */
export function renameReasonMessage(reason: string): string {
  return REASON_MESSAGES[reason] ?? 'Renaming is unavailable right now.'
}
