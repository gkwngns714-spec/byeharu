import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { resolveRewardEntries, rewardPayloadIsEmpty } from '../src/features/combat/rewardPayload'

const here = dirname(fileURLToPath(import.meta.url))
/** Source with comment lines stripped: an assertion about what a surface DOES must not be satisfied
 *  — or defeated — by the paragraph explaining what it no longer does. */
const src = (rel: string) =>
  readFileSync(join(here, '..', 'src', rel), 'utf8')
    .split(/\r?\n/)
    .filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*'))
    .join('\n')

// THE ONE READING OF A REWARD PAYLOAD. The server writes `{metal: N, items: [{item_id, quantity}]}`
// (0299:1006-1010, loot_merge_items 20260617000041:51-66) — a scalar key beside an ARRAY key. Three
// client surfaces each read it inline, typed as `Record<string, number>`, and each got it wrong in
// its own way. These tests pin the shape the server actually writes.

test('the payload the server writes: metal AND the items array, flattened in one list', () => {
  const entries = resolveRewardEntries({
    metal: 40,
    items: [
      { item_id: 'scrap_alloy', quantity: 3 },
      { item_id: 'nav_core', quantity: 1 },
    ],
  })
  expect(entries).toEqual([
    { id: 'metal', qty: 40 },
    { id: 'scrap_alloy', qty: 3 },
    { id: 'nav_core', qty: 1 },
  ])
})

test('THE DROPPED HALF: an items-only haul is NOT empty', () => {
  // `Object.entries(payload).filter(([, v]) => v > 0)` — the old ReportsSection read — is FALSE for
  // an array, so a battle whose entire reward was loot reported "Rewards: none".
  const payload = { metal: 0, items: [{ item_id: 'scrap_alloy', quantity: 2 }] }
  expect(rewardPayloadIsEmpty(payload)).toBe(false)
  expect(resolveRewardEntries(payload)).toEqual([{ id: 'scrap_alloy', qty: 2 }])
})

test('THE OTHER HALF: the items ARRAY never becomes a chip quantity', () => {
  // ActiveCombatPanel mapped every key straight to an <ItemChip qty={value}>, so `items` rendered as
  // the literal `Items ×[object Object]`. No entry may ever carry a non-number.
  for (const e of resolveRewardEntries({ metal: 5, items: [{ item_id: 'x', quantity: 1 }] })) {
    expect(typeof e.qty).toBe('number')
    expect(Number.isFinite(e.qty)).toBe(true)
    expect(e.id).not.toBe('items')
  }
})

test('duplicate codes across the two halves are summed, the way the server merges them', () => {
  expect(resolveRewardEntries({ metal: 10, items: [{ item_id: 'metal', quantity: 5 }] })).toEqual([
    { id: 'metal', qty: 15 },
  ])
})

test('nothing is fabricated: zero, negative, malformed and missing all resolve to no entry', () => {
  expect(resolveRewardEntries(null)).toEqual([])
  expect(resolveRewardEntries(undefined)).toEqual([])
  expect(resolveRewardEntries({})).toEqual([])
  expect(resolveRewardEntries({ metal: 0 })).toEqual([])
  expect(resolveRewardEntries({ metal: -5 })).toEqual([])
  expect(resolveRewardEntries({ items: 'not-an-array' })).toEqual([])
  expect(resolveRewardEntries({ items: [{ item_id: '', quantity: 3 }, { quantity: 3 }, { item_id: 'a' }] })).toEqual([])
  expect(rewardPayloadIsEmpty({ metal: 0, items: [] })).toBe(true)
})

test('a numeric arriving as a PostgREST string still counts', () => {
  expect(resolveRewardEntries({ metal: '12', items: [{ item_id: 'a', quantity: '2' }] })).toEqual([
    { id: 'metal', qty: 12 },
    { id: 'a', qty: 2 },
  ])
})

test('a future reward code surfaces instead of hiding', () => {
  expect(resolveRewardEntries({ credits: 250 })).toEqual([{ id: 'credits', qty: 250 }])
})

// ── ONE READER, COMPOSED — never a fourth inline copy ─────────────────────────────────────────────
test('every reward surface composes this reader and none re-reads the payload inline', () => {
  for (const rel of [
    'features/combat/ActiveCombatPanel.tsx',
    'features/combat/ReportsSection.tsx',
    'features/combat/RoundLog.tsx',
  ]) {
    const text = src(rel)
    expect(text, `${rel} must compose the one reader`).toContain('resolveRewardEntries')
    expect(text, `${rel} must not read the payload's keys by hand`).not.toContain('total_rewards_json ?? {}')
    expect(text, `${rel} must not reach for a single reward key`).not.toContain('reward_delta_json?.metal')
  }
})
