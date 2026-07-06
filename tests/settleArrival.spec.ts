import { test, expect } from '@playwright/test'
import {
  SETTLE_ARRIVAL_RPC,
  LEGACY_SETTLE_ARRIVAL_RPC,
  parseSettleArrivalResult,
  computeSettleDelayMs,
} from '../src/features/map/settleArrival'

// UX-CLEANUP item 6 (part A) — pure proofs for the on-demand OSN arrival-settle client surface.
// No browser/page/DB. The SERVER (command_main_ship_settle_arrival, 0150) is the sole authority; these
// prove the client only fires at the right moment and never fabricates a settled state from a bad payload.

test('item 6: the settle RPC names are pinned to the deployed functions', () => {
  expect(SETTLE_ARRIVAL_RPC).toBe('command_main_ship_settle_arrival')
  expect(LEGACY_SETTLE_ARRIVAL_RPC).toBe('command_main_ship_settle_arrival_legacy')
})

test('item 6: parseSettleArrivalResult accepts exactly the server envelope, fail-closed otherwise', () => {
  // Settled outcomes — OSN (docked / Dock-0 deterministic terminal / in-space arrival) AND
  // legacy (present at location / completed home / defensive failed).
  for (const outcome of ['docked', 'terminal', 'arrived', 'present', 'completed', 'failed']) {
    expect(parseSettleArrivalResult({ ok: true, settled: true, outcome })).toEqual({ ok: true, settled: true, outcome })
  }
  // Safe no-ops.
  for (const reason of ['busy', 'not_due', 'no_active_movement', 'already_settled']) {
    expect(parseSettleArrivalResult({ ok: true, settled: false, reason })).toEqual({ ok: true, settled: false, reason })
  }
  // Rejections pass the reason through.
  expect(parseSettleArrivalResult({ ok: false, reason: 'feature_disabled' })).toEqual({ ok: false, reason: 'feature_disabled' })
  // Anything unrecognized fails closed — never a fabricated settlement.
  for (const bad of [null, 7, [], {}, { ok: true }, { ok: true, settled: true, outcome: 'warp' }, { ok: true, settled: false, reason: '??' }, { ok: false }]) {
    const res = parseSettleArrivalResult(bad)
    expect(res.ok === false || (res.ok === true && res.settled === false)).toBe(true)
    if (res.ok === false) expect(res.reason.length).toBeGreaterThan(0)
  }
})

test('item 6: computeSettleDelayMs — fires at arrive_at, immediately when due, never without a real transit', () => {
  const now = Date.parse('2026-07-05T12:00:00Z')
  // Future arrival → the exact remaining delay (the hook adds its own small epsilon).
  expect(computeSettleDelayMs({ status: 'moving', arrive_at: '2026-07-05T12:00:10Z' }, now)).toBe(10_000)
  // Already due → 0 (fire now).
  expect(computeSettleDelayMs({ status: 'moving', arrive_at: '2026-07-05T11:59:00Z' }, now)).toBe(0)
  // No movement / not moving / unparseable timestamp → nothing to schedule (cron remains the backstop).
  expect(computeSettleDelayMs(null, now)).toBe(null)
  expect(computeSettleDelayMs(undefined, now)).toBe(null)
  expect(computeSettleDelayMs({ status: 'arrived', arrive_at: '2026-07-05T12:00:10Z' }, now)).toBe(null)
  expect(computeSettleDelayMs({ status: 'moving', arrive_at: 'not-a-date' }, now)).toBe(null)
})
