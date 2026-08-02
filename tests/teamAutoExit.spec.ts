import { test, expect } from '@playwright/test'
import {
  AUTO_EXIT_PCT_DEFAULT,
  AUTO_EXIT_PCT_MAX,
  AUTO_EXIT_PCT_MIN,
  autoExitSaveAvailability,
  autoExitSummary,
  parseAutoExitPct,
} from '../src/features/command/teamAutoExit'

// Pure unit proof for the HP auto-exit client model (0310). The server (ship_groups CHECK +
// set_group_auto_exit) is the authority on the [5,95] bounds; this file pins that the CLIENT
// mirror agrees with it exactly — a drifted mirror would disable saves the server accepts, or
// offer saves the server refuses. Run: `npx playwright test teamAutoExit.spec.ts`.

test('the client bounds mirror the server CHECK exactly (5, 95, default 30)', () => {
  expect(AUTO_EXIT_PCT_MIN).toBe(5)
  expect(AUTO_EXIT_PCT_MAX).toBe(95)
  expect(AUTO_EXIT_PCT_DEFAULT).toBe(30)
})

test('parseAutoExitPct accepts exactly the whole percents the server accepts', () => {
  expect(parseAutoExitPct('5')).toEqual({ ok: true, pct: 5 })
  expect(parseAutoExitPct('30')).toEqual({ ok: true, pct: 30 })
  expect(parseAutoExitPct('95')).toEqual({ ok: true, pct: 95 })
  expect(parseAutoExitPct(' 50 ')).toEqual({ ok: true, pct: 50 }) // trimmed, still whole
})

test('parseAutoExitPct fail-closes on everything else — out of range, fractions, NaN-shaped, junk', () => {
  for (const bad of ['4', '96', '0', '100', '150', '-5', '', ' ', '30.5', '3e1', 'NaN', 'Infinity', 'abc', '5%']) {
    expect(parseAutoExitPct(bad).ok, `"${bad}" must be refused`).toBe(false)
  }
})

test('save availability: live only for a valid, CHANGED percent; hint only for an invalid draft', () => {
  const cur = { enabled: true, pct: 30 }
  expect(autoExitSaveAvailability(cur, '50')).toEqual({ canSave: true, hint: null })
  // unchanged → nothing to save, and no scolding hint either
  expect(autoExitSaveAvailability(cur, '30')).toEqual({ canSave: false, hint: null })
  const bad = autoExitSaveAvailability(cur, '150')
  expect(bad.canSave).toBe(false)
  expect(bad.hint).toContain('5')
  expect(bad.hint).toContain('95')
})

test('the summary speaks player, never jargon or codes — and never the banned design words', () => {
  const on = autoExitSummary({ enabled: true, pct: 40 })
  expect(on).toContain('40%')
  const off = autoExitSummary({ enabled: false, pct: 40 })
  expect(off.toLowerCase()).toContain('off')
  // The design laws: no "home", no "base", no "win"; no insider jargon on a player surface.
  for (const text of [on, off]) {
    for (const banned of ['home', 'base', 'win', 'sortie', 'berth', 'auto_exit', 'pct']) {
      expect(text.toLowerCase(), `summary must not say "${banned}"`).not.toContain(banned)
    }
  }
})

// THE COPY MUST STATE THE RULE THE SERVER RUNS (review finding: the first draft said "drops to
// 30%" while the migration measured the damaged ENTRY hull — copy and engine told two different
// rules). The server's denominator is the fleet's full hull capacity (sum of max_hp), so the
// player-facing sentence must carry the capacity qualifier and must not describe an entry-hull
// rule; and since a fleet entering a fight below the line exits on the first tick, the sentence
// says that too rather than letting the owner discover it mid-fight.
test('the ON summary states the capacity-based semantics the server implements', () => {
  const on = autoExitSummary({ enabled: true, pct: 40 })
  expect(on).toMatch(/40% of full strength/)
  expect(on.toLowerCase()).not.toContain('entered') // no entry-hull phrasing
  expect(on.toLowerCase()).toContain('leaves right away') // the first-tick consequence, stated
})
