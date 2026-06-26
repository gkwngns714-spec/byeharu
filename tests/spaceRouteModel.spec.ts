import { test, expect } from '@playwright/test'
import { resolveActiveSpaceRoute } from '../src/features/map/spaceRouteModel'
import type { MarkerInputs } from '../src/features/map/resolveMainShipMarker'

// OSN-3 S6B-ROUTE — pure unit proof for the active-coordinate-route render-model resolver. No browser/page.
// The resolver defers coherence to resolveMainShipMarker AND restricts to the single coordinate kind the
// deployed writer produces (target_kind='space'); it fails closed for every other kind. The route is one
// thing only: an active OUTBOUND movement to a committed arbitrary open-space coordinate (no returning/base
// presentation). Run: `npm run verify:osn:s6b-route`.

const BASE = { x: 100, y: 200 }
const LOC = { id: 'loc-A', x: 300, y: 400 }
const DEP = '2026-01-01T00:00:00Z'
const ARR = '2026-01-01T00:10:00Z'
const depMs = Date.parse(DEP)
const arrMs = Date.parse(ARR)
const midMs = (depMs + arrMs) / 2

type ShipInput = NonNullable<MarkerInputs['mainShip']>
type FleetInput = NonNullable<MarkerInputs['mainShipFleet']>
type SpaceMv = NonNullable<MarkerInputs['spaceMovement']>

const ship = (over: Partial<ShipInput> = {}): ShipInput => ({
  main_ship_id: 'ship-1', status: 'home', spatial_state: null, space_x: null, space_y: null, ...over,
})
const fleet = (over: Partial<FleetInput> = {}): FleetInput => ({
  id: 'f1', status: 'moving', current_location_id: null,
  location_mode: 'movement', active_movement_id: null, active_space_movement_id: null, ...over,
})
const spaceMv = (over: Partial<SpaceMv> = {}): SpaceMv => ({
  id: 'mv1', main_ship_id: 'ship-1', fleet_id: 'f1',
  origin_x: 1000, origin_y: 2000, target_x: 3000, target_y: -4000,
  target_kind: 'space', status: 'moving', depart_at: DEP, arrive_at: ARR, ...over,
})

const base = (over: Partial<MarkerInputs> = {}): MarkerInputs => ({
  mainShip: ship(), mainShipFleet: null, movements: [], presence: null, spaceMovement: null,
  base: BASE, locations: [LOC], ...over,
})

// A fully-coherent open-space coordinate transit (resolver §C → open_space_fixed), target_kind='space'.
const coherentTransit = (over: Partial<SpaceMv> = {}): MarkerInputs =>
  base({
    mainShip: ship({ status: 'traveling', spatial_state: 'in_transit' }),
    mainShipFleet: fleet({ status: 'moving', active_space_movement_id: 'mv1' }),
    spaceMovement: spaceMv(over),
  })

test('route appears for one coherent active space-coordinate transit (outbound only)', () => {
  const r = resolveActiveSpaceRoute(coherentTransit(), midMs)
  expect(r).not.toBeNull()
  expect(r!.origin).toEqual({ x: 1000, y: 2000 })
  expect(r!.target).toEqual({ x: 3000, y: -4000 })
  expect(r!.departAt).toBe(DEP)
  expect(r!.arriveAt).toBe(ARR)
  // render model is geometry + timestamps only — no state/returning/targetKind semantics
  expect(r).not.toHaveProperty('state')
  expect(r).not.toHaveProperty('targetKind')
})

test('fail closed: target_kind="location" with NO destination identity renders no route', () => {
  // OSN-HUB-1A: a location target needs a target_location_id resolvable in the PUBLIC map; absent → null.
  expect(resolveActiveSpaceRoute(coherentTransit({ target_kind: 'location' }), midMs)).toBeNull()
})

test('OSN-HUB-1A: location target to a VISIBLE public location renders a route carrying its identity', () => {
  // LOC ('loc-A') is in the public locations list → the location route renders to that public marker.
  const r = resolveActiveSpaceRoute(
    coherentTransit({ target_kind: 'location', target_location_id: 'loc-A', target_x: 300, target_y: 400 }),
    midMs,
  )
  expect(r).not.toBeNull()
  expect(r!.destinationLocationId).toBe('loc-A')
  expect(r!.target).toEqual({ x: 300, y: 400 })
})

test('OSN-HUB-1A: location target to a HIDDEN/unknown destination fails closed (no route, no leak)', () => {
  // target_location_id absent from the public locations list ([LOC]=loc-A) → null (no route/id/coord/name leak).
  expect(
    resolveActiveSpaceRoute(
      coherentTransit({ target_kind: 'location', target_location_id: 'hidden-port-x', target_x: -50, target_y: -30 }),
      midMs,
    ),
  ).toBeNull()
})

test('OSN-HUB-1A: location target with explicit null destination id fails closed', () => {
  expect(resolveActiveSpaceRoute(coherentTransit({ target_kind: 'location', target_location_id: null }), midMs)).toBeNull()
})

test('OSN-HUB-1A: a space route carries NO destination identity', () => {
  const r = resolveActiveSpaceRoute(coherentTransit(), midMs)
  expect(r).not.toBeNull()
  expect(r).not.toHaveProperty('destinationLocationId')
})

test('fail closed: target_kind="base" (would be a coordinate Return) renders nothing', () => {
  expect(resolveActiveSpaceRoute(coherentTransit({ target_kind: 'base' }), midMs)).toBeNull()
})

test('fail closed: unknown/malformed target_kind renders nothing', () => {
  expect(resolveActiveSpaceRoute(coherentTransit({ target_kind: 'wormhole' }), midMs)).toBeNull()
  // deliberate cast: prove a value outside the typed union still fails closed
  expect(resolveActiveSpaceRoute(coherentTransit({ target_kind: undefined as unknown as string }), midMs)).toBeNull()
})

test('no route: home', () => {
  expect(resolveActiveSpaceRoute(base({ mainShip: ship({ status: 'home', spatial_state: 'home' }) }), midMs)).toBeNull()
})

test('no route: at named location', () => {
  const inp = base({
    mainShip: ship({ status: 'stationary', spatial_state: 'at_location' }),
    mainShipFleet: fleet({ status: 'present', current_location_id: 'loc-A' }),
    presence: { fleet_id: 'f1', location_id: 'loc-A', status: 'active' },
  })
  expect(resolveActiveSpaceRoute(inp, midMs)).toBeNull()
})

test('no route: parked open space (in_space, no active movement)', () => {
  const inp = base({ mainShip: ship({ status: 'stationary', spatial_state: 'in_space', space_x: 50, space_y: 60 }) })
  expect(resolveActiveSpaceRoute(inp, midMs)).toBeNull()
})

test('no route: legacy fleet movement (spatial_state NULL) is legacy_dynamic, not open_space_fixed', () => {
  const inp = base({
    mainShip: ship({ status: 'traveling', spatial_state: null }),
    mainShipFleet: fleet({ status: 'moving' }),
    movements: [{
      id: 'lm1', fleet_id: 'f1', status: 'moving', target_type: 'location',
      origin_x: 1, origin_y: 2, target_x: 3, target_y: 4, depart_at: DEP, arrive_at: ARR,
    } as unknown as MarkerInputs['movements'][number]],
  })
  expect(resolveActiveSpaceRoute(inp, midMs)).toBeNull()
})

test('no route: destroyed', () => {
  expect(resolveActiveSpaceRoute(base({
    mainShip: ship({ status: 'destroyed', spatial_state: 'in_transit' }),
    mainShipFleet: fleet({ status: 'moving', active_space_movement_id: 'mv1' }),
    spaceMovement: spaceMv(),
  }), midMs)).toBeNull()
})

test('no route: mismatched fleet↔movement linkage', () => {
  const inp = coherentTransit()
  ;(inp.mainShipFleet as FleetInput).active_space_movement_id = 'OTHER'
  expect(resolveActiveSpaceRoute(inp, midMs)).toBeNull()
})

test('no route: half-pair / NaN target coordinate', () => {
  expect(resolveActiveSpaceRoute(coherentTransit({ target_y: Number.NaN }), midMs)).toBeNull()
  expect(resolveActiveSpaceRoute(coherentTransit({ target_x: Number.POSITIVE_INFINITY }), midMs)).toBeNull()
})

test('no route: missing active coordinate movement', () => {
  const inp = base({
    mainShip: ship({ status: 'traveling', spatial_state: 'in_transit' }),
    mainShipFleet: fleet({ status: 'moving', active_space_movement_id: 'mv1' }),
    spaceMovement: null,
  })
  expect(resolveActiveSpaceRoute(inp, midMs)).toBeNull()
})

test('no route: terminal (non-moving) movement status', () => {
  expect(resolveActiveSpaceRoute(coherentTransit({ status: 'arrived' }), midMs)).toBeNull()
})
