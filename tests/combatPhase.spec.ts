// COMBAT PHASE — pure unit proof for selectCombatPhase, the ONE derivation of what a live encounter
// is doing right now, plus the composition proof that BOTH combat surfaces read it instead of
// re-deriving it. No browser, no page, no DB.
// Run: `npx playwright test combatPhase.spec.ts`.
import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  selectCombatPhase,
  nextWaveSeconds,
  nextWaveText,
  NEXT_WAVE_INCOMING,
  type CombatPhaseInput,
} from '../src/features/combat/combatPhase'

const NOW = Date.parse('2026-07-27T12:00:00Z')
const at = (secondsFromNow: number) => new Date(NOW + secondsFromNow * 1000).toISOString()

const row = (over: Partial<CombatPhaseInput> = {}): CombatPhaseInput => ({
  status: 'active',
  enemy_integrity_current: 285,
  ...over,
})

// ── the three phases ───────────────────────────────────────────────────────────────────────────

test('a wave in progress is FIGHTING', () => {
  const v = selectCombatPhase(row())
  expect(v.phase).toBe('fighting')
  expect(v.label).toBe('In combat')
  expect(v.betweenWaves).toBe(false)
  expect(v.isRetreating).toBe(false)
})

test('a wiped enemy side is BETWEEN WAVES — the 3s pause, not an empty fight', () => {
  const v = selectCombatPhase(row({ enemy_integrity_current: 0 }))
  expect(v.phase).toBe('next_wave')
  expect(v.label).toBe(NEXT_WAVE_INCOMING)
  expect(v.betweenWaves).toBe(true)
})

test('a retreating fleet reads RETREATING even mid-wave', () => {
  const v = selectCombatPhase(row({ status: 'retreating' }))
  expect(v.phase).toBe('retreating')
  expect(v.label).toBe('Retreating')
  expect(v.isRetreating).toBe(true)
})

test('retreating OUTRANKS between-waves for the label — the fleet leaving is the bigger news', () => {
  const v = selectCombatPhase(row({ status: 'retreating', enemy_integrity_current: 0 }))
  expect(v.phase).toBe('retreating')
  expect(v.label).toBe('Retreating')
})

test('…but betweenWaves stays TRUE while retreating — the enemy zeros are still placeholders', () => {
  // This is the whole point of keeping the two flags separate. A fleet that retreats during the
  // pause still faces enemy_integrity_current = 0, and printing "0 ships · 0/285" would be the very
  // defect this slice removes.
  const v = selectCombatPhase(row({ status: 'retreating', enemy_integrity_current: 0 }))
  expect(v.betweenWaves).toBe(true)
})

// ── the enemy side is wiped exactly when the server says so ────────────────────────────────────

test('the wipe test is <= 0, not < 0 — the tick writes greatest(0, …), so 0 IS the wipe', () => {
  expect(selectCombatPhase(row({ enemy_integrity_current: 0 })).betweenWaves).toBe(true)
  expect(selectCombatPhase(row({ enemy_integrity_current: -1 })).betweenWaves).toBe(true)
  expect(selectCombatPhase(row({ enemy_integrity_current: 0.5 })).betweenWaves).toBe(false)
})

test('the phase needs no clock at all — same row, same answer, forever', () => {
  const r = row({ enemy_integrity_current: 0 })
  expect(selectCombatPhase(r)).toEqual(selectCombatPhase(r))
  expect(selectCombatPhase(r)).toEqual({
    phase: 'next_wave',
    label: NEXT_WAVE_INCOMING,
    isRetreating: false,
    betweenWaves: true,
  })
})

// ── the countdown, the one clock-dependent leaf ────────────────────────────────────────────────

test('no recorded next_wave_at → 0 seconds, never NaN', () => {
  expect(nextWaveSeconds({ next_wave_at: null }, NOW)).toBe(0)
  expect(nextWaveText(0)).toBe(`${NEXT_WAVE_INCOMING}…`)
})

test('seconds round UP, so a 2.1s wait never reads as 2s and then stalls', () => {
  expect(nextWaveSeconds({ next_wave_at: at(2.1) }, NOW)).toBe(3)
})

test('a live countdown reads with the seconds', () => {
  expect(nextWaveText(nextWaveSeconds({ next_wave_at: at(3) }, NOW))).toBe(
    `${NEXT_WAVE_INCOMING} in 3s…`,
  )
})

test('once the moment has passed the countdown stops being rendered', () => {
  // next_wave_at is in the past but the tick has not spawned the wave yet (up to 3s of cron lag).
  const s = nextWaveSeconds({ next_wave_at: at(-4) }, NOW)
  expect(s).toBeLessThanOrEqual(0)
  expect(nextWaveText(s)).toBe(`${NEXT_WAVE_INCOMING}…`)
})

test('a surface with no clock passes null and still gets the shared phrase', () => {
  expect(nextWaveText(null)).toBe(`${NEXT_WAVE_INCOMING}…`)
})

test('the countdown advances with the supplied clock and nothing else', () => {
  const e = { next_wave_at: at(3) }
  expect(nextWaveSeconds(e, NOW)).toBe(3)
  expect(nextWaveSeconds(e, NOW + 1000)).toBe(2)
})

// ── ONE AUTHORITY: both surfaces compose it, neither re-derives it ─────────────────────────────

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', rel), 'utf8')
const selector = src('features/combat/combatPhase.ts')
const panel = src('features/combat/ActiveCombatPanel.tsx')
const card = src('features/map/CombatMapCard.tsx')

test('both combat surfaces import the shared selector', () => {
  expect(panel).toContain("from './combatPhase'")
  expect(panel).toContain('selectCombatPhase(encounter)')
  expect(card).toContain("from '../combat/combatPhase'")
  expect(card).toContain('selectCombatPhase(e)')
})

test('the raw phase derivations live in the selector and NOWHERE else', () => {
  // NO-SPAGHETTI: one authority per concept. If either surface re-derives any of these, the two
  // readouts can silently disagree about the same encounter — which is how the map card came to
  // print "ENEMY 0 ships · integrity 0/285" while the Command panel said "Next wave incoming".
  for (const derivation of ['enemy_integrity_current <= 0', 'next_wave_at']) {
    expect(selector, `combatPhase.ts must own ${derivation}`).toContain(derivation)
    expect(panel, `ActiveCombatPanel must not re-derive ${derivation}`).not.toContain(derivation)
    expect(card, `CombatMapCard must not re-derive ${derivation}`).not.toContain(derivation)
  }
  // the panel's own retreat read is gone too (the map card keeps a status test, but only to decide
  // which encounters are LIVE — a different question, pinned by combatMapCard.spec.ts).
  expect(panel).not.toContain("encounter.status === 'retreating'")
})

test('the inter-wave copy is written once and shared', () => {
  expect(selector).toContain(`export const NEXT_WAVE_INCOMING = '${NEXT_WAVE_INCOMING}'`)
  for (const surface of [panel, card]) {
    expect(surface).toContain('nextWaveText(')
    // no surface may hard-code the phrase, or the two will drift the day it is reworded
    expect(surface).not.toContain(NEXT_WAVE_INCOMING)
  }
})

test('the map card suppresses the placeholder enemy numbers during the pause', () => {
  // Between waves every enemy figure on the row is a zero the server wrote as a placeholder. The
  // card must branch on the phase BEFORE it renders the enemy bar, not render it and hope.
  expect(card).toContain('phase.betweenWaves ?')
  const between = card.indexOf('phase.betweenWaves ?')
  const enemyBar = card.indexOf('e.enemy_integrity_current')
  expect(between).toBeGreaterThan(-1)
  expect(enemyBar).toBeGreaterThan(between) // the bar is inside the else arm
})

test('the shared label drives both headers — no surface hard-codes a phase name', () => {
  expect(panel).toContain('{phase.label}')
  expect(card).toContain('{phase.label}')
  expect(panel).not.toContain("? 'Retreating' :")
  expect(card).not.toContain("? 'Retreating' :")
})

test('the map card takes no clock of its own — it shows the phase, not a countdown', () => {
  // A Date.now() read during render is impure (react-hooks/purity) and a second 1s interval on the
  // map for a 3-second pause is not worth the re-render; the phase itself needs no clock at all.
  expect(card).not.toContain('Date.now')
  expect(card).not.toContain('setInterval')
  expect(card).toContain('nextWaveText(null)')
})

test('the selector stays pure — no React, no clock, no fetch, no combat math', () => {
  // Probe the CODE, not the prose. The same coupling the SQL self-asserts have to strip `--`
  // comments for: this file's own documentation names the clock to explain why it is a parameter,
  // and a naive substring probe would trip over its own explanation.
  const code = selector.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  expect(code).toContain('export function selectCombatPhase') // the strip did not eat the code
  for (const forbidden of ['react', 'Date.now(', 'setInterval', 'setTimeout', 'supabase', 'Math.random']) {
    expect(code, `combatPhase.ts must not contain ${forbidden}`).not.toContain(forbidden)
  }
})
