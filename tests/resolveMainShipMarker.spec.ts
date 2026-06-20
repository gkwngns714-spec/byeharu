import { test, expect } from '@playwright/test'
import { resolveMainShipMarker, type MarkerInputs } from '../src/features/map/resolveMainShipMarker'

// OSN-1 + OSN-2b — pure unit test for the single main-ship marker resolver. No browser/page: just
// deterministic assertions on the pure function. Run: `npm run verify:osn1:unit` (playwright test,
// node-side). OSN-2b adds spatial_state/space_x/space_y (migration 0054) read-model coverage.

const BASE = { x: 100, y: 200 }
const LOC = { id: 'loc-A', x: 300, y: 400 }
const DEP = '2026-01-01T00:00:00Z'
const ARR = '2026-01-01T00:10:00Z'
const depMs = Date.parse(DEP)
const arrMs = Date.parse(ARR)
const midMs = (depMs + arrMs) / 2

type ShipInput = NonNullable<MarkerInputs['mainShip']>
type PresInput = NonNullable<MarkerInputs['presence']>

// Default ship = legacy NULL spatial_state (every live row today), home, no coords.
const ship = (over: Partial<ShipInput> = {}): ShipInput => ({
  main_ship_id: 'ship-1', status: 'home', spatial_state: null, space_x: null, space_y: null, ...over,
})
const pres = (over: Partial<PresInput> = {}): PresInput => ({
  fleet_id: 'f1', location_id: 'loc-A', status: 'active', ...over,
})

const inputs = (over: Partial<MarkerInputs> = {}): MarkerInputs => ({
  mainShip: ship(),
  mainShipFleet: null,
  movements: [],
  presence: null,
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

// ── Legacy (spatial_state IS NULL) — unchanged OSN-1 behavior, made deterministic ───────────────

test('legacy: home → base coordinates', () => {
  expect(resolveMainShipMarker(inputs(), Date.now())).toMatchObject({
    state: 'home', x: 100, y: 200, relation: 'self', entityType: 'main_ship', entityId: 'ship-1',
  })
})

test('legacy: valid named-location presence → location coordinates (case 1)', () => {
  const m = resolveMainShipMarker(
    inputs({
      mainShip: ship({ status: 'traveling' }),
      mainShipFleet: { id: 'f1', status: 'present', current_location_id: 'loc-A' },
      presence: pres({ fleet_id: 'f1', location_id: 'loc-A', status: 'active' }),
    }),
    Date.now(),
  )
  expect(m).toMatchObject({ state: 'present', x: 300, y: 400 })
})

test('legacy: present fleet with no matching active presence → null (case 2)', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: ship({ status: 'traveling' }),
        mainShipFleet: { id: 'f1', status: 'present', current_location_id: 'loc-A' },
        presence: null,
      }),
      Date.now(),
    ),
  ).toBeNull()
})

test('legacy: active presence with mismatched location id → null (case 3)', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: ship({ status: 'traveling' }),
        mainShipFleet: { id: 'f1', status: 'present', current_location_id: 'loc-A' },
        presence: pres({ location_id: 'loc-OTHER' }),
      }),
      Date.now(),
    ),
  ).toBeNull()
})

test('legacy: present with mismatched presence fleet_id → null', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: ship({ status: 'traveling' }),
        mainShipFleet: { id: 'f1', status: 'present', current_location_id: 'loc-A' },
        presence: pres({ fleet_id: 'OTHER' }),
      }),
      Date.now(),
    ),
  ).toBeNull()
})

test('legacy: present with current_location_id=null → null (case 4)', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: ship({ status: 'traveling' }),
        mainShipFleet: { id: 'f1', status: 'present', current_location_id: null },
        presence: pres({ location_id: null }),
      }),
      Date.now(),
    ),
  ).toBeNull()
})

test('legacy: present with non-active presence → null', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: ship({ status: 'traveling' }),
        mainShipFleet: { id: 'f1', status: 'present', current_location_id: 'loc-A' },
        presence: pres({ status: 'leaving' }),
      }),
      Date.now(),
    ),
  ).toBeNull()
})

test('legacy: outbound midpoint interpolation (case 13)', () => {
  const m = resolveMainShipMarker(
    inputs({
      mainShip: ship({ status: 'traveling' }),
      mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null },
      movements: [mv({ origin_x: 0, origin_y: 0, target_x: 100, target_y: 100, target_type: 'location' })],
    }),
    midMs,
  )
  expect(m?.state).toBe('outbound')
  expect(m?.x).toBeCloseTo(50)
  expect(m?.y).toBeCloseTo(50)
})

test('legacy: returning midpoint interpolation (case 13)', () => {
  const m = resolveMainShipMarker(
    inputs({
      mainShip: ship({ status: 'returning' }),
      mainShipFleet: { id: 'f1', status: 'returning', current_location_id: null },
      movements: [mv({ origin_x: 100, origin_y: 100, target_x: 0, target_y: 0, target_type: 'base' })],
    }),
    midMs,
  )
  expect(m?.state).toBe('returning')
  expect(m?.x).toBeCloseTo(50)
  expect(m?.y).toBeCloseTo(50)
})

test('legacy: progress clamped below 0 and above 1', () => {
  const inp = inputs({
    mainShip: ship({ status: 'traveling' }),
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

test('legacy: in-flight fleet with missing movement → null', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: ship({ status: 'traveling' }),
        mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null },
        movements: [],
      }),
      Date.now(),
    ),
  ).toBeNull()
})

test('legacy: invalid timestamps → null', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: ship({ status: 'traveling' }),
        mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null },
        movements: [mv({ depart_at: 'nope', arrive_at: 'nope' })],
      }),
      Date.now(),
    ),
  ).toBeNull()
})

test('legacy: missing endpoint coordinates → null', () => {
  expect(
    resolveMainShipMarker(
      inputs({
        mainShip: ship({ status: 'traveling' }),
        mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null },
        movements: [mv({ target_x: null })],
      }),
      Date.now(),
    ),
  ).toBeNull()
})

// ── in_space (OSN-2b) ───────────────────────────────────────────────────────────────────────────

test('in_space: valid finite coords → ship-owned coordinates (case 5)', () => {
  const m = resolveMainShipMarker(
    inputs({ mainShip: ship({ status: 'traveling', spatial_state: 'in_space', space_x: 128.5, space_y: -64.25 }) }),
    Date.now(),
  )
  expect(m).toMatchObject({ state: 'in_space', x: 128.5, y: -64.25, relation: 'self', entityType: 'main_ship' })
})

test('in_space: accepts 0, negative, and mixed-sign coordinates (case 6)', () => {
  for (const [x, y] of [[0, 0], [-5, -9], [12.5, -7], [0, -3]] as const) {
    const m = resolveMainShipMarker(
      inputs({ mainShip: ship({ spatial_state: 'in_space', space_x: x, space_y: y }) }),
      Date.now(),
    )
    expect(m?.state).toBe('in_space')
    expect(m?.x).toBe(x)
    expect(m?.y).toBe(y)
  }
})

test('in_space: only one coordinate populated → null (case 7)', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ spatial_state: 'in_space', space_x: 10, space_y: null }) }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ spatial_state: 'in_space', space_x: null, space_y: 10 }) }), Date.now())).toBeNull()
})

test('in_space: NaN / Infinity / -Infinity → null (case 8)', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ spatial_state: 'in_space', space_x: NaN, space_y: 0 }) }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ spatial_state: 'in_space', space_x: Infinity, space_y: 0 }) }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ spatial_state: 'in_space', space_x: 0, space_y: -Infinity }) }), Date.now())).toBeNull()
})

test('in_space: conflicting active fleet/presence/present-location → null (case 9)', () => {
  const parked = { spatial_state: 'in_space' as const, space_x: 5, space_y: 6 }
  // conflict: active linked fleet present
  expect(resolveMainShipMarker(inputs({
    mainShip: ship(parked), mainShipFleet: { id: 'f1', status: 'present', current_location_id: 'loc-A' },
  }), Date.now())).toBeNull()
  // conflict: active linked fleet moving
  expect(resolveMainShipMarker(inputs({
    mainShip: ship(parked), mainShipFleet: { id: 'f1', status: 'moving', current_location_id: null },
    movements: [mv()],
  }), Date.now())).toBeNull()
  // conflict: active named-location presence
  expect(resolveMainShipMarker(inputs({
    mainShip: ship(parked), presence: pres({ status: 'active' }),
  }), Date.now())).toBeNull()
})

// ── Destroyed / unknown ─────────────────────────────────────────────────────────────────────────

test('destroyed ship (status) → null (case 10)', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'destroyed' }) }), Date.now())).toBeNull()
})

test('destroyed ship even with parked coords present → null (no stale parked render)', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'destroyed', spatial_state: 'in_space', space_x: 1, space_y: 2 }) }), Date.now())).toBeNull()
})

test("spatial_state='destroyed' → null (case 11)", () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'traveling', spatial_state: 'destroyed' }) }), Date.now())).toBeNull()
})

test('recognized-but-unsupported spatial_state (home/at_location/in_transit) → null (case 12)', () => {
  for (const s of ['home', 'at_location', 'in_transit'] as const) {
    expect(
      resolveMainShipMarker(
        inputs({
          mainShip: ship({ status: 'traveling', spatial_state: s }),
          mainShipFleet: { id: 'f1', status: 'present', current_location_id: 'loc-A' },
          presence: pres(),
        }),
        Date.now(),
      ),
    ).toBeNull()
  }
})

test('unknown / malformed spatial_state → null (case 12)', () => {
  const inp = inputs()
  ;(inp.mainShip as { spatial_state: string }).spatial_state = 'totally-unknown'
  expect(resolveMainShipMarker(inp, Date.now())).toBeNull()
})

test('null mainShip → null', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: null }), Date.now())).toBeNull()
})

// ── Purity (case 14) ────────────────────────────────────────────────────────────────────────────

test('does not mutate the input object', () => {
  const inp = inputs({
    mainShip: ship({ status: 'traveling', spatial_state: 'in_space', space_x: 5, space_y: 6 }),
    mainShipFleet: { id: 'f1', status: 'present', current_location_id: 'loc-A' },
    presence: pres(),
    movements: [mv()],
  })
  const snap = JSON.stringify(inp)
  resolveMainShipMarker(inp, midMs)
  expect(JSON.stringify(inp)).toBe(snap)
})
