// PHASE 9 — PURE, framework-free parsing of the docked-port surface (get_my_current_dock_services()).
//
// No React/DOM/fetch here. Owns (1) the typed shape of the server dock projection; (2) a strict validator
// that accepts ONLY the documented states and treats anything malformed as NOT DOCKED (never throws, never
// invents a dock). Only the server 'at_location' state carries a dock + active services; every other state
// is forced to no-dock / empty. The server is the sole authority — this never reads names/coords/type/
// affiliation to decide dock access.

export const DOCK_STATES = [
  'no_main_ship', 'at_location', 'in_transit', 'in_space', 'destroyed', 'incoherent_or_unavailable',
] as const
export type DockState = (typeof DOCK_STATES)[number]

export interface DockServices {
  state: DockState
  docked: boolean
  locationId: string | null
  locationName: string | null
  services: string[]
}

// Safe default for loading / error / malformed / non-docked: nothing renders, no port action.
export const DOCK_NOT_DOCKED: DockServices = {
  state: 'incoherent_or_unavailable', docked: false, locationId: null, locationName: null, services: [],
}

function isDockState(v: unknown): v is DockState {
  return typeof v === 'string' && (DOCK_STATES as readonly string[]).includes(v)
}

/**
 * Strict validator for the raw get_my_current_dock_services() jsonb. Returns a sanitized DockServices, or a
 * no-dock default for ANY malformed/unexpected shape. ONLY 'at_location' may carry a dock + services; every
 * other state is defensively emptied even if the server included extra fields.
 */
export function parseDockServices(raw: unknown): DockServices {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return DOCK_NOT_DOCKED
  const o = raw as Record<string, unknown>
  if (!isDockState(o.state)) return DOCK_NOT_DOCKED
  if (o.state !== 'at_location') {
    return { state: o.state, docked: false, locationId: null, locationName: null, services: [] }
  }
  const locationId = typeof o.location_id === 'string' && o.location_id.length > 0 ? o.location_id : null
  if (!locationId) return DOCK_NOT_DOCKED // at_location with no real dock → treat as not docked (fail-safe)
  const locationName = typeof o.location_name === 'string' ? o.location_name : null
  const services = Array.isArray(o.services)
    ? o.services.filter((s): s is string => typeof s === 'string' && s.length > 0)
    : []
  return { state: 'at_location', docked: true, locationId, locationName, services }
}

/** Render gate: the player's main ship is genuinely docked at a port. */
export function isDocked(d: DockServices): boolean {
  return d.state === 'at_location' && d.docked === true && d.locationId !== null
}
