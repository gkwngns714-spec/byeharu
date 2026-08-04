import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { levelForXp, xpForLevel, XP_LEVEL_BASE } from '../src/features/captains/captainProgress.ts'
import { ADDITIVE_STAT_KEYS } from '../src/features/command/teamSkillset.ts'

// STAT FOUNDATION (0340) — pure structural + curve proofs.
//
// The arithmetic itself is proven against real Postgres twice: by migration 0340's own deploy-time
// self-asserts (synthetic input, non-vacuous on an empty chain) and by the parity/difference
// harness in scripts/stat-foundation-proof.sql (constructed ships, compared against the DEPLOYED
// authority). What is proven HERE is what only a build-time test can see:
//
//   * the registry seeded in SQL and the vocabulary the CLIENT still hard-codes have not drifted —
//     the four TS copies are the thing this architecture exists to delete, and until they are
//     deleted, a silent divergence between them and the registry is the exact failure mode;
//   * the SQL curve and the duplicated CLIENT curve are still the same curve, and the cap lives in
//     exactly ONE place;
//   * the slice really is unused and really is not hidden.
//
// Run: `npx playwright test statFoundation.spec.ts`

const here = dirname(fileURLToPath(import.meta.url))
const repo = join(here, '..')
const migration = readFileSync(
  join(repo, 'supabase', 'migrations', '20260618000340_stats_have_one_authority.sql'),
  'utf8',
)

/** The seeded registry rows, parsed out of the INSERT ... VALUES block. */
interface SeededStat {
  statId: string
  catalogKey: string
  fleetAggregation: string
}

function seededStats(sql: string): SeededStat[] {
  const start = sql.indexOf('insert into public.stat_definitions (')
  expect(start).toBeGreaterThan(-1)
  const end = sql.indexOf('on conflict (stat_id) do nothing;', start)
  expect(end).toBeGreaterThan(start)
  const block = sql.slice(start, end)

  // Each row opens with ('<stat_id>', '<catalog_key>', '<display name>', ...
  const rows = [...block.matchAll(/\n\s{2}\('([a-z_]+)',\s*'([a-z_]+)',/g)]
  return rows.map((m) => {
    const rowStart = m.index ?? 0
    const rowEnd = block.indexOf("\n\n", rowStart)
    const row = block.slice(rowStart, rowEnd === -1 ? block.length : rowEnd)
    const agg = /'(sum|min|max|average|weighted_average|primary_ship|none)', (?:null|'[a-z_]+')(?:, )/.exec(row)
    return {
      statId: m[1],
      catalogKey: m[2],
      fleetAggregation: agg ? agg[1] : '(unparsed)',
    }
  })
}

const stats = seededStats(migration)

test('the seed is exactly the nine deployed stats — no more, no fewer', () => {
  expect(stats.length).toBe(9)
  expect(stats.map((s) => s.statId).sort()).toEqual(
    [
      'cargo_capacity',
      'combat_power',
      'mining_yield',
      'pirate_attention',
      'repair',
      'retreat_safety',
      'scouting',
      'speed',
      'survival',
    ].sort(),
  )
})

test('every OUTPUT key the client still hard-codes has a registry row', () => {
  // ADDITIVE_STAT_KEYS is one of the four hand-written client copies this architecture exists to
  // delete. Until it is deleted it must not drift from the registry. The two slot counters are not
  // stats and are deliberately excluded.
  const clientStatKeys = ADDITIVE_STAT_KEYS.filter(
    (k) => k !== 'captain_slots_used' && k !== 'captain_slots_limit',
  )
  const registered = new Set(stats.map((s) => s.statId))
  for (const key of clientStatKeys) {
    expect(registered, `client key ${key} has no stat_definitions row`).toContain(key)
  }
  // speed is the ninth: it is folded, not summed, so it is not in ADDITIVE_STAT_KEYS.
  expect(registered).toContain('speed')
})

test('every INPUT catalog key the catalogs write has a registry row', () => {
  const catalogKeys = stats.map((s) => s.catalogKey).sort()
  expect(catalogKeys).toEqual(
    [
      'attack',
      'cargo',
      'defense',
      'evasion',
      'mining',
      'pirate_attention',
      'repair',
      'scan',
      'speed_mult_bonus',
    ].sort(),
  )
})

test("the owner's two aggregation corrections are the ones actually seeded", () => {
  const byId = new Map(stats.map((s) => [s.statId, s]))
  expect(byId.get('scouting')?.fleetAggregation).toBe('max')
  expect(byId.get('retreat_safety')?.fleetAggregation).toBe('min')
})

test('fleet travel speed is the MINIMUM, never a sum', () => {
  const speed = stats.find((s) => s.statId === 'speed')
  expect(speed?.fleetAggregation).toBe('min')
  // and the schema makes the mistake unrepresentable, not merely unmade
  expect(migration).toContain('stat_definitions_no_blanket_sum')
  expect(migration).toMatch(/check \(fleet_aggregation <> 'sum' or value_kind = 'flat'\)/)
})

test('cargo is QUARANTINED: no source may contribute and no operation is permitted', () => {
  const start = migration.indexOf("('cargo_capacity', 'cargo'")
  expect(start).toBeGreaterThan(-1)
  const row = migration.slice(start, migration.indexOf("('repair', 'repair'", start))
  // both permitted arrays are empty
  expect(row).toContain('array[]::text[]')
  expect(row).toContain('DEPRECATED display-only legacy')
  // and it declares no engine consumer
  expect(row).not.toMatch(/'combat_create_group_encounter'/)
})

test('the captain cap is 99 and lives in exactly ONE place', () => {
  // the curve seed owns it
  expect(migration).toMatch(
    /values \('captain_v1_quadratic_100', 'quadratic', 100, 99, 'accumulate_xp_no_level', '0340'\)/,
  )
  // NO SCATTERED 99 LITERALS IN CONSUMERS. The resolver bodies must derive the cap from the track's
  // curve (v_cap), never restate it. The self-assert block below them legitimately spells 99 out —
  // that is the check, not a consumer — so the scan stops where the asserts begin.
  const bodiesStart = migration.indexOf('-- ── 5. THE PURE LEAVES')
  const bodiesEnd = migration.indexOf('-- ── 11. SELF-ASSERTS')
  expect(bodiesStart).toBeGreaterThan(-1)
  expect(bodiesEnd).toBeGreaterThan(bodiesStart)
  // Comments are STRIPPED before the scan. Two comments in this region say the words "1..99" and
  // "a consumer never writes 99" — they are documentation of the rule, not violations of it, and
  // failing on prose would be the 0222 vacuity bug wearing the opposite mask (the 0333:1975-1977
  // idiom: strip line comments, then assert on what actually executes).
  const bodies = migration
    .slice(bodiesStart, bodiesEnd)
    .split('\n')
    .map((l) => l.replace(/--.*$/, ''))
    .join('\n')
  expect(bodies).not.toMatch(/\b99\b/)
  // ...and the cap really is applied, from the curve, in the one function that owns levels
  expect(bodies).toContain('if v_cap is not null and v_lvl > v_cap then')
})

test('the SQL curve and the duplicated CLIENT curve are still the same curve', () => {
  // coefficient 100 in SQL, XP_LEVEL_BASE 100 in TS. If either moves, this fails.
  expect(XP_LEVEL_BASE).toBe(100)
  expect(migration).toContain("'captain_v1_quadratic_100', 'quadratic', 100")

  // level L begins at (L-1)^2 * 100 — the shape both sides implement
  for (const level of [1, 2, 3, 4, 10, 50, 99]) {
    expect(xpForLevel(level)).toBe((level - 1) * (level - 1) * 100)
    expect(levelForXp(xpForLevel(level))).toBe(level)
    if (level > 1) expect(levelForXp(xpForLevel(level) - 1)).toBe(level - 1)
  }
  // the exact boundaries the server asserts at deploy
  expect(levelForXp(0)).toBe(1)
  expect(levelForXp(99)).toBe(1)
  expect(levelForXp(100)).toBe(2)
  expect(levelForXp(399)).toBe(2)
  expect(levelForXp(400)).toBe(3)
  expect(levelForXp(900)).toBe(4)
  // level 99 begins at 98^2 * 100
  expect(xpForLevel(99)).toBe(960400)
})

test('the client curve is UNCAPPED — the drift this slice records but does not yet fix', () => {
  // The cap is server-side only, in the track definition. captainProgress.ts has no cap and would
  // happily render level 100. That is a REAL remaining divergence, and it is recorded here so the
  // consumer-cutover slice cannot forget it rather than being papered over.
  expect(levelForXp(960400)).toBe(99)
  expect(levelForXp(99999999)).toBeGreaterThan(99)
  // the migration says so out loud
  expect(migration).toContain('there is no literal 99 in any consumer')
})

test('the slice introduces NO feature flag — the owner ruled darkness pointless', () => {
  expect(migration).not.toMatch(/insert into public\.game_config \(key, value, description\) values\s*\n\s*\('stat_resolver_enabled'/)
  expect(migration).toContain('NO FEATURE FLAG')
  // and it asserts the absence, so a later edit cannot quietly reintroduce one
  expect(migration).toContain("where key = 'stat_resolver_enabled'")
  expect(migration).toContain('this slice introduces NO feature flag')
})

test('the slice is CHECKABLE: an ownership-scoped inspection RPC exists', () => {
  expect(migration).toContain('create function public.get_my_effective_stats(')
  expect(migration).toContain('create function public.get_stat_definitions()')
  expect(migration).toContain('auth.uid()')
  expect(migration).toMatch(/grant execute on function public\.get_my_effective_stats\([^)]*\) to authenticated/)
  // ...but not to anon, and not the raw engine leaves
  expect(migration).not.toMatch(/grant execute on function public\.stat_combine\([^)]*\) to authenticated/)
  expect(migration).not.toMatch(/grant execute on function public\.resolve_effective_stats\([^)]*\) to authenticated/)
})

test('the slice is UNUSED: it re-creates no live engine function', () => {
  for (const live of [
    'calculate_expedition_stats',
    'calculate_group_expedition_stats',
    'combat_create_group_encounter',
    'process_combat_ticks',
    'command_ship_group_go',
    'resolve_fleet_movement_speed',
  ]) {
    expect(
      migration,
      `0340 must not re-create the live function ${live}`,
    ).not.toContain(`create or replace function public.${live}(`)
  }
  // no existing table is altered, no existing row is written
  expect(migration).not.toMatch(/alter table public\.(main_ship_instances|combat_units|combat_encounters|captain_instances)\b(?!.*enable row level security)/)
  expect(migration).not.toMatch(/^update public\./m)
})

test('the resolver graph is acyclic and asserted so at deploy', () => {
  expect(migration).toContain('the resolver graph is cyclic')
  // the buff family must never call the stat resolver
  const buffStart = migration.indexOf('create function public.resolve_active_buffs(')
  const buffEnd = migration.indexOf('-- ── 8. EFFECTIVE-STAT RESOLUTION')
  expect(buffStart).toBeGreaterThan(-1)
  expect(buffEnd).toBeGreaterThan(buffStart)
  expect(migration.slice(buffStart, buffEnd)).not.toContain('resolve_effective_stats(')
})

test('the pure leaves carry no clock and no RNG', () => {
  const start = migration.indexOf('create function public.stat_combine(')
  const end = migration.indexOf('-- ── 6. PROGRESSION RESOLUTION')
  expect(start).toBeGreaterThan(-1)
  expect(end).toBeGreaterThan(start)
  const leaves = migration.slice(start, end)
  expect(leaves).not.toContain('random(')
  expect(leaves).not.toContain('setseed')
  expect(leaves).not.toContain('clock_timestamp')
  expect(leaves).not.toContain('now(')
  // and the migration counts the tokens at deploy rather than trusting a boolean absence test
  expect(migration).toContain("length(replace(v_comb,  'random(', ''))")
})

test('no stored expression: a buff definition can only ever hold a number', () => {
  const start = migration.indexOf('create table public.buff_definitions (')
  const end = migration.indexOf('create table public.buff_instances (')
  const ddl = migration.slice(start, end)
  expect(ddl).toContain('magnitude        numeric not null')
  expect(ddl).toMatch(/operation\s+text not null check \(operation in/)

  // No COLUMN may exist that could hold executable text. Checked against the declared column NAMES,
  // not against the prose — the table comment legitimately uses the words "expression" and "eval"
  // to say that no such column exists, and a substring scan would fail on the very sentence that
  // documents the guarantee.
  const columnLines = ddl
    .split('\n')
    .filter((l) => /^\s{2}[a-z_]+\s+(text|numeric|integer|jsonb|boolean|uuid|timestamptz)/.test(l))
  expect(columnLines.length).toBeGreaterThan(10)
  const columnNames = columnLines.map((l) => l.trim().split(/\s+/)[0])
  for (const forbidden of ['formula', 'expression', 'sql', 'sql_text', 'eval', 'script', 'code']) {
    expect(columnNames, `buff_definitions must have no ${forbidden} column`).not.toContain(forbidden)
  }
  expect(columnNames).toContain('magnitude')
  expect(migration).toContain('scalar-or-array-of-scalars')
})
