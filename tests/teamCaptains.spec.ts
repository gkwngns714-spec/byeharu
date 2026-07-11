import { test, expect } from '@playwright/test'
import {
  captainsByShip,
  captainAssignAvailability,
  isPreviewActivity,
  PREVIEW_ACTIVITY_TYPES,
} from '../src/features/command/teamCaptains'
import type { CaptainInstance } from '../src/features/captains/captainsTypes'

// TEAM-COMMAND Slice C1 — pure-logic specs for the captain-roster split, the DISPLAY-ONLY assign
// availability mirror, and the preview activity set (no app/Supabase — the teamSkillset.spec.ts
// mold). The availability table pins the assign reject ORDER (0120/0121 wrapper + 0119 writer
// mirror): dark FIRST → ship_not_settled → already_assigned (writer step 4) → captain_slots_full
// (writer step 5) → ok; every stage is asserted with all LATER inputs also failing, so a reorder
// cannot pass. The server stays authoritative throughout.

const cap = (id: string, ship: string | null): CaptainInstance => ({
  instance_id: id,
  captain_type_id: 'navigator',
  name: `Captain ${id}`,
  specialization: 'navigation',
  stats_json: {},
  main_ship_id: ship,
  created_at: '2026-07-01T00:00:00Z',
})

// ── captainsByShip — split / order / unknown-ship bucketing / empty ─────────────────────────────

test('captainsByShip: splits on main_ship_id — null → unassigned, ids → per-ship buckets', () => {
  const out = captainsByShip([cap('c1', 'ship-a'), cap('c2', null), cap('c3', 'ship-b'), cap('c4', 'ship-a')])
  expect([...out.byShip.keys()].sort()).toEqual(['ship-a', 'ship-b'])
  expect(out.byShip.get('ship-a')!.map((c) => c.instance_id)).toEqual(['c1', 'c4'])
  expect(out.byShip.get('ship-b')!.map((c) => c.instance_id)).toEqual(['c3'])
  expect(out.unassigned.map((c) => c.instance_id)).toEqual(['c2'])
})

test('captainsByShip: PRESERVES input order inside every bucket and in unassigned', () => {
  const out = captainsByShip([
    cap('z', null),
    cap('m', 'ship-a'),
    cap('a', null),
    cap('k', 'ship-a'),
    cap('b', 'ship-a'),
  ])
  expect(out.byShip.get('ship-a')!.map((c) => c.instance_id)).toEqual(['m', 'k', 'b']) // not sorted
  expect(out.unassigned.map((c) => c.instance_id)).toEqual(['z', 'a']) // not sorted
})

test('captainsByShip: a captain pointing at a ship NOT in the roster still buckets under that id — NEVER reclassified to unassigned', () => {
  // The split has no roster input by design: the server's assignment is truth. A dangling
  // main_ship_id (ship not in the caller's list) stays an assignment under that id.
  const out = captainsByShip([cap('c1', 'ghost-ship'), cap('c2', null)])
  expect(out.byShip.get('ghost-ship')!.map((c) => c.instance_id)).toEqual(['c1'])
  expect(out.unassigned.map((c) => c.instance_id)).toEqual(['c2'])
})

test('captainsByShip: empty roster → empty map + empty unassigned', () => {
  const out = captainsByShip([])
  expect(out.byShip.size).toBe(0)
  expect(out.unassigned).toEqual([])
})

// ── captainAssignAvailability — the FULL reject-order table ─────────────────────────────────────
// Each stage is asserted with every LATER input ALSO failing, pinning the ORDER (a reorder of the
// checks would flip at least one of these reasons).

test('captainAssignAvailability: dark FIRST — captains_dark even when everything later also fails', () => {
  expect(
    captainAssignAvailability({ serverLit: false, shipSettled: false, hasFreeSlot: false, captainUnassigned: false }),
  ).toEqual({ canAssign: false, reason: 'captains_dark' })
})

test('captainAssignAvailability: lit + unsettled → ship_not_settled (before slots and assignment)', () => {
  expect(
    captainAssignAvailability({ serverLit: true, shipSettled: false, hasFreeSlot: false, captainUnassigned: false }),
  ).toEqual({ canAssign: false, reason: 'ship_not_settled' })
})

test('captainAssignAvailability: lit + settled + captain already assigned → already_assigned (BEFORE the slot cap — 0119 writer order, even with no free slot)', () => {
  expect(
    captainAssignAvailability({ serverLit: true, shipSettled: true, hasFreeSlot: false, captainUnassigned: false }),
  ).toEqual({ canAssign: false, reason: 'already_assigned' })
})

test('captainAssignAvailability: lit + settled + unassigned captain + no free slot → captain_slots_full', () => {
  expect(
    captainAssignAvailability({ serverLit: true, shipSettled: true, hasFreeSlot: false, captainUnassigned: true }),
  ).toEqual({ canAssign: false, reason: 'captain_slots_full' })
})

test('captainAssignAvailability: all inputs good → ok', () => {
  expect(
    captainAssignAvailability({ serverLit: true, shipSettled: true, hasFreeSlot: true, captainUnassigned: true }),
  ).toEqual({ canAssign: true, reason: 'ok' })
})

// ── PREVIEW_ACTIVITY_TYPES / isPreviewActivity — exactly the 0165 set ───────────────────────────

test('PREVIEW_ACTIVITY_TYPES: EXACTLY the five 0165/0122 activities, in order', () => {
  expect([...PREVIEW_ACTIVITY_TYPES]).toEqual(['pirate_hunt', 'trade_run', 'exploration', 'mining', 'none'])
})

test('isPreviewActivity: accepts each of the five values', () => {
  for (const a of PREVIEW_ACTIVITY_TYPES) expect(isPreviewActivity(a)).toBe(true)
})

test('isPreviewActivity: rejects empty, unknown, and mixed-case strings (exact-set, no folding)', () => {
  expect(isPreviewActivity('')).toBe(false)
  expect(isPreviewActivity('combat')).toBe(false)
  expect(isPreviewActivity('Mining')).toBe(false)
  expect(isPreviewActivity('PIRATE_HUNT')).toBe(false)
  expect(isPreviewActivity(' none')).toBe(false)
  expect(isPreviewActivity('none ')).toBe(false)
})
