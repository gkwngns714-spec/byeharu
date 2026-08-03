import { test, expect } from '@playwright/test'
import { repairReasonMessage } from '../src/features/ship/repairReasonMessage'

// ONE WAY TO REPAIR — specs for THE pure reason→message map (repair_ship_hull, migration 0335).
// Every server reject string maps to non-empty player text; the transport fallback 'unavailable' and
// any unknown code degrade to the generic line (never a raw code, never a throw). The
// salvageReasonMessage mold. Run: `npx playwright test repairReasonMessage.spec.ts`.

// The COMPLETE 0335 reject vocabulary. There is exactly one repair verb now, so this list is the
// whole surface — if the server grows a reason and this list does not, the "distinct" assertion
// below is what catches the missing copy.
const REASONS = [
  'repair_economy_disabled',
  'not_authenticated',
  'invalid_request',
  'invalid_amount',
  'ship_not_found',
  'not_at_port',
  'nothing_to_repair',
  'hull_unrepairable',
  'repair_misconfigured',
  'insufficient_credits',
]

test('every 0335 server reason maps to a distinct non-empty message', () => {
  const seen = new Set<string>()
  for (const r of REASONS) {
    const msg = repairReasonMessage(r)
    expect(msg.length).toBeGreaterThan(0)
    expect(msg).not.toBe('Repair unavailable.') // each known reason has its OWN copy
    expect(msg).not.toContain('_') // no snake_case code ever leaks to the screen
    seen.add(msg)
  }
  expect(seen.size).toBe(REASONS.length) // all distinct
})

test('the retired vocabularies are GONE — one verb, one set of reasons', () => {
  // 0201's destroyed-seam reject and its dock reject both disappeared with the second function:
  // a wreck is no longer refused (it is recovered) and position has one name. If either came back
  // it would mean a second repair path had been re-introduced.
  expect(repairReasonMessage('ship_destroyed')).toBe('Repair unavailable.')
  expect(repairReasonMessage('not_docked')).toBe('Repair unavailable.')
})

test('the transport fallback + unknown codes degrade to the generic line (no raw code, no throw)', () => {
  expect(repairReasonMessage('unavailable')).toBe('Repair unavailable.')
  expect(repairReasonMessage('totally_unknown_code')).toBe('Repair unavailable.')
  expect(repairReasonMessage('')).toBe('Repair unavailable.')
})
