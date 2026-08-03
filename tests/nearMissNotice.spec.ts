import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  nearMissNotices,
  nearMissText,
  NEAR_MISS_MAP_WINDOW_MS,
  NEAR_MISS_KEEP_ALL,
} from '../src/features/map/nearMissNotice'
import type { InterceptMissLite } from '../src/features/map/pirateApi'

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', rel), 'utf8')

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// THE NEAR MISS — the event that used to be silence.
//
// Owner, 2026-08-03: "i went to snare, zone, no fighting happens." Production says their last two
// Snare crossings were ROLLED FOR and both missed (risk 0.545 vs roll 0.697; risk 0.240 vs roll
// 0.336), and the game said nothing either time. The owner has since decided the probabilistic
// ambush STAYS, which is what makes this load-bearing: a 98% system can afford silence on the 2%,
// a coin flip cannot. "The dice went your way" and "the combat system is broken" must stop
// producing the identical experience.
//
// Three rules, each pinned below.
// ═══════════════════════════════════════════════════════════════════════════════════════════════

const NOW = Date.parse('2026-08-03T15:00:00Z')
const at = (msAgo: number) => new Date(NOW - msAgo).toISOString()

const miss = (over: Partial<InterceptMissLite> = {}): InterceptMissLite => ({
  id: 'pim-1',
  movement_id: 'mv-1',
  location_id: 'loc-snare',
  created_at: at(60_000),
  ...over,
})

const SITES = [
  { id: 'loc-snare', name: 'Snare' },
  { id: 'loc-reaver', name: 'Reaver' },
]

const call = (over: Partial<Parameters<typeof nearMissNotices>[0]> = {}) =>
  nearMissNotices({
    misses: [miss()],
    locations: SITES,
    activeMovementIds: [],
    nowMs: NOW,
    withinMs: NEAR_MISS_MAP_WINDOW_MS,
    ...over,
  })

// ── THE EVENT ────────────────────────────────────────────────────────────────────────────────────

test('a settled crossing that was rolled for and missed becomes a sentence, naming the place', () => {
  expect(call()).toEqual([{ id: 'pim-1', text: 'Slipped past the pirates around Snare.' }])
})

test('an unresolvable place still gets a notice — the EVENT is the news, not the name', () => {
  // Suppressing the whole thing over a name we cannot look up would put us back in silence for
  // exactly the hidden/unreleased sites where a player is most confused about what happened.
  expect(call({ misses: [miss({ location_id: null })] })[0].text).toBe(
    'Slipped past the pirates in a raided zone.',
  )
  expect(call({ misses: [miss({ location_id: 'loc-not-loaded' })] })[0].text).toBe(
    'Slipped past the pirates in a raided zone.',
  )
})

// ── RULE 1 · NEVER FOR A LEG THAT HAD NO ROLL ────────────────────────────────────────────────────

test('a trip with no roll produces nothing, because there is no row to produce it from', () => {
  // The guarantee is STRUCTURAL, not a filter here: the deployed pirate_intercept_plan_leg inserts
  // a row only for a zone the leg actually crosses. Conflating "you dodged them" with "you never
  // went near them" would be a new lie replacing the old one, so the empty input is pinned.
  expect(call({ misses: [] })).toEqual([])
})

test('the model reads no risk/roll column at all, so a number can never leak into the copy', () => {
  // Rule 2: the risk and the roll ARE on the row. They are deliberately not in the read's
  // projection and not in this module — "you slipped past" is the event, "risk 0.545" is a debug
  // readout that invites arguing with the dice instead of feeling them.
  const model = src('features/map/nearMissNotice.ts')
  expect(model).not.toMatch(/\bm\.(risk|roll|hit|exposure_fraction|combined_stats)\b/)
  expect(nearMissText('Snare')).not.toMatch(/\d/)
  expect(nearMissText(null)).not.toMatch(/\d/)
  const api = src('features/map/pirateApi.ts')
  const projection = api.slice(api.indexOf("from('pirate_intercepts')"))
  expect(projection.slice(0, 200), 'the read must not even fetch the numbers').not.toMatch(/risk|roll/)
})

// ── RULE 3 · NOT WHILE THE FLEET IS STILL FLYING ─────────────────────────────────────────────────

test('a miss on a leg still in flight says NOTHING — the crossing has not happened yet', () => {
  // The roll is sealed at ORDER time (plan_leg runs inside command_ship_group_go), so the row
  // exists seconds before the fleet reaches the zone. Announcing it then would narrate a crossing
  // that is still in the future.
  expect(call({ activeMovementIds: ['mv-1'] })).toEqual([])
  // …and the moment that leg settles out of the active list, the same row is announced.
  expect(call({ activeMovementIds: ['mv-other'] })).toHaveLength(1)
})

test('a row with no leg attached is still announceable — a null movement cannot be "in flight"', () => {
  expect(call({ misses: [miss({ movement_id: null })], activeMovementIds: ['mv-1'] })).toHaveLength(1)
})

// ── THE WINDOW: news on the map, record on the ops screen ────────────────────────────────────────

test('the map window expires an old near miss, so a clean map is never permanently occupied', () => {
  expect(call({ misses: [miss({ created_at: at(NEAR_MISS_MAP_WINDOW_MS - 1000) })] })).toHaveLength(1)
  expect(call({ misses: [miss({ created_at: at(NEAR_MISS_MAP_WINDOW_MS + 1000) })] })).toEqual([])
})

test('the record keeps what the map lets go — nothing is lost to the window', () => {
  const ancient = miss({ created_at: at(30 * 24 * 60 * 60 * 1000) })
  expect(call({ misses: [ancient] })).toEqual([])
  expect(call({ misses: [ancient], withinMs: NEAR_MISS_KEEP_ALL })).toHaveLength(1)
})

test('a future-stamped row (clock skew) is rejected in BOTH windows — never a claim from a bad clock', () => {
  const future = miss({ created_at: new Date(NOW + 60_000).toISOString() })
  expect(call({ misses: [future] })).toEqual([])
  expect(call({ misses: [future], withinMs: NEAR_MISS_KEEP_ALL })).toEqual([])
})

test('an unparseable timestamp yields silence, not a notice with a broken time', () => {
  expect(call({ misses: [miss({ created_at: 'not-a-date' })] })).toEqual([])
})

// ── ORDER AND VOLUME ─────────────────────────────────────────────────────────────────────────────

test('the read’s newest-first order is preserved, never re-sorted by a second authority', () => {
  const rows = [
    miss({ id: 'new', created_at: at(1000), movement_id: 'mv-a', location_id: 'loc-reaver' }),
    miss({ id: 'old', created_at: at(2000), movement_id: 'mv-b' }),
  ]
  expect(call({ misses: rows }).map((n) => n.id)).toEqual(['new', 'old'])
})

test('the limit caps how many alerts stack at once, and 0 is honoured rather than ignored', () => {
  const rows = ['a', 'b', 'c', 'd'].map((id) => miss({ id, movement_id: `mv-${id}` }))
  expect(call({ misses: rows, limit: 3 })).toHaveLength(3)
  expect(call({ misses: rows, limit: 0 })).toEqual([])
  expect(call({ misses: rows })).toHaveLength(4)
})

// ── ONE AUTHORITY FOR THE WORDS ──────────────────────────────────────────────────────────────────

test('the map alert and the Mission record are two VIEWS of one model, not two vocabularies', () => {
  const mapScreen = src('features/map/MapScreen.tsx')
  const section = src('features/combat/NearMissSection.tsx')
  for (const [name, text] of [['MapScreen', mapScreen], ['NearMissSection', section]] as const) {
    expect(text, `${name} must compose the model`).toMatch(/from '[^']*nearMissNotice'/)
    expect(text, `${name} must not write its own sentence`).not.toContain('Slipped past')
  }
  // The map is news and expires; the record keeps everything. Same model, different window.
  expect(mapScreen).toContain('NEAR_MISS_MAP_WINDOW_MS')
  expect(section).toContain('NEAR_MISS_KEEP_ALL')
})

test('the misses ride the SAME shell wave as the movements they are judged against', () => {
  // Rule 3 compares a miss to the active-movement list. If those two facts came from two different
  // polls (game 3s, map 4s) the notice would flicker on and off at the seam, so useGameState
  // fetches both in one Promise.all.
  const hook = src('features/dashboard/useGameState.ts')
  const wave = hook.slice(hook.indexOf('await Promise.all(['), hook.indexOf('setState({'))
  expect(wave).toContain('fetchActiveMovements()')
  expect(wave).toContain('fetchInterceptMisses()')
})
