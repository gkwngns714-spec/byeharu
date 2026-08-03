import { test, expect } from '@playwright/test'
import {
  LIVE_ENCOUNTER_STATUSES,
  SAME_POINT_EPSILON,
  isLiveEncounter,
  liveEncounterForFleet,
  resolveEncounterAnchor,
  type FleetEncounterLite,
} from '../src/features/combat/encounterAnchor'

// ENGAGEMENT ANCHOR — pure specs for the ONE client answer to "where is this fight, physically?".
// No I/O, no clock. The fixtures are combat_encounters rows exactly as the already-running poll
// (useCombat → combatApi.fetchActiveEncounters) hands them over.
//
// The rule mirrors the server verbatim: combat_create_group_encounter resolves
// coalesce(p_engagement_x, l.x) (0293:255) and the tick re-resolves coalesce(e.engagement_x, loc.x)
// (0294:424) before SEEDING every combat_units row.
//
// ⚑ THE ANCHOR IS WHERE A FIGHT STARTED — NOT WHERE THE FLEET IS. Since 0313/0314 the seeded units
// then move, so the formation walks 20-30 units off the anchor within a tick or two. "Where is this
// fleet now" is map/fleetFightPosition's question (the fleet's own ship nearest the enemy), and NO
// badge is ever DRAWN on this leaf's point. What remains here: the ambush-vs-hunt ORIGIN test (an
// anchor off the linked location's centre means the fleet was dragged into the fight en route —
// 0293's own rule), read by map/ambushEncounterNotice; the anchor as fleetFightPosition's distance
// TARGET when no living enemy is left to aim at; plus the shared live-encounter selection.
//
// The coordinates below are REAL: the owner's production encounters at Snare, site centre (-45,120),
// fights measured at (-27.37, 97.04) and (-63, 96) — gaps of 28.95 and 30.00 world units.

const SITE = { x: -45, y: 120 }
const FIGHT = { x: -27.37, y: 97.04 }

const enc = (o: Partial<FleetEncounterLite> = {}): FleetEncounterLite => ({
  id: 'e1',
  fleet_id: 'fleet-1',
  status: 'active',
  engagement_x: FIGHT.x,
  engagement_y: FIGHT.y,
  ...o,
})

// ── resolveEncounterAnchor — the coalesce ───────────────────────────────────────────────────────
test('a finite engagement anchor IS the answer, and it is flagged off-site', () => {
  expect(resolveEncounterAnchor(enc(), SITE)).toEqual({
    x: -27.37,
    y: 97.04,
    source: 'engagement',
    offSite: true,
  })
})

test('an anchor stamped ON the centre (an ordinary hunt) is the centre, and is NOT off-site', () => {
  expect(resolveEncounterAnchor(enc({ engagement_x: SITE.x, engagement_y: SITE.y }), SITE)).toEqual({
    x: -45,
    y: 120,
    source: 'engagement',
    offSite: false,
  })
})

test('a missing / NULL / half-populated / non-finite anchor falls back to the site centre', () => {
  const fallback = { x: -45, y: 120, source: 'site', offSite: false }
  expect(resolveEncounterAnchor(null, SITE)).toEqual(fallback)
  expect(resolveEncounterAnchor(undefined, SITE)).toEqual(fallback)
  expect(resolveEncounterAnchor({}, SITE)).toEqual(fallback)
  expect(resolveEncounterAnchor({ engagement_x: null, engagement_y: null }, SITE)).toEqual(fallback)
  expect(resolveEncounterAnchor({ engagement_x: FIGHT.x, engagement_y: null }, SITE)).toEqual(fallback)
  expect(resolveEncounterAnchor({ engagement_x: null, engagement_y: FIGHT.y }, SITE)).toEqual(fallback)
  expect(resolveEncounterAnchor({ engagement_x: Number.NaN, engagement_y: FIGHT.y }, SITE)).toEqual(fallback)
  expect(
    resolveEncounterAnchor({ engagement_x: FIGHT.x, engagement_y: Number.POSITIVE_INFINITY }, SITE),
  ).toEqual(fallback)
})

test('a fallback NEVER lands on the origin — it lands on the site the caller passed', () => {
  const a = resolveEncounterAnchor(null, SITE)!
  expect(a.x === 0 && a.y === 0).toBe(false)
  expect({ x: a.x, y: a.y }).toEqual(SITE)
})

test('an unusable SITE is the only null — so no caller can emit NaN into an SVG transform', () => {
  expect(resolveEncounterAnchor(enc(), { x: Number.NaN, y: 120 })).toBeNull()
  expect(resolveEncounterAnchor(enc(), { x: -45, y: Number.NaN })).toBeNull()
  expect(resolveEncounterAnchor(null, { x: Number.POSITIVE_INFINITY, y: 0 })).toBeNull()
  // …and a usable site ALWAYS yields finite coordinates, on both arms
  for (const e of [enc(), enc({ engagement_x: null, engagement_y: null })]) {
    const a = resolveEncounterAnchor(e, SITE)!
    expect(Number.isFinite(a.x) && Number.isFinite(a.y)).toBe(true)
  }
})

test('the same-point epsilon absorbs JSON round-tripping without ever hiding a real ambush', () => {
  const jitter = enc({ engagement_x: SITE.x + SAME_POINT_EPSILON / 2, engagement_y: SITE.y })
  expect(resolveEncounterAnchor(jitter, SITE)!.offSite).toBe(false)
  const real = enc({ engagement_x: SITE.x + 1, engagement_y: SITE.y })
  expect(resolveEncounterAnchor(real, SITE)!.offSite).toBe(true)
  // the owner's smallest measured gap (20.59 units) is four million epsilons wide
  expect(resolveEncounterAnchor(enc({ engagement_x: -35, engagement_y: 102 }), SITE)!.offSite).toBe(true)
})

// ── liveEncounterForFleet — WHICH fight is this fleet's ──────────────────────────────────────────
test('live statuses are exactly the pair combatApi reads back', () => {
  expect([...LIVE_ENCOUNTER_STATUSES].sort()).toEqual(['active', 'retreating'])
  expect(isLiveEncounter({ status: 'active' })).toBe(true)
  expect(isLiveEncounter({ status: 'retreating' })).toBe(true)
  expect(isLiveEncounter({ status: 'completed' })).toBe(false)
})

test('the fleet’s own live encounter is returned; another fleet’s is never', () => {
  const mine = enc()
  const theirs = enc({ fleet_id: 'fleet-2', engagement_x: -63, engagement_y: 96 })
  expect(liveEncounterForFleet([theirs, mine], 'fleet-1')).toBe(mine)
  expect(liveEncounterForFleet([theirs, mine], 'fleet-2')).toBe(theirs)
  expect(liveEncounterForFleet([theirs], 'fleet-1')).toBeNull()
})

test('fail closed: no fleet id, no rows, or only ENDED rows → null', () => {
  expect(liveEncounterForFleet([enc()], null)).toBeNull()
  expect(liveEncounterForFleet([enc()], undefined)).toBeNull()
  expect(liveEncounterForFleet([enc()], '')).toBeNull()
  expect(liveEncounterForFleet([], 'fleet-1')).toBeNull()
  for (const status of ['escaped', 'defeat', 'completed']) {
    expect(liveEncounterForFleet([enc({ status })], 'fleet-1')).toBeNull()
  }
})

test('an ended row beside a live one does not shadow it', () => {
  const live = enc()
  expect(liveEncounterForFleet([enc({ status: 'completed' }), live], 'fleet-1')).toBe(live)
})

test('TWO live encounters for one fleet is a broken invariant → null, never an arbitrary pick', () => {
  // the DB's one_active_encounter_per_fleet partial unique index (0014:35) forbids this shape
  const pair = [enc(), enc({ id: 'e2', engagement_x: -63, engagement_y: 96 })]
  expect(liveEncounterForFleet(pair, 'fleet-1')).toBeNull()
  expect(liveEncounterForFleet([...pair].reverse(), 'fleet-1')).toBeNull() // order-independent
})

test('composed: null from the selector degrades to the site centre, not to a guess', () => {
  const anchor = resolveEncounterAnchor(liveEncounterForFleet([enc({ fleet_id: 'other' })], 'fleet-1'), SITE)
  expect(anchor).toEqual({ x: -45, y: 120, source: 'site', offSite: false })
})
