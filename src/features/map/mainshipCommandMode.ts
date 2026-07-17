// FLEET-GO 4a-1 — the pure per-ship-command suppression decision for MainShipCommand (charter §2:
// "a ship never moves on its own" / §2a: all movement interaction on the map, fleet-shaped).
//
// TWO flags can suppress the per-ship Send/Move affordance, and they are DIFFERENT worlds:
//   • fleet_control_enabled (0204, OFF in prod) — the command-ship model: movement still happens
//     per the old paths but requires an ACTIVE fleet; guidance points at the Fleets screen.
//   • fleet_movement_unified_enabled (0207, OFF in prod) — the unified §2 world: the FLEET is the
//     only mover and the map's "Send a fleet here" arm is the one movement surface; guidance points
//     THERE, not at the Fleets screen.
// Either lit → the per-ship arm is suppressed (never render a mover the current world forbids).
// Both dark (today's prod) → 'per_ship', byte-identical to the pre-slice component.
//
// ⚠ Deliberately NOT keyed on mainship_send_enabled: that flag ALSO gates the whole-fleet map read
// (fetchMyFleetPositions, useGalaxyMapData) — using it as a per-ship-UI kill switch would blank the
// entire fleet marker layer. Pure — unit-tested in tests/mainshipCommandMode.spec.ts.

export type MainShipCommandMode = 'per_ship' | 'fleet_guidance'

export function mainShipCommandMode(input: {
  fleetControlEnabled: boolean
  unifiedEnabled: boolean
}): MainShipCommandMode {
  return input.fleetControlEnabled || input.unifiedEnabled ? 'fleet_guidance' : 'per_ship'
}

/** The guidance line shown while the per-ship arm is suppressed. The fleet-control strings are the
 *  0204 originals VERBATIM (dark-parity for the already-shipped fleet-control world); the unified
 *  strings point at the map's fleet send — the §2a surface — and win when both flags are lit. */
export function fleetGuidanceText(input: {
  shipName: string
  shipInFleet: boolean
  unifiedEnabled: boolean
}): string {
  if (!input.shipInFleet) return 'Add this ship to a fleet to move it.'
  return input.unifiedEnabled
    ? `Move ${input.shipName} with its fleet — use “Send a fleet here” below.`
    : `Move ${input.shipName} with its fleet from the Fleets screen.`
}
