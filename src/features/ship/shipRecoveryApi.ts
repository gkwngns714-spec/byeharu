import { supabase } from '../../lib/supabase'
import type { DisabledShipRow } from './shipRecovery'

// SHIP RECOVERY — the two thin client wrappers for migration 0297.
//
// They live here (features/ship) rather than in features/map's mainshipApi because the surface they
// serve is the Fitting screen's disabled-ship recovery; mainshipApi keeps the repair/rename wrappers
// it already owns and this module never duplicates them.
//
// Both wrappers NORMALISE rather than throw: a transport error, or a client deployed ahead of the
// migration, must degrade to "unknown"/"unavailable" and let the SERVER stay the enforcer — never
// crash a roster row and never hide a player's recovery path.

/**
 * get_my_disabled_ships() (0297 §4) — for each of the caller's DISABLED ships, whether it is at a
 * port and which one. It exists because get_my_fleet_positions excludes destroyed ships outright, so
 * this is the only way the screen can learn where a wreck is.
 *
 * Returns null when the read is unavailable (error, or RPC not deployed yet). null means UNKNOWN, and
 * the pure gate deliberately treats unknown as "offer Repair anyway" — see shipRecovery.ts.
 */
export async function fetchMyDisabledShips(): Promise<DisabledShipRow[] | null> {
  const { data, error } = await supabase.rpc('get_my_disabled_ships')
  if (error || !Array.isArray(data)) return null
  return data as DisabledShipRow[]
}

export type EmergencyTowResult =
  | { ok: true; main_ship_id: string; location_id: string; location_name: string | null }
  | { ok: false; reason: string }

/**
 * mainship_emergency_tow (0297 §3) — free, instant wreck recovery: hauls a DISABLED ship that is at
 * no port to the nearest active non-combat port and berths it there, so the position-gated repair
 * becomes possible. The server asserts ownership; the id is a request, never a claim.
 *
 * A transport error collapses to the reject envelope ('unavailable') so the UI can map it, never a
 * throw (the renameMainShip posture).
 */
export async function emergencyTowMainShip(mainShipId?: string | null): Promise<EmergencyTowResult> {
  const { data, error } = await supabase.rpc('mainship_emergency_tow', {
    p_main_ship_id: mainShipId ?? null,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as EmergencyTowResult
}
