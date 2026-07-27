import { test, expect } from '@playwright/test'
import {
  readFleetOrderOutcome,
  routeOrderOutcomeMessage,
  fleetGoOrderOutcomeMessage,
} from '../src/features/command/fleetOrderOutcome'

// INTERCEPT DEFERRED ENTRY — pure specs for the ONE authority over command_ship_group_go's
// order_outcome. No I/O, no clock. The fixtures are literal RPC envelopes from each of the THREE
// servers this client must be correct against, because it deploys via Pages independently of any
// migration: today's server (no order_outcome), the migration deployed with the flag OFF, and the
// flag ON.

// ── (a) TODAY'S SERVER — the migration is not deployed. No order_outcome at all. ───────────────────

test('DEGRADE (a): an envelope with no order_outcome and no intercepted reads as a started movement', () => {
  expect(readFleetOrderOutcome({})).toBe('movement_started')
  expect(routeOrderOutcomeMessage({})).toBe('Route sent — fleet underway.')
  expect(fleetGoOrderOutcomeMessage({}, 'Fleet 1')).toBeNull()
})

test('DEGRADE (a): today\'s successful order — intercepted:false — still reads as a started movement', () => {
  const today = { intercepted: false, intercept_encounter_id: null, movement_id: 'mv-1', redirected: false }
  expect(readFleetOrderOutcome(today)).toBe('movement_started')
  expect(routeOrderOutcomeMessage(today)).toBe('Route sent — fleet underway.')
  expect(fleetGoOrderOutcomeMessage(today, 'Fleet 1')).toBeNull()
})

test('DEGRADE (a): today\'s ORDER-TIME ambush — intercepted:true — is a real fight, so combat_started', () => {
  // On the legacy immediate path the RPC genuinely cancelled its own leg and stood the fleet in a
  // fight. `intercepted:true` is therefore a TRUE statement about combat that has already started —
  // not a prediction — and mapping it to combat_started keeps today's server honestly reported.
  const ambushed = { intercepted: true, intercept_encounter_id: 'enc-9' }
  expect(readFleetOrderOutcome(ambushed)).toBe('combat_started')
  expect(routeOrderOutcomeMessage(ambushed)).toBe('Route sent — combat started.')
  expect(fleetGoOrderOutcomeMessage(ambushed, 'Fleet 1')).toBe('Fleet 1 is in combat — no journey started.')
})

// ── (b) MIGRATION DEPLOYED, FLAG OFF — both fields present and agreeing. ──────────────────────────

test('DARK ROLLOUT (b): order_outcome and the legacy intercepted agree — movement', () => {
  const env = { order_outcome: 'movement_started', movement_id: 'mv-2', movement_eta: '2026-07-27T00:00:00Z', encounter_id: null, intercepted: false, intercept_encounter_id: null }
  expect(readFleetOrderOutcome(env)).toBe('movement_started')
  expect(routeOrderOutcomeMessage(env)).toBe('Route sent — fleet underway.')
  expect(fleetGoOrderOutcomeMessage(env, 'Fleet 2')).toBeNull()
})

test('DARK ROLLOUT (b): order_outcome and the legacy intercepted agree — combat on the legacy path', () => {
  const env = { order_outcome: 'combat_started', movement_id: null, encounter_id: 'enc-3', intercepted: true, intercept_encounter_id: 'enc-3' }
  expect(readFleetOrderOutcome(env)).toBe('combat_started')
  expect(routeOrderOutcomeMessage(env)).toBe('Route sent — combat started.')
  expect(fleetGoOrderOutcomeMessage(env, 'Fleet 2')).toBe('Fleet 2 is in combat — no journey started.')
})

// ── (c) FLAG ON — the ambush is deferred; the order can only ever have started a movement. ────────

test('DEFERRED (c): flag on — order_outcome wins and no ambush is claimed at order time', () => {
  const env = { order_outcome: 'movement_started', movement_id: 'mv-3', movement_eta: '2026-07-27T00:05:00Z', encounter_id: null, intercepted: false, intercept_encounter_id: null }
  expect(readFleetOrderOutcome(env)).toBe('movement_started')
  expect(routeOrderOutcomeMessage(env)).toBe('Route sent — fleet underway.')
})

test('PRECEDENCE: order_outcome always beats a contradicting legacy intercepted, in BOTH directions', () => {
  // The dark-rollout server is the authority on its own transaction; the legacy field is only a
  // fallback. If the two ever disagree, order_outcome is what happened.
  expect(readFleetOrderOutcome({ order_outcome: 'movement_started', intercepted: true })).toBe('movement_started')
  expect(readFleetOrderOutcome({ order_outcome: 'combat_started', intercepted: false })).toBe('combat_started')
})

// ── Robustness: a value we do not recognise must never blank or invent the player's confirmation. ──

test('an UNRECOGNISED order_outcome falls back to the legacy field, then to movement_started', () => {
  expect(readFleetOrderOutcome({ order_outcome: 'something_new' })).toBe('movement_started')
  expect(readFleetOrderOutcome({ order_outcome: 'something_new', intercepted: true })).toBe('combat_started')
  expect(routeOrderOutcomeMessage({ order_outcome: 'something_new' })).toBe('Route sent — fleet underway.')
})

test('non-boolean / junk values are compared, never coerced — only a literal true means combat', () => {
  expect(readFleetOrderOutcome({ intercepted: 'true' })).toBe('movement_started')
  expect(readFleetOrderOutcome({ intercepted: 1 })).toBe('movement_started')
  expect(readFleetOrderOutcome({ intercepted: null })).toBe('movement_started')
  expect(readFleetOrderOutcome({ order_outcome: null, intercepted: undefined })).toBe('movement_started')
})

test('the ROUTE surface always returns a line — the player pressed Send and must be told something', () => {
  for (const env of [{}, { intercepted: true }, { order_outcome: 'movement_started' }, { order_outcome: 'combat_started' }, { order_outcome: 42 }]) {
    expect(routeOrderOutcomeMessage(env).length).toBeGreaterThan(0)
  }
})

test('the deleted claim is GONE: no arm of this authority can produce the old first-leg ambush copy', () => {
  const envelopes = [{}, { intercepted: true }, { intercepted: false }, { order_outcome: 'combat_started' }, { order_outcome: 'movement_started' }]
  for (const env of envelopes) {
    expect(routeOrderOutcomeMessage(env)).not.toContain('first leg')
    expect(routeOrderOutcomeMessage(env)).not.toContain('ambush')
    expect(fleetGoOrderOutcomeMessage(env, 'Fleet 1') ?? '').not.toContain('ambush')
  }
})

test('NO PREDICTED AMBUSH: a pending/predicted field is ignored outright, never rendered', () => {
  // ChatGPT's explicit constraint — a planned ambush is an unrolled future random result. Even if a
  // server were to volunteer one, this client must not turn it into copy.
  const leaky = { order_outcome: 'movement_started', intercept_pending: true, predicted_ambush: true, predicted_encounter_id: 'enc-future' }
  expect(readFleetOrderOutcome(leaky)).toBe('movement_started')
  expect(routeOrderOutcomeMessage(leaky)).toBe('Route sent — fleet underway.')
  expect(fleetGoOrderOutcomeMessage(leaky, 'Fleet 1')).toBeNull()
})

test('the fleet-command override names the fleet and yields null for an ordinary movement', () => {
  expect(fleetGoOrderOutcomeMessage({ order_outcome: 'combat_started' }, 'Vanguard')).toBe(
    'Vanguard is in combat — no journey started.',
  )
  expect(fleetGoOrderOutcomeMessage({ order_outcome: 'movement_started' }, 'Vanguard')).toBeNull()
})
