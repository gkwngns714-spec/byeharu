import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  MAP_OVERLAY_TABS,
  MAP_OVERLAY_TAB_LABEL,
  MAP_OVERLAY_TAB_NONE,
  MAP_OVERLAY_TAB_STORAGE_KEY,
  defaultOpenTab,
  pressTab,
  readOpenTab,
  resolveOpenTab,
  tabStateValue,
  type MapOverlayTabId,
} from '../src/features/map/mapOverlayTabModel'

// ██ THE MAP'S OVERLAY TABS — pure unit proof of the rule the whole rail now rests on. ██
//
// Owner: "i want a separate tab on map for exploration, which is foldable, at the top, a square
// shaped one. also for combat, when opened it will show next wave incoming (wave info), and fleets
// info".
//
// The property that matters is not cosmetic. The rail used to STACK three panels — 583px against a
// 505px map box at the owner's own 1440x675 — and that is the shape "right now i can't press hunt"
// had. AT MOST ONE BODY makes that arithmetic impossible rather than merely survivable, so these
// tests pin the invariant, the fold, the memory, and the fail-closed reading of a corrupt byte.
//
// No browser, no page, no DB. Run: `npx playwright test mapOverlayTabs.spec.ts`.

// ── THE SET ──────────────────────────────────────────────────────────────────────────────────────

test('there are exactly three tabs, and every one of them has a plain-words label', () => {
  expect([...MAP_OVERLAY_TABS]).toEqual(['explore', 'fight', 'fleets'])
  for (const id of MAP_OVERLAY_TABS) {
    const label = MAP_OVERLAY_TAB_LABEL[id]
    expect(label, `${id} must have a label`).toBeTruthy()
    // No insider jargon on a command surface — the owner's standing map-UX rule.
    expect(label).not.toMatch(/encounter|presence|pressure|reinforcement|integrity/i)
  }
})

// ── ONE OPEN AT A TIME, AND FOLDABLE ─────────────────────────────────────────────────────────────

test('pressing another tab REPLACES the open one — it never adds a second', () => {
  expect(pressTab('explore', 'fight')).toBe('fight')
  expect(pressTab('fight', 'fleets')).toBe('fleets')
  expect(pressTab(null, 'explore')).toBe('explore')
})

test('pressing the OPEN tab closes it — the foldable half of the ask, and the only way to a bare map', () => {
  for (const id of MAP_OVERLAY_TABS) {
    expect(pressTab(id, id), `${id} must fold shut when pressed again`).toBeNull()
  }
})

test('every reachable state names at most ONE tab — exhaustive over the whole transition table', () => {
  const states: (MapOverlayTabId | null)[] = [null, ...MAP_OVERLAY_TABS]
  for (const from of states) {
    for (const pressed of MAP_OVERLAY_TABS) {
      const next = pressTab(from, pressed)
      expect(next === null || MAP_OVERLAY_TABS.includes(next)).toBe(true)
    }
  }
})

// ── WHAT OPENS WHEN NOBODY HAS CHOSEN ────────────────────────────────────────────────────────────

test('a live fight outranks everything as the DEFAULT — and only as the default', () => {
  expect(defaultOpenTab(true)).toBe('fight')
  expect(defaultOpenTab(false)).toBe('fleets')
})

test('a remembered choice always wins over the default, fight or no fight', () => {
  // The map must never yank a panel out from under the player because a fight started.
  for (const fighting of [true, false]) {
    for (const id of MAP_OVERLAY_TABS) {
      expect(resolveOpenTab(id, fighting)).toBe(id)
    }
    // …including the choice to have nothing open at all.
    expect(resolveOpenTab(MAP_OVERLAY_TAB_NONE, fighting)).toBeNull()
  }
})

test('"closed" and "never chose" are DIFFERENT — a corrupt byte can never wedge the rail', () => {
  expect(resolveOpenTab(MAP_OVERLAY_TAB_NONE, false), 'the empty string is a real choice').toBeNull()
  expect(resolveOpenTab(null, false), 'absence falls back to the default').toBe('fleets')
  expect(resolveOpenTab('garbage', false), 'so does anything this module did not write').toBe('fleets')
  expect(resolveOpenTab('FIGHT', true), 'and the match is exact, never case-folded').toBe('fight')
})

test('a throwing reader (private-mode storage) still yields a usable rail', () => {
  const boom = () => {
    throw new Error('SecurityError: localStorage is not available')
  }
  expect(readOpenTab(boom, true)).toBe('fight')
  expect(readOpenTab(boom, false)).toBe('fleets')
})

test('the reader asks for exactly one key, and it is the versioned one', () => {
  const asked: string[] = []
  readOpenTab((k) => {
    asked.push(k)
    return 'explore'
  }, false)
  expect(asked).toEqual([MAP_OVERLAY_TAB_STORAGE_KEY])
  // The house convention: a `byeharu.` prefix and a versioned namespace (collapsibleState's rule).
  expect(MAP_OVERLAY_TAB_STORAGE_KEY).toMatch(/^byeharu\..+\.v\d+$/)
})

test('what is written round-trips to what is read — for every state including closed', () => {
  const states: (MapOverlayTabId | null)[] = [null, ...MAP_OVERLAY_TABS]
  for (const state of states) {
    const stored = tabStateValue(state)
    expect(readOpenTab(() => stored, false), `${String(state)} must round-trip`).toBe(state)
  }
})

// ── THE MODULE STAYS PURE ────────────────────────────────────────────────────────────────────────

test('the model touches no React, no DOM and no storage of its own', () => {
  const here = dirname(fileURLToPath(import.meta.url))
  const source = readFileSync(join(here, '..', 'src/features/map/mapOverlayTabModel.ts'), 'utf8')
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  expect(code, 'the strip did not eat the code').toContain('export function pressTab')
  for (const forbidden of ['react', 'window.', 'localStorage', 'document', 'Date.now(', 'supabase']) {
    expect(code, `the tab model must not contain ${forbidden}`).not.toContain(forbidden)
  }
})
