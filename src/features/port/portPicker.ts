// PORT-HUB — PURE, framework-free derivation of the Port screen's port picker.
//
// No React/DOM/fetch here. Turns the whole-fleet position projection (get_my_fleet_positions, 0200 —
// REUSED via fetchMyFleetPositions; NO new server projection) into "ports where you have docked ships":
// one entry per port, each listing which of your ships are berthed there. A ship in transit or open
// space is NOT a port entry — you cannot act at a port you are not at (honest). Port names come from a
// caller-supplied world-map name lookup; a missing name (a hidden/unknown port) falls back to a neutral
// label, never leaking. The server stays the sole authority for the actual dock context — this only
// decides which ports to OFFER and which ship the pick commands.

import type { FleetPosition } from '../map/mainshipApi'

/** One of your ships berthed at a port. */
export interface DockedShipEntry {
  mainShipId: string
  name: string
}

/** A port where you currently have one or more docked ships. */
export interface PortWithShips {
  locationId: string
  locationName: string
  ships: DockedShipEntry[]
}

const UNKNOWN_PORT = 'Unknown port'
const UNNAMED_SHIP = 'Unnamed ship'

/**
 * Group the caller's DOCKED ships into one entry per port. Only place==='docked' rows with a real
 * location_id + main_ship_id count. Insertion order follows the server's own fleet ordering (stable,
 * deterministic). `portName` resolves a location id → its world-map name (undefined/empty → neutral).
 */
export function derivePortsWithShips(
  fleetPositions: readonly FleetPosition[],
  portName: (locationId: string) => string | null | undefined,
): PortWithShips[] {
  const byLoc = new Map<string, PortWithShips>()
  for (const fp of fleetPositions) {
    if (fp.place !== 'docked') continue
    const locationId = fp.location_id
    if (!locationId || !fp.main_ship_id) continue
    let entry = byLoc.get(locationId)
    if (!entry) {
      entry = { locationId, locationName: portName(locationId) || UNKNOWN_PORT, ships: [] }
      byLoc.set(locationId, entry)
    }
    entry.ships.push({ mainShipId: fp.main_ship_id, name: fp.name || UNNAMED_SHIP })
  }
  return [...byLoc.values()]
}

/** Every docked ship id across all ports, in port/ship order (the domain for validating a pick). */
export function dockedShipIds(ports: readonly PortWithShips[]): string[] {
  return ports.flatMap((p) => p.ships.map((s) => s.mainShipId))
}

/**
 * Resolve the effective acting ship: honor the caller's preferred ship IF it is actually docked
 * somewhere; otherwise default to the FIRST docked ship (one docked ship → it is auto-selected). Null
 * when nothing is docked (the empty state). The chosen id is what drives the dock read + action panels.
 */
export function resolveChosenShipId(
  ports: readonly PortWithShips[],
  preferredShipId: string | null,
): string | null {
  const ids = dockedShipIds(ports)
  if (preferredShipId && ids.includes(preferredShipId)) return preferredShipId
  return ids[0] ?? null
}

/** The port entry that holds a given ship (used to highlight the chosen ship's port). Null if none. */
export function portOfShip(ports: readonly PortWithShips[], shipId: string | null): PortWithShips | null {
  if (!shipId) return null
  return ports.find((p) => p.ships.some((s) => s.mainShipId === shipId)) ?? null
}
