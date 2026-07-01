import { test, expect } from '@playwright/test'
import {
  parseCommissionResult, parseNormalizeResult, derivePortEntryAffordance,
  commissionReasonMessage, normalizeReasonMessage, COMMISSION_RPC, NORMALIZE_RPC,
  type PortEntryShipState,
} from '../src/features/portentry/portEntry'
import {
  createPortEntryController, type PortEntryCommandController,
} from '../src/features/portentry/portEntryCommand'

// PORT-ENTRY player UI — pure-logic unit tests (no browser, no DB, no network). Covers eligibility
// rendering (affordance), the fail-closed RPC-result parsers (success + every documented failure +
// malformed), player-facing copy, and the one-shot action controller (single-in-flight duplicate-click
// guard, successful-refresh hook, and failure/network handling). The server remains the authority in
// production; these prove the client only ever OFFERS the correct control and never fabricates a transition.

// ── RPC name literals stay pinned to the deployed 0072 functions ───────────────────────────────────────
test('rpc names are exactly the deployed PORT-ENTRY functions', () => {
  expect(COMMISSION_RPC).toBe('commission_first_main_ship')
  expect(NORMALIZE_RPC).toBe('normalize_main_ship_dock')
})

// ── Eligibility rendering: state → the single affordance ───────────────────────────────────────────────
const base: PortEntryShipState = {
  hasShip: true, spatialState: null, shipStatus: 'home', fleetStatus: null, fleetLocationMode: null, hasActivePresence: false,
}

test('affordance: null state → loading (never a premature action)', () => {
  expect(derivePortEntryAffordance(null)).toEqual({ kind: 'loading' })
})

test('affordance: no ship → commission (Claim First Ship)', () => {
  expect(derivePortEntryAffordance({ ...base, hasShip: false })).toEqual({ kind: 'commission' })
})

test('affordance: canonical at_location → docked (no action)', () => {
  expect(derivePortEntryAffordance({ ...base, spatialState: 'at_location', shipStatus: 'stationary' })).toEqual({ kind: 'docked' })
})

test('affordance: canonical in_transit → in_transit', () => {
  expect(derivePortEntryAffordance({ ...base, spatialState: 'in_transit', shipStatus: 'traveling' })).toEqual({ kind: 'in_transit' })
})

test('affordance: canonical in_space → unavailable(in_space)', () => {
  expect(derivePortEntryAffordance({ ...base, spatialState: 'in_space', shipStatus: 'stationary' })).toEqual({ kind: 'unavailable', detail: 'in_space' })
})

test('affordance: canonical home → at_home (explain, no doomed button)', () => {
  expect(derivePortEntryAffordance({ ...base, spatialState: 'home', shipStatus: 'home' })).toEqual({ kind: 'at_home' })
})

test('affordance: destroyed → unavailable(destroyed)', () => {
  expect(derivePortEntryAffordance({ ...base, shipStatus: 'destroyed' })).toEqual({ kind: 'unavailable', detail: 'destroyed' })
  expect(derivePortEntryAffordance({ ...base, spatialState: 'destroyed' })).toEqual({ kind: 'unavailable', detail: 'destroyed' })
})

test('affordance: legacy_present (coherent) → normalize (Finish Docking)', () => {
  expect(derivePortEntryAffordance({
    ...base, spatialState: null, shipStatus: 'stationary', fleetStatus: 'present', fleetLocationMode: 'location', hasActivePresence: true,
  })).toEqual({ kind: 'normalize' })
})

test('affordance: legacy present but INCOHERENT (no active presence) → unavailable, NOT a normalize button', () => {
  expect(derivePortEntryAffordance({
    ...base, fleetStatus: 'present', fleetLocationMode: 'location', hasActivePresence: false,
  })).toEqual({ kind: 'unavailable', detail: 'indeterminate' })
  // present but not at a named-location mode → also not normalizable
  expect(derivePortEntryAffordance({
    ...base, fleetStatus: 'present', fleetLocationMode: 'movement', hasActivePresence: true,
  })).toEqual({ kind: 'unavailable', detail: 'indeterminate' })
})

test('affordance: legacy in-flight (moving/returning) → in_transit', () => {
  expect(derivePortEntryAffordance({ ...base, fleetStatus: 'moving' })).toEqual({ kind: 'in_transit' })
  expect(derivePortEntryAffordance({ ...base, fleetStatus: 'returning' })).toEqual({ kind: 'in_transit' })
})

test('affordance: legacy_home (idle, no fleet) → at_home', () => {
  expect(derivePortEntryAffordance({ ...base, fleetStatus: null })).toEqual({ kind: 'at_home' })
})

// ── Commission parser: success + every documented failure + malformed ──────────────────────────────────
test('parseCommission: created (A) → ok/created/docked/locationId', () => {
  expect(parseCommissionResult({ ok: true, created: true, docked: true, location_id: 'loc-1' }))
    .toEqual({ ok: true, created: true, docked: true, locationId: 'loc-1' })
})

test('parseCommission: already provisioned (B/C) → ok, created:false, keeps dock id', () => {
  expect(parseCommissionResult({ ok: true, created: false, already_provisioned: true, docked: true, location_id: 'loc-9' }))
    .toEqual({ ok: true, created: false, docked: true, locationId: 'loc-9' })
})

test('parseCommission: success with null/absent location_id → locationId null (never throws)', () => {
  expect(parseCommissionResult({ ok: true, created: true, location_id: null }))
    .toEqual({ ok: true, created: true, docked: true, locationId: null })
})

test('parseCommission: documented failure reasons pass through (+state)', () => {
  expect(parseCommissionResult({ ok: false, reason: 'needs_normalization' })).toEqual({ ok: false, reason: 'needs_normalization', state: null })
  expect(parseCommissionResult({ ok: false, reason: 'needs_compat_route' })).toEqual({ ok: false, reason: 'needs_compat_route', state: null })
  expect(parseCommissionResult({ ok: false, reason: 'not_authenticated' })).toEqual({ ok: false, reason: 'not_authenticated', state: null })
  expect(parseCommissionResult({ ok: false, reason: 'commission_unavailable' })).toEqual({ ok: false, reason: 'commission_unavailable', state: null })
  expect(parseCommissionResult({ ok: false, reason: 'not_provisionable', state: 'in_space' })).toEqual({ ok: false, reason: 'not_provisionable', state: 'in_space' })
})

test('parseCommission: malformed / unknown → fail-closed malformed', () => {
  for (const bad of [null, undefined, 42, 'x', [], {}, { ok: 'yes' }, { ok: false }, { ok: false, reason: 'weird' }]) {
    expect(parseCommissionResult(bad)).toEqual({ ok: false, reason: 'malformed' })
  }
})

// ── Normalize parser: success + failures + malformed ───────────────────────────────────────────────────
test('parseNormalize: did-work vs idempotent-noop', () => {
  expect(parseNormalizeResult({ ok: true, normalized: true, location_id: 'loc-1' })).toEqual({ ok: true, normalized: true, locationId: 'loc-1' })
  expect(parseNormalizeResult({ ok: true, normalized: false })).toEqual({ ok: true, normalized: false, locationId: null })
})

test('parseNormalize: documented failures (+state) and malformed', () => {
  expect(parseNormalizeResult({ ok: false, reason: 'not_normalizable', state: 'home' })).toEqual({ ok: false, reason: 'not_normalizable', state: 'home' })
  expect(parseNormalizeResult({ ok: false, reason: 'ineligible_port' })).toEqual({ ok: false, reason: 'ineligible_port', state: null })
  expect(parseNormalizeResult({ ok: false, reason: 'no_ship' })).toEqual({ ok: false, reason: 'no_ship', state: null })
  for (const bad of [null, {}, { ok: false, reason: 'nope' }]) {
    expect(parseNormalizeResult(bad)).toEqual({ ok: false, reason: 'malformed' })
  }
})

// ── Player-facing copy exists for every reason ─────────────────────────────────────────────────────────
test('reason copy is non-empty and distinct per surface', () => {
  expect(commissionReasonMessage('needs_normalization')).toContain('Finish Docking')
  expect(commissionReasonMessage('needs_compat_route')).toContain('home base')
  expect(normalizeReasonMessage('ineligible_port').length).toBeGreaterThan(0)
  expect(normalizeReasonMessage('no_ship').length).toBeGreaterThan(0)
})

// ── One-shot controller: helpers ───────────────────────────────────────────────────────────────────────
function deferred<T>() {
  let resolve!: (v: T) => void
  let reject!: (e: unknown) => void
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej })
  return { promise, resolve, reject }
}

test('controller: successful commission → success phase + onSettled called exactly once', async () => {
  let settled = 0
  const c = createPortEntryController({
    commission: async () => ({ ok: true, created: true, docked: true, locationId: 'loc-1' }),
    normalize: async () => ({ ok: false, reason: 'no_ship' }),
    onSettled: () => { settled += 1 },
  })
  await c.submit('commission')
  expect(c.getState().phase).toBe('success')
  expect(c.getState().kind).toBe('commission')
  expect(c.getState().message).toContain('Haven Reach')
  expect(settled).toBe(1)
})

test('controller: successful normalize → success + onSettled once', async () => {
  let settled = 0
  const c = createPortEntryController({
    commission: async () => ({ ok: false, reason: 'commission_unavailable' }),
    normalize: async () => ({ ok: true, normalized: true, locationId: 'loc-2' }),
    onSettled: () => { settled += 1 },
  })
  await c.submit('normalize')
  expect(c.getState().phase).toBe('success')
  expect(settled).toBe(1)
})

test('controller: DUPLICATE submit while in-flight is ignored (RPC called once, onSettled once)', async () => {
  let commissionCalls = 0
  let settled = 0
  const d = deferred<{ ok: true; created: boolean; docked: true; locationId: string | null }>()
  const c: PortEntryCommandController = createPortEntryController({
    commission: async () => { commissionCalls += 1; return d.promise },
    normalize: async () => ({ ok: false, reason: 'no_ship' }),
    onSettled: () => { settled += 1 },
  })
  const first = c.submit('commission')
  expect(c.getState().phase).toBe('submitting')
  // second click while the first is still in flight — must be a no-op
  await c.submit('commission')
  expect(commissionCalls).toBe(1)
  d.resolve({ ok: true, created: true, docked: true, locationId: 'loc-1' })
  await first
  expect(c.getState().phase).toBe('success')
  expect(commissionCalls).toBe(1)
  expect(settled).toBe(1)
})

test('controller: server rejection → error phase with reason copy, onSettled NOT called', async () => {
  let settled = 0
  const c = createPortEntryController({
    commission: async () => ({ ok: false, reason: 'not_provisionable', state: 'in_space' }),
    normalize: async () => ({ ok: false, reason: 'no_ship' }),
    onSettled: () => { settled += 1 },
  })
  await c.submit('commission')
  expect(c.getState().phase).toBe('error')
  expect(c.getState().message).toBe(commissionReasonMessage('not_provisionable'))
  expect(settled).toBe(0)
})

test('controller: network throw → error phase (idempotent retry safe), onSettled NOT called', async () => {
  let settled = 0
  const c = createPortEntryController({
    commission: async () => { throw new Error('offline') },
    normalize: async () => ({ ok: false, reason: 'no_ship' }),
    onSettled: () => { settled += 1 },
  })
  await c.submit('commission')
  expect(c.getState().phase).toBe('error')
  expect(c.getState().message).toContain('Could not reach the server')
  expect(settled).toBe(0)
})

test('controller: a successful onSettled that throws still leaves phase=success (refresh never demotes success)', async () => {
  const c = createPortEntryController({
    commission: async () => ({ ok: true, created: true, docked: true, locationId: 'loc-1' }),
    normalize: async () => ({ ok: false, reason: 'no_ship' }),
    onSettled: () => { throw new Error('refresh failed') },
  })
  await c.submit('commission')
  expect(c.getState().phase).toBe('success')
})

test('controller: reset returns to idle', async () => {
  const c = createPortEntryController({
    commission: async () => ({ ok: true, created: true, docked: true, locationId: 'loc-1' }),
    normalize: async () => ({ ok: false, reason: 'no_ship' }),
    onSettled: () => {},
  })
  await c.submit('commission')
  c.reset()
  expect(c.getState()).toEqual({ phase: 'idle', kind: null, message: null })
})
