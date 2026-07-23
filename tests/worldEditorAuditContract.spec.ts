import { test, expect } from '@playwright/test'
import { normalizeAuditResponse } from '../src/features/worldeditor/worldEditorAuditNormalize'
import { deriveAuditDiff } from '../src/features/worldeditor/worldEditorAuditDiff'
import { auditRecordWorldPoints, auditRecordHasFocus } from '../src/features/worldeditor/worldEditorAuditFocus'
import {
  isKnownAuditCommandType,
  type WorldEditorAuditEntry,
} from '../src/features/worldeditor/worldEditorAuditTypes'

// WORLD EDITOR V1.5 — pure contract/normalization/diff/focus tests for the owner audit reader
// (migration 0256). No React, no network — the RPC's SERVER behavior is proven by
// scripts/worldeditor-audit-read-proof.sql; here we prove the CLIENT boundary: fail-closed
// normalization, no coercion of unknown values, fail-closed rejection of forbidden server-only keys,
// the semantic diff, and the map-focus point extraction.

const okEntryRaw = (over: Record<string, unknown> = {}) => ({
  id: '11111111-1111-4111-8111-111111111111',
  request_id: 'req-1',
  command_type: 'zone_create',
  target_type: 'zone',
  target_id: 'zzz',
  created_at: '2026-07-20T14:29:28.710249+00:00',
  source_revision: 'rev-a',
  result: { created: true },
  actor_is_owner: true,
  before: null,
  after: { id: 'zzz', name: 'Z', status: 'active' },
  redactions: ['actor'],
  ...over,
})

// ── command vocabulary ──────────────────────────────────────────────────────────────────────────────
test('zone_update (0266) is a KNOWN audit command type alongside the other zone commands', () => {
  expect(isKnownAuditCommandType('zone_update')).toBe(true)
  expect(isKnownAuditCommandType('zone_create')).toBe(true)
  expect(isKnownAuditCommandType('zone_unpublish')).toBe(true)
  expect(isKnownAuditCommandType('some_future_command')).toBe(false)
})

// ── normalization ─────────────────────────────────────────────────────────────────────────────────
test('normalize: a valid success envelope becomes a typed page (camelCase)', () => {
  const r = normalizeAuditResponse({ ok: true, page_size: 50, next_cursor: null, items: [okEntryRaw()] })
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.pageSize).toBe(50)
  expect(r.nextCursor).toBeNull()
  expect(r.items).toHaveLength(1)
  expect(r.items[0].requestId).toBe('req-1')
  expect(r.items[0].commandType).toBe('zone_create')
  expect(r.items[0].actorIsOwner).toBe(true)
  expect(r.items[0].before).toBeNull()
  expect(r.items[0].redactions).toEqual(['actor'])
})

test('normalize: a next_cursor object is carried through; a malformed cursor degrades to null', () => {
  const good = normalizeAuditResponse({ ok: true, page_size: 1, next_cursor: { ts: 't', id: 'i' }, items: [okEntryRaw()] })
  if (!good.ok) throw new Error('unreachable')
  expect(good.nextCursor).toEqual({ ts: 't', id: 'i' })
  const bad = normalizeAuditResponse({ ok: true, page_size: 1, next_cursor: { ts: 't' }, items: [okEntryRaw()] })
  if (!bad.ok) throw new Error('unreachable')
  expect(bad.nextCursor).toBeNull()
})

test('normalize: a valid failure envelope carries the typed error code + details', () => {
  const r = normalizeAuditResponse({ ok: false, error: 'not_authorized' })
  expect(r.ok).toBe(false)
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('not_authorized')
  const inv = normalizeAuditResponse({ ok: false, error: 'invalid_request', details: [{ code: 'bad_limit', field: 'limit' }] })
  if (inv.ok) throw new Error('unreachable')
  expect(inv.error).toBe('invalid_request')
  expect(inv.details?.[0]?.code).toBe('bad_limit')
})

test('normalize: a malformed envelope / item / page_size is a CONTROLLED transport_error (never throws)', () => {
  for (const bad of [null, 42, 'x', {}, { ok: 'yes' }, { ok: true, items: [okEntryRaw()] /* no page_size */ }, { ok: true, page_size: 5, items: 'nope' }]) {
    const r = normalizeAuditResponse(bad)
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error('unreachable')
    expect(r.error).toBe('transport_error')
  }
  // a structurally-broken item (missing required id) fails the whole page closed
  const r = normalizeAuditResponse({ ok: true, page_size: 5, next_cursor: null, items: [okEntryRaw({ id: undefined })] })
  if (r.ok) throw new Error('unreachable')
  expect(r.error).toBe('transport_error')
})

test('normalize: unknown command/target values are PRESERVED, never coerced', () => {
  const r = normalizeAuditResponse({
    ok: true, page_size: 5, next_cursor: null,
    items: [okEntryRaw({ command_type: 'some_future_command', target_type: 'starbase' })],
  })
  if (!r.ok) throw new Error('unreachable')
  expect(r.items[0].commandType).toBe('some_future_command')
  expect(r.items[0].targetType).toBe('starbase')
})

test('normalize: FAIL-CLOSED — a forbidden server-only key in any snapshot compromises the whole page', () => {
  for (const key of ['reward_bundle_json', 'created_by', 'actor']) {
    const r = normalizeAuditResponse({
      ok: true, page_size: 5, next_cursor: null,
      items: [okEntryRaw({ after: { id: 'zzz', name: 'Z', [key]: 'LEAK' } })],
    })
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error(`forbidden key ${key} was not rejected`)
    expect(r.error).toBe('transport_error')
    expect(r.details?.[0]?.code).toBe('forbidden_field_present')
  }
})

test('normalize: an empty page is a valid ok result with zero items', () => {
  const r = normalizeAuditResponse({ ok: true, page_size: 50, next_cursor: null, items: [] })
  if (!r.ok) throw new Error('unreachable')
  expect(r.items).toHaveLength(0)
  expect(r.nextCursor).toBeNull()
})

// ── semantic diff ───────────────────────────────────────────────────────────────────────────────────
test('diff: a create record (before=null) is hasBefore=false with all fields added', () => {
  const d = deriveAuditDiff(null, { id: 'z', name: 'Z', status: 'active' })
  expect(d.hasBefore).toBe(false)
  expect(d.afterMissing).toBe(false)
  const all = d.groups.flatMap((g) => g.fields)
  expect(all.every((f) => f.klass === 'added')).toBe(true)
})

test('diff: classifies added / removed / changed / unchanged and groups semantically', () => {
  const d = deriveAuditDiff(
    { id: 'z', name: 'Old', status: 'active', source: 'drawn' },
    { id: 'z', name: 'New', status: 'inactive', location_id: 'loc-1' },
  )
  const byField = Object.fromEntries(d.groups.flatMap((g) => g.fields).map((f) => [f.field, f]))
  expect(byField.id.klass).toBe('unchanged')
  expect(byField.name.klass).toBe('changed')
  expect(byField.status.klass).toBe('changed')
  expect(byField.status.group).toBe('lifecycle')
  expect(byField.source.klass).toBe('removed')
  expect(byField.location_id.klass).toBe('added')
  expect(byField.location_id.group).toBe('coordinates')
  expect(d.changedCount).toBe(4) // name, status, source, location_id
})

test('diff: large geometry (boundary_wkt) is summarized, not dumped', () => {
  const wkt = 'POLYGON((' + Array.from({ length: 60 }, (_, i) => `${i} ${i}`).join(',') + '))'
  const d = deriveAuditDiff(null, { id: 'z', boundary_wkt: wkt })
  const geom = d.groups.find((g) => g.group === 'geometry')?.fields[0]
  expect(geom).toBeTruthy()
  expect(geom!.summarized).toBe(true)
  expect(geom!.after).toContain('polygon')
  expect(geom!.after).toContain('pts')
  expect(geom!.after!.length).toBeLessThan(40)
})

test('diff: after=null is handled without crashing (all fields removed)', () => {
  const d = deriveAuditDiff({ id: 'z', name: 'Z' }, null)
  expect(d.afterMissing).toBe(true)
  expect(d.groups.flatMap((g) => g.fields).every((f) => f.klass === 'removed')).toBe(true)
})

// ── map focus point extraction ────────────────────────────────────────────────────────────────────
const entry = (over: Partial<WorldEditorAuditEntry>): WorldEditorAuditEntry => ({
  id: 'i', requestId: 'r', commandType: 'zone_create', targetType: 'zone', targetId: 't',
  createdAt: 'now', sourceRevision: null, result: null, actorIsOwner: true,
  before: null, after: null, redactions: [], ...over,
})

test('focus: a zone boundary_wkt yields polygon vertices', () => {
  const e = entry({ after: { boundary_wkt: 'POLYGON((-10 -10,10 -10,10 10,-10 10,-10 -10))' } })
  const pts = auditRecordWorldPoints(e)
  expect(pts.length).toBe(5)
  expect(pts[0]).toEqual({ x: -10, y: -10 })
  expect(auditRecordHasFocus(e)).toBe(true)
})

test('focus: legacy x/y and OSN space_x/space_y each yield a single point; none → no focus', () => {
  expect(auditRecordWorldPoints(entry({ after: { x: 5, y: -7 } }))).toEqual([{ x: 5, y: -7 }])
  expect(auditRecordWorldPoints(entry({ after: { space_x: 100, space_y: 200 } }))).toEqual([{ x: 100, y: 200 }])
  const none = entry({ after: { name: 'no coords' }, before: null })
  expect(auditRecordWorldPoints(none)).toEqual([])
  expect(auditRecordHasFocus(none)).toBe(false)
})

test('focus: prefers after, falls back to before', () => {
  const e = entry({ before: { x: 1, y: 1 }, after: { name: 'no coords in after' } })
  expect(auditRecordWorldPoints(e)).toEqual([{ x: 1, y: 1 }])
})

// ── recursive forbidden-key detection (defense in depth) ────────────────────────────────────────────
test('normalize: forbidden key is rejected at root, nested in an object, and nested in an array element', () => {
  const cases: Record<string, unknown>[] = [
    { id: 'z', name: 'Z', created_by: 'x' }, // root
    { id: 'z', name: 'Z', meta: { deep: { reward_bundle_json: { items: [] } } } }, // nested object
    { id: 'z', name: 'Z', list: [{ ok: 1 }, { actor: 'x' }] }, // nested array element
  ]
  for (const after of cases) {
    const r = normalizeAuditResponse({ ok: true, page_size: 5, next_cursor: null, items: [okEntryRaw({ after })] })
    expect(r.ok).toBe(false)
    if (r.ok) throw new Error('nested forbidden key not rejected: ' + JSON.stringify(after))
    expect(r.error).toBe('transport_error')
    expect(r.details?.[0]?.code).toBe('forbidden_field_present')
  }
})

test('normalize: forbidden key is caught in BEFORE as well as AFTER', () => {
  const r = normalizeAuditResponse({
    ok: true, page_size: 5, next_cursor: null,
    items: [okEntryRaw({ before: { id: 'z', created_by: 'x' }, after: { id: 'z' } })],
  })
  expect(r.ok).toBe(false)
})

test('normalize: a redactions label of "created_by" (a VALUE, not a key) is accepted', () => {
  const r = normalizeAuditResponse({
    ok: true, page_size: 5, next_cursor: null,
    items: [okEntryRaw({ before: { id: 'z', status: 'active' }, after: { id: 'z', status: 'inactive' }, redactions: ['created_by', 'actor'] })],
  })
  expect(r.ok).toBe(true)
  if (!r.ok) throw new Error('unreachable')
  expect(r.items[0].redactions).toEqual(['created_by', 'actor'])
})

// ── geometry safety (pure, fail-safe, bounded) ──────────────────────────────────────────────────────
test('focus: malformed / unsupported / oversized geometry yields no focus and never throws', () => {
  const bad = [
    'POLYGON((broken', // malformed
    'LINESTRING(0 0, 1 1)', // unsupported type
    'not wkt at all',
    'POINT(1 2)', // unsupported here (POINT text form)
    'POLYGON((' + '9 9,'.repeat(50_000) + '9 9))', // oversized input
    '',
  ]
  for (const wkt of bad) {
    const e = entry({ after: { boundary_wkt: wkt } })
    expect(() => auditRecordWorldPoints(e)).not.toThrow()
    expect(auditRecordWorldPoints(e)).toEqual([])
    expect(auditRecordHasFocus(e)).toBe(false)
  }
})
