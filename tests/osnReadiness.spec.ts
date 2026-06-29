import { test, expect } from '@playwright/test'
import {
  parseOsnReadiness,
  selectableDestinationIds,
  isPortNavActionable,
  isActiveLocationTargetTransit,
  isCoordinateTargetingActionable,
  OSN_NOT_ACTIONABLE,
  type OsnReadiness,
} from '../src/features/map/osnReadiness'

// PORT-LAUNCH-1B + OSN-COORD-ENABLE-1C — pure proofs for the dark port-to-port readiness/selection boundary
// AND the runtime coordinate-capability gate. No browser/DB/network. Run: `npm run verify:osn:port`.

const anchored = (eligible: string[], coordinateTravelAvailable = false): OsnReadiness => ({
  osnAvailable: true,
  originCategory: 'anchored',
  reason: 'none',
  eligibleDestinationIds: eligible,
  coordinateTravelAvailable,
})

// ── A. boundary validation: only the documented shape is actionable ────────────────────────────────────
test('parse: a well-formed anchored response is accepted verbatim', () => {
  const r = parseOsnReadiness({ origin_category: 'anchored', osn_available: true, reason: 'none', eligible_destination_ids: ['a', 'b'] })
  expect(r).toEqual({ osnAvailable: true, originCategory: 'anchored', reason: 'none', eligibleDestinationIds: ['a', 'b'], coordinateTravelAvailable: false })
})

test('parse: each documented category is accepted; unknown categories collapse to NOT_ACTIONABLE', () => {
  for (const c of ['anchored', 'not_anchored', 'in_transit', 'destroyed', 'no_ship']) {
    expect(parseOsnReadiness({ origin_category: c, osn_available: false, reason: null, eligible_destination_ids: [] }).originCategory).toBe(c)
  }
  expect(parseOsnReadiness({ origin_category: 'teleporting', osn_available: true, eligible_destination_ids: [] })).toEqual(OSN_NOT_ACTIONABLE)
})

test('parse: malformed / incomplete / wrong-typed payloads are NOT actionable (never throw, never leak)', () => {
  for (const bad of [null, undefined, 42, 'x', [], {}, { osn_available: 'yes', origin_category: 'anchored' }, { origin_category: 'anchored' }, { osn_available: true }]) {
    expect(parseOsnReadiness(bad as unknown)).toEqual(OSN_NOT_ACTIONABLE)
  }
})

test('parse: non-string ids in eligible list are dropped (defensive)', () => {
  const r = parseOsnReadiness({ origin_category: 'anchored', osn_available: true, reason: 'none', eligible_destination_ids: ['ok', 1, null, '', 'two'] })
  expect(r.eligibleDestinationIds).toEqual(['ok', 'two'])
})

// ── B. selection: server eligibility ∩ visible world-map − current dock ─────────────────────────────────
test('selectable: only ids that are BOTH server-eligible AND in the visible world map', () => {
  // 'p2' is server-eligible but NOT visible → excluded (F4). 'p9' is visible but NOT eligible → never enters (F5).
  const r = anchored(['p1', 'p2', 'p3'])
  const visible = new Set(['p1', 'p3', 'p9'])
  expect(selectableDestinationIds(r, visible, null)).toEqual(['p1', 'p3'])
})

test('selectable: the current docked location is always excluded, even if the server includes it (F/B5)', () => {
  const r = anchored(['home', 'p1'])
  expect(selectableDestinationIds(r, new Set(['home', 'p1']), 'home')).toEqual(['p1'])
})

test('selectable: de-duplicates while preserving order', () => {
  const r = anchored(['p1', 'p1', 'p2'])
  expect(selectableDestinationIds(r, new Set(['p1', 'p2']), null)).toEqual(['p1', 'p2'])
})

// ── C. render gate: nothing actionable unless available + anchored + ≥1 visible eligible ────────────────
test('actionable: true only when available + anchored + selectable>0', () => {
  expect(isPortNavActionable(anchored(['p1']), 1)).toBe(true)
})

test('actionable: false while loading / malformed / unavailable / not-anchored / no eligible (F1)', () => {
  expect(isPortNavActionable(OSN_NOT_ACTIONABLE, 0)).toBe(false) // loading/malformed default
  expect(isPortNavActionable({ osnAvailable: false, originCategory: 'anchored', reason: 'feature_disabled', eligibleDestinationIds: ['p1'], coordinateTravelAvailable: false }, 1)).toBe(false) // flag dark
  expect(isPortNavActionable({ osnAvailable: true, originCategory: 'not_anchored', reason: 'travel_to_port', eligibleDestinationIds: [], coordinateTravelAvailable: false }, 0)).toBe(false)
  expect(isPortNavActionable({ osnAvailable: true, originCategory: 'in_transit', reason: 'in_transit', eligibleDestinationIds: [], coordinateTravelAvailable: false }, 0)).toBe(false)
  expect(isPortNavActionable(anchored(['p1']), 0)).toBe(false) // anchored but none visible-eligible
})

// ── D. Stop reuse: location-target transit only (F8/F9) ─────────────────────────────────────────────────
test('location-target transit: true ONLY for an active location move (not space / not idle)', () => {
  expect(isActiveLocationTargetTransit({ spatialState: 'in_transit', spaceMovementStatus: 'moving', spaceMovementTargetKind: 'location' })).toBe(true)
  expect(isActiveLocationTargetTransit({ spatialState: 'in_transit', spaceMovementStatus: 'moving', spaceMovementTargetKind: 'space' })).toBe(false) // F9: not for coordinate routes
  expect(isActiveLocationTargetTransit({ spatialState: 'home', spaceMovementStatus: null, spaceMovementTargetKind: null })).toBe(false)
  expect(isActiveLocationTargetTransit({ spatialState: 'in_transit', spaceMovementStatus: 'arrived', spaceMovementTargetKind: 'location' })).toBe(false)
})

// ── E. OSN-COORD-ENABLE-1C — coordinate capability parsing (strict boolean, fail-closed) ─────────────────
test('parse: coordinate_travel_available=true parses as true', () => {
  const r = parseOsnReadiness({ origin_category: 'anchored', osn_available: true, reason: 'none', eligible_destination_ids: [], coordinate_travel_available: true })
  expect(r.coordinateTravelAvailable).toBe(true)
})

test('parse: missing / null / non-boolean coordinate_travel_available is fail-closed false (strict boolean only)', () => {
  // a well-formed payload that simply omits or mis-types the field → capability false, other fields intact
  for (const v of [undefined, null, 'true', 1, 0, 'false', {}, []]) {
    const raw: Record<string, unknown> = { origin_category: 'anchored', osn_available: true, reason: 'none', eligible_destination_ids: ['p1'] }
    if (v !== undefined) raw.coordinate_travel_available = v
    const r = parseOsnReadiness(raw)
    expect(r.coordinateTravelAvailable).toBe(false)
    expect(r.originCategory).toBe('anchored') // existing fields remain compatible / unaffected
    expect(r.eligibleDestinationIds).toEqual(['p1'])
  }
})

test('parse: an old payload predating the field stays compatible (capability false, nothing crashes)', () => {
  const r = parseOsnReadiness({ origin_category: 'not_anchored', osn_available: false, reason: 'travel_to_port', eligible_destination_ids: [] })
  expect(r).toEqual({ osnAvailable: false, originCategory: 'not_anchored', reason: 'travel_to_port', eligibleDestinationIds: [], coordinateTravelAvailable: false })
})

test('parse: a fully malformed payload fails closed (capability false via OSN_NOT_ACTIONABLE)', () => {
  expect(parseOsnReadiness({ osn_available: 'yes', coordinate_travel_available: true }).coordinateTravelAvailable).toBe(false)
  expect(parseOsnReadiness(null).coordinateTravelAvailable).toBe(false)
})

// ── F. runtime coordinate-target render gate — replaces the retired OSN_COORDINATE_TRAVEL_ENABLED const ───
test('coordinate gate: actionable ONLY when capability true AND movement enabled AND ship eligible', () => {
  expect(isCoordinateTargetingActionable(anchored([], true), true, 'eligible')).toBe(true)
})

test('coordinate gate: hidden when capability is false (even if enabled + eligible)', () => {
  expect(isCoordinateTargetingActionable(anchored([], false), true, 'eligible')).toBe(false)
  expect(isCoordinateTargetingActionable(OSN_NOT_ACTIONABLE, true, 'eligible')).toBe(false) // loading/fetch-failure default
})

test('coordinate gate: hidden when the movement domain is disabled (even if capability + eligible)', () => {
  expect(isCoordinateTargetingActionable(anchored([], true), false, 'eligible')).toBe(false)
})

test('coordinate gate: hidden for any non-eligible ship even if capability is true', () => {
  for (const e of ['no_ship', 'destroyed', 'in_transit', 'something_else']) {
    expect(isCoordinateTargetingActionable(anchored([], true), true, e)).toBe(false)
  }
})
