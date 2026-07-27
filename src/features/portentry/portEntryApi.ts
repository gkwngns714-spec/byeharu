import { supabase } from '../../lib/supabase'
import { fetchMyFleetPositions, resolveOwnedShip } from '../map/mainshipApi'
import {
  COMMISSION_RPC, parseCommissionResult,
  type CommissionResult, type PortEntryShipState,
} from './portEntry'

// PORT-ENTRY player UI — client API.
//
// One zero-arg authenticated RPC (commission_first_main_ship) + a small owner-read that assembles the
// DISPLAY state used to choose the affordance. The client sends NO player/port id, coordinates, status,
// or lifecycle data — the server derives everything and is the sole authority.
//
// 4C-CLIENT: the normalize wrapper (normalize_main_ship_dock) is DELETED with the normalize affordance
// (see portEntry.ts — the legacy_present state it served is extinct and unmintable), and the ship-state
// read is REPOINTED off the retired main_ship_instances.spatial_state column onto the ship's
// get_my_fleet_positions `place` — the ONE placement projection every other surface reads. The old
// per-ship fleet/presence reads existed only to classify the legacy fleet shape and are gone with it.

/**
 * Claim the caller's FIRST main ship (commission_first_main_ship). Zero-arg; the server race-serializes on
 * the player_id UNIQUE and is idempotent (a second call on an already-provisioned ship reports the current
 * dock, never a duplicate). Errors collapse to a safe failure result — this never throws.
 */
export async function commissionFirstMainShip(): Promise<CommissionResult> {
  try {
    const { data, error } = await supabase.rpc(COMMISSION_RPC, {})
    if (error) return { ok: false, reason: 'commission_unavailable' }
    return parseCommissionResult(data)
  } catch {
    return { ok: false, reason: 'commission_unavailable' }
  }
}

interface MainShipStateRow {
  main_ship_id: string
  status: string
}

/**
 * Owner-read the DISPLAY state that drives affordance selection: HOW MANY ships the player owns, plus
 * the resolved single ship's status and fleet-positions `place`. All owner-reads; no RPC mutation, no
 * writes.
 *
 * Returns null when the read FAILED — "I could not find out", which is NOT "you own no ships". The
 * classifier turns null into silence; only a successful read reporting zero rows may offer the claim.
 * (This function used to return a hardcoded no-ship state on error, and the panel rendered "Claim First
 * Ship" from it — a transport hiccup made the player's whole fleet read as gone.)
 */
export async function fetchPortEntryShipState(mainShipId?: string | null): Promise<PortEntryShipState | null> {
  // Plural-safe owner-read: read ALL owned ships (never `.maybeSingle()`, which errors at N≥2).
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select('main_ship_id, status')
    .order('created_at', { ascending: true }) // stable enumeration only; the pick is resolver-decided, not first-row
  if (error) return null
  const ships = (data ?? []) as MainShipStateRow[]

  // WHETHER a ship exists is the row COUNT. WHICH ship the explanatory arms describe is the resolver's
  // job — and it deliberately fails closed to null at N≥2 without a selection. Those are two different
  // questions; answering the first with the resolver is what showed "Claim First Ship" to a 5-ship fleet.
  const ship = resolveOwnedShip(ships, mainShipId)
  if (!ship) return { shipCount: ships.length, shipStatus: null, place: null }

  // The ship's placement, from the ONE projection (get_my_fleet_positions — the same read the map,
  // Port hub, and Fitting tab consume). A destroyed ship has no row (handled by the status check in
  // the classifier); a transport error yields [] → place null → fail-closed 'indeterminate'.
  const positions = await fetchMyFleetPositions()
  const place = positions.find((p) => p.main_ship_id === ship.main_ship_id)?.place ?? null

  return { shipCount: ships.length, shipStatus: ship.status, place }
}
