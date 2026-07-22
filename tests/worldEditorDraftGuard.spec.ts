import { test, expect } from '@playwright/test'
import {
  actionNeedsConfirm,
  allDirtyDrafts,
  beforeUnloadShouldWarn,
  draftsAbandonedBy,
  isLiveConflict,
  type DirtyDraftsByDomain,
  type GuardedActionKind,
} from '../src/features/worldeditor/worldEditorDraftGuard'
import type { PendingDraftDomain } from '../src/features/worldeditor/worldEditorPendingDrafts'
import { beginCreate, isDirty, patch } from '../src/features/worldeditor/draftModel'
import { LOCATION_DRAFT_DESCRIPTOR } from '../src/features/worldeditor/locationDraftModel'
import { MINING_DRAFT_DESCRIPTOR } from '../src/features/worldeditor/miningDraftModel'
import { EXPLORATION_DRAFT_DESCRIPTOR } from '../src/features/worldeditor/explorationDraftModel'
import { ZONE_DRAFT_DESCRIPTOR } from '../src/features/worldeditor/zoneDraftModel'
import type { WorldEditorErrorCode } from '../src/features/worldeditor/commandContract'

// WORLD EDITOR V5 — pure proofs for the unsaved-draft NAVIGATION GUARD (worldEditorDraftGuard). No
// browser/DB: the guard decision is pure (per-domain DIRTY-draft ids + a requested action → whether to
// confirm + exactly which drafts a discard would drop). It is the ONE authority that stops a
// context-changing action from silently abandoning locally-authored unpublished edits. The React binding
// (dialog state + beforeunload/popstate listeners) lives in useWorldEditorDraftGuard.ts; these specs pin
// the DECISION + the real dirtiness derivation the hook feeds it. Run: `npx playwright test
// worldEditorDraftGuard.spec.ts`.

const NOW = 1_700_000_000_000

/** Assemble a DirtyDraftsByDomain from per-domain dirty-id lists (every key present, [] when clean). */
const dirty = (o: Partial<Record<PendingDraftDomain, readonly string[]>>): DirtyDraftsByDomain => ({
  locations: o.locations ?? [],
  mining: o.mining ?? [],
  exploration: o.exploration ?? [],
  zones: o.zones ?? [],
})

const CLEAN: DirtyDraftsByDomain = dirty({})

// Every SCOPED (in-page) guarded action — each endangers ONLY the active authoring domain's dirty work.
const SCOPED_ACTIONS: readonly GuardedActionKind[] = [
  'select-entity',
  'search-jump',
  'camera-jump',
  'switch-domain',
  'change-filter',
  'open-history',
  'revert',
  'unpublish',
  'reactivate',
]

// ── real dirtiness derivation (what the hook feeds the pure decision) ─────────────────────────────────
// A blank create is CLEAN (nothing to lose); patching a field makes it DIRTY. This is the ONE isDirty
// predicate the guard hook filters each store's drafts by, proven per authoring domain.

test('a patched location form is DIRTY; a blank location create is CLEAN', () => {
  const blank = beginCreate(LOCATION_DRAFT_DESCRIPTOR, 'loc-1', NOW)
  expect(isDirty(LOCATION_DRAFT_DESCRIPTOR, blank)).toBe(false)
  const edited = patch(blank, { name: 'Alpha Station' }, NOW + 1)
  expect(isDirty(LOCATION_DRAFT_DESCRIPTOR, edited)).toBe(true)
})

test('a patched mining form is DIRTY; a blank mining create is CLEAN', () => {
  const blank = beginCreate(MINING_DRAFT_DESCRIPTOR, 'min-1', NOW)
  expect(isDirty(MINING_DRAFT_DESCRIPTOR, blank)).toBe(false)
  const edited = patch(blank, { space_x: 1234 }, NOW + 1)
  expect(isDirty(MINING_DRAFT_DESCRIPTOR, edited)).toBe(true)
})

test('a patched exploration form is DIRTY; a blank exploration create is CLEAN', () => {
  const blank = beginCreate(EXPLORATION_DRAFT_DESCRIPTOR, 'exp-1', NOW)
  expect(isDirty(EXPLORATION_DRAFT_DESCRIPTOR, blank)).toBe(false)
  const edited = patch(blank, { space_y: -42 }, NOW + 1)
  expect(isDirty(EXPLORATION_DRAFT_DESCRIPTOR, edited)).toBe(true)
})

test('a drawn zone geometry is DIRTY; a blank zone create is CLEAN', () => {
  const blank = beginCreate(ZONE_DRAFT_DESCRIPTOR, 'zone-1', NOW)
  expect(isDirty(ZONE_DRAFT_DESCRIPTOR, blank)).toBe(false)
  const drawn = patch(
    blank,
    { geometry: { kind: 'polygon', vertices: [{ x: 1, y: 1 }, { x: 2, y: 2 }, { x: 3, y: 1 }] } },
    NOW + 1,
  )
  expect(isDirty(ZONE_DRAFT_DESCRIPTOR, drawn)).toBe(true)
})

test('patching a field back to its baseline returns the draft to CLEAN (no phantom guard)', () => {
  const blank = beginCreate(LOCATION_DRAFT_DESCRIPTOR, 'loc-2', NOW)
  const edited = patch(blank, { name: 'Temp' }, NOW + 1)
  expect(isDirty(LOCATION_DRAFT_DESCRIPTOR, edited)).toBe(true)
  const reverted = patch(edited, { name: '' }, NOW + 2)
  expect(isDirty(LOCATION_DRAFT_DESCRIPTOR, reverted)).toBe(false)
})

// ── the guard decision: every context-changing action confirms while the active domain is dirty ───────

test('search jump while the active domain is dirty needs a confirm', () => {
  expect(actionNeedsConfirm('search-jump', 'locations', dirty({ locations: ['d1'] }))).toBe(true)
})

test('map selection while the active domain is dirty needs a confirm', () => {
  expect(actionNeedsConfirm('select-entity', 'zones', dirty({ zones: ['z1'] }))).toBe(true)
})

test('tab change while the active domain is dirty needs a confirm', () => {
  expect(actionNeedsConfirm('switch-domain', 'mining', dirty({ mining: ['m1'] }))).toBe(true)
})

test('filter change (hiding the selection) while dirty needs a confirm', () => {
  expect(actionNeedsConfirm('change-filter', 'exploration', dirty({ exploration: ['e1'] }))).toBe(true)
})

test('revert / unpublish / reactivate while the active domain is dirty each need a confirm', () => {
  const d = dirty({ zones: ['z1'] })
  expect(actionNeedsConfirm('revert', 'zones', d)).toBe(true)
  expect(actionNeedsConfirm('unpublish', 'zones', d)).toBe(true)
  expect(actionNeedsConfirm('reactivate', 'zones', d)).toBe(true)
})

test('every scoped action confirms iff the ACTIVE domain is dirty (a dirty OTHER domain never triggers it)', () => {
  for (const kind of SCOPED_ACTIONS) {
    // active domain dirty → confirm
    expect(actionNeedsConfirm(kind, 'locations', dirty({ locations: ['d1'] })), `${kind}: active dirty`).toBe(true)
    // only a DIFFERENT domain dirty → no confirm (you are not abandoning the active context's work)
    expect(actionNeedsConfirm(kind, 'locations', dirty({ zones: ['z1'] })), `${kind}: other dirty`).toBe(false)
  }
})

// ── CLEAN state proceeds WITHOUT a dialog ─────────────────────────────────────────────────────────────
test('a CLEAN authoring context proceeds without a dialog for every action', () => {
  for (const kind of [...SCOPED_ACTIONS, 'leave-route', 'before-unload'] as GuardedActionKind[]) {
    expect(actionNeedsConfirm(kind, 'locations', CLEAN), `${kind} clean`).toBe(false)
    expect(draftsAbandonedBy(kind, 'locations', CLEAN), `${kind} clean set`).toEqual([])
  }
})

// ── whole-surface leaves endanger EVERY domain's dirty work ───────────────────────────────────────────
test('leaving the route / unloading endangers dirty drafts across ALL domains, not just the active one', () => {
  const d = dirty({ locations: ['l1'], zones: ['z1', 'z2'] })
  // active domain is mining (clean) — yet a whole-surface leave still endangers locations + zones
  expect(actionNeedsConfirm('leave-route', 'mining', d)).toBe(true)
  expect(actionNeedsConfirm('before-unload', 'mining', d)).toBe(true)
  expect(draftsAbandonedBy('before-unload', 'mining', d)).toEqual([
    { domain: 'locations', draftId: 'l1' },
    { domain: 'zones', draftId: 'z1' },
    { domain: 'zones', draftId: 'z2' },
  ])
})

// ── discarding one draft does NOT delete unrelated pending drafts ─────────────────────────────────────
// The affected set a "Discard and continue" drops is EXACTLY the endangered scope — never a draft in
// another domain, and (for scoped actions) never another domain's dirty work.
test('a scoped action abandons ONLY the active domain — unrelated pending drafts are never in the discard set', () => {
  const d = dirty({ locations: ['keep-a', 'keep-b'], zones: ['drop-z'] })
  const abandoned = draftsAbandonedBy('select-entity', 'zones', d)
  expect(abandoned).toEqual([{ domain: 'zones', draftId: 'drop-z' }])
  // the two location drafts are NOT in the discard set — an unrelated domain is never touched
  expect(abandoned.some((a) => a.domain === 'locations')).toBe(false)
})

// ── browser beforeunload: the handler decision (dirty vs clean) ───────────────────────────────────────
test('beforeUnloadShouldWarn warns iff ANY domain holds a dirty draft', () => {
  expect(beforeUnloadShouldWarn(CLEAN)).toBe(false)
  expect(beforeUnloadShouldWarn(dirty({ exploration: ['e1'] }))).toBe(true)
  expect(beforeUnloadShouldWarn(dirty({ locations: ['l1'], mining: ['m1'] }))).toBe(true)
})

test('allDirtyDrafts lists every dirty draft across domains in registry order', () => {
  const d = dirty({ zones: ['z1'], locations: ['l1'], mining: ['m1'] })
  expect(allDirtyDrafts(d)).toEqual([
    { domain: 'locations', draftId: 'l1' },
    { domain: 'mining', draftId: 'm1' },
    { domain: 'zones', draftId: 'z1' },
  ])
})

// ── conflict behaviour: which command errors are a LIVE-DRIFT conflict (offer Reload live version) ─────
test('isLiveConflict is true for the optimistic-concurrency / live-drift codes and false otherwise', () => {
  const conflicts: WorldEditorErrorCode[] = ['stale_revision', 'conflict', 'source_missing', 'not_found']
  for (const c of conflicts) expect(isLiveConflict(c), c).toBe(true)
  const nonConflicts: WorldEditorErrorCode[] = [
    'not_authenticated',
    'not_authorized',
    'invalid_request',
    'duplicate_request',
    'validation_failed',
    'not_unpublishable',
    'not_revertable',
    'not_enabled',
    'transport_error',
  ]
  for (const c of nonConflicts) expect(isLiveConflict(c), c).toBe(false)
})
