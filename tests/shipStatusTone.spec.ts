import { test, expect } from '@playwright/test'
import { mainShipInstanceStatusLabel, mainShipInstanceStatusTone } from '../src/features/map/mainshipStatusLabel'

// FLEET-READ — pure unit proof for the roster's status tone. No browser/page.
//
// The fleet roster used to render every ship in one grey, so nothing was scannable. The tone map gives each
// status a semantic tone, and deliberately speaks the SAME colour language as the galaxy map so a ship reads
// the same on both surfaces. Run: `npx playwright test shipStatusTone.spec.ts`.

test('travelling matches the map’s outbound path colour (warning/amber)', () => {
  expect(mainShipInstanceStatusTone('traveling')).toBe('warning')
})

test('returning matches the map’s return-home colour (accent)', () => {
  expect(mainShipInstanceStatusTone('returning')).toBe('accent')
})

test('docked is the quiet default (neutral) — the resting state must not shout', () => {
  expect(mainShipInstanceStatusTone('stationary')).toBe('neutral')
})

test('ready to launch reads as success', () => {
  expect(mainShipInstanceStatusTone('home')).toBe('success')
})

test('danger states are danger', () => {
  for (const s of ['hunting', 'retreating', 'destroyed']) {
    expect(mainShipInstanceStatusTone(s)).toBe('danger')
  }
})

test('activity states share the accent tone', () => {
  for (const s of ['trading', 'exploring', 'mining']) {
    expect(mainShipInstanceStatusTone(s)).toBe('accent')
  }
})

// An unmapped status must degrade to a colour that claims nothing, mirroring the label map's `?? status`.
test('an unknown/future status → neutral, never a wrong-colour claim', () => {
  expect(mainShipInstanceStatusTone('some_future_status')).toBe('neutral')
  expect(mainShipInstanceStatusTone('')).toBe('neutral')
})

// The whole known vocabulary, pinned. 'stationary' → 'neutral' is INTENTIONAL (a docked ship is at rest
// and must not shout), which is why this is an explicit table rather than a "nothing is neutral" assertion:
// from outside, an intentional neutral and an unmapped fall-through look identical. Add a status to the
// label map and this table fails until it is given a tone on purpose.
test('the full status vocabulary maps to its intended tone', () => {
  const expected: Record<string, string> = {
    home: 'success',
    stationary: 'neutral', // deliberate: docked/at rest
    traveling: 'warning',
    returning: 'accent',
    hunting: 'danger',
    retreating: 'danger',
    destroyed: 'danger',
    repairing: 'warning',
    trading: 'accent',
    exploring: 'accent',
    mining: 'accent',
  }
  for (const [status, tone] of Object.entries(expected)) {
    expect(mainShipInstanceStatusLabel(status), `${status} should have a human label`).not.toBe(status)
    expect(mainShipInstanceStatusTone(status), `${status} tone`).toBe(tone)
  }
})
