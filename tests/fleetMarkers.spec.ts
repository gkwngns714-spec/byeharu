import { test, expect } from '@playwright/test'
import { resolveFleetMarkers } from '../src/features/map/resolveFleetMarkers'
import type { FleetPosition } from '../src/features/map/mainshipApi'

// FLEETMAP — pure unit test for the whole-fleet marker resolver. No browser/page/DB; plain input objects only.
// Proves EVERY owned ship is placed (the bug was: owning 2+ ships hid the whole fleet), across docked /
// in-transit interpolation / in_space / hidden, with the selected-ship highlight. Run in the pure battery.

const LOC_A = { id: 'loc-A', x: 300, y: 400 }
const LOC_B = { id: 'loc-B', x: -120, y: 80 }
const LOCS = [LOC_A, LOC_B]
const DEP = '2026-01-01T00:00:00Z'
const ARR = '2026-01-01T00:10:00Z'
const depMs = Date.parse(DEP)
const arrMs = Date.parse(ARR)
const midMs = (depMs + arrMs) / 2

const base = (over: Partial<FleetPosition> = {}): FleetPosition => ({
  main_ship_id: 'ship-1',
  name: 'Alpha',
  class: 'starter_frigate',
  status: 'stationary',
  spatial_state: 'at_location',
  place: 'docked',
  location_id: 'loc-A',
  space_x: null,
  space_y: null,
  segment: null,
  ...over,
})

const transit = (over: Partial<FleetPosition> = {}): FleetPosition =>
  base({
    place: 'transit',
    location_id: null,
    spatial_state: 'in_transit',
    status: 'traveling',
    segment: {
      origin_x: 0,
      origin_y: 0,
      target_x: 1000,
      target_y: 2000,
      target_kind: 'space',
      depart_at: DEP,
      arrive_at: ARR,
    },
    ...over,
  })

test('docked ship → marker at the port coordinates', () => {
  const m = resolveFleetMarkers([base()], LOCS, null, midMs)
  expect(m).toHaveLength(1)
  expect(m[0]).toMatchObject({ main_ship_id: 'ship-1', x: 300, y: 400, state: 'docked', selected: false })
})

test('docked ship whose port is not in the visible world → NO marker (fail closed)', () => {
  const m = resolveFleetMarkers([base({ location_id: 'loc-missing' })], LOCS, null, midMs)
  expect(m).toHaveLength(0)
})

test('in-transit ship → interpolated at the segment midpoint (outbound)', () => {
  const m = resolveFleetMarkers([transit()], LOCS, null, midMs)
  expect(m).toHaveLength(1)
  expect(m[0].state).toBe('outbound')
  expect(m[0].x).toBeCloseTo(500) // half of 1000
  expect(m[0].y).toBeCloseTo(1000) // half of 2000
})

test('in-transit endpoints clamp at depart and arrive', () => {
  const atDepart = resolveFleetMarkers([transit()], LOCS, null, depMs)[0]
  expect(atDepart.x).toBeCloseTo(0)
  expect(atDepart.y).toBeCloseTo(0)
  const past = resolveFleetMarkers([transit()], LOCS, null, arrMs + 999999)[0]
  expect(past.x).toBeCloseTo(1000)
  expect(past.y).toBeCloseTo(2000)
})

test('returning transit (target_kind=base) → returning state', () => {
  const m = resolveFleetMarkers(
    [transit({ segment: { origin_x: 0, origin_y: 0, target_x: 10, target_y: 10, target_kind: 'base', depart_at: DEP, arrive_at: ARR } })],
    LOCS,
    null,
    midMs,
  )
  expect(m[0].state).toBe('returning')
})

test('transit with a null/incoherent segment → NO marker (never a guessed point)', () => {
  expect(resolveFleetMarkers([transit({ segment: null })], LOCS, null, midMs)).toHaveLength(0)
  // arrive <= depart is incoherent → the shared lerp returns null → skipped
  const bad = transit({ segment: { origin_x: 0, origin_y: 0, target_x: 1, target_y: 1, target_kind: 'space', depart_at: ARR, arrive_at: DEP } })
  expect(resolveFleetMarkers([bad], LOCS, null, midMs)).toHaveLength(0)
})

test('in_space ship → marker at its own coordinates', () => {
  const m = resolveFleetMarkers(
    [base({ place: 'in_space', spatial_state: 'in_space', location_id: null, space_x: 4200, space_y: -1500 })],
    LOCS,
    null,
    midMs,
  )
  expect(m).toHaveLength(1)
  expect(m[0]).toMatchObject({ x: 4200, y: -1500, state: 'in_space' })
})

test('in_space with a non-finite coordinate → NO marker', () => {
  const m = resolveFleetMarkers(
    [base({ place: 'in_space', location_id: null, space_x: Number.NaN, space_y: 10 })],
    LOCS,
    null,
    midMs,
  )
  expect(m).toHaveLength(0)
})

test('hidden ship (home / incoherent) → NO marker', () => {
  const m = resolveFleetMarkers([base({ place: 'hidden', location_id: null, spatial_state: 'home' })], LOCS, null, midMs)
  expect(m).toHaveLength(0)
})

test('empty projection → empty markers', () => {
  expect(resolveFleetMarkers([], LOCS, 'ship-1', midMs)).toEqual([])
})

test('N≥2 — EVERY placeable owned ship is drawn (the bug fix)', () => {
  const ships = [
    base({ main_ship_id: 'ship-1', location_id: 'loc-A' }),
    base({ main_ship_id: 'ship-2', location_id: 'loc-B' }),
    transit({ main_ship_id: 'ship-3' }),
  ]
  const m = resolveFleetMarkers(ships, LOCS, null, midMs)
  expect(m.map((x) => x.main_ship_id)).toEqual(['ship-1', 'ship-2', 'ship-3'])
})

test('selected ship is flagged; the others are not', () => {
  const ships = [base({ main_ship_id: 'ship-1' }), base({ main_ship_id: 'ship-2', location_id: 'loc-B' })]
  const m = resolveFleetMarkers(ships, LOCS, 'ship-2', midMs)
  expect(m.find((x) => x.main_ship_id === 'ship-1')!.selected).toBe(false)
  expect(m.find((x) => x.main_ship_id === 'ship-2')!.selected).toBe(true)
})

test('no selection → nothing flagged selected', () => {
  const m = resolveFleetMarkers([base(), base({ main_ship_id: 'ship-2', location_id: 'loc-B' })], LOCS, null, midMs)
  expect(m.every((x) => !x.selected)).toBe(true)
})

// ── FLEETMAP de-dup — a ship a TEAM marker already represents is SKIPPED here (no redundant chevron) ──
test('excludeShipIds — ships already drawn by a team marker are skipped; solo/ungrouped ships still draw', () => {
  const ships = [
    base({ main_ship_id: 'ship-1', location_id: 'loc-A' }), // team member (docked-together fleet) → skipped
    base({ main_ship_id: 'ship-2', location_id: 'loc-A' }), // team member → skipped
    base({ main_ship_id: 'ship-solo', location_id: 'loc-B' }), // ungrouped → still drawn
  ]
  const m = resolveFleetMarkers(ships, LOCS, null, midMs, new Set(['ship-1', 'ship-2']))
  expect(m.map((x) => x.main_ship_id)).toEqual(['ship-solo'])
})

test('empty exclude set (the default) draws every placeable ship — byte-identical to today', () => {
  const ships = [base({ main_ship_id: 'ship-1' }), base({ main_ship_id: 'ship-2', location_id: 'loc-B' })]
  expect(resolveFleetMarkers(ships, LOCS, null, midMs, new Set()).map((x) => x.main_ship_id)).toEqual(['ship-1', 'ship-2'])
  expect(resolveFleetMarkers(ships, LOCS, null, midMs).map((x) => x.main_ship_id)).toEqual(['ship-1', 'ship-2'])
})

test('S1 BERTH MODEL: berthed ship → deliberately NO marker (only fleets are map markers)', () => {
  const m = resolveFleetMarkers(
    [base({ place: 'berthed', location_id: 'loc-A', spatial_state: null, status: 'home' })],
    LOCS,
    null,
    midMs,
  )
  expect(m).toHaveLength(0)
})
