import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// WORLD EDITOR V5 LIFECYCLE — STRUCTURAL proofs for the shell wiring that a pure model test can't reach
// (JSX rendering + effect orchestration). We assert the invariants the spec pins as source facts:
//   • the inactive inspector NEVER renders a revision field and derives NOTHING from the audit ledger;
//   • updated_at is rendered ONLY when non-null;
//   • a successful reactivation refreshes BOTH the catalog AND the active domain reader;
//   • changing the lifecycle filter clears ONLY the visible selection and NEVER touches a draft store
//     (draft safety — drafts live in their own stores);
//   • the map/search source is the 0269 catalog, and search is passed the shared filter.
// Run: `npx playwright test worldEditorLifecycleWiring.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', 'features', 'worldeditor', rel), 'utf8')

const inactiveInspector = src('WorldEditorInactiveInspector.tsx')
const shell = src('WorldEditor.tsx')
const filters = src('worldEditorFilters.ts')

// ── inactive inspector: no revision, no audit derivation, updated_at guarded ─────────────────────────
test('the inactive inspector never renders a revision field and never derives from the audit ledger', () => {
  // revision is never READ off the row for display (you cannot render what you never read)…
  expect(inactiveInspector).not.toMatch(/row\.revision/)
  // …and no revision label is rendered in JSX (a `>Revision` / `Revision<` text node)…
  expect(inactiveInspector).not.toMatch(/>\s*Revision|Revision\s*</)
  // …and nothing is derived from the audit ledger.
  expect(inactiveInspector).not.toMatch(/audit/i)
})

test('the inactive inspector renders updated_at ONLY when non-null', () => {
  // the display is guarded by a non-null check on the row's updatedAt
  expect(inactiveInspector).toMatch(/row\.updatedAt\s*!=\s*null/)
})

test('the inactive inspector routes failures through the shared error copy + inline Notice', () => {
  expect(inactiveInspector).toContain('describeWorldEditorError')
  expect(inactiveInspector).toContain('onReactivated')
})

// ── reactivation refreshes BOTH the catalog and the active domain reader ─────────────────────────────
test('onReactivated refreshes BOTH the catalog and the active domain reader (reloadData)', () => {
  const m = shell.match(/const onReactivated = useCallback\(async \(\) => \{([\s\S]*?)\},/)
  expect(m).not.toBeNull()
  const body = m![1]
  expect(body).toContain('reloadCatalog')
  expect(body).toContain('reloadData')
})

// ── draft safety: filter change clears only the visible selection, never a draft store ───────────────
test('changeStatusFilter clears only the visible selection and never touches a draft store', () => {
  const m = shell.match(/const changeStatusFilter = useCallback\(([\s\S]*?)\[catalogRows\],\s*\)/)
  expect(m).not.toBeNull()
  const body = m![1]
  // it may clear the selection...
  expect(body).toContain('setSelected')
  // ...but must NOT discard / patch / mutate any draft store from the filter change
  expect(body).not.toMatch(/discardDraft|patchDraft|beginCreateDraft|forkEditDraft|DraftStore/)
})

// ── the catalog is the ONE map/search source; search obeys the shared filter ─────────────────────────
test('the shell builds the map/search item source from the 0269 catalog and passes the filter to search', () => {
  expect(shell).toContain('catalogItemsByLayer(catalogRows)')
  expect(shell).toMatch(/WorldEditorSearchBox[\s\S]*statusFilter=\{statusFilter\}/)
})

// ── the filter module is pure (no store / no IO) ─────────────────────────────────────────────────────
test('worldEditorFilters is a pure view filter: no supabase, no draft-store import, no IO', () => {
  expect(filters).not.toMatch(/supabase|\.rpc\(|fetch\(/)
  expect(filters).not.toMatch(/useDrafts|DraftsStore/)
})
