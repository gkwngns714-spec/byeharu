import type { ShipMarker } from './resolveMainShipMarker'
import type { MainShipSpaceMovement } from './mainshipApi'

// OSN-HUB-1A — pure, read-only presentation helper for the main ship's human-readable location status.
// It NEVER reveals a non-public location: a name is resolved SOLELY from the public get_world_map() result
// (visible locations only), and any destination/docked location absent from that public list FAILS CLOSED to
// a generic label (never the hidden location's name, id, or coordinates). No React/DOM/fetch/state; safe to
// unit-test directly. The client computes NO authoritative position/route/dock outcome here — it only labels
// the server-resolved marker/movement it already holds.

/** The minimal public-location shape needed to resolve a display name (from get_world_map). */
export interface PublicLocationName {
  id: string
  name: string
}

export interface MainShipStatusLabelInputs {
  /** the server-resolved display marker (from resolveMainShipMarker), or null when nothing is shown. */
  marker: ShipMarker | null
  /** the active coordinate movement (owner-read), used to name a 'location' target. */
  spaceMovement: MainShipSpaceMovement | null
  /** the VISIBLE public locations from get_world_map() — the ONLY source of a destination/dock name. */
  publicLocations: PublicLocationName[]
  /** the docked location id (from the present fleet / active presence) when the ship is at_location. */
  dockedLocationId?: string | null
}

/**
 * A short status label for the main ship, or null when there is nothing to show. Behavior:
 *  - in_space             → "Parked in open space"
 *  - present (docked)     → "Docked at <name>" for a VISIBLE location, else a generic "Docked" (no leak)
 *  - outbound/returning   → "Traveling to <name>" for a VISIBLE 'location' target, else "Traveling to open space"
 *  - home                 → "Ready to launch"
 * Hidden/unknown destinations and dock locations NEVER surface a name, id, or coordinate.
 */
export function resolveMainShipStatusLabel(inp: MainShipStatusLabelInputs): string | null {
  const { marker, spaceMovement, publicLocations, dockedLocationId } = inp
  if (!marker) return null

  const publicNameOf = (id: string | null | undefined): string | null => {
    if (!id) return null
    const loc = publicLocations.find((l) => l.id === id)
    return loc ? loc.name : null // fail closed: not in the public map (e.g. a hidden port) → no name
  }

  switch (marker.state) {
    case 'in_space':
      return 'Parked in open space'
    case 'present': {
      const name = publicNameOf(dockedLocationId)
      return name ? `Docked at ${name}` : 'Docked'
    }
    case 'outbound':
    case 'returning': {
      if (spaceMovement && spaceMovement.target_kind === 'location') {
        const name = publicNameOf(spaceMovement.target_location_id ?? null)
        return name ? `Traveling to ${name}` : 'Traveling'
      }
      return 'Traveling to open space'
    }
    case 'home':
      return 'Ready to launch'
    default:
      return null
  }
}

// TRADE-UI-1 — sibling pure helper for the RAW main_ship_instances.status enum (migration 0043:
// 'home'|'traveling'|'hunting'|'trading'|'exploring'|'mining'|'retreating'|'returning'|'repairing'|'destroyed').
// Distinct from resolveMainShipStatusLabel above (which labels a leak-safe LOCATION marker): a ship-list row
// carries only this activity-status string, so labeling lives here to keep ALL main-ship status labels in one
// module. Pure (no marker/movement/location inputs), and it exposes no location name — nothing to leak.
const INSTANCE_STATUS_LABELS: Record<string, string> = {
  home: 'Ready to launch',
  traveling: 'Traveling',
  hunting: 'Hunting',
  trading: 'Trading',
  exploring: 'Exploring',
  mining: 'Mining',
  retreating: 'Retreating',
  returning: 'Returning',
  repairing: 'Repairing',
  destroyed: 'Disabled',
}

/** A short human label for a raw main_ship_instances.status; falls back to the raw value so an unmapped/future
 *  status degrades readably rather than blank (mirrors the DockServicesPanel SERVICE_LABELS `?? s` idiom). */
export function mainShipInstanceStatusLabel(status: string): string {
  return INSTANCE_STATUS_LABELS[status] ?? status
}
