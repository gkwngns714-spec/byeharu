import { test, expect } from '@playwright/test'
import {
  captainProgress,
  captainProgressVisible,
  levelForXp,
  xpForLevel,
} from '../src/features/captains/captainProgress'

// C2-3 — pure-logic specs for the captain-progression helpers (no app/Supabase). The client curve
// must mirror the SERVER curve exactly (migration 0177: level = 1 + floor(sqrt(xp / 100)),
// maintained inline by captain_xp_accrue) — these pins are the parity proof. Also pins the render
// gate's DARK STORY: a level-1 0-xp captain (every captain while captain_growth_enabled is false)
// shows NOTHING. Run: `npx playwright test captainProgress.spec.ts`.

// ── xpForLevel — the threshold table (level−1)² × 100 ───────────────────────────────────────────
test('xpForLevel: the 0177 threshold table (0 / 100 / 400 / 900 …)', () => {
  expect(xpForLevel(1)).toBe(0)
  expect(xpForLevel(2)).toBe(100)
  expect(xpForLevel(3)).toBe(400)
  expect(xpForLevel(4)).toBe(900)
  expect(xpForLevel(11)).toBe(10_000)
})

test('xpForLevel: sub-1 / malformed levels clamp to level 1 (→ 0 xp)', () => {
  expect(xpForLevel(0)).toBe(0)
  expect(xpForLevel(-3)).toBe(0)
  expect(xpForLevel(Number.NaN)).toBe(0)
})

// ── levelForXp — the server curve verbatim, boundary-exact ───────────────────────────────────────
test('levelForXp: boundary-exact against the server curve (99→1, 100→2, 399→2, 400→3, 900→4)', () => {
  expect(levelForXp(0)).toBe(1)
  expect(levelForXp(99)).toBe(1)
  expect(levelForXp(100)).toBe(2)
  expect(levelForXp(399)).toBe(2)
  expect(levelForXp(400)).toBe(3)
  expect(levelForXp(899)).toBe(3)
  expect(levelForXp(900)).toBe(4)
})

test('levelForXp: negative / non-finite xp degrades to level 1 (never throws)', () => {
  expect(levelForXp(-50)).toBe(1)
  expect(levelForXp(Number.NaN)).toBe(1)
})

// ── captainProgress — fraction boundaries + the server-level-wins clamp ─────────────────────────
test('captainProgress: level-1 boundaries — 0 xp → 0, 50 → .5, 99 → .99 of the 100-xp span', () => {
  expect(captainProgress(0, 1)).toMatchObject({ level: 1, floorXp: 0, nextXp: 100, intoLevel: 0, span: 100, fraction: 0 })
  expect(captainProgress(50, 1).fraction).toBe(0.5)
  expect(captainProgress(99, 1).fraction).toBe(0.99)
})

test('captainProgress: a fresh level-up sits at fraction 0 of the NEXT span (100 xp @ level 2)', () => {
  expect(captainProgress(100, 2)).toMatchObject({ level: 2, floorXp: 100, nextXp: 400, intoLevel: 0, span: 300, fraction: 0 })
  expect(captainProgress(250, 2).fraction).toBe(0.5)
})

test('captainProgress: the SERVER level wins — a disagreeing xp clamps into [0, span], never re-levels', () => {
  // xp far above the level's span (mid-accrual read): clamp to a full bar, level untouched.
  expect(captainProgress(1000, 2)).toMatchObject({ level: 2, intoLevel: 300, fraction: 1 })
  // xp below the level's floor: clamp to an empty bar, level untouched.
  expect(captainProgress(50, 2)).toMatchObject({ level: 2, intoLevel: 0, fraction: 0 })
})

test('captainProgress: malformed inputs degrade to level 1 / 0 xp (never throws, never NaN)', () => {
  expect(captainProgress(Number.NaN, Number.NaN)).toMatchObject({ level: 1, intoLevel: 0, fraction: 0 })
  expect(captainProgress(-10, 0)).toMatchObject({ level: 1, intoLevel: 0, fraction: 0 })
})

// ── captainProgressVisible — the render gate + THE DARK STORY ───────────────────────────────────
test('DARK STORY: a level-1 0-xp captain (every captain while captain_growth_enabled is false) shows NOTHING', () => {
  expect(captainProgressVisible({ xp: 0, level: 1 })).toBe(false)
})

test('visible once there is progression: xp > 0 at level 1, or level > 1 even at the floor', () => {
  expect(captainProgressVisible({ xp: 10, level: 1 })).toBe(true)
  expect(captainProgressVisible({ xp: 100, level: 2 })).toBe(true)
  // a level-2 row whose xp momentarily reads 0 still shows (level > 1 carries the signal).
  expect(captainProgressVisible({ xp: 0, level: 2 })).toBe(true)
})

test('an explicit growthVisible signal forces the bar for a level-1 0-xp captain (future lit-flag hook)', () => {
  expect(captainProgressVisible({ xp: 0, level: 1 }, true)).toBe(true)
})

test('a projection NOT carrying finite xp/level (pre-0181 envelope) is never visible', () => {
  expect(captainProgressVisible({})).toBe(false)
  expect(captainProgressVisible({ xp: 10 })).toBe(false)
  expect(captainProgressVisible({ level: 2 })).toBe(false)
  expect(captainProgressVisible({ xp: null, level: null })).toBe(false)
  expect(captainProgressVisible({ xp: Number.NaN, level: 2 })).toBe(false)
  // even with the explicit signal — no data, no bar.
  expect(captainProgressVisible({}, true)).toBe(false)
})

test('a malformed sub-1 level is never visible (the 0177 CHECK mirror)', () => {
  expect(captainProgressVisible({ xp: 10, level: 0 })).toBe(false)
})
