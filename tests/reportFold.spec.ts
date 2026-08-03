import { test, expect } from '@playwright/test'
import { newestReportId, reportRowOpen } from '../src/features/combat/reportFold'

// Pure proofs for the report-row fold policy (src/features/combat/reportFold.ts): the newest
// report defaults OPEN, older ones CLOSED, and the player's explicit toggle always wins.

const r = (encounter_id: string, created_at: string) => ({ encounter_id, created_at })

test('newestReportId: picks the max created_at regardless of array order', () => {
  const reports = [
    r('mid', '2026-08-02T10:00:00Z'),
    r('new', '2026-08-03T09:00:00Z'),
    r('old', '2026-07-30T23:59:59Z'),
  ]
  expect(newestReportId(reports)).toBe('new')
  expect(newestReportId([...reports].reverse())).toBe('new')
})

test('newestReportId: empty list → null (no row can default open)', () => {
  expect(newestReportId([])).toBeNull()
})

test('newestReportId: a created_at tie keeps the first seen (deterministic, never two open)', () => {
  const reports = [r('a', '2026-08-03T09:00:00Z'), r('b', '2026-08-03T09:00:00Z')]
  expect(newestReportId(reports)).toBe('a')
})

test('default state: only the newest row opens; every older row starts collapsed', () => {
  expect(reportRowOpen({}, 'new', 'new')).toBe(true)
  expect(reportRowOpen({}, 'old', 'new')).toBe(false)
  expect(reportRowOpen({}, 'any', null)).toBe(false) // no newest (empty list edge)
})

test('the player wins: an explicit toggle overrides the default in both directions', () => {
  expect(reportRowOpen({ new: false }, 'new', 'new')).toBe(false) // collapsed the newest
  expect(reportRowOpen({ old: true }, 'old', 'new')).toBe(true) // opened an older one
})

test('a NEW newest report auto-opens while an untouched previous newest folds back', () => {
  // Session starts: 'first' is newest and open by default.
  expect(reportRowOpen({}, 'first', 'first')).toBe(true)
  // A fresh report lands ('second' becomes newest); the player never touched 'first'.
  expect(reportRowOpen({}, 'second', 'second')).toBe(true)
  expect(reportRowOpen({}, 'first', 'second')).toBe(false)
  // …but a row the player explicitly opened stays open through the shift.
  expect(reportRowOpen({ first: true }, 'first', 'second')).toBe(true)
})
