import { test, expect } from '@playwright/test'
import { mainShipCommandMode, fleetGuidanceText } from '../src/features/map/mainshipCommandMode'

// FLEET-GO 4a-1 — pure specs for the per-ship-command suppression decision MainShipCommand renders
// through (charter §2: a ship never moves on its own). Two independent runtime flags can suppress
// the per-ship Send/Move arm; both dark (today's prod) must be EXACTLY the pre-slice behavior.

test('both flags dark (prod today) → per_ship: the pre-slice per-ship arm renders unchanged', () => {
  expect(mainShipCommandMode({ fleetControlEnabled: false, unifiedEnabled: false })).toBe('per_ship')
})

test('fleet_control lit (the 0204 world) → suppressed, exactly as before this slice', () => {
  expect(mainShipCommandMode({ fleetControlEnabled: true, unifiedEnabled: false })).toBe('fleet_guidance')
})

test('unified lit (the §2 world) → suppressed: the fleet is the only mover, the map owns movement', () => {
  expect(mainShipCommandMode({ fleetControlEnabled: false, unifiedEnabled: true })).toBe('fleet_guidance')
  expect(mainShipCommandMode({ fleetControlEnabled: true, unifiedEnabled: true })).toBe('fleet_guidance')
})

test('guidance copy: the 0204 fleet-control strings are preserved VERBATIM (dark-parity for that world)', () => {
  expect(fleetGuidanceText({ shipName: 'Peregrine', shipInFleet: true, unifiedEnabled: false })).toBe(
    'Move Peregrine with its fleet from the Fleets screen.',
  )
  expect(fleetGuidanceText({ shipName: 'Peregrine', shipInFleet: false, unifiedEnabled: false })).toBe(
    'Add this ship to a fleet to move it.',
  )
})

test('guidance copy: the unified world points at the map\'s fleet send, not the Fleets screen', () => {
  const msg = fleetGuidanceText({ shipName: 'Peregrine', shipInFleet: true, unifiedEnabled: true })
  expect(msg).toContain('Send a fleet here')
  expect(msg).not.toContain('Fleets screen')
  // an un-fleeted ship still gets the add-to-fleet nudge in both worlds
  expect(fleetGuidanceText({ shipName: 'Peregrine', shipInFleet: false, unifiedEnabled: true })).toBe(
    'Add this ship to a fleet to move it.',
  )
})
