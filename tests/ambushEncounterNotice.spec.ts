import { test, expect } from '@playwright/test'
import {
  AMBUSH_NOTICE_TEXT,
  ambushEncounterNotices,
  type AmbushEncounterLite,
  type AmbushLocationLite,
} from '../src/features/map/ambushEncounterNotice'

// INTERCEPT DEFERRED ENTRY — pure specs for the ENCOUNTER-DRIVEN ambush notice. No I/O, no clock.
// The fixtures are combat_encounters rows as the already-running poll (useCombat) hands them over,
// plus the map's locations. The rule mirrors migration 0293: an encounter whose engagement point is
// its location's centre is a hunt the player sailed to; an encounter anchored anywhere else was
// sprung on the fleet en route.

const locations: AmbushLocationLite[] = [
  { id: 'loc-reaver', x: 210, y: -30 },
  { id: 'loc-snare', x: -400, y: 120 },
]

const enc = (over: Partial<AmbushEncounterLite> = {}): AmbushEncounterLite => ({
  id: 'enc-1',
  status: 'active',
  location_id: 'loc-reaver',
  engagement_x: 210,
  engagement_y: -30,
  ...over,
})

test('an engagement point AWAY from the location centre is the ambush — one notice, keyed by encounter', () => {
  const notices = ambushEncounterNotices({
    encounters: [enc({ engagement_x: 155.5, engagement_y: -88.25 })],
    locations,
  })
  expect(notices).toEqual([{ encounterId: 'enc-1', text: AMBUSH_NOTICE_TEXT }])
  expect(AMBUSH_NOTICE_TEXT).toBe('Ambushed at the zone boundary.')
})

test('an engagement point ON the location centre is an ordinary hunt — no notice', () => {
  expect(ambushEncounterNotices({ encounters: [enc()], locations })).toEqual([])
})

test('a retreating fleet is still in the fight, so the notice survives the retreat', () => {
  const notices = ambushEncounterNotices({
    encounters: [enc({ status: 'retreating', engagement_x: 0, engagement_y: 0 })],
    locations,
  })
  expect(notices).toHaveLength(1)
})

test('a finished encounter never renders — escaped / defeat / completed are not live', () => {
  for (const status of ['escaped', 'defeat', 'completed', 'anything_else']) {
    expect(
      ambushEncounterNotices({ encounters: [enc({ status, engagement_x: 0, engagement_y: 0 })], locations }),
    ).toEqual([])
  }
})

// ── FAIL CLOSED — every unprovable case is SILENCE, never a claim. ─────────────────────────────────

test('FAIL CLOSED: no engagement anchor (a server predating 0293) → no notice', () => {
  expect(ambushEncounterNotices({ encounters: [enc({ engagement_x: undefined, engagement_y: undefined })], locations })).toEqual([])
  expect(ambushEncounterNotices({ encounters: [enc({ engagement_x: null, engagement_y: null })], locations })).toEqual([])
  // A half-present anchor is just as unprovable as an absent one.
  expect(ambushEncounterNotices({ encounters: [enc({ engagement_x: 0, engagement_y: null })], locations })).toEqual([])
  expect(ambushEncounterNotices({ encounters: [enc({ engagement_x: null, engagement_y: 0 })], locations })).toEqual([])
})

test('FAIL CLOSED: a non-finite coordinate is not a comparison — NaN and Infinity yield nothing', () => {
  expect(ambushEncounterNotices({ encounters: [enc({ engagement_x: Number.NaN, engagement_y: 0 })], locations })).toEqual([])
  expect(ambushEncounterNotices({ encounters: [enc({ engagement_x: 0, engagement_y: Number.POSITIVE_INFINITY })], locations })).toEqual([])
})

test('FAIL CLOSED: no linked location, or a location the map has not loaded → no notice', () => {
  expect(ambushEncounterNotices({ encounters: [enc({ location_id: null, engagement_x: 0, engagement_y: 0 })], locations })).toEqual([])
  expect(ambushEncounterNotices({ encounters: [enc({ location_id: 'loc-unknown', engagement_x: 0, engagement_y: 0 })], locations })).toEqual([])
  expect(ambushEncounterNotices({ encounters: [enc({ engagement_x: 0, engagement_y: 0 })], locations: [] })).toEqual([])
})

test('nothing fighting → an empty list, so the map stays clean', () => {
  expect(ambushEncounterNotices({ encounters: [], locations })).toEqual([])
})

// ── Comparison precision ──────────────────────────────────────────────────────────────────────────

test('JSON round-tripping noise is absorbed; a real ambush point is world units away', () => {
  // Sub-epsilon drift is the same point.
  expect(
    ambushEncounterNotices({ encounters: [enc({ engagement_x: 210 + 1e-9, engagement_y: -30 - 1e-9 })], locations }),
  ).toEqual([])
  // A single world unit off centre is already a different point.
  expect(
    ambushEncounterNotices({ encounters: [enc({ engagement_x: 211, engagement_y: -30 })], locations }),
  ).toHaveLength(1)
  expect(
    ambushEncounterNotices({ encounters: [enc({ engagement_x: 210, engagement_y: -29 })], locations }),
  ).toHaveLength(1)
})

test('several live encounters are judged independently and reported in order', () => {
  const notices = ambushEncounterNotices({
    encounters: [
      enc({ id: 'hunt', location_id: 'loc-snare', engagement_x: -400, engagement_y: 120 }),
      enc({ id: 'ambush-a', location_id: 'loc-reaver', engagement_x: 12, engagement_y: 34 }),
      enc({ id: 'dead', status: 'completed', engagement_x: 12, engagement_y: 34 }),
      enc({ id: 'ambush-b', location_id: 'loc-snare', engagement_x: -401, engagement_y: 120 }),
    ],
    locations,
  })
  expect(notices.map((n) => n.encounterId)).toEqual(['ambush-a', 'ambush-b'])
  expect(notices.every((n) => n.text === AMBUSH_NOTICE_TEXT)).toBe(true)
})

test('the notice carries no codes, no ids and no jargon — one plain sentence', () => {
  const [only] = ambushEncounterNotices({ encounters: [enc({ engagement_x: 1, engagement_y: 2 })], locations })
  expect(only.text).toBe('Ambushed at the zone boundary.')
  expect(only.text).not.toMatch(/[_{}[\]]|enc-|loc-/)
})
