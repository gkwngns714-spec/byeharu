import { test, expect } from '@playwright/test'
import {
  normalizeShipName,
  renameReasonMessage,
  shipNameProblem,
  SHIP_NAME_MAX,
} from '../src/features/ship/shipName'

// SHIP-IDENTITY — pure-logic specs for the ship-rename mirror (no app/Supabase). The mirror must
// match rename_main_ship_self (migration 0184: btrim → non-empty → length ≤ 40, the 0043 rules)
// exactly, in the server's own order — display-only, the server re-validates.

// ── normalizeShipName — the server's btrim ────────────────────────────────────────────────────────
test('normalize: trims exactly like the server btrim', () => {
  expect(normalizeShipName('  Sparrow II  ')).toBe('Sparrow II')
  expect(normalizeShipName('\t \n')).toBe('')
})

// ── shipNameProblem — the server rejects, in the server order ─────────────────────────────────────
test('problem: empty / whitespace-only → name_empty (btrim first, like the server)', () => {
  expect(shipNameProblem('')).toBe('name_empty')
  expect(shipNameProblem('   ')).toBe('name_empty')
})

test('problem: length is checked AFTER trim, capped at the server max (40)', () => {
  expect(shipNameProblem('x'.repeat(SHIP_NAME_MAX))).toBeNull() // exactly 40 is legal (server: > 40 rejects)
  expect(shipNameProblem('x'.repeat(SHIP_NAME_MAX + 1))).toBe('name_too_long')
  // 41 raw chars but 40 after trim → legal; the mirror must trim BEFORE measuring, like btrim.
  expect(shipNameProblem(' ' + 'x'.repeat(SHIP_NAME_MAX))).toBeNull()
})

test('problem: a normal personalized name passes', () => {
  expect(shipNameProblem('Scorpion')).toBeNull()
  expect(shipNameProblem('Sparrow II')).toBeNull()
})

// ── renameReasonMessage — server rejects + transport fallback + unknown ───────────────────────────
test('reasons: every server reject of rename_main_ship_self (0184) maps to player copy', () => {
  for (const r of ['not_authenticated', 'name_empty', 'name_too_long', 'no_ship', 'unavailable']) {
    const msg = renameReasonMessage(r)
    expect(msg.length).toBeGreaterThan(0)
    expect(msg).not.toContain('_') // player copy, never the raw code
  }
})

test('reasons: unknown → generic line, never a throw or a raw code', () => {
  expect(renameReasonMessage('some_future_reason')).toBe('Renaming is unavailable right now.')
})
