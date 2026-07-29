import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  AUTHORING_DOMAIN_NOUNS,
  authoringEditLabel,
  authoringEditTitle,
  editPlanNeedsGuard,
  planSelectedEdit,
} from '../src/features/worldeditor/worldEditorAuthoringIntent'
import { PENDING_DRAFT_DOMAINS } from '../src/features/worldeditor/worldEditorPendingDrafts'
import { actionNeedsConfirm } from '../src/features/worldeditor/worldEditorDraftGuard'

// WORLD EDITOR — SELECTION-DERIVED EDIT. Three proof layers:
//   1. PURE planner proofs, table-driven over all four domains × active domains.
//   2. The REGRESSION the owner actually hit: selected = zone, active domain = locations → the Edit
//      control must be ENABLED and must name the zone (it used to be disabled and blame the owner).
//   3. STRUCTURAL proofs that the fix cannot become a SECOND authority: the planner takes no dirty
//      input, decides no dirtiness, and the shell routes cross-domain edits through the EXISTING
//      'switch-domain' guard as ONE atomic closure (switch + fork commit together or not at all).
// Run: `npx playwright test worldEditorAuthoringIntent.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const WE = join(here, '..', 'src', 'features', 'worldeditor')
const src = (rel: string) => readFileSync(join(WE, rel), 'utf8')

const planner = src('worldEditorAuthoringIntent.ts')
const shell = src('WorldEditor.tsx')

// ── 1. the pure planner ─────────────────────────────────────────────────────────────────────────────
test('no selection → disabled, and the tooltip never blames the owner for shell state', () => {
  for (const activeDomain of PENDING_DRAFT_DOMAINS) {
    const plan = planSelectedEdit({ selectedDomain: null, hasLiveRow: false, activeDomain })
    expect(plan).toEqual({ kind: 'disabled', reason: 'no-selection' })
    expect(editPlanNeedsGuard(plan)).toBe(false)
    expect(authoringEditLabel(plan)).toBe('Edit')
  }
})

test('a selection with no live row → disabled (an inactive entity has nothing to fork)', () => {
  const plan = planSelectedEdit({
    selectedDomain: 'zones',
    hasLiveRow: false,
    activeDomain: 'zones',
  })
  expect(plan).toEqual({ kind: 'disabled', reason: 'no-live-row' })
})

test('same-domain selection → edit-here, and it must NOT raise the switch-domain guard', () => {
  for (const domain of PENDING_DRAFT_DOMAINS) {
    const plan = planSelectedEdit({ selectedDomain: domain, hasLiveRow: true, activeDomain: domain })
    expect(plan).toEqual({ kind: 'edit-here', domain })
    expect(editPlanNeedsGuard(plan)).toBe(false)
  }
})

test('cross-domain selection → switch-then-edit, targeting the SELECTED domain (never the active one)', () => {
  for (const selectedDomain of PENDING_DRAFT_DOMAINS) {
    for (const activeDomain of PENDING_DRAFT_DOMAINS) {
      if (selectedDomain === activeDomain) continue
      const plan = planSelectedEdit({ selectedDomain, hasLiveRow: true, activeDomain })
      expect(plan).toEqual({ kind: 'switch-then-edit', domain: selectedDomain })
      expect(editPlanNeedsGuard(plan)).toBe(true)
      expect(authoringEditLabel(plan)).toBe(`Edit ${AUTHORING_DOMAIN_NOUNS[selectedDomain]}`)
    }
  }
})

test('every domain has a plain-language noun — no domain keys or slice codes leak into the caption', () => {
  for (const domain of PENDING_DRAFT_DOMAINS) {
    const noun = AUTHORING_DOMAIN_NOUNS[domain]
    expect(noun).toBeTruthy()
    expect(noun).toMatch(/^[a-z ]+$/)
    const label = authoringEditLabel({ kind: 'edit-here', domain })
    expect(label).not.toMatch(/slice|V\d|domain|_enabled/i)
  }
})

test('no tooltip tells the owner to satisfy an unrelated internal condition', () => {
  const tips = [
    authoringEditTitle({ kind: 'disabled', reason: 'no-selection' }),
    authoringEditTitle({ kind: 'disabled', reason: 'no-live-row' }),
    ...PENDING_DRAFT_DOMAINS.flatMap((domain) => [
      authoringEditTitle({ kind: 'edit-here', domain }),
      authoringEditTitle({ kind: 'switch-then-edit', domain }),
    ]),
  ]
  for (const tip of tips) {
    // the exact reported defect: "Select a location first." shown while a ZONE was selected
    expect(tip).not.toMatch(/select a (location|zone|mining field|exploration site) first/i)
    expect(tip).not.toMatch(/switch to .* (tab|domain)/i)
  }
})

// ── 2. the reported regression ──────────────────────────────────────────────────────────────────────
test('REGRESSION: zone selected on a cold load (active domain locations) → Edit is ENABLED and says "Edit zone"', () => {
  const plan = planSelectedEdit({
    selectedDomain: 'zones',
    hasLiveRow: true,
    activeDomain: 'locations', // the cold-load default
  })
  expect(plan.kind).not.toBe('disabled')
  expect(authoringEditLabel(plan)).toBe('Edit zone')
  expect(authoringEditTitle(plan)).toMatch(/zone/)
})

// ── 3. structural — the fix must not become a second authority ──────────────────────────────────────
test('the planner is PURE and takes NO dirty-state input — dirtiness stays the guard\'s alone', () => {
  expect(planner).not.toMatch(/\bfrom 'react'|useState|useEffect|localStorage|fetch\(|document\./)
  // Strip comments first: the header prose deliberately DESCRIBES what this module must not do, so a
  // raw scan would match its own documentation rather than its code.
  const code = planner.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
  expect(code).not.toMatch(/isDirty|DirtyDraftsByDomain|discardDraft|draftsAbandonedBy/)
  // and the only thing it may import is the domain vocabulary
  const imports = code.match(/^import .*$/gm) ?? []
  expect(imports).toHaveLength(1)
  expect(imports[0]).toMatch(/worldEditorPendingDrafts/)
})

test('the shell routes CROSS-domain edits through the EXISTING switch-domain guard', () => {
  const start = shell.indexOf('const requestEditSelected')
  expect(start).toBeGreaterThan(-1)
  const body = shell.slice(start, shell.indexOf('\n  }, [', start))
  expect(body).toMatch(/editPlanNeedsGuard\(plan\)/)
  expect(body).toMatch(/requestAction\('switch-domain', commit\)/)
  // …and a same-domain edit commits WITHOUT the guard
  expect(body).toMatch(/else commit\(\)/)
})

test('switch + fork commit as ONE closure — no half-applied transition, nothing forked before confirm', () => {
  const start = shell.indexOf('const commit = () =>')
  expect(start).toBeGreaterThan(-1)
  const commit = shell.slice(start, shell.indexOf('\n    }', start))
  // both effects live inside the single closure handed to the guard
  expect(commit).toMatch(/switchAuthoringDomain\(plan\.domain\)/)
  expect(commit).toMatch(/forkSelectedInto\(plan\.domain\)/)
  // the fork must NOT be invoked outside that closure (i.e. before the guard decides)
  const handler = shell.slice(
    shell.indexOf('const requestEditSelected'),
    shell.indexOf('\n  }, [', shell.indexOf('const requestEditSelected')),
  )
  expect(handler.match(/forkSelectedInto\(/g) ?? []).toHaveLength(1)
})

test('the Edit control is derived from the PLAN, never re-branched on authoringDomain', () => {
  const start = shell.indexOf('data-testid="worldeditor-inspector-edit"')
  expect(start).toBeGreaterThan(-1)
  const button = shell.slice(start - 400, start + 200)
  expect(button).toMatch(/disabled=\{selectedEditPlan\.kind === 'disabled'\}/)
  expect(button).toMatch(/authoringEditTitle\(selectedEditPlan\)/)
  expect(button).toMatch(/authoringEditLabel\(selectedEditPlan\)/)
  // the old four-way branch on authoringDomain must be gone from the inspector's Draft row
  expect(button).not.toMatch(/authoringDomain ===/)
})

test('forking ADDS a draft (fresh uuid + upsert) — an existing dirty draft is never overwritten', () => {
  const drafts = readFileSync(join(WE, 'useDrafts.ts'), 'utf8')
  const start = drafts.indexOf('const forkEditDraft')
  expect(start).toBeGreaterThan(-1)
  const body = drafts.slice(start, start + 400)
  expect(body).toMatch(/crypto\.randomUUID\(\)/)
  expect(body).toMatch(/type: 'upsert'/)
  expect(body).not.toMatch(/discard|replace|clear/i)
})

test('the guard authority itself is untouched: switch-domain still confirms iff the ACTIVE domain is dirty', () => {
  const clean = { locations: [], mining: [], exploration: [], zones: [] }
  expect(actionNeedsConfirm('switch-domain', 'locations', clean)).toBe(false)
  expect(
    actionNeedsConfirm('switch-domain', 'locations', { ...clean, locations: ['d1'] }),
  ).toBe(true)
  // a dirty OTHER domain never triggers the switch guard
  expect(actionNeedsConfirm('switch-domain', 'locations', { ...clean, zones: ['d9'] })).toBe(false)
})
