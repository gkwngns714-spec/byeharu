import { test, expect } from '@playwright/test'
import {
  deriveInactive,
  mergePageDedup,
  safeCommandLabel,
  safeTargetLabel,
  shortId,
  summarizeResult,
} from '../src/features/worldeditor/worldEditorAuditView'
import type { WorldEditorAuditEntry } from '../src/features/worldeditor/worldEditorAuditTypes'

// WORLD EDITOR V1.5 — pure display + pagination-merge helpers for the History UI.

const e = (over: Partial<WorldEditorAuditEntry>): WorldEditorAuditEntry => ({
  id: 'i', requestId: 'r', commandType: 'zone_unpublish', targetType: 'zone', targetId: 't',
  createdAt: '2026-07-20T14:29:29Z', sourceRevision: null, result: null, actorIsOwner: true,
  before: null, after: null, redactions: [], ...over,
})

test('safe labels: known values pass through; unknown values are shown as Unsupported (never coerced)', () => {
  expect(safeCommandLabel('zone_create')).toBe('zone_create')
  expect(safeCommandLabel('future_cmd')).toBe('Unsupported: future_cmd')
  expect(safeTargetLabel('zone')).toBe('zone')
  expect(safeTargetLabel('starbase')).toBe('Unsupported: starbase')
  expect(safeTargetLabel(null)).toBe('—')
})

test('deriveInactive: true when after.status=inactive or after.is_active=false, else false', () => {
  expect(deriveInactive(e({ after: { status: 'inactive' } }))).toBe(true)
  expect(deriveInactive(e({ after: { is_active: false } }))).toBe(true)
  expect(deriveInactive(e({ after: { status: 'active' } }))).toBe(false)
  expect(deriveInactive(e({ after: null }))).toBe(false)
})

test('summarizeResult + shortId are safe on any input', () => {
  expect(summarizeResult({ created: true })).toBe('created')
  expect(summarizeResult({ unpublished: true })).toBe('unpublished')
  expect(summarizeResult(null)).toBe('—')
  expect(shortId('abcdef12-3456')).toBe('abcdef12…')
  expect(shortId(null)).toBe('—')
})

test('mergePageDedup: appends only new ids — keyset pagination never yields duplicate rows', () => {
  const p1 = [e({ id: 'a' }), e({ id: 'b' }), e({ id: 'c' })]
  const p2 = [e({ id: 'c' }), e({ id: 'd' })] // 'c' overlaps the previous page's last item
  const merged = mergePageDedup(p1, p2)
  expect(merged.map((x) => x.id)).toEqual(['a', 'b', 'c', 'd'])
  // idempotent: re-merging the same page adds nothing
  expect(mergePageDedup(merged, p2).map((x) => x.id)).toEqual(['a', 'b', 'c', 'd'])
})
