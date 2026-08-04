import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  generateStatRegistryModule,
  parseStatDefinitionSeed,
  STAT_REGISTRY_SOURCE_MIGRATION,
} from '../scripts/generateStatRegistry.ts'
import { STAT_DEFINITION_ROWS } from '../src/features/stats/statRegistry.generated.ts'

// THE PROJECTION IS THE MIGRATION — proof that the client's stat metadata has exactly ONE authority.
//
// The owner's ruling forbids a second list: "Presentation must read lifecycle from the canonical
// stat metadata introduced by 0340, or from a generated/typed projection whose sole authority is
// that metadata." This spec is what makes "sole authority" true rather than claimed: it re-derives
// the committed projection from the migration text and byte-compares. Edit either side alone and
// this goes red.
//
// Run: `npx playwright test statRegistryProjection.spec.ts`

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
// These sources are stored LF and checked out CRLF on Windows; a byte-compare that ignores that
// passes in CI and fails on the owner's machine, which is the worst kind of green.
const lf = (s: string) => s.replace(/\r\n/g, '\n')

const migration = lf(
  readFileSync(join(repo, 'supabase', 'migrations', STAT_REGISTRY_SOURCE_MIGRATION), 'utf8'),
)
const committed = lf(
  readFileSync(join(repo, 'src', 'features', 'stats', 'statRegistry.generated.ts'), 'utf8'),
)

test('the committed projection is byte-for-byte what the 0340 seed generates', () => {
  expect(lf(generateStatRegistryModule(migration))).toBe(committed)
})

test('the projection carries every seeded stat, and nothing it invented', () => {
  const seeded = parseStatDefinitionSeed(migration)
  expect(STAT_DEFINITION_ROWS.length).toBe(seeded.length)
  expect(STAT_DEFINITION_ROWS.length).toBe(10)
  expect(STAT_DEFINITION_ROWS.map((r) => r.statId)).toEqual(seeded.map((s) => s.statId))
  for (const row of STAT_DEFINITION_ROWS) {
    const src = seeded.find((s) => s.statId === row.statId)
    expect(src, `${row.statId} is in the projection but not in the seed`).toBeTruthy()
    expect(row.lifecycle).toBe(src?.lifecycle)
    expect(row.catalogKey).toBe(src?.catalogKey)
    expect(row.displayName).toBe(src?.displayName)
    expect(row.displayOrder).toBe(src?.displayOrder)
  }
})

test('the projection agrees with what production actually serves', () => {
  // Read off the live stat_definitions table with the anon key on 2026-08-04 (the table is
  // client-readable — HTTP 200; the get_stat_definitions RPC is NOT, it answers 42501). Pinned here
  // so a projection that parses cleanly but says something production does not is still a failure.
  const observed: Record<string, string> = {
    combat_power: 'active',
    survival: 'active',
    speed: 'active',
    cargo_capacity: 'deprecated',
    cargo_volume_m3: 'dormant',
    repair: 'dormant',
    scouting: 'dormant',
    mining_yield: 'dormant',
    retreat_safety: 'dormant',
    pirate_attention: 'dormant',
  }
  for (const [statId, lifecycle] of Object.entries(observed)) {
    const row = STAT_DEFINITION_ROWS.find((r) => r.statId === statId)
    expect(row, `${statId} is served by production but absent from the projection`).toBeTruthy()
    expect(row?.lifecycle, `${statId} lifecycle disagrees with production`).toBe(lifecycle)
  }
  expect(STAT_DEFINITION_ROWS.map((r) => r.statId).sort()).toEqual(Object.keys(observed).sort())
})

test('the generated file says it is generated, and names its one source', () => {
  expect(committed).toContain('GENERATED FILE — DO NOT EDIT BY HAND')
  expect(committed).toContain(STAT_REGISTRY_SOURCE_MIGRATION)
})

test('the parser FAILS LOUD rather than projecting a half-registry', () => {
  // A text parser that silently matches nothing is how a client ends up believing every stat is
  // unknown — or worse, believing an unparsed lifecycle is fine.
  expect(() => parseStatDefinitionSeed('-- nothing here')).toThrow(/seed not found/)
  const truncated = migration.slice(0, migration.indexOf('insert into public.stat_definitions (') + 40)
  expect(() => parseStatDefinitionSeed(truncated)).toThrow()
})

test('a seed row with an unparseable lifecycle is refused, never defaulted', () => {
  // Swap the lifecycle literal for an expression the projection cannot read. The generator must
  // throw rather than emit a row whose lifecycle it guessed.
  const broken = migration.replace("null, null, null, 'dormant', null, null, '0340')", 'null, null, null, coalesce(x), null, null, %L)')
  expect(broken).not.toBe(migration)
  expect(() => parseStatDefinitionSeed(broken)).toThrow()
})
