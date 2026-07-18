import { test, expect } from '@playwright/test'
import {
  derivePortsWithShips, dockedShipIds, resolveChosenShipId, portOfShip,
  type PortWithShips,
} from '../src/features/port/portPicker'
import type { FleetPosition } from '../src/features/map/mainshipApi'

// PORT-HUB — pure-logic unit tests for the Port screen's port picker derivation (no browser, no DB,
// no network). Proves the picker OFFERS exactly the ports where the player has ships at dock (grouped,
// named, transit/space excluded), and that the chosen acting ship resolves honestly (preferred-if-docked
// → first docked → null). The server stays the dock authority; this only decides what to offer.
// MAP-INTEGRATION M3: place='berthed' (the S1 unfleeted berth) ALSO counts as at-port — flagged
// `berthed: true` so the screen can stay honest about service availability (see the specs below).

// A minimal FleetPosition factory — only the fields derivePortsWithShips reads matter; the rest are
// filled with inert placeholders so the shape is a real FleetPosition.
function fp(over: Partial<FleetPosition>): FleetPosition {
  return {
    main_ship_id: 'ship-x', name: 'Ship X', class: 'frigate', status: 'stationary',
    place: 'docked', location_id: null, segment: null,
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
    {
      locationId: 'loc-haven',
      locationName: 'Haven',
      ships: [
        { mainShipId: 's1', name: 'Kestrel', berthed: false },
        { mainShipId: 's3', name: 'Lark', berthed: false },
      ],
    },
    { locationId: 'loc-slag', locationName: 'Slagworks', ships: [{ mainShipId: 's2', name: 'Wren', berthed: false }] },
  ])
})

// ── MAP-INTEGRATION M3 — 'berthed' counts as at-port (the Port↔Fitting contradiction fix) ────────
test('M3: a BERTHED ship (S1 unfleeted) IS a port entry, flagged berthed — consistent with Fitting\'s "Docked at X"', () => {
  const ports = derivePortsWithShips(
    [fp({ main_ship_id: 's1', name: 'Kestrel', place: 'berthed', location_id: 'loc-haven' })],
    name,
  )
  expect(ports).toEqual<PortWithShips[]>([
    { locationId: 'loc-haven', locationName: 'Haven', ships: [{ mainShipId: 's1', name: 'Kestrel', berthed: true }] },
  ])
  // and it participates in the chosen-ship resolution like any at-port ship
  expect(resolveChosenShipId(ports, null)).toBe('s1')
})

test('M3: docked + berthed ships at the SAME port share one entry, each honestly flagged', () => {
  const ports = derivePortsWithShips(
    [
      fp({ main_ship_id: 's1', name: 'Kestrel', place: 'docked', location_id: 'loc-haven' }),
      fp({ main_ship_id: 's2', name: 'Wren', place: 'berthed', location_id: 'loc-haven' }),
    ],
    name,
  )
  expect(ports).toHaveLength(1)
  expect(ports[0].ships).toEqual([
    { mainShipId: 's1', name: 'Kestrel', berthed: false },
    { mainShipId: 's2', name: 'Wren', berthed: true },
  ])
})

test('M3: a berthed row without a location_id is still skipped (fail-safe, same as docked)', () => {
  expect(derivePortsWithShips([fp({ main_ship_id: 's1', place: 'berthed', location_id: null })], name)).toEqual([])
})

// ── M3 REVIEW FIX — the fallback prefers a serviceable DOCKED ship over a berthed one ────────────
// A berthed ship has no usable dock services until 4c; defaulting to it (just because its projection
// row came first) would open the Port tab on the actionless berthed state while a docked ship sits
// right there. Explicit picks + the shared selection stay respected verbatim (berthed included).
test('M3 review fix: the DEFAULT chosen ship skips an earlier BERTHED ship when a DOCKED one exists', () => {
  const ports = derivePortsWithShips(
    [
      fp({ main_ship_id: 'b1', name: 'Moored', place: 'berthed', location_id: 'loc-haven' }), // earlier row
      fp({ main_ship_id: 'd1', name: 'Kestrel', place: 'docked', location_id: 'loc-slag' }),
    ],
    name,
  )
  expect(resolveChosenShipId(ports, null)).toBe('d1') // docked preferred over the earlier berthed
  expect(resolveChosenShipId(ports, 'ghost')).toBe('d1') // a stale preferred falls the same way
})

test('M3 review fix: an EXPLICIT pick of a berthed ship is still honored (only the fallback changed)', () => {
  const ports = derivePortsWithShips(
    [
      fp({ main_ship_id: 'b1', name: 'Moored', place: 'berthed', location_id: 'loc-haven' }),
      fp({ main_ship_id: 'd1', name: 'Kestrel', place: 'docked', location_id: 'loc-slag' }),
    ],
    name,
  )
  expect(resolveChosenShipId(ports, 'b1')).toBe('b1')
})

test('M3 review fix: with ONLY berthed ships, the first berthed ship is chosen (its honest state renders)', () => {
  const ports = derivePortsWithShips(
    [
      fp({ main_ship_id: 'b1', name: 'Moored', place: 'berthed', location_id: 'loc-haven' }),
      fp({ main_ship_id: 'b2', name: 'Skiff', place: 'berthed', location_id: 'loc-slag' }),
    ],
    name,
  )
  expect(resolveChosenShipId(ports, null)).toBe('b1')
})

test('derivePortsWithShips: only DOCKED ships count — transit / in_space / hidden are not port entries', () => {
  const ports = derivePortsWithShips(
    [
      fp({ main_ship_id: 's1', place: 'docked', location_id: 'loc-haven' }),
      fp({ main_ship_id: 's2', place: 'transit', location_id: 'loc-haven', segment: null }),
      fp({ main_ship_id: 's3', place: 'in_space', location_id: null }),
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
    { locationId: 'loc-secret', locationName: 'Unknown port', ships: [{ mainShipId: 's1', name: 'Unnamed ship', berthed: false }] },
  ])
})

test('derivePortsWithShips: no docked ships anywhere → empty list (the empty state)', () => {
  expect(derivePortsWithShips([], name)).toEqual([])
  expect(derivePortsWithShips([fp({ place: 'in_space', location_id: null })], name)).toEqual([])
})

// ── resolveChosenShipId: preferred-if-docked → first docked → null ────────────────────────────────────
const twoPorts: PortWithShips[] = [
  {
    locationId: 'loc-haven',
    locationName: 'Haven',
    ships: [
      { mainShipId: 's1', name: 'Kestrel', berthed: false },
      { mainShipId: 's3', name: 'Lark', berthed: false },
    ],
  },
  { locationId: 'loc-slag', locationName: 'Slagworks', ships: [{ mainShipId: 's2', name: 'Wren', berthed: false }] },
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
  const one: PortWithShips[] = [{ locationId: 'loc-haven', locationName: 'Haven', ships: [{ mainShipId: 's1', name: 'Kestrel', berthed: false }] }]
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
