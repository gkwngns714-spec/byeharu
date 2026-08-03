import { test, expect } from '@playwright/test'
import { foldStateValue, foldStorageKey, readFoldState } from '../src/components/ui/collapsibleState'

// Pure proofs for the Collapsible primitive's persistence helpers (src/components/ui/
// collapsibleState.ts) — the storage contract the rendered proof (collapsibleUi.uispec.ts)
// exercises end-to-end through localStorage.

test('foldStorageKey: versioned byeharu namespace + the section id', () => {
  expect(foldStorageKey('command.reports')).toBe('byeharu.fold.v1:command.reports')
})

test('foldStateValue: open → "1", closed → "0" (the only two values ever written)', () => {
  expect(foldStateValue(true)).toBe('1')
  expect(foldStateValue(false)).toBe('0')
})

test('readFoldState: a stored "1"/"0" wins over the default, in both directions', () => {
  const store: Record<string, string> = { [foldStorageKey('a')]: '1', [foldStorageKey('b')]: '0' }
  const read = (k: string) => store[k] ?? null
  expect(readFoldState(read, 'a', false)).toBe(true) // stored open beats default-closed
  expect(readFoldState(read, 'b', true)).toBe(false) // stored closed beats default-open
})

test('readFoldState: absence falls back to the default', () => {
  const read = () => null
  expect(readFoldState(read, 'missing', true)).toBe(true)
  expect(readFoldState(read, 'missing', false)).toBe(false)
})

test('readFoldState: garbage is untrusted — falls back to the default, never a guess', () => {
  const read = () => 'true' // not a value this module writes
  expect(readFoldState(read, 'x', false)).toBe(false)
  expect(readFoldState(read, 'x', true)).toBe(true)
})

test('readFoldState: a throwing reader (private-mode storage) degrades to the default', () => {
  const read = () => {
    throw new Error('storage unavailable')
  }
  expect(readFoldState(read, 'x', true)).toBe(true)
  expect(readFoldState(read, 'x', false)).toBe(false)
})

test('round-trip: what foldStateValue writes, readFoldState reads back', () => {
  for (const open of [true, false]) {
    const store: Record<string, string> = { [foldStorageKey('rt')]: foldStateValue(open) }
    expect(readFoldState((k) => store[k] ?? null, 'rt', !open)).toBe(open)
  }
})
