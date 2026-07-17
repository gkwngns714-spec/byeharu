import { test, expect } from '@playwright/test'
import {
  resolveSpaceTapOwner,
  fleetGoTargetView,
  fleetGoRpcTarget,
  classifyFleetCoordinateGo,
  fleetGoButtonLabel,
  fleetGoSuccessMessage,
  formatWorldPoint,
  type SpaceTapOwner,
} from '../src/features/map/fleetGoTarget'
import { canonicalizeWorldTarget, roundHalfAwayFromZero } from '../src/features/map/spaceMoveCommand'
import { isWithinOpenSpaceBounds } from '../src/features/map/openSpaceTransform'
import { buildCommandShipGroupGoArgs } from '../src/features/command/teamMove'
import type { UnifiedGroupFleetLite } from '../src/features/command/teamApi'

// FLEET-GO 4a-2 — pure specs for the fleet coordinate-go surface. No I/O, no clock, no DOM.
// Pins: (1) the tap-owner precedence (incl. the DARK-INERT law: flag false → NEVER 'fleet'),
// (2) the bounds/rounding mirror of 0208's coordinate arm (bounds on the RAW wire value,
// half-away-from-zero canonical PREVIEW — asserted AGAINST canonicalizeWorldTarget so the two
// mirrors cannot drift), (3) the go/redirect/already-here classifier, and (4) the RAW-COORDS law
// (the RPC payload is the tapped point, never the rounded preview).

// ── resolveSpaceTapOwner — who owns an open-space tap ────────────────────────────────────────────

test('unified lit + ≥1 group → the FLEET owns the tap (per-ship capability is irrelevant)', () => {
  expect(resolveSpaceTapOwner({ unifiedEnabled: true, hasGroups: true, perShipCanTarget: true })).toBe('fleet')
  // The fleet surface's ONLY gate is flag + groups — a per-ship canTarget=false must NOT block it
  // (canTarget is a per-SHIP capability; §2 says the ship is not the mover).
  expect(resolveSpaceTapOwner({ unifiedEnabled: true, hasGroups: true, perShipCanTarget: false })).toBe('fleet')
})

test('unified DARK → today’s behavior verbatim: per-ship exactly when canTarget, else none', () => {
  expect(resolveSpaceTapOwner({ unifiedEnabled: false, hasGroups: true, perShipCanTarget: true })).toBe('per_ship')
  expect(resolveSpaceTapOwner({ unifiedEnabled: false, hasGroups: true, perShipCanTarget: false })).toBe('none')
  expect(resolveSpaceTapOwner({ unifiedEnabled: false, hasGroups: false, perShipCanTarget: true })).toBe('per_ship')
  expect(resolveSpaceTapOwner({ unifiedEnabled: false, hasGroups: false, perShipCanTarget: false })).toBe('none')
})

test('unified lit + ZERO groups → per-ship path unchanged (no fleet exists to command)', () => {
  expect(resolveSpaceTapOwner({ unifiedEnabled: true, hasGroups: false, perShipCanTarget: true })).toBe('per_ship')
  expect(resolveSpaceTapOwner({ unifiedEnabled: true, hasGroups: false, perShipCanTarget: false })).toBe('none')
})

test('DARK-INERT LAW: with the flag false, NO input combination yields fleet — the fleet-go tree can never mount', () => {
  const owners: SpaceTapOwner[] = []
  for (const hasGroups of [true, false]) {
    for (const perShipCanTarget of [true, false]) {
      owners.push(resolveSpaceTapOwner({ unifiedEnabled: false, hasGroups, perShipCanTarget }))
    }
  }
  expect(owners).not.toContain('fleet')
})

// ── fleetGoTargetView — the bounds + rounding mirror of 0208’s coordinate arm ────────────────────

test('canonical preview agrees with canonicalizeWorldTarget on every sample (the two mirrors cannot drift)', () => {
  const samples = [
    { x: 0, y: 0 },
    { x: 0.5, y: -0.5 }, // halves round AWAY from zero: 1 / -1 (Postgres round(numeric))
    { x: 2.5, y: -2.5 }, // 3 / -3 — NOT banker’s rounding, NOT JS Math.round on the negative half
    { x: 3.49, y: -3.49 },
    { x: 9999.6, y: -9999.6 },
    { x: 123.456, y: -654.321 },
  ]
  for (const s of samples) {
    expect(fleetGoTargetView(s).canonical).toEqual(canonicalizeWorldTarget(s))
  }
  // and the underlying rule, explicitly (incl. the negative halves):
  expect(roundHalfAwayFromZero(0.5)).toBe(1)
  expect(roundHalfAwayFromZero(-0.5)).toBe(-1)
  expect(roundHalfAwayFromZero(2.5)).toBe(3)
  expect(roundHalfAwayFromZero(-2.5)).toBe(-3)
})

test('bounds mirror: ±10000 INCLUSIVE (0208 c_lo/c_hi), checked on the RAW point', () => {
  expect(fleetGoTargetView({ x: 10000, y: -10000 }).withinBounds).toBe(true)
  expect(fleetGoTargetView({ x: -10000, y: 10000 }).withinBounds).toBe(true)
  expect(fleetGoTargetView({ x: 10000.001, y: 0 }).withinBounds).toBe(false)
  expect(fleetGoTargetView({ x: 0, y: -10000.001 }).withinBounds).toBe(false)
  // The RAW point is what rides the wire, and 0208 bound-checks it BEFORE rounding (0208:257-261):
  // raw 10000.4 is target_out_of_bounds server-side even though its canonical preview is 10000.
  // A canonical-based client check would greenlight a doomed round-trip — pin the raw check.
  const edge = fleetGoTargetView({ x: 10000.4, y: 0 })
  expect(edge.canonical.x).toBe(10000)
  expect(edge.withinBounds).toBe(false)
  // agreement with the ONE bounds predicate (same inputs, same verdict — no second authority)
  expect(edge.withinBounds).toBe(isWithinOpenSpaceBounds({ x: 10000.4, y: 0 }))
})

test('non-finite taps are out of bounds (0208 invalid_coordinate; never sent)', () => {
  expect(fleetGoTargetView({ x: Number.NaN, y: 0 }).withinBounds).toBe(false)
  expect(fleetGoTargetView({ x: 0, y: Number.POSITIVE_INFINITY }).withinBounds).toBe(false)
  expect(fleetGoTargetView({ x: Number.NEGATIVE_INFINITY, y: 0 }).withinBounds).toBe(false)
})

// ── THE RAW-COORDS LAW — the wire carries the tapped point, never the preview ────────────────────

test('RAW-coords law: 3.5/-3.5 reach the RPC args as 3.5/-3.5 — never the rounded 4/-4', () => {
  const view = fleetGoTargetView({ x: 3.5, y: -3.5 })
  expect(view.canonical).toEqual({ x: 4, y: -4 }) // the PREVIEW rounds (half away from zero)…
  const args = buildCommandShipGroupGoArgs('group-1', fleetGoRpcTarget(view))
  expect(args).toEqual({ p_group_id: 'group-1', p_target_x: 3.5, p_target_y: -3.5 }) // …the WIRE does not
})

// ── classifyFleetCoordinateGo — what a go to this point IS ───────────────────────────────────────

const fleetRow = (patch: Partial<UnifiedGroupFleetLite>): UnifiedGroupFleetLite => ({
  group_id: 'group-1',
  status: 'idle',
  location_mode: 'base',
  current_location_id: null,
  space_x: null,
  space_y: null,
  ...patch,
})

test('no unified fleet row yet → go (bootstrap — 0208 creates the group’s fleet on first command)', () => {
  expect(classifyFleetCoordinateGo(null, { x: 10, y: 20 })).toBe('go')
})

test('a MOVING fleet → redirect (0208 cancels the live leg at its interpolated point)', () => {
  expect(classifyFleetCoordinateGo(fleetRow({ status: 'moving' }), { x: 10, y: 20 })).toBe('redirect')
  // moving wins even over stale equal parked coords — a live leg is never an already-here
  expect(
    classifyFleetCoordinateGo(
      fleetRow({ status: 'moving', location_mode: 'space', space_x: 10, space_y: 20 }),
      { x: 10, y: 20 },
    ),
  ).toBe('redirect')
})

test('parked in space at EXACTLY the canonical point → already_here (suppress a pointless no-op go; the server floors it to a harmless 5s trip, min_travel_seconds — it does not raise)', () => {
  expect(
    classifyFleetCoordinateGo(
      fleetRow({ status: 'idle', location_mode: 'space', space_x: 10, space_y: 20 }),
      { x: 10, y: 20 },
    ),
  ).toBe('already_here')
})

test('parked in space ELSEWHERE → go (a parked fleet departs again with no port involved — 3b’s closed model)', () => {
  expect(
    classifyFleetCoordinateGo(
      fleetRow({ status: 'idle', location_mode: 'space', space_x: 10, space_y: 21 }),
      { x: 10, y: 20 },
    ),
  ).toBe('go')
  // null coords in space mode (defensive) → never a spurious already-here
  expect(
    classifyFleetCoordinateGo(
      fleetRow({ status: 'idle', location_mode: 'space', space_x: null, space_y: null }),
      { x: 10, y: 20 },
    ),
  ).toBe('go')
})

test('present at a port → go (the mover launches from wherever the fleet is — §2)', () => {
  expect(
    classifyFleetCoordinateGo(
      fleetRow({ status: 'present', location_mode: 'location', current_location_id: 'port-1' }),
      { x: 10, y: 20 },
    ),
  ).toBe('go')
})

// ── copy helpers — redirect-aware, naming fleet + coordinate ─────────────────────────────────────

test('button copy: moving → "Redirect fleet here", otherwise "Send fleet here"', () => {
  expect(fleetGoButtonLabel('redirect')).toBe('Redirect fleet here')
  expect(fleetGoButtonLabel('go')).toBe('Send fleet here')
  expect(fleetGoButtonLabel('already_here')).toBe('Send fleet here') // unused (badge), but total
})

test('success copy names the fleet + the CANONICAL destination, redirect-aware from the SERVER envelope', () => {
  expect(
    fleetGoSuccessMessage({ fleetName: 'Fleet 1', shipCount: 3, canonical: { x: 120, y: -45 }, redirected: false }),
  ).toBe('Sent Fleet 1 — 3 ships — to (120, -45).')
  expect(
    fleetGoSuccessMessage({ fleetName: 'Fleet 1', shipCount: 1, canonical: { x: 4, y: -4 }, redirected: true }),
  ).toBe('Redirected Fleet 1 — 1 ship — to (4, -4).')
  // a missing member_count echo drops the segment, the line still reads whole
  expect(fleetGoSuccessMessage({ fleetName: 'Fleet 2', canonical: { x: 0, y: 0 }, redirected: false })).toBe(
    'Sent Fleet 2 to (0, 0).',
  )
  expect(formatWorldPoint({ x: -1, y: 2 })).toBe('(-1, 2)')
})
