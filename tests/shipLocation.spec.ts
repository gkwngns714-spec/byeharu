import { test, expect } from '@playwright/test'
import { resolveBerthedLocationLabel, resolveShipLocationLabel } from '../src/features/ship/shipLocation'
import type { MainShipFleet } from '../src/features/map/mainshipApi'
import type { FleetMovement } from '../src/features/fleets/fleetTypes'
import type { MapLocation } from '../src/features/map/mapTypes'

// SHIPLOC — pure-logic proof for the ONE shared main-ship LOCATION resolver (no app/Supabase). The
// same helper feeds BOTH the dossier's location strip and ShipStatusCard's destination/countdown, so
// these cases lock the labels for docked / in-transit (+ eta) / deep space / combat / returning /
// home / null-safety, plus the fail-closed no-leak path for a hidden location.
// Run: `npx playwright test shipLocation.spec.ts`.

const fleet = (over: Partial<MainShipFleet> = {}): MainShipFleet => ({
  id: 'fleet-1',
  status: 'present',
  current_location_id: null,
  location_mode: null,
  active_movement_id: null,
  ...over,
})

const movement = (over: Partial<FleetMovement> = {}): FleetMovement => ({
  id: 'mv-1',
  fleet_id: 'fleet-1',
  origin_type: 'location',
  origin_x: 0,
  origin_y: 0,
  target_type: 'location',
  target_location_id: 'loc-slag',
  target_base_id: null,
  target_x: 10,
  target_y: 10,
  mission_type: 'expedition',
  status: 'moving',
  depart_at: '2020-01-01T00:00:00Z',
  arrive_at: '2999-01-01T00:00:00Z', // far future → formatCountdown returns a non-null "…m …s"
  travel_seconds: 100,
  travel_distance: 100,
  ...over,
})

const loc = (over: Partial<MapLocation> = {}): MapLocation => ({
  id: 'loc-haven',
  name: 'Haven Reach',
  location_type: 'trade_outpost',
  x: 0,
  y: 0,
  base_difficulty: 1,
  reward_tier: 1,
  activity_type: 'trade_visit',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  ...over,
})

const LOCS: MapLocation[] = [
  loc(),
  loc({ id: 'loc-slag', name: 'Slagworks', location_type: 'mining_site', activity_type: 'mine_resource' }),
  loc({ id: 'loc-den', name: 'Pirate Den', location_type: 'pirate_den', activity_type: 'hunt_pirates' }),
]

test('docked — present at a named location → "Docked at <name>"', () => {
  const r = resolveShipLocationLabel(fleet({ status: 'present', current_location_id: 'loc-haven' }), null, LOCS)
  expect(r.kind).toBe('docked')
  expect(r.label).toBe('Docked at Haven Reach')
  expect(r.etaText).toBeNull()
  expect(r.destination).toBe('Haven Reach')
})

test('in-transit — a moving expedition → "In transit to <name>" + a live eta', () => {
  const r = resolveShipLocationLabel(fleet({ status: 'moving' }), movement(), LOCS)
  expect(r.kind).toBe('in-transit')
  expect(r.label).toBe('In transit to Slagworks')
  expect(r.destination).toBe('Slagworks')
  expect(r.heading).toBe(false)
})

test('eta — the moving leg exposes a non-null countdown string the strip appends', () => {
  const r = resolveShipLocationLabel(fleet({ status: 'moving' }), movement(), LOCS)
  expect(r.etaText).not.toBeNull()
  expect(r.etaText).toMatch(/\d/) // e.g. "3m 12s" / "45s" — a real remaining-time value
})

test('deep space — present but at no named location → "In deep space"', () => {
  const r = resolveShipLocationLabel(fleet({ status: 'present', current_location_id: null }), null, LOCS)
  expect(r.kind).toBe('deep-space')
  expect(r.label).toBe('In deep space')
})

test('combat — present at a hunt/pirate site → "In combat at <name>"', () => {
  const r = resolveShipLocationLabel(fleet({ status: 'present', current_location_id: 'loc-den' }), null, LOCS)
  expect(r.kind).toBe('combat')
  expect(r.label).toBe('In combat at Pirate Den')
})

test('returning — a return-home movement → "Returning home" (no destination name)', () => {
  const r = resolveShipLocationLabel(
    fleet({ status: 'returning' }),
    movement({ mission_type: 'return_home', target_type: 'base', target_location_id: null }),
    LOCS,
  )
  expect(r.kind).toBe('returning')
  expect(r.label).toBe('Returning home')
  expect(r.heading).toBe(true)
  expect(r.etaText).not.toBeNull()
})

test('null / idle — no active fleet is a genuine idle/undeployed ship (no-home: never "home"), not a crash', () => {
  const r = resolveShipLocationLabel(null, null, LOCS)
  expect(r.kind).toBe('idle')
  expect(r.label).toBe('Idle')
  expect(r.label.toLowerCase()).not.toContain('home')
  expect(r.destination).toBeNull()
  expect(r.etaText).toBeNull()
})

test('fail closed — present at a HIDDEN location (absent from the map) → generic "Docked", no id leak', () => {
  const r = resolveShipLocationLabel(fleet({ status: 'present', current_location_id: 'hidden-x' }), null, LOCS)
  expect(r.kind).toBe('docked')
  expect(r.label).toBe('Docked')
  expect(r.label).not.toContain('hidden-x')
})

// ── S1 BERTH MODEL (0216) — resolveBerthedLocationLabel: a berthed ship is a DOCKED read ─────────
// The helper COMPOSES resolveShipLocationLabel (one implementation of "where is the ship"), so
// these cases pin that composition: named port → "Docked at <port>"; combat port inherits the
// combat wording; unknown port fails closed with no id leak; a null id degrades to deep space.

test('berthed — a berth at a named port reads "Docked at <port>" (kind docked)', () => {
  const r = resolveBerthedLocationLabel('loc-haven', LOCS)
  expect(r.kind).toBe('docked')
  expect(r.label).toBe('Docked at Haven Reach')
})

test('berthed — a berth at a combat port inherits the combat wording (resolver composition)', () => {
  const r = resolveBerthedLocationLabel('loc-den', LOCS)
  expect(r.kind).toBe('combat')
  expect(r.label).toBe('In combat at Pirate Den')
})

test('berthed — an unknown/hidden berth port fails closed to "Docked", never a leaked id', () => {
  const r = resolveBerthedLocationLabel('secret-port', LOCS)
  expect(r.kind).toBe('docked')
  expect(r.label).toBe('Docked')
  expect(r.label).not.toContain('secret-port')
})

test('berthed — a null berth id (shape-impossible server-side) degrades honestly, no crash, no invented port', () => {
  const r = resolveBerthedLocationLabel(null, LOCS)
  expect(r.kind).toBe('deep-space')
  expect(r.label).toBe('In deep space')
})
