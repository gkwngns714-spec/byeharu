import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { levelForXp, xpForLevel, XP_LEVEL_BASE } from '../src/features/captains/captainProgress.ts'
import { ADDITIVE_STAT_KEYS, EFFECTIVE_STAT_KEYS } from '../src/features/command/teamSkillset.ts'
import { DORMANT_STAT_IDS } from '../src/features/stats/statLifecycle.ts'

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
  lifecycle: string
  row: string
}

function seededStats(sql: string): SeededStat[] {
  const start = sql.indexOf('insert into public.stat_definitions (')
  expect(start).toBeGreaterThan(-1)
  const end = sql.indexOf('on conflict (stat_id) do nothing;', start)
  expect(end).toBeGreaterThan(start)
  const block = sql.slice(start, end)

  // Each row opens with ('<stat_id>', '<catalog_key>', '<display name>', ...
  const rows = [...block.matchAll(/\n\s{2}\('([a-z0-9_]+)',\s*'([a-z0-9_]+)',/g)]
  return rows.map((m) => {
    const rowStart = m.index ?? 0
    const rowEnd = block.indexOf('\n\n', rowStart)
    const row = block.slice(rowStart, rowEnd === -1 ? block.length : rowEnd)
    const agg = /'(sum|min|max|average|weighted_average|primary_ship|none)', (?:null|'[a-z_]+')(?:, )/.exec(row)
    const life = /'(active|dormant|deprecated)'/.exec(row)
    return {
      statId: m[1],
      catalogKey: m[2],
      fleetAggregation: agg ? agg[1] : '(unparsed)',
      lifecycle: life ? life[1] : '(unparsed)',
      row,
    }
  })
}

const stats = seededStats(migration)
const byId = new Map(stats.map((s) => [s.statId, s]))

test('the seed is exactly the ten registered stats — no more, no fewer', () => {
  expect(stats.length).toBe(10)
  expect(stats.map((s) => s.statId).sort()).toEqual(
    [
      'cargo_capacity',
      'cargo_volume_m3',
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

// ── LIFECYCLE ───────────────────────────────────────────────────────────────────────────────────

test('every seeded stat declares a lifecycle, and it parses to one of exactly three values', () => {
  for (const s of stats) {
    expect(['active', 'dormant', 'deprecated'], `${s.statId} declares no lifecycle`).toContain(
      s.lifecycle,
    )
  }
})

test('the lifecycle column has NO DEFAULT and a closed CHECK — an undeclared lifecycle fails closed', () => {
  // No default: a row that forgets to state a lifecycle is rejected, never silently promoted.
  expect(migration).toMatch(
    /lifecycle\s+text not null check \(lifecycle in \('active','dormant','deprecated'\)\)/,
  )
  expect(migration).not.toMatch(/lifecycle\s+text not null default/)
  // And the migration EXECUTES both illegal inserts rather than trusting the CHECK exists:
  // an UNKNOWN value, and an OMITTED one (the second is what "no default" actually means, and it
  // is the probe the disposable full-chain apply proved was needed).
  expect(migration).toContain("'experimental'")
  expect(migration).toContain('the lifecycle vocabulary does not fail closed')
  expect(migration).toContain(
    'a stat with NO lifecycle was ACCEPTED — the column has a default it must not have',
  )
  expect(migration).toContain('exception when not_null_violation then null;')
})

test('every fail-closed probe declares a lifecycle, or it fails for the wrong reason', () => {
  // A probe that aborts on a not-null violation instead of the CHECK it names is a probe wearing a
  // passing coat. Each registry probe must state a lifecycle AND an intent superset of what it
  // permits, so only the constraint under test can fire. (Found by the apply proof, not by review.)
  const start = migration.indexOf('__sf_probe_blanket_sum__')
  const end = migration.indexOf('probe row(s) survived')
  expect(start).toBeGreaterThan(-1)
  expect(end).toBeGreaterThan(start)
  const probes = migration.slice(start, end)
  const inserts = (probes.match(/insert into public\.stat_definitions \(/g) ?? []).length
  const lifecycles = (probes.match(/lifecycle, (?:engine_consumer, )?(?:deprecated_reason, )?(?:supersedes_stat_id, )?registered_in\)/g) ?? []).length
  // every probe but the deliberate no-lifecycle one names the column
  expect(inserts).toBeGreaterThanOrEqual(10)
  expect(lifecycles).toBe(inserts - 1)
})

test('active REQUIRES a consumer, dormant FORBIDS one, deprecated may never hold a gameplay one', () => {
  expect(migration).toContain('stat_definitions_active_needs_consumer')
  expect(migration).toContain('stat_definitions_dormant_has_no_consumer')
  expect(migration).toContain('stat_definitions_deprecated_is_legacy_only')
  // exactly three active stats, and they are the three that name a decider
  const active = stats.filter((s) => s.lifecycle === 'active').map((s) => s.statId).sort()
  expect(active).toEqual(['combat_power', 'speed', 'survival'])
})

test('the five confirmed-dead outputs are seeded DORMANT, not as active gameplay stats', () => {
  for (const dead of ['retreat_safety', 'scouting', 'mining_yield', 'repair', 'pirate_attention']) {
    expect(byId.get(dead)?.lifecycle, `${dead} must be dormant`).toBe('dormant')
  }
})

test('a DORMANT stat is not computed on the routine path — it is absent from the routine snapshot', () => {
  // The routine snapshot is the ONE place the vocabulary is decided, and the rule lives in ONE
  // function. Dormant is excluded from 'routine' and included only in 'inspection'.
  expect(migration).toMatch(
    /when p_scope = 'routine'\s+then p_lifecycle in \('active','deprecated'\)/,
  )
  expect(migration).toMatch(
    /when p_scope = 'inspection' then p_lifecycle in \('active','dormant','deprecated'\)/,
  )
  // The resolver defaults to routine, so a caller that says nothing gets no dormant stat.
  expect(migration).toMatch(/p_lifecycle_scope text\s+default 'routine'/)
  // The gatherers filter on the SNAPSHOT, never on a second lifecycle predicate over the table —
  // two predicates answering one question is how a dormant stat gets gathered by a forgotten path.
  expect(migration).not.toMatch(/where d\.is_active/)
  expect(migration).not.toMatch(/and d\.is_active/)
  const gathererFilters = migration.match(/\(v_reg -> 'stats'\) \? d\.stat_id/g) ?? []
  expect(gathererFilters.length).toBeGreaterThanOrEqual(4) // hull, trait, module, captain
  // and the migration PROVES it at deploy rather than describing it
  expect(migration).toContain('a DORMANT stat is present in the ROUTINE registry snapshot')
  expect(migration).toContain('a contribution to a DORMANT stat was accepted on the routine path')
})

test('a dormant value never reaches `stats`, and is marked effective=false when inspected', () => {
  expect(migration).toMatch(/if \(v_def ->> 'lifecycle'\) = 'dormant' then/)
  expect(migration).toContain("'effective', false")
  expect(migration).toContain('a dormant stat reached `stats` under inspection')
})

test('the client lifecycle answer IS the migration seed — there is no second list to drift', () => {
  // The client used to carry DORMANT_STAT_KEYS, a hand-written mirror of this seed. It is gone:
  // DORMANT_STAT_IDS is DERIVED from the generated projection of this very INSERT, so the two
  // cannot disagree — and the assertion below is the proof that the derivation is faithful.
  const seededDormant = stats
    .filter((s) => s.lifecycle === 'dormant')
    .map((s) => s.statId)
    .sort()
  expect([...DORMANT_STAT_IDS].sort()).toEqual(seededDormant)
  // cargo_volume_m3 is a dormant CANONICAL TARGET the legacy fold never emits, so it is absent from
  // the client's per-member envelope — but it is still, correctly, a dormant registry row.
  expect(DORMANT_STAT_IDS).toContain('cargo_volume_m3')
  expect(ADDITIVE_STAT_KEYS as readonly string[]).not.toContain('cargo_volume_m3')
  // and no dormant stat is rendered as an effective total
  for (const k of DORMANT_STAT_IDS) {
    expect(EFFECTIVE_STAT_KEYS as readonly string[], `${k} is still rendered as an effective total`).not.toContain(k)
  }
  // ...while the effective list is still a subset of what the server actually sends
  for (const k of EFFECTIVE_STAT_KEYS) {
    expect(ADDITIVE_STAT_KEYS as readonly string[]).toContain(k)
  }
})

test('pirate_attention stays dormant DESPITE 0331 widening it across four catalog surfaces', () => {
  expect(byId.get('pirate_attention')?.lifecycle).toBe('dormant')
  // the four surfaces are documented at the point of the decision, with their line numbers
  const row = byId.get('pirate_attention')?.row ?? ''
  const context = migration.slice(Math.max(0, migration.indexOf(row) - 2000), migration.indexOf(row) + row.length)
  expect(context).toContain('20260618000331')
  expect(context).toContain(':471-475') // ship traits
  expect(context).toContain(':493-496') // command buffs
  expect(context).toContain(':500-508') // modules
  expect(context).toContain(':511-519') // captains
})

test('every OUTPUT key the client folds has a registry row', () => {
  // ADDITIVE_STAT_KEYS was one of the four hand-written client copies this architecture exists to
  // delete. It is now DERIVED from the registry; this keeps proving the invariant that made it
  // dangerous. The two slot counters are not stats and are deliberately excluded.
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
      'cargo_volume_m3',
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

test("the owner's two aggregation corrections are still the ones seeded, dormant or not", () => {
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

// ── CARGO, AFTER THE OWNER'S RE-RULING ──────────────────────────────────────────────────────────

test('the legacy cargo integer is DEPRECATED and non-authoritative, never a second gameplay stat', () => {
  const row = byId.get('cargo_capacity')?.row ?? ''
  expect(row).not.toBe('')
  expect(byId.get('cargo_capacity')?.lifecycle).toBe('deprecated')
  // both permitted arrays are empty
  expect(row).toContain('array[]::text[]')
  expect(row).toContain('DEPRECATED legacy display integer')
  // and it declares no engine consumer — the table forbids one on a deprecated row
  expect(row).not.toMatch(/'combat_create_group_encounter'/)
  expect(migration).toMatch(
    /check \(lifecycle <> 'deprecated'\s*\n\s*or \(deprecated_reason is not null and engine_consumer is null\)\)/,
  )
})

test('the canonical cargo target is ship-bound VOLUME in m3, modelled with provenance', () => {
  const row = byId.get('cargo_volume_m3')?.row ?? ''
  expect(row).not.toBe('')
  expect(row).toContain("'m3'")
  // it names what it supersedes — that is the provenance
  expect(row).toContain("'cargo_capacity'")
  // its base is the ship's REAL volume column, not a converted integer
  expect(row).toContain("'instance_column', 'cargo_capacity_m3'")
  expect(byId.get('cargo_volume_m3')?.lifecycle).toBe('dormant')
})

test('the cargo unit conversion is NOT ACTIVATED, and the table is what makes that so', () => {
  // unit_conversion is a CLOSED enum, so an undefined conversion cannot be faked with prose
  expect(migration).toMatch(/unit_conversion\s+text check \(unit_conversion in \('identity'\)\)/)
  // ...and while it is NULL the superseding stat may accept NOTHING. This is the 0333:1926-1929
  // precedent (enforce, never comment) expressed as a constraint instead of a text scan.
  expect(migration).toContain('stat_definitions_undefined_conversion_accepts_nothing')
  expect(migration).toMatch(
    /check \(supersedes_stat_id is null or unit_conversion is not null\s*\n\s*or \(permitted_operations = '\{\}'::text\[\] and permitted_source_kinds = '\{\}'::text\[\]\)\)/,
  )
  // the migration EXECUTES the illegal insert rather than trusting the constraint
  expect(migration).toContain(
    'a superseding stat with an UNDEFINED unit conversion ACCEPTED a module contribution',
  )
  // NO +25 IS COPIED: the volume stat's permitted lists are empty in the seed itself
  const row = byId.get('cargo_volume_m3')?.row ?? ''
  const permittedEmpty = (row.match(/array\[\]::text\[\]/g) ?? []).length
  expect(permittedEmpty).toBe(2) // permitted_operations AND permitted_source_kinds
  // ...while the INTENT is recorded, because modules/captains/traits ARE meant to affect volume
  expect(row).toContain("array['hull','trait','module','captain']::text[]")
  expect(migration).toContain('stat_definitions_permitted_within_intended')
})

test('the two cargo representations can never share a catalog key', () => {
  expect(byId.get('cargo_capacity')?.catalogKey).toBe('cargo')
  expect(byId.get('cargo_volume_m3')?.catalogKey).toBe('cargo_volume_m3')
  expect(byId.get('cargo_capacity')?.catalogKey).not.toBe(byId.get('cargo_volume_m3')?.catalogKey)
  expect(migration).toContain('the m3 authority and the legacy integer share a catalog key')
})

test('this slice changes NO live hold size', () => {
  // The volume authority and its columns are 0333/0076's; 0340 must not write either.
  expect(migration).not.toMatch(/update public\.main_ship_instances/)
  // it never CALLS or re-creates the 0333 volume authority (a prose mention of it is fine)
  expect(migration).not.toMatch(/public\.fleet_hold_capacity_m3\(/)
  expect(migration).not.toMatch(/public\.fleet_hold_used_m3\(/)
  expect(migration).not.toMatch(/create (or replace )?function public\.fleet_hold/)
})

// ── THREE-WAY PROVENANCE ────────────────────────────────────────────────────────────────────────

test('a real zero, a resolution failure and a not-applicable are three different shapes', () => {
  // Four disjoint maps, indexed by one provenance object. The law is a FUNCTION that raises, so a
  // collapsed result cannot be ignored by not reading a boolean.
  expect(migration).toContain('create function public.stat_assert_provenance_partition')
  expect(migration).toContain('appears in more than one provenance map')
  expect(migration).toContain('has a provenance status but appears in no map')
  // a real zero is a RESOLVED value and says so
  expect(migration).toContain("'is_real_zero', (v_running = 0)")
  // ...and the migration executes all three in one place
  expect(migration).toContain('a real zero is not recorded as a RESOLVED value')
  expect(migration).toContain('a not-applicable stat leaked a value')
  expect(migration).toContain('a member resolution failure did not become an UNRESOLVED stat')
})

test('a member whose own resolution failed can never be silently dropped from a fleet fold', () => {
  // Dropping the member is how a min becomes too high and a sum too low — a confident wrong answer.
  expect(migration).toContain("v_status not in ('resolved','unresolved')")
  expect(migration).toContain('member_resolution_failed')
  expect(migration).toContain('a member with no status was treated as resolved')
  // and an unresolved stat may never hold a number
  expect(migration).toContain('must never be expressible as a value')
})

// ── THE AMBUSH IMPOSSIBILITY PIN ────────────────────────────────────────────────────────────────

test('a stat-resolution failure cannot become a numeric risk value', () => {
  // ONE numeric extractor, and it refuses every non-ok envelope. There is no second door, so there
  // is no path from "we could not read the stats" to a number the risk formula would accept.
  expect(migration).toContain('create function public.stat_required_sum')
  expect(migration).toContain('refusing to produce a number from a failed stat resolution')
  // the refusal carries no values object at all — nothing to read optimistically
  expect(migration).toContain(
    'a REFUSAL carried a values object — there must be nothing to read optimistically',
  )
  // ...and it is EXECUTED against all three failure shapes at deploy
  expect(migration).toContain('this is exactly the 0301:545-547 fail-open defect')
  expect(migration).toContain('an empty fleet produced the numeric risk input')
  expect(migration).toContain('an envelope claiming ok with no values produced')
  expect(migration).toContain('an envelope whose values is a NUMBER produced')
  expect(migration).toContain('an EMPTY values object produced')
  // ...and the guard is NULL-safe: jsonb_typeof(NULL) is NULL, and a three-valued comparison used
  // as a two-valued guard is how a fail-closed check quietly stops being one.
  expect(migration).toMatch(
    /coalesce\(jsonb_typeof\(p_envelope -> 'values'\), 'absent'\) <> 'object'/,
  )
  // a genuinely weak fleet still resolves — to a REAL zero. That is the distinction the live
  // consumer cannot make.
  expect(migration).toContain('a genuinely weak (real zero) fleet was not resolvable to 0')
})

test('the live ambush consumer is designed against, NOT repaired — and that is pinned', () => {
  // Repairing pirate_intercept_plan_leg is the bounded consumer-retirement sequence, not this
  // slice. The fail-open handler must still be exactly where it was.
  expect(migration).toContain(
    'the 0301:545-547 fail-open handler is gone — repairing the live ambush consumer is OUT OF SCOPE',
  )
  expect(migration).toContain(
    'pirate_intercept_plan_leg carries a 0340 token — the consumer cutover is a separate, bounded sequence',
  )
  // the replacement contract is stated in full: no max risk, no min risk, no roll, no mutation
  expect(migration).toContain(
    'reject or defer at the nearest atomic boundary, preserve prior valid state, do not roll, do not mutate movement or intercept state',
  )
})

test('the ambush contract states the ACTUAL atomic boundaries, by name and line', () => {
  expect(migration).toContain('20260618000330_the_mover_is_in_the_repo.sql:226')
  expect(migration).toContain('process_pirate_route_legs (0301:2376)')
  // and it refuses the deployed route-deletion behaviour explicitly
  expect(migration).toContain("DO NOT delete the fleet's remaining route")
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
