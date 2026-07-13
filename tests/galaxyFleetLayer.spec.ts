import { test, expect } from '@playwright/test'
import { fleetShipsLayer, FleetShipsMarkers, FleetShipMarker, fleetLayerMarkers } from '../src/features/map/fleetShipsLayer'
import type { FleetPosition } from '../src/features/map/mainshipApi'
import type { FleetMarker } from '../src/features/map/resolveFleetMarkers'

// FLEETMAP — GalaxyMap wiring proof. GalaxyMap renders `{fleetShipsLayer(...)}`; this test calls the SAME pure
// helper (the shipLayer element-tree convention) and inspects the descriptors. `fleetLayerMarkers` and
// FleetShipMarker are hook-free, so they are invoked directly and their output checked. No hooks run in the
// helper; no DB.
//
// SINGLE SOURCE OF TRUTH: the fleet layer EXCLUDES the selected ship (the single MainShipMarker owns its glyph
// + emphasis, one clock) — so the selected ship can never be double-drawn or leave an orphan ring here.

const DEP = '2026-01-01T00:00:00Z'
const ARR = '2026-01-01T00:10:00Z'
const midMs = (Date.parse(DEP) + Date.parse(ARR)) / 2
const norm = (p: { x: number; y: number }) => p
const pos = (over: Partial<FleetPosition> = {}): FleetPosition => ({
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
const LOCS = [{ id: 'loc-A', x: 10, y: 20 }]

test('mainshipSendEnabled=false → whole layer empty (data-dark parity with the single-ship marker)', () => {
  expect(
    fleetShipsLayer({ mainshipSendEnabled: false, positions: [pos()], locations: LOCS, selectedShipId: null, norm, k: 1 }),
  ).toEqual([])
})

test('empty projection → empty layer (map byte-identical to today)', () => {
  expect(
    fleetShipsLayer({ mainshipSendEnabled: true, positions: [], locations: LOCS, selectedShipId: null, norm, k: 1 }),
  ).toEqual([])
})

test('enabled + positions → one FleetShipsMarkers node carrying the projection + the excluded (selected) id', () => {
  const layer = fleetShipsLayer({
    mainshipSendEnabled: true,
    positions: [pos()],
    locations: LOCS,
    selectedShipId: 'ship-1',
    norm,
    k: 1,
  })
  expect(layer).toHaveLength(1)
  expect(layer[0].type).toBe(FleetShipsMarkers)
  const props = layer[0].props as { positions: FleetPosition[]; selectedShipId: string | null }
  expect(props.positions).toHaveLength(1)
  expect(props.selectedShipId).toBe('ship-1')
})

// ── fleetLayerMarkers (pure): the selected ship is never drawn by the fleet layer ──
test('the fleet layer EXCLUDES the selected ship (owned by the single MainShipMarker) and draws the rest', () => {
  const positions = [pos({ main_ship_id: 'ship-1' }), pos({ main_ship_id: 'ship-2' })]
  const drawn = fleetLayerMarkers(positions, LOCS, 'ship-1', midMs)
  expect(drawn.map((m) => m.main_ship_id)).toEqual(['ship-2'])
})

test('no selection → the fleet layer draws every placeable ship', () => {
  const positions = [pos({ main_ship_id: 'ship-1' }), pos({ main_ship_id: 'ship-2' })]
  expect(fleetLayerMarkers(positions, LOCS, null, midMs).map((m) => m.main_ship_id)).toEqual(['ship-1', 'ship-2'])
})

test('a selected ship that IS placeable still yields NO fleet-layer marker (no dual draw / no orphan)', () => {
  expect(fleetLayerMarkers([pos({ main_ship_id: 'ship-1' })], LOCS, 'ship-1', midMs)).toEqual([])
})

// ── FleetShipMarker (hook-free) — subdued fleetmate only; never the selected emphasis ──
const marker = (over: Partial<FleetMarker> = {}): FleetMarker => ({
  main_ship_id: 'ship-9',
  name: 'Nine',
  x: 1,
  y: 2,
  state: 'docked',
  selected: false,
  ...over,
})

function testids(el: ReturnType<typeof FleetShipMarker>): string[] {
  const found: string[] = []
  const walk = (node: unknown): void => {
    if (!node || typeof node !== 'object') return
    if (Array.isArray(node)) return node.forEach(walk)
    const n = node as { props?: { 'data-testid'?: string; children?: unknown } }
    if (n.props?.['data-testid']) found.push(n.props['data-testid'])
    if (n.props?.children !== undefined) walk(n.props.children)
  }
  walk(el)
  return found
}

test('FleetShipMarker renders a subdued fleetmate with its id testid and NO selected emphasis', () => {
  const ids = testids(FleetShipMarker({ marker: marker(), x: 1, y: 2, k: 1 }))
  expect(ids).toContain('fleet-ship-ship-9')
  expect(ids).not.toContain('fleet-ship-selected')
})
