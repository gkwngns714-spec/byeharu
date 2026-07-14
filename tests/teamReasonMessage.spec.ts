import { test, expect } from '@playwright/test'
import { teamReasonMessage } from '../src/features/command/teamReasonMessage'

// TEAM-MAP-SEND — pure unit proof for the fail-closed team reason→message map (the
// tradeReasonMessage.spec.ts idiom). Every mapped server reason — the reject vocabularies of
// send_ship_group_expedition (0163), send_ship_group_hunt (0168), move_ship_group_to_location
// (0190), and the preview/totals reads (0165/0166) — yields specific player-facing text; any
// unmapped/unknown reason (incl. the teamApi transport 'unavailable' fallback) hits the generic
// "Team order unavailable." — never a raw code.
// Run: `npx playwright test teamReasonMessage.spec.ts`.

const FALLBACK = 'Fleet order unavailable.'

test('every known team-RPC reject reason maps to specific player text (not the fallback, never the raw code)', () => {
  const known = [
    // shared prefix (0163/0165/0166/0168/0190)
    'team_command_disabled',
    'not_authenticated',
    'group_not_found',
    'empty_group',
    // expedition send (0163) + docked-team move (0190) — the all-or-nothing member loops
    'member_send_failed',
    // hunt send (0168)
    'invalid_location',
    // shared readiness reject: hunt (0168) + docked-team move (0190)
    'member_not_ready',
    'fleet_limit_reached',
    'stats_invalid',
    'power_below_required',
    'no_home_base',
    // preview/totals reads (0165/0166)
    'invalid_activity',
  ]
  for (const reason of known) {
    const msg = teamReasonMessage(reason)
    expect(msg).not.toBe(FALLBACK)
    expect(msg).not.toContain(reason) // player copy, never the raw code
    expect(msg.length).toBeGreaterThan(10)
  }
})

test('an unmapped/unknown reason (incl. the transport fallback) hits the generic fallback', () => {
  expect(teamReasonMessage('some_unknown_reason')).toBe(FALLBACK)
  expect(teamReasonMessage('unavailable')).toBe(FALLBACK)
  expect(teamReasonMessage('')).toBe(FALLBACK)
})
