import { test, expect } from '@playwright/test'
import {
  aggregateTeamStats,
  groupPreviewAvailability,
  ADDITIVE_STAT_KEYS,
  type MemberStats,
  type PreviewMember,
} from '../src/features/command/teamSkillset'

// TEAM-COMMAND Slice C0 — pure-logic specs for the group-preview client mirror + the DISPLAY-ONLY
// team totals (no app/Supabase). The availability mirror asserts the same reject ORDER as the
// server RPC get_my_group_expedition_preview (migration 0165): dark gate FIRST, then activity,
// then group resolution, then non-empty membership. The totals helper is not server truth (Slice D
// owns authoritative team stats) — these specs pin its display contract only.

// ── groupPreviewAvailability — the full reject-order table ──────────────────────────────────────

test('groupPreviewAvailability: gate dark → gate_dark (before activity/group/member checks)', () => {
  expect(
    groupPreviewAvailability({ gateEnabled: false, activityKnown: true, groupResolved: true, memberCount: 3 }),
  ).toEqual({ canPreview: false, reason: 'gate_dark' })
})

test('groupPreviewAvailability: gate on + unknown activity → invalid_activity', () => {
  expect(
    groupPreviewAvailability({ gateEnabled: true, activityKnown: false, groupResolved: true, memberCount: 3 }),
  ).toEqual({ canPreview: false, reason: 'invalid_activity' })
})

test('groupPreviewAvailability: gate on + known activity + unresolved group → group_not_found', () => {
  expect(
    groupPreviewAvailability({ gateEnabled: true, activityKnown: true, groupResolved: false, memberCount: 3 }),
  ).toEqual({ canPreview: false, reason: 'group_not_found' })
})

test('groupPreviewAvailability: gate on + known + resolved + empty group → empty_group', () => {
  expect(
    groupPreviewAvailability({ gateEnabled: true, activityKnown: true, groupResolved: true, memberCount: 0 }),
  ).toEqual({ canPreview: false, reason: 'empty_group' })
})

test('groupPreviewAvailability: gate on + known + resolved + ≥1 member → ok', () => {
  expect(
    groupPreviewAvailability({ gateEnabled: true, activityKnown: true, groupResolved: true, memberCount: 1 }),
  ).toEqual({ canPreview: true, reason: 'ok' })
})

test('groupPreviewAvailability: order — dark gate beats everything else failing too', () => {
  expect(
    groupPreviewAvailability({ gateEnabled: false, activityKnown: false, groupResolved: false, memberCount: 0 })
      .reason,
  ).toBe('gate_dark')
})

test('groupPreviewAvailability: order — activity is checked before group resolution', () => {
  expect(
    groupPreviewAvailability({ gateEnabled: true, activityKnown: false, groupResolved: false, memberCount: 0 })
      .reason,
  ).toBe('invalid_activity')
})

test('groupPreviewAvailability: order — group resolution is checked before membership', () => {
  expect(
    groupPreviewAvailability({ gateEnabled: true, activityKnown: true, groupResolved: false, memberCount: 0 })
      .reason,
  ).toBe('group_not_found')
})

// ── aggregateTeamStats — DISPLAY-ONLY totals ────────────────────────────────────────────────────

const stats = (o: Partial<MemberStats> = {}): MemberStats => ({
  combat_power: 0,
  survival: 0,
  repair: 0,
  cargo_capacity: 0,
  scouting: 0,
  mining_yield: 0,
  retreat_safety: 0,
  pirate_attention: 0,
  captain_slots_used: 0,
  captain_slots_limit: 6,
  speed: 1,
  ...o,
})

const member = (id: string, s?: MemberStats): PreviewMember =>
  s ? { main_ship_id: id, valid: true, stats: s } : { main_ship_id: id, valid: false }

test('aggregateTeamStats: sums additive keys across 3 members, incl. the captain-slot keys', () => {
  const out = aggregateTeamStats([
    member('a', stats({ combat_power: 4, cargo_capacity: 50, captain_slots_used: 2, speed: 1 })),
    member('b', stats({ combat_power: 8, cargo_capacity: 58, captain_slots_used: 0, speed: 0.9 })),
    member('c', stats({ combat_power: 0, cargo_capacity: 50, mining_yield: 4, speed: 1.1 })),
  ])
  expect(out.memberCount).toBe(3)
  expect(out.validCount).toBe(3)
  expect(out.invalidCount).toBe(0)
  expect(out.totals.combat_power).toBe(12)
  expect(out.totals.cargo_capacity).toBe(158)
  expect(out.totals.mining_yield).toBe(4)
  expect(out.totals.captain_slots_used).toBe(2)
  expect(out.totals.captain_slots_limit).toBe(18) // 3 × 6 — capacity sums like any additive key
})

test('aggregateTeamStats: slowestSpeed is the MIN member speed (members travel individually)', () => {
  const out = aggregateTeamStats([
    member('a', stats({ speed: 1.2 })),
    member('b', stats({ speed: 0.86 })),
    member('c', stats({ speed: 1.0 })),
  ])
  expect(out.slowestSpeed).toBe(0.86)
})

test('aggregateTeamStats: invalid members are skipped from totals but counted', () => {
  const out = aggregateTeamStats([
    member('a', stats({ combat_power: 10, speed: 0.5 })),
    member('b'), // valid:false — e.g. an over-capacity member the server flagged
  ])
  expect(out.memberCount).toBe(2)
  expect(out.validCount).toBe(1)
  expect(out.invalidCount).toBe(1)
  expect(out.totals.combat_power).toBe(10) // the invalid member contributed nothing
  expect(out.slowestSpeed).toBe(0.5)
})

test('aggregateTeamStats: empty input → zero totals, zero counts, slowestSpeed null', () => {
  const out = aggregateTeamStats([])
  expect(out.memberCount).toBe(0)
  expect(out.validCount).toBe(0)
  expect(out.invalidCount).toBe(0)
  expect(out.slowestSpeed).toBeNull()
  for (const k of ADDITIVE_STAT_KEYS) expect(out.totals[k]).toBe(0)
})

test('aggregateTeamStats: all-invalid → zero totals + slowestSpeed null (never NaN)', () => {
  const out = aggregateTeamStats([member('a'), member('b')])
  expect(out.validCount).toBe(0)
  expect(out.invalidCount).toBe(2)
  expect(out.slowestSpeed).toBeNull()
  for (const k of ADDITIVE_STAT_KEYS) expect(out.totals[k]).toBe(0)
})

test('aggregateTeamStats: missing stat keys contribute 0 — no NaN anywhere', () => {
  // a sparse stats object (only combat_power + speed present) must not poison the other totals.
  const out = aggregateTeamStats([
    { main_ship_id: 'a', valid: true, stats: { combat_power: 4, speed: 1 } },
    member('b', stats({ survival: 3 })),
  ])
  expect(out.totals.combat_power).toBe(4)
  expect(out.totals.survival).toBe(3)
  for (const k of ADDITIVE_STAT_KEYS) expect(Number.isNaN(out.totals[k])).toBe(false)
  expect(out.slowestSpeed).toBe(1)
})

test('aggregateTeamStats: a valid member with no speed key does not produce a bogus slowestSpeed', () => {
  const out = aggregateTeamStats([{ main_ship_id: 'a', valid: true, stats: { combat_power: 1 } }])
  expect(out.slowestSpeed).toBeNull()
  expect(out.totals.combat_power).toBe(1)
})

test('aggregateTeamStats: an invalid member carrying the 0165 per-member `error` detail aggregates exactly like any invalid member', () => {
  // Slice C1 widened PreviewMember with the optional `error` migration 0165 emits beside
  // valid:false — display-only detail; aggregation must key ONLY on `valid` (the error string
  // never changes counts, totals, or slowestSpeed).
  const out = aggregateTeamStats([
    member('a', stats({ combat_power: 7, speed: 1.1 })),
    { main_ship_id: 'b', valid: false, error: 'captain headcount exceeds capacity' },
  ])
  expect(out.memberCount).toBe(2)
  expect(out.validCount).toBe(1)
  expect(out.invalidCount).toBe(1)
  expect(out.totals.combat_power).toBe(7)
  expect(out.slowestSpeed).toBe(1.1)
})

test('aggregateTeamStats: a valid member with NO stats payload stays valid (zero contribution), never demoted', () => {
  // Server said valid:true — client must NOT reclassify it as invalid just because stats is absent.
  const out = aggregateTeamStats([
    { main_ship_id: 'a', valid: true, stats: stats({ combat_power: 5, speed: 0.9 }) },
    { main_ship_id: 'b', valid: true }, // valid per server, but no stats object
  ])
  expect(out.validCount).toBe(2)
  expect(out.invalidCount).toBe(0)
  expect(out.totals.combat_power).toBe(5) // the payload-less valid member contributed 0, not NaN
  expect(out.slowestSpeed).toBe(0.9) // and did not perturb the min speed
  for (const k of ADDITIVE_STAT_KEYS) expect(Number.isNaN(out.totals[k])).toBe(false)
})
