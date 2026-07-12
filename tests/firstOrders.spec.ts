import { test, expect } from '@playwright/test'
import {
  DOCKED_SPATIAL_STATE,
  deriveFirstOrders,
  firstOrdersComplete,
  firstOrdersDismissKey,
  isWonReport,
  projectFirstOrders,
  type FirstOrdersInput,
} from '../src/features/onboarding/firstOrders'

// OB-1 (plan §C P10) — pure-logic specs for the First Orders checklist (no app/Supabase; the
// teamRoster.spec.ts mold). Pins: each step's done-condition BOUNDARIES, the flag-aware step set
// (dark feature → step OMITTED, never greyed), the won-rule mirror of ReportsSection, the
// projection's fail-closed docked read, and the auto-hide + dismissal-key contracts.

const input = (o: Partial<FirstOrdersInput> = {}): FirstOrdersInput => ({
  shipCount: 0,
  docked: false,
  wonBattle: false,
  expeditionsLit: true,
  additionalShipsLit: true,
  ...o,
})

const ids = (i: FirstOrdersInput) => deriveFirstOrders(i).map((s) => s.id)
const step = (i: FirstOrdersInput, id: string) => {
  const s = deriveFirstOrders(i).find((x) => x.id === id)
  if (!s) throw new Error(`step ${id} not derived`)
  return s
}

// ── step set + order (flag-aware: dark feature → step omitted) ──────────────────────────────────
test('all lit → the four v1 steps, in first-session order', () => {
  expect(ids(input())).toEqual(['claim-ship', 'dock-port', 'first-hunt', 'second-ship'])
})

test('expeditions dark → dock + hunt steps OMITTED (not greyed)', () => {
  expect(ids(input({ expeditionsLit: false }))).toEqual(['claim-ship', 'second-ship'])
})

test('additional ships dark → second-ship step OMITTED', () => {
  expect(ids(input({ additionalShipsLit: false }))).toEqual(['claim-ship', 'dock-port', 'first-hunt'])
})

test('everything dark → the always-lit claim step alone (never an empty invented list)', () => {
  expect(ids(input({ expeditionsLit: false, additionalShipsLit: false }))).toEqual(['claim-ship'])
})

test('every derived step carries a non-empty label and hint', () => {
  for (const s of deriveFirstOrders(input())) {
    expect(s.label.length).toBeGreaterThan(0)
    expect(s.hint.length).toBeGreaterThan(0)
  }
})

// ── claim-ship boundaries ───────────────────────────────────────────────────────────────────────
test('claim-ship: 0 ships → not done; 1 ship → done', () => {
  expect(step(input({ shipCount: 0 }), 'claim-ship').done).toBe(false)
  expect(step(input({ shipCount: 1 }), 'claim-ship').done).toBe(true)
})

// ── dock-port boundaries ────────────────────────────────────────────────────────────────────────
test('dock-port: not docked → not done; docked → done', () => {
  expect(step(input({ shipCount: 1, docked: false }), 'dock-port').done).toBe(false)
  expect(step(input({ shipCount: 1, docked: true }), 'dock-port').done).toBe(true)
})

test('dock-port: LIVE semantics — a launched (no longer docked) sole ship un-ticks the step', () => {
  // Deliberate: done mirrors current server state; no client-side progress is stored.
  expect(step(input({ shipCount: 1, docked: false, wonBattle: true }), 'dock-port').done).toBe(false)
})

test('dock-port: shipCount>=2 marks done even when the dock signal is unresolvable', () => {
  // The polled sole-ship read fails closed to null at N≥2, so `docked` reads false exactly when
  // the last step completes — the disjunct keeps an unresolvable signal from pinning the card open.
  expect(step(input({ shipCount: 2, docked: false }), 'dock-port').done).toBe(true)
})

// ── first-hunt boundaries ───────────────────────────────────────────────────────────────────────
test('first-hunt: no won report → not done; won report → done', () => {
  expect(step(input({ wonBattle: false }), 'first-hunt').done).toBe(false)
  expect(step(input({ wonBattle: true }), 'first-hunt').done).toBe(true)
})

// ── second-ship boundaries ──────────────────────────────────────────────────────────────────────
test('second-ship: 1 ship → not done; 2 ships → done; more stays done', () => {
  expect(step(input({ shipCount: 1 }), 'second-ship').done).toBe(false)
  expect(step(input({ shipCount: 2 }), 'second-ship').done).toBe(true)
  expect(step(input({ shipCount: 5 }), 'second-ship').done).toBe(true)
})

// ── isWonReport — MUST mirror ReportsSection's won rule (escaped | completed) ───────────────────
test('isWonReport: completed and escaped are won (the ReportsSection rule, verbatim)', () => {
  expect(isWonReport('completed')).toBe(true)
  expect(isWonReport('escaped')).toBe(true)
})

test('isWonReport: everything else is not won (defeat, in-flight states, junk)', () => {
  for (const r of ['defeat', 'active', 'retreating', '', 'victory', 'COMPLETED']) {
    expect(isWonReport(r)).toBe(false)
  }
})

// ── projectFirstOrders — the shell-state projection boundaries ──────────────────────────────────
const project = (o: Partial<Parameters<typeof projectFirstOrders>[0]> = {}) =>
  projectFirstOrders({
    selectionShipCount: 0,
    polledShipKnown: false,
    spatialState: null,
    reports: [],
    expeditionsLit: true,
    additionalShipsLit: true,
    ...o,
  })

test('projection: docked ONLY for the canonical at_location spatial mode (fail closed)', () => {
  expect(project({ spatialState: DOCKED_SPATIAL_STATE }).docked).toBe(true)
  for (const s of ['home', 'in_transit', 'in_space', 'destroyed', null, undefined, '']) {
    expect(project({ spatialState: s }).docked).toBe(false)
  }
})

test('projection: shipCount is the max of the selection list and the polled sole-ship read', () => {
  // Fresh claim: selection list not yet refetched, polled read already sees the ship.
  expect(project({ selectionShipCount: 0, polledShipKnown: true }).shipCount).toBe(1)
  // Multi-ship: polled sole-ship read fails closed to null; the selection list is authoritative.
  expect(project({ selectionShipCount: 2, polledShipKnown: false }).shipCount).toBe(2)
  expect(project({ selectionShipCount: 0, polledShipKnown: false }).shipCount).toBe(0)
})

test('projection: wonBattle = ANY report matching the won rule (mixed history counts)', () => {
  expect(project({ reports: [] }).wonBattle).toBe(false)
  expect(project({ reports: [{ result: 'defeat' }] }).wonBattle).toBe(false)
  expect(project({ reports: [{ result: 'defeat' }, { result: 'completed' }] }).wonBattle).toBe(true)
  expect(project({ reports: [{ result: 'escaped' }] }).wonBattle).toBe(true)
})

test('projection: lit flags pass through untouched', () => {
  const p = project({ expeditionsLit: false, additionalShipsLit: true })
  expect(p.expeditionsLit).toBe(false)
  expect(p.additionalShipsLit).toBe(true)
})

// ── firstOrdersComplete — the auto-hide contract ────────────────────────────────────────────────
test('complete: true only when EVERY visible step is done', () => {
  expect(firstOrdersComplete(deriveFirstOrders(input({ shipCount: 2, wonBattle: true })))).toBe(true)
  expect(firstOrdersComplete(deriveFirstOrders(input({ shipCount: 2, wonBattle: false })))).toBe(false)
  expect(firstOrdersComplete(deriveFirstOrders(input()))).toBe(false)
})

test('complete: an empty step list is NOT complete (never auto-hide by omission alone)', () => {
  expect(firstOrdersComplete([])).toBe(false)
})

test('complete: a dark-feature player finishes their shorter visible list', () => {
  // Expeditions dark → only claim + second-ship are visible; both done → complete.
  expect(
    firstOrdersComplete(deriveFirstOrders(input({ expeditionsLit: false, shipCount: 2 }))),
  ).toBe(true)
})

// ── dismissal key — per-user, versioned, anon-safe ──────────────────────────────────────────────
test('dismissKey: per-user + versioned; null/empty user falls back to anon', () => {
  expect(firstOrdersDismissKey('u-123')).toBe('byeharu.firstOrders.v1.dismissed:u-123')
  expect(firstOrdersDismissKey(null)).toBe('byeharu.firstOrders.v1.dismissed:anon')
  expect(firstOrdersDismissKey(undefined)).toBe('byeharu.firstOrders.v1.dismissed:anon')
  expect(firstOrdersDismissKey('')).toBe('byeharu.firstOrders.v1.dismissed:anon')
  expect(firstOrdersDismissKey('a')).not.toBe(firstOrdersDismissKey('b'))
})
