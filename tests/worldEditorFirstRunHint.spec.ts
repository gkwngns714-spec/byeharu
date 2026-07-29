import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  WORLD_EDITOR_HINT_BODY,
  WORLD_EDITOR_HINT_TITLE,
  shouldShowFirstRunHint,
  worldEditorHintDismissKey,
} from '../src/features/worldeditor/worldEditorFirstRunHint'
import {
  INITIAL_WORLD_EDITOR_CHROME,
  dismissChrome,
  openTool,
} from '../src/features/worldeditor/worldEditorChrome'

// WORLD EDITOR — the FIRST-RUN HINT. Two proof layers:
//   1. PURE model proofs for the show/hide decision (cold+empty only, and permanently dismissable).
//   2. STRUCTURAL proofs that the hint CANNOT regress the two authorities it sits next to: it never
//      changes chrome state (map-UX law #1's clean-map default survives byte-for-byte) and it never
//      touches a draft store, so there is no path from "a hint rendered" to "a panel opened" or
//      "a draft moved".
// Run: `npx playwright test worldEditorFirstRunHint.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const WE = join(here, '..', 'src', 'features', 'worldeditor')
const src = (rel: string) => readFileSync(join(WE, rel), 'utf8')

const hintModel = src('worldEditorFirstRunHint.ts')
const chromeModel = src('worldEditorChrome.ts')
const dock = src('WorldEditorDock.tsx')
const shell = src('WorldEditor.tsx')

const COLD = { chrome: INITIAL_WORLD_EDITOR_CHROME, pendingDraftTotal: 0, dismissed: false }

// ── 1. the pure decision ────────────────────────────────────────────────────────────────────────────
test('shows on a COLD, EMPTY editor — the exact state that reads as broken', () => {
  expect(shouldShowFirstRunHint(COLD)).toBe(true)
})

test('retires the moment ANY tool is summoned — the hint has been obeyed', () => {
  for (const tool of ['layers', 'find', 'inspect', 'author', 'history', 'combat'] as const) {
    expect(
      shouldShowFirstRunHint({ ...COLD, chrome: openTool(INITIAL_WORLD_EDITOR_CHROME, tool) }),
    ).toBe(false)
  }
})

test('never stacks on a fully dismissed map — that surface has its own summon hint (law #6)', () => {
  expect(shouldShowFirstRunHint({ ...COLD, chrome: dismissChrome() })).toBe(false)
})

test('pending drafts prove the rail was already found — no hint', () => {
  expect(shouldShowFirstRunHint({ ...COLD, pendingDraftTotal: 1 })).toBe(false)
  expect(shouldShowFirstRunHint({ ...COLD, pendingDraftTotal: 9 })).toBe(false)
})

test('an explicit dismissal wins over every other condition', () => {
  expect(shouldShowFirstRunHint({ ...COLD, dismissed: true })).toBe(false)
})

test('the dismissal key is per-user and versioned; anon never shares an owner dismissal', () => {
  expect(worldEditorHintDismissKey('u1')).toBe('byeharu.worldEditor.hint.v1.dismissed:u1')
  expect(worldEditorHintDismissKey('u2')).not.toBe(worldEditorHintDismissKey('u1'))
  expect(worldEditorHintDismissKey(null)).toBe('byeharu.worldEditor.hint.v1.dismissed:anon')
  expect(worldEditorHintDismissKey(undefined)).toBe(worldEditorHintDismissKey(null))
  expect(worldEditorHintDismissKey('')).toBe(worldEditorHintDismissKey(null))
})

test('the copy is plain language — no slice codes, no flag names, no engineering caveats', () => {
  const copy = `${WORLD_EDITOR_HINT_TITLE} ${WORLD_EDITOR_HINT_BODY}`
  expect(copy).not.toMatch(/slice|V\d|_enabled|RPC|migration|jsonb/i)
  expect(WORLD_EDITOR_HINT_TITLE.length).toBeLessThanOrEqual(40)
})

// ── 2. structural proofs — the hint cannot regress chrome or drafts ─────────────────────────────────
test('map-UX law #1 survives: the clean-map default is untouched by this feature', () => {
  expect(INITIAL_WORLD_EDITOR_CHROME.openTool).toBeNull()
  expect(chromeModel).not.toMatch(/worldEditorFirstRunHint|FirstRunHint/)
})

test('the hint model is PURE — no React, no DOM, no storage IO, no network', () => {
  expect(hintModel).not.toMatch(/\bfrom 'react'|useState|useEffect/)
  expect(hintModel).not.toMatch(/localStorage\.(get|set|remove)Item|document\.|fetch\(|supabase/)
})

test('the hint component cannot summon a tool or reach a draft store', () => {
  const start = dock.indexOf('export function WorldEditorFirstRunHint')
  expect(start).toBeGreaterThan(-1)
  const body = dock.slice(start, dock.indexOf('interface DockProps', start))
  expect(body).not.toMatch(/onToggleTool|openTool|setChrome|Draft|publish/i)
  expect(body).toMatch(/onDismiss/)
})

test('the shell gates the hint on the pure predicate, never on an ad-hoc inline condition', () => {
  expect(shell).toMatch(/shouldShowFirstRunHint\(\{/)
  expect(shell).toMatch(/<WorldEditorFirstRunHint onDismiss=\{dismissHint\}/)
})

test('dismissal persistence is try/catch-guarded in BOTH directions — blocked storage degrades, never throws', () => {
  for (const fn of ['readHintDismissed', 'writeHintDismissed']) {
    const start = shell.indexOf(`function ${fn}(`)
    expect(start, `${fn} must exist`).toBeGreaterThan(-1)
    const body = shell.slice(start, shell.indexOf('\n}', start))
    expect(body, `${fn} must guard storage IO`).toMatch(/try \{[\s\S]*localStorage[\s\S]*\} catch/)
  }
})

test('the hint reads storage via lazy init — no effect, no setState-in-effect cascade', () => {
  expect(shell).toMatch(/useState\(\(\) => readHintDismissed\(hintKey\)\)/)
  const start = shell.indexOf('const dismissHint')
  expect(start).toBeGreaterThan(-1)
  // The dismiss handler writes through the guarded helper, never raw storage. Scoped to the handler
  // body itself — a wider window would bleed into neighbouring comments that mention localStorage.
  const handler = shell.slice(start, shell.indexOf('}, [hintKey])', start))
  expect(handler).toMatch(/writeHintDismissed\(hintKey\)/)
  expect(handler).not.toMatch(/localStorage/)
})
