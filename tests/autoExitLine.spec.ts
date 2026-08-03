import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { resolveAutoExitLine } from '../src/features/combat/autoExitLine'

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', rel), 'utf8')

// THE SAFETY LINE (0310). It has been ending real production fights since it deployed, and no combat
// surface said a word about it — `grep auto_exit src/features/combat/` returned nothing at all.

const enc = (o: Partial<{ status: string; player_integrity_current: number; player_integrity_max: number }> = {}) => ({
  status: 'active',
  player_integrity_current: 480,
  player_integrity_max: 480,
  ...o,
})

test('the threshold is capacity × pct — the SAME denominator the tick uses', () => {
  // 0331:579 states it outright: player_integrity_max equals 0310's live denominator exactly.
  const line = resolveAutoExitLine(enc(), { enabled: true, pct: 30 })!
  expect(line.hull).toBe(144)
  expect(line.frac).toBeCloseTo(0.3, 6)
  expect(line.reached).toBe(false)
  expect(line.close).toBe(false)
  expect(line.text).toContain('30%')
})

test('AT the line: the fleet pulls out on the next exchange, and it says so', () => {
  const line = resolveAutoExitLine(enc({ player_integrity_current: 144 }), { enabled: true, pct: 30 })!
  expect(line.reached).toBe(true)
  expect(line.text).toContain('pulls out')
})

test('BELOW the line while retreating: it states the position, it does not claim the cause', () => {
  // The retreat could have been ordered by hand in the same second. Saying "auto-retreat fired"
  // would be a causal claim the client cannot see; saying where the fleet stands is a fact.
  const line = resolveAutoExitLine(
    enc({ status: 'retreating', player_integrity_current: 100 }),
    { enabled: true, pct: 30 },
  )!
  expect(line.reached).toBe(true)
  expect(line.text).toContain('breaking off')
  expect(line.text).not.toContain('triggered')
})

test('CLOSE to the line: the warning arrives before the decision is taken away', () => {
  const line = resolveAutoExitLine(enc({ player_integrity_current: 170 }), { enabled: true, pct: 30 })!
  expect(line.close).toBe(true)
  expect(line.reached).toBe(false)
  expect(line.text).toContain('Close to')
})

test('SILENCE, never a denial: an unknown or disabled setting says nothing at all', () => {
  // A failed read must not render "no auto-retreat" — the fleet may well have one.
  expect(resolveAutoExitLine(enc(), null)).toBeNull()
  expect(resolveAutoExitLine(enc(), undefined)).toBeNull()
  expect(resolveAutoExitLine(enc(), { enabled: false, pct: 30 })).toBeNull()
})

test('a degenerate row yields no line rather than a NaN percentage', () => {
  expect(resolveAutoExitLine(enc({ player_integrity_max: 0 }), { enabled: true, pct: 30 })).toBeNull()
  expect(resolveAutoExitLine(enc(), { enabled: true, pct: Number.NaN })).toBeNull()
  expect(resolveAutoExitLine(enc(), { enabled: true, pct: 0 })).toBeNull()
  expect(resolveAutoExitLine(enc(), { enabled: true, pct: 100 })).toBeNull()
})

// ── ONE DERIVATION, TWO SURFACES ──────────────────────────────────────────────────────────────────
test('both combat surfaces compose the one resolver and neither re-derives the threshold', () => {
  for (const rel of ['features/map/CombatMapCard.tsx', 'features/combat/ActiveCombatPanel.tsx']) {
    const text = src(rel)
    expect(text, `${rel} must compose resolveAutoExitLine`).toContain('resolveAutoExitLine')
    expect(text, `${rel} must not do the threshold arithmetic itself`).not.toContain('pct / 100')
    expect(text, `${rel} must not read the raw column`).not.toContain('auto_exit_hp_pct')
  }
})

test('the setting is read per ENCOUNTER, off the combat poll, and only while fighting', () => {
  const api = src('features/combat/combatApi.ts')
  expect(api).toContain('fetchAutoExitByEncounter')
  expect(api).toContain('auto_exit_hp_pct')
  const hook = src('features/combat/useCombat.ts')
  // no fight → no request; the quiet map must not gain a sixth call every 1.5 seconds
  expect(hook).toContain('encs.length > 0 ? fetchAutoExitByEncounter(encs) : Promise.resolve({})')
})
