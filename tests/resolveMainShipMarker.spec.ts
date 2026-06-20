import { test, expect } from '@playwright/test'
import { resolveMainShipMarker, type MarkerInputs } from '../src/features/map/resolveMainShipMarker'

// OSN-1 — pure unit test for the main-ship marker resolver. No browser/page: just deterministic
// assertions on the pure function. Run: `npm run verify:osn1:unit` (playwright test, node-side).

const BASE = { x: 100, y: 200 }
const LOC = { id: 'loc-A', x: 300, y: 400 }
const DEP = '2026-01-01T00:00:00Z'
const ARR = '2026-01-01T00:10:00Z'
const depMs = Date.parse(DEP)
const arrMs = Date.parse(ARR)
const midMs = (depMs + arrMs) / 2

const inputs = (over: Partial<MarkerInputs> = {}): MarkerInputs => ({
  mainShip: { main_ship_id: 'ship-1', status: 'home' },
  mainShipFleet: null,
  movements: [],
  base: BASE,
  locations: [LOC],
  ...over,
})

// Minimal movement fixture (resolver only reads fleet_id/status/origin_*/target_*/timestamps).
const mv = (over: Record<string, unknown> = {}) =>
  ({
    id: 'm1', fleet_id: 'f1', origin_type: 'location', origin_x: 0, origin_y: 0,
    target_type: 'location', target_location_id: 'loc-A', target_base_id: null, target_x: 100, target_y: 100,
    mission_type: 'rally', status: 'moving', depart_at: DEP, arrive_at: ARR,
    ...over,
  }) as unknown as MarkerInputs['movements'][number]

test('home → base coordinates', () => {
  expect(resolveMainShipMarker(inputs(), Date.now())).toMatchObject({
    state: 'home', x: 100, y: 200, relation: 'self', entityType: 'main_ship', entityId: 'ship-1',
  })
})

test('present → current location coordinates', () => {
  const m = resolveMainShipMarker(
    inputs({
      mainShip: { main_ship_id: 'ship-1', status: 'traveling' },
      mainShipFleet: { id: 'f1', status: 'present', current_location_id: 'loc-A' },
    }),
    Date.now(),
  )
  expect(m).toMatchObject({ state: 'present', x: 300, y: 400 })
})

test('outbound midpoint interpolation', () => {
  const m = resolveMainShipMarker(
    inputs({
      mainShip: { main_ship_id: 'ship-1', status: 'traveling' },
      mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null },
      movements: [mv({ origin_x: 0, origin_y: 0, target_x: 100, target_y: 100, target_type: 'location' })],
    }),
    midMs,
  )
  expect(m?.state).toBe('outbound')
  expect(m?.x).toBeCloseTo(50)
  expect(m?.y).toBeCloseTo(50)
})

test('returning midpoint interpolation', () => {
  const m = resolveMainShipMarker(
    inputs({
      mainShip: { main_ship_id: 'ship-1', status: 'returning' },
      mainShipFleet: { id: 'f1', status: 'returning', current_location_id: null },
      movements: [mv({ origin_x: 100, origin_y: 100, target_x: 0, target_y: 0, target_type: 'base' })],
    }),
    midMs,
  )
  expect(m?.state).toBe('returning')
  expect(m?.x).toBeCloseTo(50)
  expect(m?.y).toBeCloseTo(50)
})

test('progress clamped below 0 and above 1', () => {
  const inp = inputs({
    mainShip: { main_ship_id: 'ship-1', status: 'traveling' },
    mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null },
    movements: [mv({ origin_x: 0, origin_y: 0, target_x: 100, target_y: 100 })],
  })
  const before = resolveMainShipMarker(inp, depMs - 60_000) // t<0 → clamp 0 → origin
  expect(before?.x).toBeCloseTo(0)
  expect(before?.y).toBeCloseTo(0)
  const after = resolveMainShipMarker(inp, arrMs + 60_000) // t>1 → clamp 1 → target
  expect(after?.x).toBeCloseTo(100)
  expect(after?.y).toBeCloseTo(100)
})

test('destroyed → null', () => {
  expect(
    resolveMainShipMarker(inputs({ mainShip: { main_ship_id: 'ship-1', status: 'destroyed' } }), Date.now()),
  ).toBeNull()
})

test('in-flight fleet with missing movement → null', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: { main_ship_id: 'ship-1', status: 'traveling' },
        mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null },
        movements: [],
      }),
      Date.now(),
    ),
  ).toBeNull()
})

test('invalid timestamps → null', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: { main_ship_id: 'ship-1', status: 'traveling' },
        mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null },
        movements: [mv({ depart_at: 'nope', arrive_at: 'nope' })],
      }),
      Date.now(),
    ),
  ).toBeNull()
})

test('missing endpoint coordinates → null', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: { main_ship_id: 'ship-1', status: 'traveling' },
        mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null },
        movements: [mv({ target_x: null })],
      }),
      Date.now(),
    ),
  ).toBeNull()
})

test('present but unresolved location → null', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: { main_ship_id: 'ship-1', status: 'traveling' },
        mainShipFleet: { id: 'f1', status: 'present', current_location_id: 'missing' },
      }),
      Date.now(),
    ),
  ).toBeNull()
})
