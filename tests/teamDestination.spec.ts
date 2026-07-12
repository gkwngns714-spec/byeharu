import { test, expect } from '@playwright/test'
import { teamDestinationKind } from '../src/features/command/teamDestination'

// TEAM-MAP-SEND — pure unit proof for the ONE destination-kind classifier the map sheet's
// "Send a team here" section renders from. It REUSES sendableDestinations/huntableDestinations
// (whose own bands are proven in teamSend.spec.ts / teamCombat.spec.ts) — these tests assert only
// what is NEW: the single-location classification and its null (not-a-team-destination) band.
// Run: `npx playwright test teamDestination.spec.ts`.

const loc = (o: Partial<{ id: string; name: string; status: string; activity_type: string }> = {}) => ({
  id: 'l1',
  name: 'Haven',
  status: 'active',
  activity_type: 'none',
  ...o,
})

test('active + activity none → expedition (the safe team send)', () => {
  expect(teamDestinationKind(loc())).toBe('expedition')
})

test('active + hunt_pirates → hunt (the combat team send)', () => {
  expect(teamDestinationKind(loc({ activity_type: 'hunt_pirates' }))).toBe('hunt')
})

test('active non-none, non-hunt activities are NOT team destinations (null)', () => {
  for (const activity of ['trade_visit', 'mine_resource', 'explore_derelict', 'rally']) {
    expect(teamDestinationKind(loc({ activity_type: activity }))).toBe(null)
  }
})

test('non-active locations are never team destinations, whatever the activity (defensive status clause)', () => {
  expect(teamDestinationKind(loc({ status: 'inactive', activity_type: 'none' }))).toBe(null)
  expect(teamDestinationKind(loc({ status: 'inactive', activity_type: 'hunt_pirates' }))).toBe(null)
})
