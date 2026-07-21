import { test, expect } from '@playwright/test'
import {
  applyFailure,
  applyInitialSuccess,
  applyNextPageSuccess,
  beginInitial,
  beginNextPage,
  dispose,
  initialAuditRequestState,
  isCurrent,
  selectEntry,
} from '../src/features/worldeditor/worldEditorAuditRequestState'
import type {
  WorldEditorAuditEntry,
  WorldEditorAuditFailure,
  WorldEditorAuditPage,
} from '../src/features/worldeditor/worldEditorAuditTypes'

// WORLD EDITOR V1.5 — BEHAVIORAL tests for the pure request-lifecycle coordinator: stale-response
// rejection, keyset pagination (dedup + stable order), filter reset, retry, disposal, and duplicate
// next-page prevention. No React, no Supabase.

const entry = (id: string): WorldEditorAuditEntry => ({
  id,
  requestId: `r-${id}`,
  commandType: 'zone_unpublish',
  targetType: 'zone',
  targetId: 't',
  createdAt: 'now',
  sourceRevision: null,
  result: null,
  actorIsOwner: true,
  before: null,
  after: null,
  redactions: [],
})
const page = (ids: string[], next: { ts: string; id: string } | null = null): WorldEditorAuditPage => ({
  ok: true,
  pageSize: 25,
  nextCursor: next,
  items: ids.map(entry),
})
const fail = (error: WorldEditorAuditFailure['error']): WorldEditorAuditFailure => ({ ok: false, error })
const loaded = (ids: string[], next: { ts: string; id: string } | null = null) => {
  const b = beginInitial(initialAuditRequestState())
  return applyInitialSuccess(b.state, b.gen, page(ids, next))
}

test('1: a current initial response is accepted (entries + cursor set, loading cleared)', () => {
  const { state, gen } = beginInitial(initialAuditRequestState())
  expect(state.loadingInitial).toBe(true)
  const s = applyInitialSuccess(state, gen, page(['a', 'b'], { ts: 't', id: 'b' }))
  expect(s.entries.map((e) => e.id)).toEqual(['a', 'b'])
  expect(s.cursor).toEqual({ ts: 't', id: 'b' })
  expect(s.loadingInitial).toBe(false)
})

test('2: an older initial response is rejected after a newer request begins', () => {
  const older = beginInitial(initialAuditRequestState()) // gen 1
  const newer = beginInitial(older.state) // gen 2
  expect(isCurrent(newer.state, older.gen)).toBe(false)
  const s = applyInitialSuccess(newer.state, older.gen, page(['x']))
  expect(s.entries).toEqual([]) // rejected — nothing applied
})

test('3: an initial response from the previous filter generation is rejected', () => {
  const g1 = beginInitial(initialAuditRequestState())
  const applied = applyInitialSuccess(g1.state, g1.gen, page(['a']))
  const g2 = beginInitial(applied) // filter change → new generation, clears entries
  const stale = applyInitialSuccess(g2.state, g1.gen, page(['old']))
  expect(stale.entries).toEqual([])
})

test('4: changing filters invalidates an in-flight next-page request', () => {
  const s = loaded(['a'], { ts: 't', id: 'a' })
  const np = beginNextPage(s)
  expect(np).not.toBeNull()
  const changed = beginInitial(np!.state) // filter change bumps generation
  const stale = applyNextPageSuccess(changed.state, np!.gen, page(['b']))
  expect(stale.entries).toEqual([]) // new initial cleared entries; stale next-page ignored
})

test('5: a valid current next-page response is appended and advances the cursor', () => {
  const s = loaded(['a', 'b'], { ts: 't', id: 'b' })
  const np = beginNextPage(s)!
  const after = applyNextPageSuccess(np.state, np.gen, page(['c', 'd'], null))
  expect(after.entries.map((e) => e.id)).toEqual(['a', 'b', 'c', 'd'])
  expect(after.cursor).toBeNull()
  expect(after.nextPageInFlight).toBe(false)
})

test('6: a stale next-page response is rejected', () => {
  const s = loaded(['a'], { ts: 't', id: 'a' })
  const np = beginNextPage(s)!
  const changed = beginInitial(np.state) // supersede
  const stale = applyNextPageSuccess(changed.state, np.gen, page(['b']))
  expect(stale.entries).toEqual([])
})

test('7: two next-page responses for one in-flight request do not duplicate entries', () => {
  const s = loaded(['a', 'b'], { ts: 't', id: 'b' })
  const np = beginNextPage(s)!
  const first = applyNextPageSuccess(np.state, np.gen, page(['c'], null))
  // a second (duplicate/racing) response for the SAME page is ignored — nextPageInFlight already cleared
  const second = applyNextPageSuccess(first, np.gen, page(['c']))
  expect(second.entries.map((e) => e.id)).toEqual(['a', 'b', 'c'])
})

test('8: duplicate IDs within one returned page do not create duplicate entries', () => {
  const s = loaded(['a'], { ts: 't', id: 'a' })
  const np = beginNextPage(s)!
  const after = applyNextPageSuccess(np.state, np.gen, page(['b', 'b', 'c']))
  expect(after.entries.map((e) => e.id)).toEqual(['a', 'b', 'c'])
})

test('9: existing entry order remains stable when a page is appended', () => {
  const s = loaded(['a', 'b', 'c'], { ts: 't', id: 'c' })
  const np = beginNextPage(s)!
  const after = applyNextPageSuccess(np.state, np.gen, page(['c', 'd'])) // c overlaps
  expect(after.entries.map((e) => e.id)).toEqual(['a', 'b', 'c', 'd'])
})

test('10: a new initial response replaces the prior filtered result set', () => {
  const s = loaded(['a', 'b'], { ts: 't', id: 'b' })
  const g2 = beginInitial(s)
  const replaced = applyInitialSuccess(g2.state, g2.gen, page(['x', 'y']))
  expect(replaced.entries.map((e) => e.id)).toEqual(['x', 'y'])
})

test('11: a filter reset (beginInitial) clears entries, cursor, selection, and error', () => {
  let s = loaded(['a', 'b'], { ts: 't', id: 'b' })
  s = selectEntry(s, 'a')
  s = applyFailure(s, s.generation, fail('invalid_request'))
  const reset = beginInitial(s).state
  expect(reset.entries).toEqual([])
  expect(reset.cursor).toBeNull()
  expect(reset.selectedId).toBeNull()
  expect(reset.error).toBeNull()
})

test('12: a response received after disposal (unmount) is rejected', () => {
  const { state, gen } = beginInitial(initialAuditRequestState())
  const disposed = dispose(state)
  expect(isCurrent(disposed, gen)).toBe(false)
  const s = applyInitialSuccess(disposed, gen, page(['a']))
  expect(s.entries).toEqual([])
})

test('13: a second load-more is rejected while the current next-page request is active', () => {
  const s = loaded(['a'], { ts: 't', id: 'a' })
  const first = beginNextPage(s)
  expect(first).not.toBeNull()
  const second = beginNextPage(first!.state) // already in flight
  expect(second).toBeNull()
})

test('14: retry uses the current generation and does not revive an older one', () => {
  const g1 = beginInitial(initialAuditRequestState())
  const retry = beginInitial(g1.state) // retry → new generation
  expect(applyInitialSuccess(retry.state, g1.gen, page(['old'])).entries).toEqual([]) // g1 rejected
  expect(applyInitialSuccess(retry.state, retry.gen, page(['new'])).entries.map((e) => e.id)).toEqual(['new'])
})

test('15: a failed CURRENT request sets the controlled error and clears loading', () => {
  const { state, gen } = beginInitial(initialAuditRequestState())
  const s = applyFailure(state, gen, fail('not_authorized'))
  expect(s.error?.error).toBe('not_authorized')
  expect(s.loadingInitial).toBe(false)
})

test('16: a failed STALE request may not overwrite current state with an error', () => {
  const g1 = beginInitial(initialAuditRequestState())
  const applied = applyInitialSuccess(g1.state, g1.gen, page(['a']))
  const g2 = beginInitial(applied) // supersede (gen 2)
  const s = applyFailure(g2.state, g1.gen, fail('transport_error')) // stale g1 failure
  expect(s.error).toBeNull() // not applied
})
