import { test, expect } from '@playwright/test'
import {
  derivePortsWithShips, dockedShipIds, resolveChosenShipId, portOfShip,
  type PortWithShips,
} from '../src/features/port/portPicker'
import type { FleetPosition } from '../src/features/map/mainshipApi'

// PORT-HUB — pure-logic unit tests for the Port screen's port picker derivation (no browser, no DB,
// no network). Proves the picker OFFERS exactly the ports where the player has docked ships (grouped,
// named, transit/space excluded), and that the chosen acting ship resolves honestly (preferred-if-docked
// → first docked → null). The server stays the dock authority; this only decides what to offer.

// A minimal FleetPosition factory — only the fields derivePortsWithShips reads matter; the rest are
// filled with inert placeholders so the shape is a real FleetPosition.
function fp(over: Partial<FleetPosition>): FleetPosition {
  return {
    main_ship_id: 'ship-x', name: 'Ship X', class: 'frigate', status: 'stationary',
    spatial_state: null, place: 'docked', location_id: null, space_x: null, space_y: null, segment: null,
    ...over,
  }
}

const NAMES: Record<string, string> = { 'loc-haven': 'Haven', 'loc-slag': 'Slagworks' }
const name = (id: string) => NAMES[id]

test('derivePortsWithShips: groups docked ships by port, names them from the world map', () => {
  const ports = derivePortsWithShips(
    [
      fp({ main_ship_id: 's1', name: 'Kestrel', place: 'docked', location_id: 'loc-haven' }),
      fp({ main_ship_id: 's2', name: 'Wren', place: 'docked', location_id: 'loc-slag' }),
      fp({ main_ship_id: 's3', name: 'Lark', place: 'docked', location_id: 'loc-haven' }),
    ],
    name,
  )
  expect(ports).toEqual<PortWithShips[]>([
    { locationId: 'loc-haven', locationName: 'Haven', ships: [{ mainShipId: 's1', name: 'Kestrel' }, { mainShipId: 's3', name: 'Lark' }] },
    { locationId: 'loc-slag', locationName: 'Slagworks', ships: [{ mainShipId: 's2', name: 'Wren' }] },
  ])
})

test('derivePortsWithShips: only DOCKED ships count — transit / in_space / hidden are not port entries', () => {
  const ports = derivePortsWithShips(
    [
      fp({ main_ship_id: 's1', place: 'docked', location_id: 'loc-haven' }),
      fp({ main_ship_id: 's2', place: 'transit', location_id: 'loc-haven', segment: null }),
      fp({ main_ship_id: 's3', place: 'in_space', location_id: null, space_x: 1, space_y: 2 }),
      fp({ main_ship_id: 's4', place: 'hidden', location_id: 'loc-haven' }),
    ],
    name,
  )
  expect(ports).toHaveLength(1)
  expect(dockedShipIds(ports)).toEqual(['s1'])
})

test('derivePortsWithShips: docked with no location_id or no ship id is skipped (fail-safe)', () => {
  const ports = derivePortsWithShips(
    [
      fp({ main_ship_id: 's1', place: 'docked', location_id: null }),
      fp({ main_ship_id: '', place: 'docked', location_id: 'loc-haven' }),
    ],
    name,
  )
  expect(ports).toEqual([])
})

test('derivePortsWithShips: an unknown / unnamed port falls back to a neutral label (never leaks a raw id)', () => {
  const ports = derivePortsWithShips(
    [fp({ main_ship_id: 's1', name: '', place: 'docked', location_id: 'loc-secret' })],
    name, // no entry for loc-secret
  )
  expect(ports).toEqual<PortWithShips[]>([
    { locationId: 'loc-secret', locationName: 'Unknown port', ships: [{ mainShipId: 's1', name: 'Unnamed ship' }] },
  ])
})

test('derivePortsWithShips: no docked ships anywhere → empty list (the empty state)', () => {
  expect(derivePortsWithShips([], name)).toEqual([])
  expect(derivePortsWithShips([fp({ place: 'in_space', location_id: null })], name)).toEqual([])
})

// ── resolveChosenShipId: preferred-if-docked → first docked → null ────────────────────────────────────
const twoPorts: PortWithShips[] = [
  { locationId: 'loc-haven', locationName: 'Haven', ships: [{ mainShipId: 's1', name: 'Kestrel' }, { mainShipId: 's3', name: 'Lark' }] },
  { locationId: 'loc-slag', locationName: 'Slagworks', ships: [{ mainShipId: 's2', name: 'Wren' }] },
]

test('resolveChosenShipId: honors the preferred ship when it is actually docked', () => {
  expect(resolveChosenShipId(twoPorts, 's2')).toBe('s2')
  expect(resolveChosenShipId(twoPorts, 's3')).toBe('s3')
})

test('resolveChosenShipId: preferred not docked (or null) → defaults to the FIRST docked ship', () => {
  expect(resolveChosenShipId(twoPorts, 'ghost')).toBe('s1')
  expect(resolveChosenShipId(twoPorts, null)).toBe('s1')
})

test('resolveChosenShipId: one docked ship → it is auto-selected regardless of preferred', () => {
  const one: PortWithShips[] = [{ locationId: 'loc-haven', locationName: 'Haven', ships: [{ mainShipId: 's1', name: 'Kestrel' }] }]
  expect(resolveChosenShipId(one, null)).toBe('s1')
  expect(resolveChosenShipId(one, 'ghost')).toBe('s1')
})

test('resolveChosenShipId: nothing docked → null (empty state)', () => {
  expect(resolveChosenShipId([], 's1')).toBeNull()
  expect(resolveChosenShipId([], null)).toBeNull()
})

test('portOfShip: finds the chosen ship\'s port (for highlighting), null when not docked / no ship', () => {
  expect(portOfShip(twoPorts, 's3')?.locationId).toBe('loc-haven')
  expect(portOfShip(twoPorts, 's2')?.locationId).toBe('loc-slag')
  expect(portOfShip(twoPorts, 'ghost')).toBeNull()
  expect(portOfShip(twoPorts, null)).toBeNull()
})
