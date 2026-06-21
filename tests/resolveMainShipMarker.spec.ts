import { test, expect } from '@playwright/test'
import { resolveMainShipMarker, type MarkerInputs } from '../src/features/map/resolveMainShipMarker'

// OSN-1 / OSN-2b / OSN-3-S1 — pure unit test for the single main-ship marker resolver. No browser/page.
// Run: `npm run verify:osn:resolver`.

const BASE = { x: 100, y: 200 }
const LOC = { id: 'loc-A', x: 300, y: 400 }
const DEP = '2026-01-01T00:00:00Z'
const ARR = '2026-01-01T00:10:00Z'
const depMs = Date.parse(DEP)
const arrMs = Date.parse(ARR)
const midMs = (depMs + arrMs) / 2

type ShipInput = NonNullable<MarkerInputs['mainShip']>
type FleetInput = NonNullable<MarkerInputs['mainShipFleet']>
type PresInput = NonNullable<MarkerInputs['presence']>
type SpaceMv = NonNullable<MarkerInputs['spaceMovement']>

const ship = (over: Partial<ShipInput> = {}): ShipInput => ({
  main_ship_id: 'ship-1', status: 'home', spatial_state: null, space_x: null, space_y: null, ...over,
})
const fleet = (over: Partial<FleetInput> = {}): FleetInput => ({
  id: 'f1', status: 'moving', current_location_id: null,
  location_mode: 'movement', active_movement_id: null, active_space_movement_id: null, ...over,
})
const pres = (over: Partial<PresInput> = {}): PresInput => ({
  fleet_id: 'f1', location_id: 'loc-A', status: 'active', ...over,
})
const spaceMv = (over: Partial<SpaceMv> = {}): SpaceMv => ({
  id: 'sm1', main_ship_id: 'ship-1', fleet_id: 'f1', origin_x: 0, origin_y: 0, target_x: 100, target_y: 100,
  target_kind: 'space', status: 'moving', depart_at: DEP, arrive_at: ARR, ...over,
})

const inputs = (over: Partial<MarkerInputs> = {}): MarkerInputs => ({
  mainShip: ship(),
  mainShipFleet: null,
  movements: [],
  presence: null,
  spaceMovement: null,
  base: BASE,
  locations: [LOC],
  ...over,
})

const mv = (over: Record<string, unknown> = {}) =>
  ({
    id: 'm1', fleet_id: 'f1', origin_type: 'location', origin_x: 0, origin_y: 0,
    target_type: 'location', target_location_id: 'loc-A', target_base_id: null, target_x: 100, target_y: 100,
    mission_type: 'rally', status: 'moving', depart_at: DEP, arrive_at: ARR,
    ...over,
  }) as unknown as MarkerInputs['movements'][number]

// ── Legacy (spatial_state IS NULL) — unchanged ──────────────────────────────────────────────────

test('legacy: home → base coordinates', () => {
  expect(resolveMainShipMarker(inputs(), Date.now())).toMatchObject({ state: 'home', x: 100, y: 200 })
})

test('legacy: valid named-location presence → location coords', () => {
  const m = resolveMainShipMarker(inputs({
    mainShip: ship({ status: 'traveling' }),
    mainShipFleet: fleet({ status: 'present', current_location_id: 'loc-A' }),
    presence: pres(),
  }), Date.now())
  expect(m).toMatchObject({ state: 'present', x: 300, y: 400 })
})

test('legacy: present fleet with no active presence → null', () => {
  expect(resolveMainShipMarker(inputs({
    mainShip: ship({ status: 'traveling' }), mainShipFleet: fleet({ status: 'present', current_location_id: 'loc-A' }), presence: null,
  }), Date.now())).toBeNull()
})

test('legacy: active presence mismatched location id → null', () => {
  expect(resolveMainShipMarker(inputs({
    mainShip: ship({ status: 'traveling' }), mainShipFleet: fleet({ status: 'present', current_location_id: 'loc-A' }), presence: pres({ location_id: 'loc-OTHER' }),
  }), Date.now())).toBeNull()
})

test('legacy: outbound midpoint interpolation', () => {
  const m = resolveMainShipMarker(inputs({
    mainShip: ship({ status: 'traveling' }),
    mainShipFleet: fleet({ status: 'moving' }),
    movements: [mv({ origin_x: 0, origin_y: 0, target_x: 100, target_y: 100, target_type: 'location' })],
  }), midMs)
  expect(m?.state).toBe('outbound'); expect(m?.x).toBeCloseTo(50); expect(m?.y).toBeCloseTo(50)
})

test('legacy: returning midpoint interpolation', () => {
  const m = resolveMainShipMarker(inputs({
    mainShip: ship({ status: 'returning' }),
    mainShipFleet: fleet({ status: 'returning' }),
    movements: [mv({ origin_x: 100, origin_y: 100, target_x: 0, target_y: 0, target_type: 'base' })],
  }), midMs)
  expect(m?.state).toBe('returning'); expect(m?.x).toBeCloseTo(50); expect(m?.y).toBeCloseTo(50)
})

test('legacy: in-flight with missing movement → null', () => {
  expect(resolveMainShipMarker(inputs({
    mainShip: ship({ status: 'traveling' }), mainShipFleet: fleet({ status: 'moving' }), movements: [],
  }), Date.now())).toBeNull()
})

// ── in_space (OSN-2b) ───────────────────────────────────────────────────────────────────────────

test('in_space: valid finite coords → ship coords', () => {
  const m = resolveMainShipMarker(inputs({ mainShip: ship({ status: 'stationary', spatial_state: 'in_space', space_x: 128.5, space_y: -64.25 }) }), Date.now())
  expect(m).toMatchObject({ state: 'in_space', x: 128.5, y: -64.25 })
})

test('in_space: 0/negative/mixed accepted', () => {
  for (const [x, y] of [[0, 0], [-5, -9], [12.5, -7]] as const) {
    const m = resolveMainShipMarker(inputs({ mainShip: ship({ status: 'stationary', spatial_state: 'in_space', space_x: x, space_y: y }) }), Date.now())
    expect(m?.x).toBe(x); expect(m?.y).toBe(y)
  }
})

test('in_space: half-pair / NaN / Infinity → null', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'stationary', spatial_state: 'in_space', space_x: 10, space_y: null }) }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'stationary', spatial_state: 'in_space', space_x: NaN, space_y: 0 }) }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'stationary', spatial_state: 'in_space', space_x: 0, space_y: Infinity }) }), Date.now())).toBeNull()
})

test('in_space: conflicting active fleet / presence / coordinate movement → null', () => {
  const parked = { status: 'stationary' as const, spatial_state: 'in_space' as const, space_x: 5, space_y: 6 }
  expect(resolveMainShipMarker(inputs({ mainShip: ship(parked), mainShipFleet: fleet({ status: 'present', current_location_id: 'loc-A' }) }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(inputs({ mainShip: ship(parked), presence: pres() }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(inputs({ mainShip: ship(parked), spaceMovement: spaceMv() }), Date.now())).toBeNull()
})

// ── in_transit (OSN-3 S1) ───────────────────────────────────────────────────────────────────────

const transitInputs = (over: Partial<MarkerInputs> = {}) => inputs({
  mainShip: ship({ status: 'traveling', spatial_state: 'in_transit' }),
  mainShipFleet: fleet({ status: 'moving', location_mode: 'movement', active_movement_id: null, active_space_movement_id: 'sm1' }),
  spaceMovement: spaceMv({ origin_x: 0, origin_y: 0, target_x: 100, target_y: 100 }),
  ...over,
})

test('in_transit: midpoint interpolation (outbound)', () => {
  const m = resolveMainShipMarker(transitInputs(), midMs)
  expect(m?.state).toBe('outbound'); expect(m?.x).toBeCloseTo(50); expect(m?.y).toBeCloseTo(50)
})

test('in_transit: departure and post-arrival clamp', () => {
  const before = resolveMainShipMarker(transitInputs(), depMs - 60_000)
  expect(before?.x).toBeCloseTo(0); expect(before?.y).toBeCloseTo(0)
  const after = resolveMainShipMarker(transitInputs(), arrMs + 60_000)
  expect(after?.x).toBeCloseTo(100); expect(after?.y).toBeCloseTo(100)
})

test('in_transit: base target → returning state', () => {
  const m = resolveMainShipMarker(transitInputs({ spaceMovement: spaceMv({ target_kind: 'base', origin_x: 0, origin_y: 0, target_x: 100, target_y: 100 }) }), midMs)
  expect(m?.state).toBe('returning')
})

test('in_transit: missing coordinate movement → null', () => {
  expect(resolveMainShipMarker(transitInputs({ spaceMovement: null }), midMs)).toBeNull()
})

test('in_transit: mismatched ship/fleet/pointer linkage → null', () => {
  expect(resolveMainShipMarker(transitInputs({ spaceMovement: spaceMv({ main_ship_id: 'other' }) }), midMs)).toBeNull()
  expect(resolveMainShipMarker(transitInputs({ spaceMovement: spaceMv({ fleet_id: 'other' }) }), midMs)).toBeNull()
  expect(resolveMainShipMarker(transitInputs({ mainShipFleet: fleet({ status: 'moving', active_space_movement_id: 'DIFFERENT' }) }), midMs)).toBeNull()
})

test('in_transit: active legacy movement pointer present → null', () => {
  expect(resolveMainShipMarker(transitInputs({ mainShipFleet: fleet({ status: 'moving', active_movement_id: 'm9', active_space_movement_id: 'sm1' }) }), midMs)).toBeNull()
})

test('in_transit: non-stationary fleet state / wrong location_mode → null', () => {
  expect(resolveMainShipMarker(transitInputs({ mainShipFleet: fleet({ status: 'present', active_space_movement_id: 'sm1' }) }), midMs)).toBeNull()
  expect(resolveMainShipMarker(transitInputs({ mainShipFleet: fleet({ status: 'moving', location_mode: 'base', active_space_movement_id: 'sm1' }) }), midMs)).toBeNull()
})

test('in_transit: invalid timestamps / coords → null', () => {
  expect(resolveMainShipMarker(transitInputs({ spaceMovement: spaceMv({ depart_at: 'nope', arrive_at: 'nope' }) }), midMs)).toBeNull()
  expect(resolveMainShipMarker(transitInputs({ spaceMovement: spaceMv({ target_x: NaN as unknown as number }) }), midMs)).toBeNull()
})

test('in_transit: with active presence → null', () => {
  expect(resolveMainShipMarker(transitInputs({ presence: pres() }), midMs)).toBeNull()
})

// ── at_location (OSN-3 S1) ──────────────────────────────────────────────────────────────────────

const atLocInputs = (over: Partial<MarkerInputs> = {}) => inputs({
  mainShip: ship({ status: 'stationary', spatial_state: 'at_location' }),
  mainShipFleet: fleet({ status: 'present', current_location_id: 'loc-A', location_mode: 'location', active_movement_id: null, active_space_movement_id: null }),
  presence: pres(),
  ...over,
})

test('at_location: valid → location coords', () => {
  expect(resolveMainShipMarker(atLocInputs(), Date.now())).toMatchObject({ state: 'present', x: 300, y: 400 })
})

test('at_location: non-stationary ship → null', () => {
  expect(resolveMainShipMarker(atLocInputs({ mainShip: ship({ status: 'traveling', spatial_state: 'at_location' }) }), Date.now())).toBeNull()
})

test('at_location: no matching active presence → null', () => {
  expect(resolveMainShipMarker(atLocInputs({ presence: null }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(atLocInputs({ presence: pres({ location_id: 'loc-OTHER' }) }), Date.now())).toBeNull()
})

test('at_location: residual movement pointer → null', () => {
  expect(resolveMainShipMarker(atLocInputs({ mainShipFleet: fleet({ status: 'present', current_location_id: 'loc-A', active_space_movement_id: 'sm1' }) }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(atLocInputs({ spaceMovement: spaceMv() }), Date.now())).toBeNull()
})

// ── home (OSN-3 S1, non-null spatial_state) ─────────────────────────────────────────────────────

test('home (spatial_state=home): valid → base coords', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'home', spatial_state: 'home' }) }), Date.now()))
    .toMatchObject({ state: 'home', x: 100, y: 200 })
})

test('home (spatial_state=home): with active fleet / presence / coordinate movement → null', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'home', spatial_state: 'home' }), mainShipFleet: fleet({ status: 'moving' }) }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'home', spatial_state: 'home' }), presence: pres() }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'home', spatial_state: 'home' }), spaceMovement: spaceMv() }), Date.now())).toBeNull()
})

// ── destroyed / malformed ───────────────────────────────────────────────────────────────────────

test('destroyed (status) → null', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'destroyed' }) }), Date.now())).toBeNull()
})
test("spatial_state='destroyed' → null", () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'traveling', spatial_state: 'destroyed' }) }), Date.now())).toBeNull()
})
test('stationary + NULL spatial_state → null', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'stationary', spatial_state: null }) }), Date.now())).toBeNull()
})
test('unknown spatial_state → null', () => {
  const inp = inputs()
  ;(inp.mainShip as { spatial_state: string }).spatial_state = 'totally-unknown'
  expect(resolveMainShipMarker(inp, Date.now())).toBeNull()
})
test('null mainShip → null', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: null }), Date.now())).toBeNull()
})

// ── purity ──────────────────────────────────────────────────────────────────────────────────────

test('does not mutate the input object', () => {
  const inp = transitInputs()
  const snap = JSON.stringify(inp)
  resolveMainShipMarker(inp, midMs)
  expect(JSON.stringify(inp)).toBe(snap)
})
