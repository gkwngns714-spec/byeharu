import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR V5 — STRUCTURAL proofs that the ONE unsaved-draft guard is wired into EVERY
// context-changing call site (JSX + handler orchestration a pure model test can't reach). The guard
// DECISION is proven in worldEditorDraftGuard.spec.ts; here we pin the source facts:
//   • the shell provides the guard context + renders the confirm dialog once;
//   • every in-page context change (map select, search jump, camera jump, tab switch, filter change)
//     routes through guard.requestAction with the right action kind;
//   • the command/nav surfaces (History open + revert, zone unpublish/reactivate, inactive reactivate)
//     route through the guard from context;
//   • the conflict "Reload live version" is wired into the three publish/reactivate/revert surfaces;
//   • the browser refresh/close + SPA back guards live in the hook;
//   • the guard decision module stays pure (no React / no IO).
// Run: `npx playwright test worldEditorDraftGuardWiring.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', 'features', 'worldeditor', rel), 'utf8')

const shell = src('WorldEditor.tsx')
const hook = src('useWorldEditorDraftGuard.ts')
const guard = src('worldEditorDraftGuard.ts')
const dialog = src('PendingDraftsDialog.tsx')
const conflict = src('WorldEditorConflictNotice.tsx')
const historyPanel = src('WorldEditorHistoryPanel.tsx')
const historyDetail = src('WorldEditorHistoryDetail.tsx')
const inactiveInspector = src('WorldEditorInactiveInspector.tsx')
const zoneActions = src('ZoneInspectorActions.tsx')

// ── the shell provides the guard + renders the dialog once ────────────────────────────────────────────
test('the shell builds the guard, provides it via context, and renders the confirm dialog once', () => {
  expect(shell).toContain('useWorldEditorDraftGuard(')
  expect(shell).toContain('<WorldEditorDraftGuardContext.Provider value={draftGuard}>')
  expect(shell).toContain('<PendingDraftsDialog />')
})

// ── every in-page context change routes through the guard with its action kind ────────────────────────
test('picking an entity routes through the guard, not a raw setSelected', () => {
  expect(shell).toContain("requestAction('select-entity'")
  // Map picking has ONE entry point instead of a per-shape onClick on every polygon and marker — that
  // duplication is what let a co-located location steal a zone's clicks. The svg now routes through the
  // shell-owned onMapClick router, which decides selection-vs-authoring before the hit test runs.
  expect(shell).toContain('onClick={(e) => onMapClick(e.clientX, e.clientY)}')
  expect(shell).toContain('requestSelect({ layer: only.layer, id: only.id })')
  expect(shell).toContain('requestSelect({ layer: c.layer, id: c.id })')
  expect(shell).toContain('requestSelect(null)')
  // and no shape may select on its own any more
  expect(shell).not.toContain('e.stopPropagation(); requestSelect(')
})

// A DESELECT IS NOT GUARDED, and this test used to assert the opposite. Clearing the selection writes
// no draft, discards none, closes no panel and changes no domain — so routing it through the guard put
// "Discard and continue" (which DISCARDS the draft) in front of an action that risked nothing, and
// since a click on empty map deselects, that fired on every miss while drawing a polygon.
test('a deselect clears directly and never reaches the guard', () => {
  const sel = shell.slice(shell.indexOf('const requestSelect = useCallback('))
  const body = sel.slice(0, sel.indexOf('}, [])'))
  expect(body).toMatch(/if \(next === null\)[\s\S]*setSelected\(null\)[\s\S]*return/)
  // the guard is still consulted for a real selection CHANGE, after that early return
  expect(body.indexOf('next === null')).toBeLessThan(body.indexOf("requestAction('select-entity'"))
})

test('search jump, camera jump, tab switch and filter change each route through the guard', () => {
  expect(shell).toContain("requestAction('search-jump'")
  expect(shell).toContain("requestAction('camera-jump'")
  expect(shell).toContain("requestAction('switch-domain'")
  expect(shell).toContain("requestAction('change-filter'")
  // the tabs call the guarded switch (not switchAuthoringDomain directly)
  expect(shell).toContain('requestSwitchDomain(d)')
})

// ── command / nav surfaces route through the guard from context ───────────────────────────────────────
test('opening another history record is guarded', () => {
  expect(historyPanel).toContain('useDraftGuard')
  expect(historyPanel).toContain("requestAction('open-history'")
})

test('the History revert confirm is guarded', () => {
  expect(historyDetail).toContain('useDraftGuard')
  expect(historyDetail).toContain("requestAction('revert'")
})

test('the inactive reactivate is guarded', () => {
  expect(inactiveInspector).toContain('useDraftGuard')
  expect(inactiveInspector).toContain("requestAction('reactivate'")
})

test('the zone unpublish / reactivate is guarded (direction picks the action kind)', () => {
  expect(zoneActions).toContain('useDraftGuard')
  expect(zoneActions).toContain("requestAction(status === 'active' ? 'unpublish' : 'reactivate'")
})

// ── conflict "Reload live version" is wired into the three publish/reactivate/revert surfaces ─────────
test('the conflict notice offers an explicit Reload live version and self-hides for non-conflict errors', () => {
  expect(conflict).toContain('isLiveConflict')
  expect(conflict).toContain('worldeditor-reload-live')
  expect(conflict).toContain('Reload live version')
})

test('every command surface mounts the conflict notice and threads a reload-live handler', () => {
  for (const [name, s] of [
    ['WorldEditorHistoryDetail', historyDetail],
    ['WorldEditorInactiveInspector', inactiveInspector],
    ['ZoneInspectorActions', zoneActions],
  ] as const) {
    expect(s, `${name} mounts the conflict notice`).toContain('WorldEditorConflictNotice')
    expect(s, `${name} threads onReloadLive`).toContain('onReloadLive')
  }
  // the shell threads its ONE reloadLive into all three surfaces
  expect(shell).toContain('onReloadLive={reloadLive}')
})

// ── the browser refresh/close + SPA route-leave guards live in the hook ───────────────────────────────
test('the hook installs the beforeunload + popstate leave guards and discards only via store.discardDraft', () => {
  expect(hook).toContain("addEventListener('beforeunload'")
  expect(hook).toContain("addEventListener('popstate'")
  expect(hook).toContain('beforeUnloadShouldWarn')
  // discard is the SAME store action the panels use — scoped to the abandoned draft, never a bulk wipe
  expect(hook).toContain('discardDraft')
})

// ── the decision module stays pure (no React, no IO) ──────────────────────────────────────────────────
test('worldEditorDraftGuard is a pure decision module: no React, no supabase, no fetch/rpc', () => {
  expect(guard).not.toMatch(/from 'react'/)
  expect(guard).not.toMatch(/supabase|\.rpc\(|fetch\(/)
  expect(guard).not.toMatch(/useState|useEffect|useCallback/)
})

// ── the dialog offers EXACTLY the two spec'd actions ──────────────────────────────────────────────────
test('the dialog offers exactly Keep editing + Discard and continue', () => {
  expect(dialog).toContain('Keep editing')
  expect(dialog).toContain('Discard and continue')
  expect(dialog).toContain('guard.keepEditing')
  expect(dialog).toContain('guard.discardAndContinue')
})
