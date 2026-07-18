import { test, expect } from '@playwright/test'
import {
  parseCommissionResult, derivePortEntryAffordance, commissionReasonMessage, COMMISSION_RPC,
  type PortEntryShipState,
} from '../src/features/portentry/portEntry'
import {
  createPortEntryController, type PortEntryCommandController,
} from '../src/features/portentry/portEntryCommand'

// PORT-ENTRY player UI — pure-logic unit tests (no browser, no DB, no network). Covers eligibility
// rendering (affordance), the fail-closed commission parser (success + every documented failure +
// malformed), player-facing copy, and the one-shot action controller (single-in-flight duplicate-click
// guard, successful-refresh hook, and failure/network handling). The server remains the authority in
// production; these prove the client only ever OFFERS the correct control and never fabricates a transition.
//
// 4C-CLIENT: the normalize (Finish Docking) arm + its parser/copy/affordance tests are DELETED with
// the extinct legacy_present state; the classifier is now pinned on the get_my_fleet_positions
// `place` projection instead of the retired main_ship_instances.spatial_state column.

// ── RPC name literal stays pinned to the deployed 0072 function ────────────────────────────────────────
test('rpc name is exactly the deployed PORT-ENTRY commission function', () => {
  expect(COMMISSION_RPC).toBe('commission_first_main_ship')
})

// ── Eligibility rendering: state → the single affordance (place-based, 4C-CLIENT) ──────────────────────
const base: PortEntryShipState = { hasShip: true, shipStatus: 'stationary', place: null }

test('affordance: null state → loading (never a premature action)', () => {
  expect(derivePortEntryAffordance(null)).toEqual({ kind: 'loading' })
})

test('affordance: no ship → commission (Claim First Ship)', () => {
  expect(derivePortEntryAffordance({ ...base, hasShip: false })).toEqual({ kind: 'commission' })
})

test('affordance: docked → docked (no action; ordinary dock experience)', () => {
  expect(derivePortEntryAffordance({ ...base, place: 'docked' })).toEqual({ kind: 'docked' })
})

test('affordance: berthed → docked too (berth-truth agrees with the Fitting/Port "Docked at …" read)', () => {
  expect(derivePortEntryAffordance({ ...base, place: 'berthed' })).toEqual({ kind: 'docked' })
})

test('affordance: transit → in_transit', () => {
  expect(derivePortEntryAffordance({ ...base, shipStatus: 'traveling', place: 'transit' })).toEqual({ kind: 'in_transit' })
})

test('affordance: in_space → unavailable(in_space)', () => {
  expect(derivePortEntryAffordance({ ...base, place: 'in_space' })).toEqual({ kind: 'unavailable', detail: 'in_space' })
})

test('affordance: hidden (idle/undeployed) → at_home (explain, no doomed button)', () => {
  expect(derivePortEntryAffordance({ ...base, shipStatus: 'home', place: 'hidden' })).toEqual({ kind: 'at_home' })
})

test('affordance: destroyed → unavailable(destroyed), even with no projection row (destroyed ships have none)', () => {
  expect(derivePortEntryAffordance({ ...base, shipStatus: 'destroyed', place: null })).toEqual({ kind: 'unavailable', detail: 'destroyed' })
  // and the status check wins over any (stale) place
  expect(derivePortEntryAffordance({ ...base, shipStatus: 'destroyed', place: 'docked' })).toEqual({ kind: 'unavailable', detail: 'destroyed' })
})

test('affordance: null/unknown place (projection unreadable) → fail-closed indeterminate, never a wrong claim', () => {
  expect(derivePortEntryAffordance({ ...base, place: null })).toEqual({ kind: 'unavailable', detail: 'indeterminate' })
  expect(derivePortEntryAffordance({ ...base, place: 'totally-new-place' })).toEqual({ kind: 'unavailable', detail: 'indeterminate' })
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

// ── Player-facing copy exists for every reason ─────────────────────────────────────────────────────────
test('reason copy is non-empty and never names the deleted Finish Docking button', () => {
  expect(commissionReasonMessage('needs_normalization').length).toBeGreaterThan(0)
  expect(commissionReasonMessage('needs_normalization')).not.toContain('Finish Docking')
  expect(commissionReasonMessage('needs_compat_route')).toContain('Travel to a port')
  expect(commissionReasonMessage('not_provisionable').length).toBeGreaterThan(0)
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
    onSettled: () => { settled += 1 },
  })
  await c.submit('commission')
  expect(c.getState().phase).toBe('success')
  expect(c.getState().kind).toBe('commission')
  expect(c.getState().message).toContain('Haven')
  expect(settled).toBe(1)
})

test('controller: DUPLICATE submit while in-flight is ignored (RPC called once, onSettled once)', async () => {
  let commissionCalls = 0
  let settled = 0
  const d = deferred<{ ok: true; created: boolean; docked: true; locationId: string | null }>()
  const c: PortEntryCommandController = createPortEntryController({
    commission: async () => { commissionCalls += 1; return d.promise },
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
    onSettled: () => { throw new Error('refresh failed') },
  })
  await c.submit('commission')
  expect(c.getState().phase).toBe('success')
})

test('controller: reset returns to idle', async () => {
  const c = createPortEntryController({
    commission: async () => ({ ok: true, created: true, docked: true, locationId: 'loc-1' }),
    onSettled: () => {},
  })
  await c.submit('commission')
  c.reset()
  expect(c.getState()).toEqual({ phase: 'idle', kind: null, message: null })
})
