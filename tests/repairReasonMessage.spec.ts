import { test, expect } from '@playwright/test'
import { repairReasonMessage } from '../src/features/port/repairReasonMessage'

// REPAIR-ECON — specs for the pure reason→message map (repair_ship_hull_at_port, migration 0201). Every
// server reject string maps to non-empty player text; the transport fallback 'unavailable' and any
// unknown code degrade to the generic line (never a raw code, never a throw). The salvageReasonMessage
// mold. Run: `npx playwright test repairReasonMessage.spec.ts`.

test('every 0201 server reason maps to a distinct non-empty message', () => {
  const reasons = [
    'repair_economy_disabled',
    'not_authenticated',
    'invalid_request',
    'invalid_amount',
    'ship_not_found',
    'ship_destroyed',
    'not_docked',
    'nothing_to_repair',
    'repair_misconfigured',
    'insufficient_credits',
  ]
  const seen = new Set<string>()
  for (const r of reasons) {
    const msg = repairReasonMessage(r)
    expect(msg.length).toBeGreaterThan(0)
    expect(msg).not.toBe('Repair unavailable.') // each known reason has its OWN copy
    seen.add(msg)
  }
  expect(seen.size).toBe(reasons.length) // all distinct
})

test('the destroyed-seam message points to the FREE recovery (not the paid desk)', () => {
  expect(repairReasonMessage('ship_destroyed').toLowerCase()).toContain('free')
})

test('the transport fallback + unknown codes degrade to the generic line (no raw code, no throw)', () => {
  expect(repairReasonMessage('unavailable')).toBe('Repair unavailable.')
  expect(repairReasonMessage('totally_unknown_code')).toBe('Repair unavailable.')
  expect(repairReasonMessage('')).toBe('Repair unavailable.')
})
