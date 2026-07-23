import { test, expect } from '@playwright/test'
import {
  pendingDraftsSummary,
  pendingDomains,
  nextPendingDomain,
  PENDING_DRAFT_DOMAINS,
  type DomainDraftsView,
  type PendingDraftDomain,
} from '../src/features/worldeditor/worldEditorPendingDrafts'

// WORLD EDITOR V5 — pure proofs for the cross-domain PENDING-DRAFTS selector
// (worldEditorPendingDrafts). No browser/DB: the selector is pure (per-domain draft views in → a
// {total, byDomain} summary out) and reads ONLY `.drafts.length`. It sums unpublished authoring work
// across all four domains for the shell's single compact indicator, without touching any store, draft,
// or publish path. Run: `npx playwright test worldEditorPendingDrafts.spec.ts`.

/** A domain view holding `n` placeholder drafts (the selector never inspects a draft's contents — it
 *  only counts presence, so opaque markers are faithful to what it reads). */
const view = (n: number): DomainDraftsView => ({ drafts: Array.from({ length: n }, (_, i) => ({ i })) })

/** Assemble the four-domain store map the shell passes in. */
const stores = (
  counts: Partial<Record<PendingDraftDomain, number>>,
): Record<PendingDraftDomain, DomainDraftsView> => ({
  locations: view(counts.locations ?? 0),
  mining: view(counts.mining ?? 0),
  exploration: view(counts.exploration ?? 0),
  zones: view(counts.zones ?? 0),
})

// ── domain authority ─────────────────────────────────────────────────────────────────────────────────
test('PENDING_DRAFT_DOMAINS is the four domains in registry order', () => {
  expect(PENDING_DRAFT_DOMAINS).toEqual(['locations', 'mining', 'exploration', 'zones'])
})

// ── total: sums across domains ──────────────────────────────────────────────────────────────────────
test('total sums the present drafts across ALL four domains', () => {
  const s = pendingDraftsSummary(stores({ locations: 2, mining: 1, exploration: 3, zones: 4 }))
  expect(s.total).toBe(10)
  expect(s.byDomain).toEqual({ locations: 2, mining: 1, exploration: 3, zones: 4 })
})

// ── zero state: nothing pending ─────────────────────────────────────────────────────────────────────
test('zero when no drafts exist anywhere (every domain key present and 0)', () => {
  const s = pendingDraftsSummary(stores({}))
  expect(s.total).toBe(0)
  expect(s.byDomain).toEqual({ locations: 0, mining: 0, exploration: 0, zones: 0 })
  expect(pendingDomains(s)).toEqual([])
})

// ── per-domain breakdown is exact + isolated ────────────────────────────────────────────────────────
test('per-domain breakdown attributes each count to the right domain only', () => {
  const s = pendingDraftsSummary(stores({ zones: 5 }))
  expect(s.total).toBe(5)
  expect(s.byDomain).toEqual({ locations: 0, mining: 0, exploration: 0, zones: 5 })
  expect(pendingDomains(s)).toEqual(['zones'])
})

test('pendingDomains lists only domains with drafts, in registry order', () => {
  const s = pendingDraftsSummary(stores({ mining: 1, zones: 2 }))
  expect(pendingDomains(s)).toEqual(['mining', 'zones'])
})

// ── ignores published/discarded: only PRESENT drafts count ──────────────────────────────────────────
// A discarded draft has left its store, and publish does not exist in this layer — so a store's
// `.drafts` array IS exactly the set of pending (unpublished, undiscarded) drafts. An empty store
// therefore contributes nothing, exactly like a store whose only draft was discarded.
test('ignores published/discarded work: an emptied store contributes 0', () => {
  const before = pendingDraftsSummary(stores({ locations: 1, mining: 2 }))
  expect(before.total).toBe(3)
  // mining's drafts were all discarded (store now empty); locations' single draft was "published"
  // out of the layer (also gone). Only what REMAINS in a store is pending.
  const after = pendingDraftsSummary(stores({ locations: 0, mining: 0 }))
  expect(after.total).toBe(0)
  expect(pendingDomains(after)).toEqual([])
})

// ── nextPendingDomain: jump target (cycles, skips empties) ───────────────────────────────────────────
test('nextPendingDomain returns null when nothing is pending', () => {
  const s = pendingDraftsSummary(stores({}))
  expect(nextPendingDomain(s, 'locations')).toBeNull()
})

test('nextPendingDomain jumps to the next pending domain after current, skipping empty ones', () => {
  // pending: locations + zones. From locations, the next pending (wrapping past empty mining/exploration)
  // is zones.
  const s = pendingDraftsSummary(stores({ locations: 1, zones: 1 }))
  expect(nextPendingDomain(s, 'locations')).toBe('zones')
  // from zones it wraps back to locations
  expect(nextPendingDomain(s, 'zones')).toBe('locations')
  // from a non-pending domain in between, it still finds the next pending one
  expect(nextPendingDomain(s, 'mining')).toBe('zones')
  expect(nextPendingDomain(s, 'exploration')).toBe('zones')
})

test('nextPendingDomain returns current when it is the ONLY domain with pending drafts', () => {
  const s = pendingDraftsSummary(stores({ mining: 2 }))
  expect(nextPendingDomain(s, 'mining')).toBe('mining')
  // and still points AT the sole pending domain when starting elsewhere
  expect(nextPendingDomain(s, 'locations')).toBe('mining')
})

test('nextPendingDomain walks through every pending domain over repeated clicks', () => {
  const s = pendingDraftsSummary(stores({ locations: 1, mining: 1, exploration: 1, zones: 1 }))
  const walk: PendingDraftDomain[] = []
  let cur: PendingDraftDomain = 'locations'
  for (let i = 0; i < 4; i++) {
    const nxt = nextPendingDomain(s, cur)!
    walk.push(nxt)
    cur = nxt
  }
  // from locations: mining → exploration → zones → locations (full ring)
  expect(walk).toEqual(['mining', 'exploration', 'zones', 'locations'])
})

// ── purity: input stores never mutated ──────────────────────────────────────────────────────────────
test('pendingDraftsSummary NEVER mutates its input stores', () => {
  const input = stores({ locations: 2, zones: 1 })
  const snapshot = input.locations.drafts.length + input.zones.drafts.length
  pendingDraftsSummary(input)
  pendingDomains(pendingDraftsSummary(input))
  nextPendingDomain(pendingDraftsSummary(input), 'locations')
  expect(input.locations.drafts.length + input.zones.drafts.length).toBe(snapshot)
})
