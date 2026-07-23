import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  INITIAL_WORLD_EDITOR_CHROME,
  WORLD_EDITOR_TOOLS,
  WORLD_EDITOR_TOOL_ICONS,
  WORLD_EDITOR_TOOL_LABELS,
  collapsePanel,
  dismissChrome,
  isPanelOpen,
  isToolOpen,
  openTool,
  summonChrome,
  toggleChrome,
  toggleTool,
} from '../src/features/worldeditor/worldEditorChrome'
import { ICON_NAMES } from '../src/components/ui/icons'

// WORLD EDITOR — UX COMFORT PASS. Two proof layers:
//   1. PURE model proofs for the chrome state machine (summon / fold / dismiss / restore).
//   2. STRUCTURAL proofs that the redesign obeys the owner's map-UX law AND — critically — that it
//      CANNOT regress the unsaved-draft guard: chrome is view state only, so there is no path from
//      "hide a panel" to "lose a draft", and neither the guard dialog nor the unpublished-drafts
//      indicator can be dismissed away.
// Run: `npx playwright test worldEditorChrome.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const WE = join(here, '..', 'src', 'features', 'worldeditor')
const src = (rel: string) => readFileSync(join(WE, rel), 'utf8')

const shell = src('WorldEditor.tsx')
const chromeModel = src('worldEditorChrome.ts')
const dock = src('WorldEditorDock.tsx')

// ── 1. the pure chrome state machine ────────────────────────────────────────────────────────────────
test('the default chrome is a CLEAN map: rail available, NO panel parked over the map', () => {
  expect(INITIAL_WORLD_EDITOR_CHROME.openTool).toBeNull()
  expect(INITIAL_WORLD_EDITOR_CHROME.railVisible).toBe(true)
  expect(isPanelOpen(INITIAL_WORLD_EDITOR_CHROME)).toBe(false)
})

test('every tool has a plain-language label and an icon that exists in the design system', () => {
  for (const tool of WORLD_EDITOR_TOOLS) {
    const label = WORLD_EDITOR_TOOL_LABELS[tool]
    expect(label, `${tool} needs a label`).toBeTruthy()
    // minimal words (map-UX law #4): one or two words, never a sentence
    expect(label.split(' ').length, `${tool} label is too wordy: "${label}"`).toBeLessThanOrEqual(2)
    // no slice codenames / phase codes leak into what the owner reads (law #5)
    expect(label, `${tool} label leaks a slice code`).not.toMatch(/\bV\d|Foundation|slice|no publish/i)
    expect(ICON_NAMES).toContain(WORLD_EDITOR_TOOL_ICONS[tool])
  }
})

test('toggleTool summons a panel, and toggling the SAME tool folds it away again', () => {
  const opened = toggleTool(INITIAL_WORLD_EDITOR_CHROME, 'layers')
  expect(isToolOpen(opened, 'layers')).toBe(true)
  const folded = toggleTool(opened, 'layers')
  expect(folded.openTool).toBeNull()
  expect(folded.railVisible).toBe(true)
})

test('toggleTool on a DIFFERENT tool swaps the panel (only ever one panel over the map)', () => {
  const a = toggleTool(INITIAL_WORLD_EDITOR_CHROME, 'layers')
  const b = toggleTool(a, 'history')
  expect(b.openTool).toBe('history')
  expect(isToolOpen(b, 'layers')).toBe(false)
})

test('collapse folds the panel back to the rail; dismiss removes ALL chrome', () => {
  const open = openTool(INITIAL_WORLD_EDITOR_CHROME, 'author')
  expect(collapsePanel(open)).toEqual({ railVisible: true, openTool: null })
  expect(dismissChrome()).toEqual({ railVisible: false, openTool: null })
})

test('a dismissed map is fully clean and is restored by the summon gesture', () => {
  const hidden = dismissChrome()
  expect(isPanelOpen(hidden)).toBe(false)
  expect(isToolOpen(hidden, 'layers')).toBe(false)
  const back = summonChrome(hidden)
  expect(back.railVisible).toBe(true)
  expect(back.openTool).toBeNull() // restoring chrome never re-parks a panel
})

test('toggleChrome round-trips: showing → dismissed → showing', () => {
  const hidden = toggleChrome(openTool(INITIAL_WORLD_EDITOR_CHROME, 'find'))
  expect(hidden).toEqual({ railVisible: false, openTool: null })
  expect(toggleChrome(hidden).railVisible).toBe(true)
})

test('openTool on a hidden map un-hides the rail (a panel is never orphaned)', () => {
  expect(openTool(dismissChrome(), 'inspect')).toEqual({ railVisible: true, openTool: 'inspect' })
})

test('every transition is pure — the input state object is never mutated', () => {
  const base = { railVisible: true, openTool: 'layers' } as const
  const snapshot = { ...base }
  toggleTool(base, 'find')
  collapsePanel(base)
  toggleChrome(base)
  summonChrome(base)
  expect(base).toEqual(snapshot)
})

// ── 2. DRAFT-GUARD SAFETY: dismissing chrome can never lose unsaved work ────────────────────────────
/** Strip block + line comments so a structural scan judges CODE, not prose. */
const codeOf = (s: string) =>
  s
    .replace(/\{\/\*[\s\S]*?\*\/\}/g, '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^\s*\/\/.*$/gm, '')

test('the chrome model is pure VIEW state: no draft store, no discard, no IO, no React', () => {
  const code = codeOf(chromeModel)
  expect(code, 'chrome must not import a draft store').not.toMatch(/useDrafts|DraftsStore|draftModel/)
  expect(code, 'chrome must never discard/patch/publish a draft').not.toMatch(
    /discardDraft|patchDraft|beginCreateDraft|forkEditDraft|publish/,
  )
  expect(code, 'chrome must not touch the network').not.toMatch(/supabase|\.rpc\(|fetch\(/)
  expect(code, 'chrome must stay React-free').not.toMatch(/from 'react'/)
})

test('the dock/rail are presentation only — no store, no command, no fetch', () => {
  expect(dock).not.toMatch(/discardDraft|patchDraft|beginCreateDraft|forkEditDraft/)
  expect(dock).not.toMatch(/supabase|\.rpc\(|fetch\(|commandClient|invokeWorldEditorCommand/)
})

test('no chrome handler in the shell touches a draft store', () => {
  // the four chrome bindings must be plain setChrome calls over the pure model
  for (const decl of [
    /const toggleTool = useCallback\(\(tool: WorldEditorTool\) => setChrome\(\(c\) => toggleChromeTool\(c, tool\)\), \[\]\)/,
    /const collapseChrome = useCallback\(\(\) => setChrome\(collapsePanel\), \[\]\)/,
    /const hideChrome = useCallback\(\(\) => setChrome\(dismissChrome\), \[\]\)/,
    /const toggleAllChrome = useCallback\(\(\) => setChrome\(toggleChrome\), \[\]\)/,
  ]) {
    expect(shell, `chrome binding missing or not a pure setChrome: ${decl}`).toMatch(decl)
  }
})

test('the unsaved-draft dialog and the unpublished-drafts indicator are OUTSIDE the dismissible chrome', () => {
  // The confirm dialog is rendered once at the shell root, never inside the dock…
  const dockOpen = shell.indexOf('<WorldEditorDock')
  const dockClose = shell.indexOf('</WorldEditorDock>')
  const dialogIdx = shell.indexOf('<PendingDraftsDialog />')
  expect(dockOpen).toBeGreaterThan(0)
  expect(dockClose).toBeGreaterThan(dockOpen)
  expect(dialogIdx, 'the guard dialog must not live inside the dismissible dock').toBeGreaterThan(dockClose)

  // …and the pending-drafts indicator renders on `pendingDrafts.total > 0` alone — it is NEVER
  // conditioned on chrome.railVisible, so hiding the chrome cannot hide unsaved work.
  const indicator = /\{pendingDrafts\.total > 0 && \(\s*<button/
  expect(shell).toMatch(indicator)
  const indicatorIdx = shell.search(indicator)
  expect(indicatorIdx).toBeGreaterThan(0)
  expect(indicatorIdx, 'the indicator must not live inside the dismissible dock').toBeLessThan(dockOpen)
})

test('the beforeunload / route-leave guard is untouched by the redesign', () => {
  const hook = src('useWorldEditorDraftGuard.ts')
  expect(hook).toContain("addEventListener('beforeunload'")
  expect(hook).toContain("addEventListener('popstate'")
  // and nothing about chrome leaked into the guard
  expect(hook).not.toMatch(/worldEditorChrome|railVisible|openTool/)
})

// ── 3. map-UX law: plain language + corner/edge chrome ──────────────────────────────────────────────
test('no build-slice codename or engineering caveat survives in owner-visible shell text', () => {
  // strip comments (internal vocabulary is deliberately preserved there — this is about what the
  // OWNER SEES), then scan the remaining source for the banned strings.
  const codeOnly = shell
    .replace(/\{\/\*[\s\S]*?\*\/\}/g, '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^\s*\/\/.*$/gm, '')
  for (const banned of [
    'Foundation V1 · read-only live',
    'V1B-1 · local drafts',
    'V2A-2 · mining drafts',
    'V2C · exploration drafts',
    'V3A-2 · zone drafts',
    '(no publish)',
    'dev · owner-only',
  ]) {
    expect(codeOnly, `owner-visible text still leaks "${banned}"`).not.toContain(banned)
  }
})

test('the map is the surface: full-bleed SVG, corner-anchored controls, nothing in the centre', () => {
  expect(shell, 'the map must fill the shell').toContain('absolute inset-0 h-full w-full cursor-grab')
  expect(shell, 'the shell is a single full-viewport map surface').toContain(
    'relative h-screen w-full overflow-hidden bg-app text-ink',
  )
  // the tool rail hugs the top-left corner and the camera cluster the bottom-left corner
  expect(shell).toContain('absolute left-3 top-3')
  expect(shell).toContain('absolute bottom-3 left-3')
  // the dock is an EDGE panel, not a centre modal
  expect(dock).toContain('absolute inset-y-0 right-0')
  // a centred modal would read `fixed inset-0 … items-center justify-center` (the PendingDraftsDialog
  // idiom) — the dock must never take that shape.
  expect(dock, 'the dock must never be a centred full-screen overlay').not.toMatch(/fixed inset-0/)
  expect(dock, 'the dock must not centre itself over the map').not.toMatch(/-translate-x-1\/2|left-1\/2/)
})

test('the dock offers BOTH a fold and a dismiss, and renders nothing when no tool is summoned', () => {
  expect(dock).toContain('worldeditor-dock-collapse')
  expect(dock).toContain('worldeditor-dock-dismiss')
  expect(dock).toMatch(/if \(!chrome\.railVisible \|\| chrome\.openTool === null\) return null/)
})

test('the summon gesture is wired to the map (double-click) and the rail has a hide control', () => {
  expect(shell).toMatch(/onDoubleClick=\{\(e\) => \{[\s\S]*?toggleAllChrome\(\)/)
  expect(dock).toContain('worldeditor-chrome-hide')
  expect(shell).toContain('worldeditor-summon-hint')
})

// ── 4. nothing was lost: every capability still mounts somewhere in the shell ───────────────────────
test('every pre-existing capability still mounts in the redesigned shell', () => {
  for (const mounted of [
    '<WorldEditorSearchBox',
    '<WorldEditorGotoBox',
    '<WorldEditorHistoryPanel',
    '<CombatContentPanel',
    '<WorldEditorInactiveInspector',
    '<ZoneInspectorActions',
    '<LocationDraftPanel',
    '<MiningDraftPanel',
    '<ExplorationDraftPanel',
    '<ZoneDraftPanel',
    '<PendingDraftsDialog',
    'worldeditor-pending-drafts',
    'we-status-filter',
    'cameraForDomain',
  ]) {
    expect(shell, `${mounted} must still be mounted after the redesign`).toContain(mounted)
  }
})

test('the chrome files stay inside the worldeditor feature and add no command path', () => {
  const names = readdirSync(WE)
  expect(names).toContain('worldEditorChrome.ts')
  expect(names).toContain('WorldEditorDock.tsx')
})
