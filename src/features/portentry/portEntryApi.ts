import { supabase } from '../../lib/supabase'
import {
  fetchActiveMainShipFleet, fetchActiveMainShipPresence, type SpatialState,
} from '../map/mainshipApi'
import {
  COMMISSION_RPC, NORMALIZE_RPC, parseCommissionResult, parseNormalizeResult,
  type CommissionResult, type NormalizeResult, type PortEntryShipState,
} from './portEntry'

// PORT-ENTRY player UI — client API.
//
// Two authenticated, zero-arg, auth.uid()-scoped RPCs (migration 0072) + a small owner-read that assembles
// the DISPLAY state used to choose the affordance. The client sends NO player/ship/port id, coordinates,
// status, or lifecycle data — the server derives everything and is the sole authority. Nothing here touches
// coordinate travel, its flag/gate, port-to-port travel, migrations, or production data.

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

/**
 * Finish docking the caller's legacy-present ship IN PLACE (normalize_main_ship_dock). Zero-arg; idempotent
 * (already-canonical → normalized:false). Errors collapse to a safe failure result — this never throws.
 */
export async function normalizeMainShipDock(): Promise<NormalizeResult> {
  try {
    const { data, error } = await supabase.rpc(NORMALIZE_RPC, {})
    if (error) return { ok: false, reason: 'not_normalizable' }
    return parseNormalizeResult(data)
  } catch {
    return { ok: false, reason: 'not_normalizable' }
  }
}

interface MainShipStateRow {
  main_ship_id: string
  status: string
  spatial_state: SpatialState | null
}

/**
 * Owner-read the DISPLAY state that drives affordance selection: does a ship exist, its spatial_state +
 * status, and (only when a ship exists) the linked-fleet shape used to distinguish legacy_present from
 * legacy_home. All owner-read RLS; no RPC mutation, no writes. Any read error fails closed to "no ship".
 */
export async function fetchPortEntryShipState(): Promise<PortEntryShipState> {
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select('main_ship_id, status, spatial_state')
    .maybeSingle() // owner-read RLS → the caller's single ship, or null
  if (error) {
    return { hasShip: false, spatialState: null, shipStatus: null, fleetStatus: null, fleetLocationMode: null, hasActivePresence: false }
  }
  const ship = (data as MainShipStateRow) ?? null
  if (!ship) {
    return { hasShip: false, spatialState: null, shipStatus: null, fleetStatus: null, fleetLocationMode: null, hasActivePresence: false }
  }

  // Only read the linked fleet/presence when a ship exists (mirrors useGalaxyMapData's ordering).
  const fleet = await fetchActiveMainShipFleet(ship.main_ship_id)
  const hasActivePresence =
    fleet && fleet.status === 'present' ? (await fetchActiveMainShipPresence(fleet.id)) !== null : false

  return {
    hasShip: true,
    spatialState: ship.spatial_state,
    shipStatus: ship.status,
    fleetStatus: fleet?.status ?? null,
    fleetLocationMode: fleet?.location_mode ?? null,
    hasActivePresence,
  }
}
