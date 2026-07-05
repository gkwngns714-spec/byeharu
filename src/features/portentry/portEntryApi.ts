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
// One zero-arg authenticated RPC (commission_first_main_ship) + one that takes the explicit selected/sole
// main-ship id (normalize_main_ship_dock — TRADE-FLEET-0C §2.5: p_main_ship_id, null → server sole-ship shim,
// ownership server-asserted) + a small owner-read that assembles the DISPLAY state used to choose the
// affordance. Aside from that ship id, the client sends NO player/port id, coordinates, status, or lifecycle
// data — the server derives everything and is the sole authority. Nothing here touches coordinate travel, its
// flag/gate, port-to-port travel, migrations, or production data.

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
 * Finish docking the caller's legacy-present ship IN PLACE (normalize_main_ship_dock). TRADE-FLEET-0C §2.5:
 * sends the EXPLICIT selected/sole main-ship id (p_main_ship_id); the server asserts ownership (own ship only)
 * and a null id preserves the sole-ship shim (behavior-identical while single-ship). Idempotent
 * (already-canonical → normalized:false). Errors collapse to a safe failure result — this never throws.
 */
export async function normalizeMainShipDock(mainShipId?: string | null): Promise<NormalizeResult> {
  try {
    const { data, error } = await supabase.rpc(NORMALIZE_RPC, { p_main_ship_id: mainShipId ?? null })
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
    return { hasShip: false, spatialState: null, shipStatus: null, fleetStatus: null, fleetLocationMode: null, hasActivePresence: false, presentLocationId: null }
  }
  const ship = (data as MainShipStateRow) ?? null
  if (!ship) {
    return { hasShip: false, spatialState: null, shipStatus: null, fleetStatus: null, fleetLocationMode: null, hasActivePresence: false, presentLocationId: null }
  }

  // Only read the linked fleet/presence when a ship exists (mirrors useGalaxyMapData's ordering).
  const fleet = await fetchActiveMainShipFleet(ship.main_ship_id)
  const hasActivePresence =
    fleet && fleet.status === 'present' ? (await fetchActiveMainShipPresence(fleet.id)) !== null : false

  return {
    hasShip: true,
    main_ship_id: ship.main_ship_id, // §2.5: surfaced so the normalize path can send an explicit p_main_ship_id
    spatialState: ship.spatial_state,
    shipStatus: ship.status,
    fleetStatus: fleet?.status ?? null,
    fleetLocationMode: fleet?.location_mode ?? null,
    hasActivePresence,
    // UX-CLEANUP item 2: the legacy-present location, from the fleet row ALREADY fetched above (no new
    // read) — drives the display-only waypoint-vs-port affordance split.
    presentLocationId: fleet?.status === 'present' ? (fleet.current_location_id ?? null) : null,
  }
}
