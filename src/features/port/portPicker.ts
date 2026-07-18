// PORT-HUB — PURE, framework-free derivation of the Port screen's port picker.
//
// No React/DOM/fetch here. Turns the whole-fleet position projection (get_my_fleet_positions, 0200 —
// REUSED via fetchMyFleetPositions; NO new server projection) into "ports where you have ships at
// dock": one entry per port, each listing which of your ships are there. A ship in transit or open
// space is NOT a port entry — you cannot act at a port you are not at (honest). Port names come from a
// caller-supplied world-map name lookup; a missing name (a hidden/unknown port) falls back to a neutral
// label, never leaking. The server stays the sole authority for the actual dock context — this only
// decides which ports to OFFER and which ship the pick commands.
//
// MAP-INTEGRATION M3 — 'berthed' counts as at-port. The S1 berth model (0216) splits at-port ships
// into fleeted place='docked' and unfleeted place='berthed'; both are physically AT the port (the
// Fitting tab labels both "Docked at <port>" through the ONE SHIPLOC resolver), so excluding berthed
// here made the Port tab claim "no docked ships" while Fitting showed the same ship docked — a flat
// contradiction. A berthed ship now appears in the list, FLAGGED (`berthed: true`) so the screen can
// stay honest about services: a berthed ship is not at_location server-side until slice 4c, so every
// paid dock-service RPC still answers not-docked — PortScreen shows the fitgate-honesty explainer
// instead of offering actions that 100%-fail (see the berthed branch there). When 4c canonicalizes
// berthed server-side, the flag's honesty copy retires and the entry becomes a full dock.

import type { FleetPosition } from '../map/mainshipApi'

/** One of your ships at a port. `berthed` = the S1 unfleeted berth (place='berthed'): physically at
 *  the port but not yet at_location server-side (until 4c) — dock SERVICES will answer not-docked. */
export interface DockedShipEntry {
  mainShipId: string
  name: string
  berthed: boolean
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
 * Group the caller's AT-PORT ships into one entry per port. place==='docked' (fleeted dock) AND
 * place==='berthed' (the S1 unfleeted berth — M3: same port, same "Docked at X" read as the Fitting
 * tab) rows with a real location_id + main_ship_id count; berthed rows are flagged so the screen can
 * reflect their service limits honestly. Insertion order follows the server's own fleet ordering
 * (stable, deterministic). `portName` resolves a location id → its world-map name (undefined/empty →
 * neutral).
 */
export function derivePortsWithShips(
  fleetPositions: readonly FleetPosition[],
  portName: (locationId: string) => string | null | undefined,
): PortWithShips[] {
  const byLoc = new Map<string, PortWithShips>()
  for (const fp of fleetPositions) {
    if (fp.place !== 'docked' && fp.place !== 'berthed') continue
    const locationId = fp.location_id
    if (!locationId || !fp.main_ship_id) continue
    let entry = byLoc.get(locationId)
    if (!entry) {
      entry = { locationId, locationName: portName(locationId) || UNKNOWN_PORT, ships: [] }
      byLoc.set(locationId, entry)
    }
    entry.ships.push({ mainShipId: fp.main_ship_id, name: fp.name || UNNAMED_SHIP, berthed: fp.place === 'berthed' })
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
