import { test, expect } from '@playwright/test'
import { resolveRefLabel, shortUuid, type NamedRef } from '../src/features/worldeditor/bindingLabels'

// M5 — the binding surface resolves stored UUIDs to human labels for DISPLAY; a stale UUID with no snapshot
// match falls back to a short UUID rather than a wall of hex. Pure — no payload/value change.
// Run: `npx playwright test bindingLabels.spec.ts`.

const refs: NamedRef[] = [
  { id: '11111111-2222-3333-4444-555555555555', label: 'Ceres Belt' },
  { id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', label: 'Pirate Ambush' },
]

test('a known UUID resolves to its human label', () => {
  expect(resolveRefLabel('11111111-2222-3333-4444-555555555555', refs)).toBe('Ceres Belt')
  expect(resolveRefLabel('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', refs)).toBe('Pirate Ambush')
})

test('a stale UUID with no match falls back to a short UUID, not raw hex', () => {
  const stale = '99999999-0000-0000-0000-000000000000'
  const out = resolveRefLabel(stale, refs)
  expect(out).toBe('99999999…')
  expect(out).not.toBe(stale)
})

test('shortUuid takes the first segment plus an ellipsis', () => {
  expect(shortUuid('deadbeef-1234-5678-9abc-def012345678')).toBe('deadbeef…')
})

test('a short/non-UUID id passes through unchanged', () => {
  expect(shortUuid('abc')).toBe('abc')
  expect(resolveRefLabel('abc', refs)).toBe('abc')
})

test('resolution is presentational only — the refs list is not mutated', () => {
  const snapshot = JSON.parse(JSON.stringify(refs))
  resolveRefLabel('99999999-0000-0000-0000-000000000000', refs)
  expect(refs).toEqual(snapshot)
})
