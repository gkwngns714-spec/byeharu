import { test, expect } from '@playwright/test'
import { haulAcceptAvailability, haulDeadlineLabel, haulDeliverAvailability } from '../src/features/port/haulBoard'

// HAUL-3 — pure-logic specs for the bulletin-board client mirrors (no app/Supabase). Asserts the
// same reject ORDER as the server RPCs haul_accept_contract / haul_deliver_contract (migration
// 0179): gate FIRST, then ship, then docking, then the per-command guards — and the pure deadline
// label. Run: `npx playwright test haulBoard.spec.ts`.

// A fully-acceptable input; tests flip one clause at a time (the teamSend mold).
const acceptOk = () => ({
  serverLit: true,
  shipResolved: true,
  dockedAtOrigin: true,
  offerFresh: true,
  activeCount: 0,
  maxActive: 3 as number | null,
})

test('haulAcceptAvailability: everything satisfied → ok', () => {
  expect(haulAcceptAvailability(acceptOk())).toEqual({ canAccept: true, reason: 'ok' })
})

test('haulAcceptAvailability: dark gate wins over EVERYTHING (server order: gate first)', () => {
  expect(
    haulAcceptAvailability({ ...acceptOk(), serverLit: false, shipResolved: false, offerFresh: false }),
  ).toEqual({ canAccept: false, reason: 'haul_contracts_disabled' })
})

test('haulAcceptAvailability: no resolved ship → ship_not_found (before docking/offer checks)', () => {
  expect(haulAcceptAvailability({ ...acceptOk(), shipResolved: false, dockedAtOrigin: false })).toEqual({
    canAccept: false,
    reason: 'ship_not_found',
  })
})

test('haulAcceptAvailability: not docked at the origin → not_docked (before the offer checks)', () => {
  expect(haulAcceptAvailability({ ...acceptOk(), dockedAtOrigin: false, offerFresh: false })).toEqual({
    canAccept: false,
    reason: 'not_docked',
  })
})

test('haulAcceptAvailability: stale offer folds into contract_not_found (the 0179 §3 fail-closed mirror)', () => {
  expect(haulAcceptAvailability({ ...acceptOk(), offerFresh: false })).toEqual({
    canAccept: false,
    reason: 'contract_not_found',
  })
})

test('haulAcceptAvailability: at/over the active cap → too_many_active (boundary: count == max)', () => {
  expect(haulAcceptAvailability({ ...acceptOk(), activeCount: 3, maxActive: 3 })).toEqual({
    canAccept: false,
    reason: 'too_many_active',
  })
  expect(haulAcceptAvailability({ ...acceptOk(), activeCount: 4, maxActive: 3 })).toEqual({
    canAccept: false,
    reason: 'too_many_active',
  })
  // one under the cap is fine.
  expect(haulAcceptAvailability({ ...acceptOk(), activeCount: 2, maxActive: 3 }).canAccept).toBe(true)
})

test('haulAcceptAvailability: unknown cap (null) SKIPS the precheck — the server answers itself', () => {
  expect(haulAcceptAvailability({ ...acceptOk(), activeCount: 99, maxActive: null })).toEqual({
    canAccept: true,
    reason: 'ok',
  })
})

test('haulAcceptAvailability: a 0 cap (legal owner value — freeze new accepts) blocks at 0 active', () => {
  expect(haulAcceptAvailability({ ...acceptOk(), activeCount: 0, maxActive: 0 })).toEqual({
    canAccept: false,
    reason: 'too_many_active',
  })
})

// ── deliver mirror — the 0179 deliver order: gate → ship → docked → dest → deadline → cargo ─────
const deliverOk = () => ({
  serverLit: true,
  shipResolved: true,
  docked: true,
  atDestination: true,
  deadlineAhead: true,
  hasCargo: true,
})

test('haulDeliverAvailability: everything satisfied → ok', () => {
  expect(haulDeliverAvailability(deliverOk())).toEqual({ canDeliver: true, reason: 'ok' })
})

test('haulDeliverAvailability: dark gate wins over everything', () => {
  expect(haulDeliverAvailability({ ...deliverOk(), serverLit: false, docked: false, hasCargo: false })).toEqual({
    canDeliver: false,
    reason: 'haul_contracts_disabled',
  })
})

test('haulDeliverAvailability: no ship → ship_not_found; then not_docked before the port/deadline/cargo guards', () => {
  expect(haulDeliverAvailability({ ...deliverOk(), shipResolved: false })).toEqual({
    canDeliver: false,
    reason: 'ship_not_found',
  })
  expect(haulDeliverAvailability({ ...deliverOk(), docked: false, atDestination: false, hasCargo: false })).toEqual({
    canDeliver: false,
    reason: 'not_docked',
  })
})

test('haulDeliverAvailability: docked at the wrong port → wrong_port (before deadline/cargo)', () => {
  expect(haulDeliverAvailability({ ...deliverOk(), atDestination: false, deadlineAhead: false })).toEqual({
    canDeliver: false,
    reason: 'wrong_port',
  })
})

test('haulDeliverAvailability: past deliver_by → deadline_passed (before the cargo check)', () => {
  expect(haulDeliverAvailability({ ...deliverOk(), deadlineAhead: false, hasCargo: false })).toEqual({
    canDeliver: false,
    reason: 'deadline_passed',
  })
})

test('haulDeliverAvailability: short cargo → insufficient_cargo (the display-only lot-sum mirror)', () => {
  expect(haulDeliverAvailability({ ...deliverOk(), hasCargo: false })).toEqual({
    canDeliver: false,
    reason: 'insufficient_cargo',
  })
})

// ── haulDeadlineLabel — pure, injected-now formatting boundaries ─────────────────────────────────
const NOW = Date.UTC(2026, 0, 1, 12, 0, 0)
const at = (deltaMs: number) => new Date(NOW + deltaMs).toISOString()

test('haulDeadlineLabel: missing/invalid timestamps → "—" (never throws)', () => {
  expect(haulDeadlineLabel(null, NOW)).toBe('—')
  expect(haulDeadlineLabel(undefined, NOW)).toBe('—')
  expect(haulDeadlineLabel('', NOW)).toBe('—')
  expect(haulDeadlineLabel('not-a-date', NOW)).toBe('—')
})

test('haulDeadlineLabel: elapsed (or exactly now) → "overdue"', () => {
  expect(haulDeadlineLabel(at(0), NOW)).toBe('overdue')
  expect(haulDeadlineLabel(at(-1), NOW)).toBe('overdue')
  expect(haulDeadlineLabel(at(-3_600_000), NOW)).toBe('overdue')
})

test('haulDeadlineLabel: sub-minute → seconds only; sub-hour → "Mm SSs" (padded)', () => {
  expect(haulDeadlineLabel(at(45_000), NOW)).toBe('45s')
  expect(haulDeadlineLabel(at(1_000), NOW)).toBe('1s')
  expect(haulDeadlineLabel(at(90_000), NOW)).toBe('1m 30s')
  expect(haulDeadlineLabel(at(60_000), NOW)).toBe('1m 00s')
  expect(haulDeadlineLabel(at(59 * 60_000 + 5_000), NOW)).toBe('59m 05s')
})

test('haulDeadlineLabel: an hour or more → "Hh MMm" (padded minutes; hour boundary exact)', () => {
  expect(haulDeadlineLabel(at(3_600_000), NOW)).toBe('1h 00m')
  expect(haulDeadlineLabel(at(2 * 3_600_000 + 5 * 60_000), NOW)).toBe('2h 05m')
  expect(haulDeadlineLabel(at(12 * 3_600_000), NOW)).toBe('12h 00m')
})

test('haulDeadlineLabel: remaining time is CEILED to the second (never "0s" while still ahead)', () => {
  expect(haulDeadlineLabel(at(1), NOW)).toBe('1s')
  expect(haulDeadlineLabel(at(59_001), NOW)).toBe('1m 00s')
})
