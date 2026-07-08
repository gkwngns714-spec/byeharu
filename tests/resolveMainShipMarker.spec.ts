import { test, expect } from '@playwright/test'
import { resolveMainShipMarker, type MarkerInputs } from '../src/features/map/resolveMainShipMarker'
import { markerViewBoxPoint } from '../src/features/map/MainShipMarker'
import { worldToViewBox } from '../src/features/map/openSpaceTransform'

// OSN-1 / OSN-2b / OSN-3-S1 — pure unit test for the single main-ship marker resolver. No browser/page.
// Run: `npm run verify:osn:resolver`.

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

test('legacy: home → null (port-centric: no home base marker)', () => {
  expect(resolveMainShipMarker(inputs(), Date.now())).toBeNull()
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

test('home (spatial_state=home): → null (port-centric: no home base marker)', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'home', spatial_state: 'home' }) }), Date.now())).toBeNull()
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

// ── OSN-3 S6B2: coordinate-space provenance (the `coordinateSpace` discriminant) ─────────────────────
// The existing assertions above (state/x/y, null cases) remain valid unchanged — requirement 8. These
// add the provenance contract: legacy/named → 'legacy_dynamic'; in_space + coordinate in_transit →
// 'open_space_fixed'; stale/incoherent coordinate data → null (never a guessed legacy fallback).

test('S6B2: at-location / present states → coordinateSpace legacy_dynamic (home has no marker)', () => {
  expect(resolveMainShipMarker(atLocInputs(), Date.now())?.coordinateSpace).toBe('legacy_dynamic') // §D at_location
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'traveling' }), mainShipFleet: fleet({ status: 'present', current_location_id: 'loc-A' }), presence: pres() }), Date.now())?.coordinateSpace).toBe('legacy_dynamic') // §F present
})

test('S6B2: legacy named outbound + return travel → legacy_dynamic', () => {
  const out = resolveMainShipMarker(inputs({ mainShip: ship({ status: 'traveling' }), mainShipFleet: fleet({ status: 'moving' }), movements: [mv({ target_type: 'location' })] }), midMs)
  expect(out).toMatchObject({ state: 'outbound', coordinateSpace: 'legacy_dynamic' })
  const ret = resolveMainShipMarker(inputs({ mainShip: ship({ status: 'returning' }), mainShipFleet: fleet({ status: 'returning' }), movements: [mv({ target_type: 'base', origin_x: 100, origin_y: 100, target_x: 0, target_y: 0 })] }), midMs)
  expect(ret).toMatchObject({ state: 'returning', coordinateSpace: 'legacy_dynamic' })
})

test('S6B2: in_space → open_space_fixed', () => {
  const m = resolveMainShipMarker(inputs({ mainShip: ship({ status: 'stationary', spatial_state: 'in_space', space_x: 42, space_y: -17 }) }), Date.now())
  expect(m).toMatchObject({ state: 'in_space', x: 42, y: -17, coordinateSpace: 'open_space_fixed' })
})

test('S6B2: coordinate in_transit (coherent) → open_space_fixed; world-space interp at start/mid/end', () => {
  expect(resolveMainShipMarker(transitInputs(), depMs)).toMatchObject({ x: 0, y: 0, coordinateSpace: 'open_space_fixed' })
  const mid = resolveMainShipMarker(transitInputs(), midMs)
  expect(mid?.coordinateSpace).toBe('open_space_fixed'); expect(mid?.x).toBeCloseTo(50); expect(mid?.y).toBeCloseTo(50)
  expect(resolveMainShipMarker(transitInputs(), arrMs)).toMatchObject({ x: 100, y: 100, coordinateSpace: 'open_space_fixed' })
})

test('S6B2: in_transit with missing / stale / incoherent space movement → null (no legacy fallback)', () => {
  expect(resolveMainShipMarker(transitInputs({ spaceMovement: null }), midMs)).toBeNull() // missing
  expect(resolveMainShipMarker(transitInputs({ spaceMovement: spaceMv({ status: 'arrived' }) }), midMs)).toBeNull() // stale (not 'moving')
  expect(resolveMainShipMarker(transitInputs({ spaceMovement: spaceMv({ fleet_id: 'other' }) }), midMs)).toBeNull() // incoherent link
})

test('S6B2: destroyed / repair-unavailable never produce a fixed-space marker', () => {
  // destroyed status wins even over a populated in_space coordinate state → no marker at all.
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'destroyed', spatial_state: 'in_space', space_x: 1, space_y: 2 }) }), Date.now())).toBeNull()
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'traveling', spatial_state: 'destroyed' }) }), Date.now())).toBeNull()
})

test('S6B2: no legacy / home / at-location / travel path can acquire open_space_fixed', () => {
  const legacyCases = [
    atLocInputs(),
    inputs({ mainShip: ship({ status: 'traveling' }), mainShipFleet: fleet({ status: 'moving' }), movements: [mv()] }),
    inputs({ mainShip: ship({ status: 'returning' }), mainShipFleet: fleet({ status: 'returning' }), movements: [mv({ target_type: 'base' })] }),
  ]
  for (const inp of legacyCases) {
    const m = resolveMainShipMarker(inp, midMs)
    expect(m).not.toBeNull()
    expect(m?.coordinateSpace).toBe('legacy_dynamic')
  }
})

test('S6B2: only in_space and coordinate in_transit yield open_space_fixed', () => {
  expect(resolveMainShipMarker(inputs({ mainShip: ship({ status: 'stationary', spatial_state: 'in_space', space_x: 0, space_y: 0 }) }), Date.now())?.coordinateSpace).toBe('open_space_fixed')
  expect(resolveMainShipMarker(transitInputs(), midMs)?.coordinateSpace).toBe('open_space_fixed')
})

// ── OSN-3 S6B4: the REAL MainShipMarker fixed-provenance route (markerViewBoxPoint — the SAME helper the
// component calls). Proves a resolved open_space_fixed marker is projected through worldToViewBox and
// NEVER through the dynamic `norm`; a legacy marker still routes through the supplied `norm`. ─────────────

test('S6B4: a resolved open_space_fixed marker routes through the fixed transform (real component helper)', () => {
  // a real in_space ship resolves to an open_space_fixed marker at world (8000,-8000)
  const m = resolveMainShipMarker(inputs({ mainShip: ship({ status: 'stationary', spatial_state: 'in_space', space_x: 8000, space_y: -8000 }) }), Date.now())
  expect(m?.coordinateSpace).toBe('open_space_fixed')
  // route via the EXACT helper MainShipMarker uses, with a `norm` stub that must NEVER be called
  let normCalled = false
  const stubNorm = (_p: { x: number; y: number }) => { normCalled = true; return { x: -999, y: -999 } }
  const pt = markerViewBoxPoint(m!, stubNorm)
  expect(pt).toEqual(worldToViewBox({ x: 8000, y: -8000 })) // fixed transform, exact-by-construction
  expect(Math.abs(pt.x - 900)).toBeLessThanOrEqual(1e-6) // === { x: 900, y: 900 }
  expect(Math.abs(pt.y - 900)).toBeLessThanOrEqual(1e-6)
  expect(normCalled).toBe(false) // the dynamic normalizer is NEVER used for a coordinate marker
})

test('S6B4: a legacy_dynamic marker routes through the supplied norm', () => {
  let normCalled = false
  const stubNorm = (p: { x: number; y: number }) => { normCalled = true; return { x: p.x + 1, y: p.y + 2 } }
  const pt = markerViewBoxPoint({ x: 300, y: 400, coordinateSpace: 'legacy_dynamic' }, stubNorm)
  expect(normCalled).toBe(true)
  expect(pt).toEqual({ x: 301, y: 402 }) // the stub's transformed result
})
