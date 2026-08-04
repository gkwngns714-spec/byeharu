import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  foldRetreatDelaySeconds,
  resolveRetreatCountdown,
} from '../src/features/combat/retreatCountdown'

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', rel), 'utf8')

// THE RETREAT COUNTDOWN — the proof that an unknown escape window renders as NO CLAIM.
//
// The defect this pins: MissionScreen passed `game.config['retreat_delay_seconds'] ?? 20` into the
// combat panel. Production's value is 8 (20260617000028_retreat_delay_8s.sql), so a config hiccup —
// and fetchGameConfig omits a key outright on a partial read — showed a confident countdown 2.5x
// longer than the real window, at the exact moment the player is deciding whether they can escape.
//
// NO WALL CLOCK: every call passes an explicit nowMs.

const T0 = Date.parse('2026-08-04T12:00:00.000Z')
const startedAt = '2026-08-04T12:00:00.000Z'

// ── THE FOLD: absent is not a number ──────────────────────────────────────────────────────────────

test('an ABSENT config key folds to null — the record simply has no such key after a partial read', () => {
  const config: Record<string, number> = {} // exactly what fetchGameConfig returns when the row is missing
  expect(foldRetreatDelaySeconds(config['retreat_delay_seconds'])).toBeNull()
  expect(foldRetreatDelaySeconds(undefined)).toBeNull()
  expect(foldRetreatDelaySeconds(null)).toBeNull()
  expect(foldRetreatDelaySeconds('')).toBeNull()
  expect(foldRetreatDelaySeconds('not a number')).toBeNull()
  expect(foldRetreatDelaySeconds(Number.NaN)).toBeNull()
  expect(foldRetreatDelaySeconds(-1)).toBeNull()
})

test('the SERVER’s value comes through verbatim — 8 is 8, and a numeric string is the same number', () => {
  expect(foldRetreatDelaySeconds(8)).toBe(8)
  expect(foldRetreatDelaySeconds('8')).toBe(8)
  // zero is a real window (breaks away on the very next tick), not an unknown
  expect(foldRetreatDelaySeconds(0)).toBe(0)
})

// ── THE SENTENCE: no claim when the window is unknown ─────────────────────────────────────────────

test('UNKNOWN WINDOW → the countdown makes NO numeric claim at all', () => {
  const view = resolveRetreatCountdown({ retreatStartedAt: startedAt, delaySeconds: null, nowMs: T0 + 1000 })
  expect(view.secondsLeft).toBeNull()
  // The whole point: not one digit reaches the screen. A "20" here is the defect.
  expect(view.text).not.toMatch(/\d/)
  expect(view.text).not.toContain('20')
  // …but it still says the two things the encounter row alone proves.
  expect(view.text).toContain('breaking away')
  expect(view.text).toContain('damage')
})

test('an unreadable retreat start is the same kind of unknown — no invented countdown', () => {
  for (const started of [null, 'not-a-timestamp']) {
    const view = resolveRetreatCountdown({ retreatStartedAt: started, delaySeconds: 8, nowMs: T0 })
    expect(view.secondsLeft).toBeNull()
    expect(view.text).not.toMatch(/\d/)
  }
})

test('KNOWN WINDOW → the TRUE value counts down, and it is the server’s 8 — never a 20', () => {
  const at = (ms: number) =>
    resolveRetreatCountdown({ retreatStartedAt: startedAt, delaySeconds: 8, nowMs: T0 + ms })
  expect(at(0).secondsLeft).toBe(8)
  expect(at(0).text).toContain('8s')
  expect(at(3000).secondsLeft).toBe(5)
  expect(at(3000).text).toContain('5s')
  // The 8-second window is OVER by the time a 20-second one would still be showing 12 left.
  expect(at(8000).secondsLeft).toBeLessThanOrEqual(0)
  expect(at(8000).text).toContain('a moment')
  expect(at(8000).text).not.toContain('12')
})

test('past the window is not an unknown — the fleet IS leaving, so it still says so', () => {
  const view = resolveRetreatCountdown({ retreatStartedAt: startedAt, delaySeconds: 8, nowMs: T0 + 30_000 })
  expect(view.secondsLeft).toBeLessThan(0)
  expect(view.text).toContain('a moment')
})

// ── ONE AUTHORITY, AND NO ARITHMETIC PATH FROM A MISSING VALUE ────────────────────────────────────

test('the screen composes the FOLD and carries no fallback number of its own', () => {
  const screen = src('features/command/MissionScreen.tsx')
  expect(screen).toContain('foldRetreatDelaySeconds')
  // THE REGRESSION GUARD: any `?? <number>` on the config read is the defect coming back.
  expect(screen, 'a defaulted config value is a confident guess').not.toMatch(
    /config\['retreat_delay_seconds'\]\s*\?\?/,
  )
})

test('the panel composes the resolver and never times the retreat itself', () => {
  const panel = src('features/combat/ActiveCombatPanel.tsx')
  expect(panel).toContain('resolveRetreatCountdown')
  expect(panel, 'the countdown arithmetic belongs to one module').not.toContain(
    'Math.ceil(retreatDelaySeconds',
  )
  expect(panel).not.toContain('retreat_started_at).getTime()')
})
