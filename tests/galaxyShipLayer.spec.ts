import { test, expect } from '@playwright/test'
import { shipLayer, SpaceRouteLine } from '../src/features/map/SpaceRouteLine'
import { MainShipMarker } from '../src/features/map/MainShipMarker'
import { resolveActiveSpaceRoute } from '../src/features/map/spaceRouteModel'
import type { MarkerInputs } from '../src/features/map/resolveMainShipMarker'

// OSN-3 S6B-ROUTE — GalaxyMap wiring proof. GalaxyMap renders `{shipLayer(...)}`; this test calls the SAME
// pure helper (the markerViewBoxPoint pattern) and inspects the returned element descriptors. No hooks run,
// no DB, no commands, no fabricated backend rows — only plain input objects. Run with `verify:osn:s6b-route`.

const DEP = '2026-01-01T00:00:00Z'
const ARR = '2026-01-01T00:10:00Z'
const midMs = (Date.parse(DEP) + Date.parse(ARR)) / 2
const norm = (p: { x: number; y: number }) => p // identity stub; only stored on the marker descriptor

type FleetInput = NonNullable<MarkerInputs['mainShipFleet']>

// A coherent active space-coordinate transit (target_kind='space').
const coherent: MarkerInputs = {
  mainShip: { main_ship_id: 'ship-1', status: 'traveling', spatial_state: 'in_transit', space_x: null, space_y: null },
  mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null, location_mode: 'movement', active_movement_id: null, active_space_movement_id: 'mv1' },
  movements: [],
  presence: null,
  spaceMovement: { id: 'mv1', main_ship_id: 'ship-1', fleet_id: 'f1', origin_x: 1000, origin_y: 2000, target_x: 3000, target_y: -4000, target_kind: 'space', status: 'moving', depart_at: DEP, arrive_at: ARR },
  locations: [{ id: 'loc-A', x: 300, y: 400 }],
}

// A legacy fleet movement context (spatial_state NULL) — must NOT produce a coordinate route.
const legacy: MarkerInputs = {
  mainShip: { main_ship_id: 'ship-1', status: 'traveling', spatial_state: null, space_x: null, space_y: null },
  mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null, location_mode: 'movement', active_movement_id: null, active_space_movement_id: null } as FleetInput,
  movements: [{ id: 'lm1', fleet_id: 'f1', status: 'moving', target_type: 'location', origin_x: 1, origin_y: 2, target_x: 3, target_y: 4, depart_at: DEP, arrive_at: ARR } as unknown as MarkerInputs['movements'][number]],
  presence: null,
  spaceMovement: null,
  locations: [{ id: 'loc-A', x: 300, y: 400 }],
}

test('1) mainshipSendEnabled=false → SpaceRouteLine absent (whole layer empty)', () => {
  const layer = shipLayer({ mainshipSendEnabled: false, inputs: coherent, norm, k: 1 })
  expect(layer).toEqual([])
})

test('2) mainshipSendEnabled=true + coherent → SpaceRouteLine mounted exactly once', () => {
  const layer = shipLayer({ mainshipSendEnabled: true, inputs: coherent, norm, k: 1 })
  const routeCount = layer.filter((e) => e.type === SpaceRouteLine).length
  expect(routeCount).toBe(1)
})

test('3) route is layered UNDER the main-ship marker (earlier in paint order)', () => {
  const types = shipLayer({ mainshipSendEnabled: true, inputs: coherent, norm, k: 1 }).map((e) => e.type)
  expect(types.indexOf(SpaceRouteLine)).toBeGreaterThanOrEqual(0)
  expect(types.indexOf(MainShipMarker)).toBeGreaterThanOrEqual(0)
  expect(types.indexOf(SpaceRouteLine)).toBeLessThan(types.indexOf(MainShipMarker))
})

test('route and marker receive the SAME ship/movement context', () => {
  const layer = shipLayer({ mainshipSendEnabled: true, inputs: coherent, norm, k: 1 })
  const routeEl = layer.find((e) => e.type === SpaceRouteLine)!
  const markerEl = layer.find((e) => e.type === MainShipMarker)!
  expect((routeEl.props as { inputs: unknown }).inputs).toBe((markerEl.props as { inputs: unknown }).inputs)
})

test('4) legacy fleet-movement context produces no coordinate route (coherence authority returns null)', () => {
  expect(resolveActiveSpaceRoute(legacy, midMs)).toBeNull()
})
