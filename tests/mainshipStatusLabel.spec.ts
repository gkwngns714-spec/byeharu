import { test, expect } from '@playwright/test'
import { resolveMainShipStatusLabel } from '../src/features/map/mainshipStatusLabel'
import type { ShipMarker, MainShipMarkerState } from '../src/features/map/resolveMainShipMarker'
import type { MainShipSpaceMovement } from '../src/features/map/mainshipApi'

// OSN-HUB-1A — pure unit proof for the leak-safe status-label helper. Names resolve SOLELY from the public
// (get_world_map) location list; any hidden/unknown destination or dock location falls back to a generic
// label and NEVER surfaces a name/id/coordinate. Run: `npx playwright test mainshipStatusLabel.spec.ts`.

const PUBLIC = [
  { id: 'loc-haven', name: 'Haven Reach' },
  { id: 'loc-port', name: 'Old Port' },
]

const marker = (state: MainShipMarkerState): ShipMarker => ({
  entityId: 'ship-1',
  entityType: 'main_ship',
  relation: 'self',
  x: 0,
  y: 0,
  state,
  coordinateSpace: state === 'present' || state === 'home' ? 'legacy_dynamic' : 'open_space_fixed',
})

const mv = (over: Partial<MainShipSpaceMovement> = {}): MainShipSpaceMovement => ({
  id: 'mv1', main_ship_id: 'ship-1', fleet_id: 'f1',
  origin_x: 0, origin_y: 0, target_x: 10, target_y: 10,
  target_kind: 'space', status: 'moving', depart_at: 'x', arrive_at: 'y', ...over,
})

test('null marker → null label', () => {
  expect(resolveMainShipStatusLabel({ marker: null, spaceMovement: null, publicLocations: PUBLIC })).toBeNull()
})

test('in_space → "Parked in open space"', () => {
  expect(resolveMainShipStatusLabel({ marker: marker('in_space'), spaceMovement: null, publicLocations: PUBLIC }))
    .toBe('Parked in open space')
})

test('docked at a VISIBLE location → "Docked at <name>"', () => {
  expect(resolveMainShipStatusLabel({ marker: marker('present'), spaceMovement: null, publicLocations: PUBLIC, dockedLocationId: 'loc-haven' }))
    .toBe('Docked at Haven Reach')
})

test('docked at a HIDDEN/unknown location → generic "Docked" (no name/id leak)', () => {
  const label = resolveMainShipStatusLabel({ marker: marker('present'), spaceMovement: null, publicLocations: PUBLIC, dockedLocationId: 'hidden-1' })
  expect(label).toBe('Docked')
  expect(label).not.toContain('hidden-1')
})

test('traveling to a VISIBLE location target → "Traveling to <name>"', () => {
  const label = resolveMainShipStatusLabel({
    marker: marker('outbound'),
    spaceMovement: mv({ target_kind: 'location', target_location_id: 'loc-port' }),
    publicLocations: PUBLIC,
  })
  expect(label).toBe('Traveling to Old Port')
})

test('traveling to a HIDDEN location target → generic "Traveling" (no leak)', () => {
  const label = resolveMainShipStatusLabel({
    marker: marker('outbound'),
    spaceMovement: mv({ target_kind: 'location', target_location_id: 'hidden-port-x' }),
    publicLocations: PUBLIC,
  })
  expect(label).toBe('Traveling')
  expect(label).not.toContain('hidden-port-x')
})

test('traveling to an open-space coordinate → "Traveling to open space"', () => {
  expect(resolveMainShipStatusLabel({ marker: marker('outbound'), spaceMovement: mv({ target_kind: 'space' }), publicLocations: PUBLIC }))
    .toBe('Traveling to open space')
})

test('home → "At home base"', () => {
  expect(resolveMainShipStatusLabel({ marker: marker('home'), spaceMovement: null, publicLocations: PUBLIC }))
    .toBe('At home base')
})
