import { test, expect } from '@playwright/test'
import { retreatErrorMessage, fleeErrorMessage } from '../src/features/combat/combatReasonMessage'

// 0307 — COMBAT REJECT COPY: pure mapper unit tests (the teamReasonMessage.spec idiom). The two
// combat-time verbs used to surface raw Postgres text: a double-pressed Retreat rendered
// `request_retreat: presence not active (is retreating)` verbatim and a raced Flee rendered the
// bare token `no_pending`. Both vocabularies are enumerated FROM THE SERVER SOURCE —
// request_retreat's raises (20260616000019:93-103) and combat_flee_pending's ok:false reasons
// (20260618000230) — and every one must resolve to plain player copy; anything unknown must
// degrade to a generic sentence, never leak the input.

// The full raise vocabulary of request_retreat, exactly as plpgsql formats it. The parameterized
// raise is expanded over location_presence's whole status domain (20260616000008:21) minus
// 'active', which cannot raise.
const RETREAT_RAISES = [
  'request_retreat: not authenticated',
  'request_retreat: presence not found',
  'request_retreat: not owned',
  'request_retreat: presence not active (is retreating)',
  'request_retreat: presence not active (is leaving)',
  'request_retreat: presence not active (is completed)',
  'request_retreat: presence not active (is destroyed)',
  'request_retreat: presence not active (is expired)',
]

// The full ok:false reason vocabulary of combat_flee_pending, plus telegraphApi's own fallback
// token for an envelope with no reason. (`presence_already_closed` rides ok:true and never throws.)
const FLEE_REASONS = ['no_pending', 'telegraph_disabled', 'not_authenticated', 'flee_failed']

test('RETREAT: every server raise maps to plain copy — no raw prefix, no code, no base/home', () => {
  for (const raw of RETREAT_RAISES) {
    const msg = retreatErrorMessage(raw)
    expect(msg.length, `${raw} produced empty copy`).toBeGreaterThan(0)
    expect(msg).not.toContain('request_retreat')
    expect(msg).not.toContain('presence')
    expect(msg).not.toContain('base')
    expect(msg).not.toContain('home')
  }
})

test('RETREAT: the double-press reads as "already retreating", not as an error about state', () => {
  // The defect this map exists for: pressing Retreat twice threw the raise text at the player.
  expect(retreatErrorMessage('request_retreat: presence not active (is retreating)')).toBe(
    'Your fleet is already retreating.',
  )
  // 'leaving' is the same story one step later — the first press worked.
  expect(retreatErrorMessage('request_retreat: presence not active (is leaving)')).toBe(
    'Your fleet is already retreating.',
  )
  // A terminal presence means the fight ended under the player — different copy, still plain.
  for (const status of ['completed', 'destroyed', 'expired']) {
    expect(retreatErrorMessage(`request_retreat: presence not active (is ${status})`)).toBe(
      'This fight is already over.',
    )
  }
})

test('RETREAT: unknown input (transport noise, future raises) degrades to the generic sentence', () => {
  for (const raw of ['', 'TypeError: failed to fetch', 'request_retreat: something new', 'no_pending']) {
    expect(retreatErrorMessage(raw)).toBe('Couldn’t order the retreat — try again.')
  }
})

test('FLEE: every reason token maps to plain copy — the token itself never leaks', () => {
  for (const raw of FLEE_REASONS) {
    const msg = fleeErrorMessage(raw)
    expect(msg.length, `${raw} produced empty copy`).toBeGreaterThan(0)
    expect(msg).not.toContain(raw)
    expect(msg).not.toContain('base')
    expect(msg).not.toContain('home')
  }
})

test('FLEE: the raced flee (resolver won, combat opened) points the player at Retreat', () => {
  expect(fleeErrorMessage('no_pending')).toBe(
    'Too late to slip away — the fight is starting. Order a retreat instead.',
  )
})

test('FLEE: unknown input degrades to the generic sentence', () => {
  for (const raw of ['', 'TypeError: failed to fetch', 'presence_already_closed', 'something_new']) {
    expect(fleeErrorMessage(raw)).toBe('Couldn’t flee — try again.')
  }
})
