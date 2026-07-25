import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  ZONE_KINDS,
  ZONE_KIND_LABELS,
  ZONE_KIND_PERMITTED_EFFECTS,
  blockingEffectsFor,
  explainKindConversion,
  isZoneKind,
  planKindConversion,
} from '../src/features/worldeditor/zoneKindConversion'
import { ZONE_EFFECT_KINDS, type ZoneEffectKind } from '../src/features/worldeditor/zoneEffects'

// ZONE KIND CONVERSION — the client mirror of the server's refusal rule (zone_kind_change, 0285).
// The single most valuable test here is the AGREEMENT test: a mirror that silently drifts is worse
// than no mirror, because the editor would then confidently offer a conversion the server rejects.
// Run: `npx playwright test zoneKindConversion.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const migration = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000285_zone_kind_change.sql'),
  'utf8',
).replace(/\r\n/g, '\n')
const source = readFileSync(
  join(repo, 'src', 'features', 'worldeditor', 'zoneKindConversion.ts'),
  'utf8',
)

// ── the test that matters most ──────────────────────────────────────────────────────────────────
test('the mirror AGREES with the server table, pair for pair', () => {
  // parse the authority: insert into zone_kind_permitted_effects ... values ('pirate','pirate_intercept'), ...
  const block = migration.slice(
    migration.indexOf('insert into public.zone_kind_permitted_effects'),
  )
  const values = block.slice(0, block.indexOf(';'))
  const serverPairs = [...values.matchAll(/\('([a-z_]+)',\s*'([a-z_]+)'\)/g)]
    .map(([, kind, effect]) => `${kind}:${effect}`)
    .sort()
  expect(serverPairs.length, 'the server table should declare pairs').toBeGreaterThan(0)

  const clientPairs = Object.entries(ZONE_KIND_PERMITTED_EFFECTS)
    .flatMap(([kind, effects]) => effects.map((e) => `${kind}:${e}`))
    .sort()

  expect(clientPairs, 'client mirror drifted from the server authority').toEqual(serverPairs)
})

test('the kind list matches the widened zone_kind CHECK', () => {
  for (const k of ZONE_KINDS) {
    expect(migration, `${k} must be a permitted kind on the server`).toMatch(
      new RegExp(`\\('${k}',`),
    )
  }
  expect([...ZONE_KINDS].sort()).toEqual(['combat', 'exploration', 'mining', 'pirate'])
})

// ── the verdict ─────────────────────────────────────────────────────────────────────────────────
test('a clean conversion is allowed', () => {
  expect(planKindConversion('pirate', 'mining', [])).toEqual({ kind: 'allowed' })
})

test('a conversion is BLOCKED by an effect the target kind does not permit, and names it', () => {
  const v = planKindConversion('pirate', 'mining', ['pirate_intercept'])
  expect(v).toEqual({ kind: 'blocked', blockingEffects: ['pirate_intercept'] })
})

test('an effect the target DOES permit never blocks', () => {
  expect(planKindConversion('pirate', 'mining', ['mining'])).toEqual({ kind: 'allowed' })
})

test('blocking is reported even when the kind is unchanged — a hidden inconsistency is still one', () => {
  // a zone already 'mining' but still carrying pirate_intercept has a real problem; answering
  // "already that kind" would bury it
  const v = planKindConversion('mining', 'mining', ['pirate_intercept'])
  expect(v).toEqual({ kind: 'blocked', blockingEffects: ['pirate_intercept'] })
})

test('a genuine no-op is typed, not silently allowed', () => {
  expect(planKindConversion('mining', 'mining', ['mining'])).toEqual({ kind: 'already-that-kind' })
})

test('an unrecognised target is typed and short-circuits before any effect reasoning', () => {
  expect(planKindConversion('pirate', 'wormhole', ['pirate_intercept'])).toEqual({
    kind: 'unknown-kind',
  })
  expect(isZoneKind('wormhole')).toBe(false)
  expect(isZoneKind('mining')).toBe(true)
})

test('multiple blockers are all reported, in a stable order', () => {
  const carried: ZoneEffectKind[] = ['pirate_intercept', 'combat'] as ZoneEffectKind[]
  const a = blockingEffectsFor('mining', carried)
  const b = blockingEffectsFor('mining', [...carried].reverse() as ZoneEffectKind[])
  expect(a).toEqual(b) // order of the input must not reshuffle the UI
  expect(a).toHaveLength(2)
})

// ── the message ─────────────────────────────────────────────────────────────────────────────────
test('the explanation says plainly that nothing is removed for you', () => {
  const v = planKindConversion('pirate', 'mining', ['pirate_intercept'])
  const msg = explainKindConversion(v, 'mining', (e) => e)
  expect(msg).toMatch(/not removed for you/)
  expect(msg).toMatch(/pirate_intercept/)
})

test('singular and plural read correctly', () => {
  const one = explainKindConversion(
    { kind: 'blocked', blockingEffects: ['pirate_intercept'] as ZoneEffectKind[] },
    'mining',
    (e) => e,
  )
  const two = explainKindConversion(
    { kind: 'blocked', blockingEffects: ['pirate_intercept', 'combat'] as ZoneEffectKind[] },
    'mining',
    (e) => e,
  )
  expect(one).toMatch(/cannot carry it\b/)
  expect(two).toMatch(/cannot carry them\b/)
})

test('every kind has an owner-facing label with no schema keys in it', () => {
  for (const k of ZONE_KINDS) {
    expect(ZONE_KIND_LABELS[k]).toBeTruthy()
    expect(ZONE_KIND_LABELS[k]).not.toMatch(/_/)
  }
})

// ── structural ──────────────────────────────────────────────────────────────────────────────────
test('the module is PURE and cannot remove anything', () => {
  expect(source).not.toMatch(/\bfrom 'react'|useState|document\.|fetch\(|localStorage|supabase/)
  expect(source).not.toMatch(/delete|remove\w*\(/i.source ? /\bdeleteEffect\b|\bremoveEffect\b/ : /$^/)
  expect(source).toMatch(/never deletes anything/i)
})

test('the effect registry stays 1:1 with the server zone_effect_* tables', () => {
  // "an effect is present iff its row exists" is only true of effects the client knows about — an
  // effect table with no registry entry is invisible to the editor, which is how a zone ends up
  // doing something the owner cannot see or remove.
  const dir = join(repo, 'supabase', 'migrations')
  const files = readdirSync(dir).filter((f) => f.endsWith('.sql'))
  const serverEffects = new Set<string>()
  for (const f of files) {
    const sql = readFileSync(join(dir, f), 'utf8')
    for (const [, name] of sql.matchAll(/create table public\.zone_effect_([a-z_]+)\s*\(/g)) {
      serverEffects.add(name)
    }
  }
  expect(serverEffects.size, 'expected effect tables to exist').toBeGreaterThan(0)
  expect([...serverEffects].sort()).toEqual([...ZONE_EFFECT_KINDS].sort())
})

test('it states that the server is the authority, not this file', () => {
  expect(source).toMatch(/That refusal is the\n\/\/ authority and this module cannot weaken it/)
})
