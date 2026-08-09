import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { HAUL_AT_STAKE, resolveFightHaul } from '../src/features/combat/fightHaul'

// ██ THE HAUL — pure unit proof of the number the whole fight turns on. ██
//
// The owner's combat law: "the whole point of this game is never to win, but exit appropriately."
// 0347's cap grows without bound on purpose, so no fight is ever won; and a DEFEAT zeroes
// total_rewards_json outright — measured on production, one death destroyed 10 of the 11 engine_parts
// and all 1,115 metal an account had ever earned at Reaver. So the only question the fight asks is
// "one more kill, or leave with this", and the haul is the instrument for it.
//
// The payload is `{"metal": N, "items":[{item_id, quantity}, …]}` — a scalar key BESIDE an array key.
// Reading it inline is how two surfaces once rendered `Items ×[object Object]`. This leaf composes
// the ONE reader and adds exactly one piece of arithmetic: catalog volume × quantity.
//
// No browser, no page, no DB. Run: `npx playwright test fightHaul.spec.ts`.

const VOL = new Map<string, number>([
  ['scrap', 0.5],
  ['pirate_alloy', 0.5],
  ['weapon_parts', 0.2],
])

const payload = { metal: 1115, items: [{ item_id: 'scrap', quantity: 12 }, { item_id: 'pirate_alloy', quantity: 3 }] }

// ── WHAT WAS WON ─────────────────────────────────────────────────────────────────────────────────

test('the array half is READ — the bug this leaf exists downstream of', () => {
  const v = resolveFightHaul(payload, VOL)
  expect(v.entries.map((e) => e.id)).toEqual(['metal', 'scrap', 'pirate_alloy'])
  expect(v.entries.map((e) => e.qty)).toEqual([1115, 12, 3])
  expect(v.empty).toBe(false)
})

test('an empty, absent or wholly-zero payload is EMPTY — decided by the one reader, never by a key probe', () => {
  for (const p of [null, undefined, {}, { metal: 0 }, { items: [] }, { metal: 0, items: [] }]) {
    const v = resolveFightHaul(p, VOL)
    expect(v.empty, `${JSON.stringify(p)} must read as empty`).toBe(true)
    expect(v.entries).toEqual([])
    expect(v.m3).toBeNull()
  }
})

// ── WHAT IT TAKES UP ─────────────────────────────────────────────────────────────────────────────

test('volume is quantity × the catalog’s per-unit m³, summed over what the catalog prices', () => {
  const v = resolveFightHaul(payload, VOL)
  // 12 × 0.5 + 3 × 0.5 = 7.5. `metal` has no item_types row and is NOT folded in at zero.
  expect(v.m3).toBeCloseTo(7.5, 6)
  expect(v.entries.find((e) => e.id === 'scrap')!.m3).toBeCloseTo(6, 6)
  expect(v.entries.find((e) => e.id === 'pirate_alloy')!.m3).toBeCloseTo(1.5, 6)
})

test('a code with NO catalog volume is reported as unknown, never as zero', () => {
  // `metal` is a currency: it has no item_types row, so it has no volume. Folding it in at 0 would
  // quietly under-report a haul, and a fabricated value is worse than a blank.
  const v = resolveFightHaul(payload, VOL)
  expect(v.entries.find((e) => e.id === 'metal')!.m3).toBeNull()
  expect(v.unmeasured, 'the surface must be able to say the total is a floor').toBe(1)
})

test('an EMPTY catalog says nothing about volume at all — it never prints a zero it cannot defend', () => {
  const v = resolveFightHaul(payload, new Map())
  expect(v.m3).toBeNull()
  expect(v.unmeasured).toBe(3)
  expect(v.entries.every((e) => e.m3 === null)).toBe(true)
  // …and the haul itself is still fully listed. A missing catalog hides the volume, never the loot.
  expect(v.entries.map((e) => e.id)).toEqual(['metal', 'scrap', 'pirate_alloy'])
})

test('a malformed catalog entry is ignored rather than propagated as NaN', () => {
  const bad = new Map<string, number>([['scrap', Number.NaN], ['pirate_alloy', 0], ['metal', -1]])
  const v = resolveFightHaul(payload, bad)
  expect(v.m3).toBeNull()
  expect(v.entries.every((e) => e.m3 === null)).toBe(true)
})

test('every entry’s m³ is either a positive finite number or null — never NaN, never negative', () => {
  const v = resolveFightHaul(payload, VOL)
  for (const e of v.entries) {
    if (e.m3 !== null) {
      expect(Number.isFinite(e.m3)).toBe(true)
      expect(e.m3).toBeGreaterThan(0)
    }
  }
})

// ── WHAT IS AT STAKE ─────────────────────────────────────────────────────────────────────────────

test('the stake is one sentence, unconditional, and it names BOTH outcomes', () => {
  // Not a warning that appears at a threshold: it is true of every live fight, always.
  expect(HAUL_AT_STAKE).toMatch(/banked/i)
  expect(HAUL_AT_STAKE).toMatch(/lost/i)
  expect(HAUL_AT_STAKE).toMatch(/destroyed/i)
})

test('██ IT NAMES WHERE THE HAUL GOES, AND THE PLACE IT NAMES IS THE PORT ██', () => {
  // Owner, playing 2026-08-09: *"fleet hold is not updated when fight is done"*. He was reading the
  // card correctly and the card was wrong. TRACED THROUGH THE DEPLOYED SERVER:
  //   a kill folds into combat_encounters.total_rewards_json (0344's payout arm)
  //   → leaving copies it onto the RETURN LEG as fleet_movements.reward_payload_json
  //     (movement_attach_cargo, 0030:30)
  //   → the leg's arrival calls reward_grant(…, base, payload) (0307:172), which deposits into a
  //     BASE — that PORT's storage. 0333 states it outright: "reward_grant (loot) → the base it is
  //     already handed; and where that is NULL … the player's OLDEST ACTIVE base".
  // `fleet_items` — the HOLD — is written by NO arm of that chain. The old sentence ("banked when the
  // fleet leaves and arrives"), printed directly above a Fleet hold meter, promised a relationship
  // the database does not have. That was the whole defect, and it was CLIENT SIDE.
  expect(HAUL_AT_STAKE).toMatch(/port/i)
  expect(HAUL_AT_STAKE, 'the haul does not ride in the hold and must not say it does').not.toMatch(/hold/i)
})

// ── ONE READER, AND NO CAPACITY MATH ─────────────────────────────────────────────────────────────

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', rel), 'utf8')

test('the leaf composes the ONE payload reader and never touches the raw json', () => {
  const source = src('features/combat/fightHaul.ts')
  expect(source).toContain("from './rewardPayload'")
  expect(source).toContain('resolveRewardEntries(payload)')
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  expect(code, 'the strip did not eat the code').toContain('export function resolveFightHaul')
  // It must not re-read the payload's own keys — that is the `Items ×[object Object]` defect.
  expect(code).not.toContain("payload['items']")
  expect(code).not.toContain("payload.items")
  // …and it must never compute an occupancy or a capacity. Those are the server's (get_my_hold).
  for (const forbidden of ['capacity', 'usedM3', 'freeM3', 'cargo_capacity_m3', 'react', 'supabase']) {
    expect(code, `fightHaul.ts must not contain ${forbidden}`).not.toContain(forbidden)
  }
})
