// STAT REGISTRY PROJECTION — the generator.
//
// WHY THIS EXISTS (the owner's ruling, 2026-08-04):
//   "Do not fix this by adding another hardcoded list of dead stat identifiers. Presentation must
//    read lifecycle from the canonical stat metadata introduced by 0340, or from a generated/typed
//    projection whose sole authority is that metadata. The frontend must not independently maintain
//    a conflicting active-stat allowlist."
//
// stat_definitions is Reference/Config (docs/SYSTEM_BOUNDARIES.md:27) — migration-seeded only, NO
// runtime writer, ever (0340:133-135). So a BUILD-TIME projection of the seed is exactly as
// authoritative as a runtime read of the table, and it cannot fail open on a bad network read.
//
// WHY NOT THE RPC: get_stat_definitions() exists but is REVOKED from every client role — probed
// against production on 2026-08-04 with the anon key, it answers HTTP 401 / SQLSTATE 42501
// ("permission denied for function get_stat_definitions"). The TABLE is the client's access path
// (0340:314-316 grants exactly select to anon + authenticated), and this file projects the seed that
// fills it. tests/statRegistryProjection.spec.ts re-derives the projection from the migration and
// byte-compares it against the committed file, so the file can never drift from its one authority.
//
// PURE: no I/O, no node globals. The spec feeds it the migration text and compares the result.

/** The ONE migration this projection is allowed to come from. */
export const STAT_REGISTRY_SOURCE_MIGRATION = '20260618000340_stats_have_one_authority.sql'

/** One seeded stat_definitions row, as far as PRESENTATION needs it. The engine-facing columns
 *  (permitted_operations, permitted_source_kinds, clamps, snapshot policy…) are deliberately NOT
 *  projected: nothing on the client may decide with them, and projecting them would invite it. */
export interface SeededStatDefinition {
  readonly statId: string
  readonly catalogKey: string
  readonly displayName: string
  readonly displayOrder: number
  readonly lifecycle: string
  readonly valueKind: string
  readonly combinationClass: string
  readonly fleetAggregation: string
  readonly unit: string
  readonly supersedesStatId: string | null
  readonly engineConsumer: string | null
  readonly presentationConsumer: string | null
  readonly deprecatedReason: string | null
}

const SEED_START = 'insert into public.stat_definitions ('
const SEED_END = 'on conflict (stat_id) do nothing;'

/** The columns this projection carries, mapped from their SQL names. Anything not listed is
 *  dropped on purpose (see the interface comment). */
const PROJECTED: Record<string, keyof SeededStatDefinition> = {
  stat_id: 'statId',
  catalog_key: 'catalogKey',
  display_name: 'displayName',
  display_order: 'displayOrder',
  lifecycle: 'lifecycle',
  value_kind: 'valueKind',
  combination_class: 'combinationClass',
  fleet_aggregation: 'fleetAggregation',
  unit: 'unit',
  supersedes_stat_id: 'supersedesStatId',
  engine_consumer: 'engineConsumer',
  presentation_consumer: 'presentationConsumer',
  deprecated_reason: 'deprecatedReason',
}

/** Split the VALUES region into tuples of raw field text. Handles what the seed actually contains:
 *  `--` line comments, single-quoted literals with '' escapes, `array[...]::text[]` (whose commas
 *  are NOT field separators) and nested parentheses inside prose. */
function splitTuples(region: string): string[][] {
  const tuples: string[][] = []
  let cur: string[] | null = null
  let field = ''
  let depth = 0
  let bracket = 0
  let i = 0
  while (i < region.length) {
    const c = region[i]
    if (c === '-' && region[i + 1] === '-') {
      while (i < region.length && region[i] !== '\n') i += 1
      continue
    }
    if (c === "'") {
      let j = i + 1
      let lit = "'"
      while (j < region.length) {
        if (region[j] === "'") {
          if (region[j + 1] === "'") {
            lit += "''"
            j += 2
            continue
          }
          lit += "'"
          j += 1
          break
        }
        lit += region[j]
        j += 1
      }
      if (cur !== null) field += lit
      i = j
      continue
    }
    if (cur === null) {
      if (c === '(') {
        cur = []
        field = ''
        depth = 1
        bracket = 0
      }
      i += 1
      continue
    }
    if (c === '(') depth += 1
    else if (c === ')') {
      depth -= 1
      if (depth === 0) {
        cur.push(field.trim())
        tuples.push(cur)
        cur = null
        field = ''
        i += 1
        continue
      }
    } else if (c === '[') bracket += 1
    else if (c === ']') bracket -= 1
    else if (c === ',' && depth === 1 && bracket === 0) {
      cur.push(field.trim())
      field = ''
      i += 1
      continue
    }
    field += c
    i += 1
  }
  return tuples
}

const STRING_ONLY = /^(?:'(?:[^']|'')*'\s*)+$/

/** A field's value when it is a plain SQL scalar. Adjacent string literals concatenate, which is
 *  how the seed spells cargo_capacity's multi-line deprecation reason. Anything else (an array
 *  constructor, a cast) returns undefined — this projection never carries those. */
function parseScalar(field: string): string | number | null | undefined {
  const t = field.trim()
  if (/^null$/i.test(t)) return null
  if (STRING_ONLY.test(t)) {
    let out = ''
    const re = /'((?:[^']|'')*)'/g
    let m: RegExpExecArray | null
    while ((m = re.exec(t)) !== null) out += m[1].replace(/''/g, "'")
    return out
  }
  if (/^-?\d+(?:\.\d+)?$/.test(t)) return Number(t)
  return undefined
}

/** Parse the 0340 stat_definitions seed. Throws — loudly and early — on anything it does not
 *  recognise, because a silently mis-parsed lifecycle is the exact failure this file prevents. */
export function parseStatDefinitionSeed(sql: string): SeededStatDefinition[] {
  const start = sql.indexOf(SEED_START)
  if (start < 0) throw new Error('stat_definitions seed not found in the migration')
  const colsEnd = sql.indexOf(') values', start)
  if (colsEnd < 0) throw new Error('stat_definitions seed has no `) values` header')
  const end = sql.indexOf(SEED_END, colsEnd)
  if (end < 0) throw new Error('stat_definitions seed has no `on conflict` terminator')

  const columns = sql
    .slice(start + SEED_START.length, colsEnd)
    .split(',')
    .map((c) => c.replace(/--.*$/gm, '').trim())
    .filter((c) => c.length > 0)

  const rows = splitTuples(sql.slice(colsEnd + ') values'.length, end)).map((fields) => {
    if (fields.length !== columns.length) {
      throw new Error(
        `stat_definitions seed row has ${fields.length} fields for ${columns.length} columns`,
      )
    }
    const out: Record<string, string | number | null> = {}
    for (let i = 0; i < columns.length; i += 1) {
      const key = PROJECTED[columns[i]]
      if (key === undefined) continue
      const value = parseScalar(fields[i])
      if (value === undefined) {
        throw new Error(`stat_definitions column ${columns[i]} is not a plain scalar: ${fields[i]}`)
      }
      out[key] = value
    }
    for (const key of Object.values(PROJECTED)) {
      if (!(key in out)) throw new Error(`stat_definitions seed is missing column ${key}`)
    }
    return out as unknown as SeededStatDefinition
  })

  // FAIL LOUD, NOT OPEN. The parse is a text parse; if it ever silently matched half a file the
  // client would present a half-registry as the whole truth.
  if (rows.length === 0) throw new Error('stat_definitions seed parsed to zero rows')
  for (const r of rows) {
    if (typeof r.statId !== 'string' || r.statId.length === 0) {
      throw new Error('stat_definitions seed row has no stat_id')
    }
    if (typeof r.lifecycle !== 'string' || r.lifecycle.length === 0) {
      throw new Error(`stat_definitions row ${r.statId} has no lifecycle`)
    }
    if (typeof r.displayOrder !== 'number') {
      throw new Error(`stat_definitions row ${r.statId} has no numeric display_order`)
    }
  }
  return rows.sort((a, b) => a.displayOrder - b.displayOrder)
}

const q = (v: string | null): string => (v === null ? 'null' : JSON.stringify(v))

/** Render the committed projection module. Byte-compared by tests/statRegistryProjection.spec.ts. */
export function generateStatRegistryModule(sql: string): string {
  const rows = parseStatDefinitionSeed(sql)
  const body = rows
    .map(
      (r) =>
        `  {\n` +
        `    statId: ${q(r.statId)},\n` +
        `    catalogKey: ${q(r.catalogKey)},\n` +
        `    displayName: ${q(r.displayName)},\n` +
        `    displayOrder: ${r.displayOrder},\n` +
        `    lifecycle: ${q(r.lifecycle)},\n` +
        `    valueKind: ${q(r.valueKind)},\n` +
        `    combinationClass: ${q(r.combinationClass)},\n` +
        `    fleetAggregation: ${q(r.fleetAggregation)},\n` +
        `    unit: ${q(r.unit)},\n` +
        `    supersedesStatId: ${q(r.supersedesStatId)},\n` +
        `    engineConsumer: ${q(r.engineConsumer)},\n` +
        `    presentationConsumer: ${q(r.presentationConsumer)},\n` +
        `    deprecatedReason: ${q(r.deprecatedReason)},\n` +
        `  },`,
    )
    .join('\n')

  return `// GENERATED FILE — DO NOT EDIT BY HAND.
//
// THE ONE CLIENT PROJECTION of public.stat_definitions, generated from the seed in
// supabase/migrations/${STAT_REGISTRY_SOURCE_MIGRATION}.
//
// Regenerate by re-running tests/statRegistryProjection.spec.ts: it re-derives this file from the
// migration and byte-compares, so the migration is this file's SOLE authority and drift is a red
// test rather than a wrong number on a player's screen.
//
// Editing this file by hand would recreate exactly what migration 0340 exists to delete: a second
// place that decides whether a stat is in play.

/** One projected stat_definitions row.
 *
 *  \`lifecycle\` is DELIBERATELY typed \`string\`, not the three-value union. The union lives in
 *  statLifecycle.ts, behind a mapping that FAILS CLOSED — an unknown lifecycle must be unrepresentable
 *  as an effective player benefit, and typing this field as the union would let the compiler assume
 *  a value the database is the only authority on. */
export interface StatDefinitionRow {
  readonly statId: string
  readonly catalogKey: string
  readonly displayName: string
  readonly displayOrder: number
  readonly lifecycle: string
  readonly valueKind: string
  readonly combinationClass: string
  readonly fleetAggregation: string
  readonly unit: string
  readonly supersedesStatId: string | null
  readonly engineConsumer: string | null
  readonly presentationConsumer: string | null
  readonly deprecatedReason: string | null
}

/** The migration that owns every row below. */
export const STAT_REGISTRY_SOURCE_MIGRATION = '${STAT_REGISTRY_SOURCE_MIGRATION}'

/** The seeded registry, in display_order. */
export const STAT_DEFINITION_ROWS: readonly StatDefinitionRow[] = [
${body}
]
`
}
