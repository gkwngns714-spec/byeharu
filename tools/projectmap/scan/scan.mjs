#!/usr/bin/env node
// Byeharu Project Map — repo scanner.
//
// Reads the repo (migrations + docs) and emits a graph of what exists and what
// connects to what. Pure derivation: every node and edge traces to a file on
// disk. Nothing here is hand-authored opinion, and nothing here knows about
// production — live truth is a separate overlay (see scan/live.mjs).
//
//   node tools/projectmap/scan/scan.mjs
//   -> tools/projectmap/public/graph.json

import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = join(HERE, '..', '..', '..')
const MIGRATIONS = join(REPO, 'supabase', 'migrations')
const DOCS = join(REPO, 'docs')
const OUT = join(HERE, '..', 'public', 'graph.json')

// SQL keywords that regexes can otherwise mistake for identifiers.
const NOISE = new Set([
  'if', 'not', 'exists', 'only', 'public', 'table', 'function', 'trigger', 'index',
  'policy', 'from', 'into', 'select', 'update', 'insert', 'delete', 'values', 'set',
  'where', 'and', 'or', 'on', 'as', 'is', 'null', 'true', 'false', 'return', 'returns',
  'begin', 'end', 'declare', 'then', 'else', 'when', 'case', 'loop', 'for', 'in',
  'create', 'replace', 'alter', 'drop', 'add', 'column', 'constraint', 'check',
])

const strip = (s) => s.replace(/^public\./i, '').toLowerCase()

/** Remove comments and string literals so they can't produce phantom references. */
function sqlBody(src) {
  return src
    .replace(/--[^\n]*/g, ' ')
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/'(?:[^']|'')*'/g, "''")
}

function matchAll(re, s, group = 1) {
  const out = []
  for (const m of s.matchAll(re)) if (m[group]) out.push(strip(m[group]))
  return out
}

// ── real build chronology ─────────────────────────────────────────────────────
// The filename stamps are synthetic — all 205 sit inside two fabricated days, so
// they order the chain but say nothing about when we actually built anything.
// Git knows the truth: the commit that first added each file.
// execFileSync, not execSync: on Windows execSync goes through cmd.exe, where `^`
// is the escape character and would silently eat a format marker.
function gitAddDates() {
  const dates = new Map()
  try {
    const out = execFileSync('git', [
      'log', '--diff-filter=A', '--format=@@%aI', '--name-only', '--reverse', '--', 'supabase/migrations',
    ], { cwd: REPO, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 * 1024 * 1024 })
    let when = null
    for (const line of out.split('\n')) {
      const t = line.trim()
      if (t.startsWith('@@')) { when = t.slice(2); continue }
      const m = t.match(/supabase\/migrations\/(.+\.sql)$/)
      if (m && when && !dates.has(m[1])) dates.set(m[1], when)
    }
  } catch (err) {
    console.error(`! git history unavailable (${err.message?.split('\n')[0]}) — build-order view degrades to file order`)
  }
  return dates
}
const addDates = gitAddDates()
if (!addDates.size) console.error('! no git add-dates resolved — the build-order tree will bucket everything as uncommitted')

// ── read migrations ───────────────────────────────────────────────────────────
const files = readdirSync(MIGRATIONS).filter((f) => f.endsWith('.sql')).sort()

const migrations = files.map((file) => {
  const raw = readFileSync(join(MIGRATIONS, file), 'utf8')
  const body = sqlBody(raw)

  // 20260618000205_cmdbuff_command_buffs.sql -> stamp 20260618000205, seq 0205
  const stamp = file.match(/^(\d+)_/)?.[1] ?? file
  const slug = file.replace(/^\d+_/, '').replace(/\.sql$/, '')

  // The header comment is the migration's own description of itself.
  const header = raw.split('\n').filter((l) => l.startsWith('--')).slice(0, 6)
    .map((l) => l.replace(/^--\s?/, '').trim()).filter(Boolean).join(' ')
  const seq = header.match(/Migration\s+(\d{3,4})/i)?.[1] ?? null

  const createsFn = [...new Set(matchAll(/create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?([a-z_][a-z0-9_]*)/gi, body))]
  const createsTable = [...new Set(matchAll(/create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?([a-z_][a-z0-9_]*)/gi, body))]
  const altersTable = [...new Set(matchAll(/alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?(?:public\.)?([a-z_][a-z0-9_]*)/gi, body))]
  const dropsFn = [...new Set(matchAll(/drop\s+function\s+(?:if\s+exists\s+)?(?:public\.)?([a-z_][a-z0-9_]*)/gi, body))]
  const createsTrigger = [...new Set(matchAll(/create\s+(?:or\s+replace\s+)?trigger\s+([a-z_][a-z0-9_]*)/gi, body))]
  const createsType = [...new Set(matchAll(/create\s+type\s+(?:public\.)?([a-z_][a-z0-9_]*)/gi, body))]

  // A flag only counts as REAL if a migration seeds it as a game_config row.
  // Strings merely mentioned in prose are not flags (e.g. shield_enabled).
  const seedsFlag = [...new Set(
    [...raw.matchAll(/insert\s+into\s+(?:public\.)?game_config[\s\S]{0,400}?/gi)]
      .flatMap((m) => {
        const tail = raw.slice(m.index, m.index + 600)
        return [...tail.matchAll(/\(\s*'([a-z_0-9]+)'\s*,/g)].map((x) => x[1])
      })
  )]

  // Flags this migration READS (gates behaviour on).
  const readsFlag = [...new Set([
    ...matchAll(/cfg_bool\s*\(\s*'([a-z_0-9]+)'/gi, raw),
    ...matchAll(/config_flag\s*\(\s*'([a-z_0-9]+)'/gi, raw),
    ...matchAll(/game_config[\s\S]{0,80}?key\s*=\s*'([a-z_0-9]+_enabled)'/gi, raw),
  ])]

  return {
    file, stamp, slug, seq, header: header.slice(0, 400),
    createsFn, createsTable, altersTable, dropsFn, createsTrigger, createsType,
    seedsFlag, readsFlag, body, raw,
  }
})

// ── derive the symbol universe ────────────────────────────────────────────────
const allFns = [...new Set(migrations.flatMap((m) => m.createsFn))]
const allTables = [...new Set(migrations.flatMap((m) => m.createsTable))]
const allFlags = [...new Set(migrations.flatMap((m) => m.seedsFlag))].filter((f) => /_enabled$/.test(f))

const fnSet = new Set(allFns)
const tableSet = new Set(allTables)

// ── system ownership, parsed from the sole-writer matrix in SYSTEM_BOUNDARIES ──
// The doc is the project's own law of separation; we read it rather than invent it.
const ownership = new Map() // table -> system
let boundariesFound = false
const bPath = join(DOCS, 'SYSTEM_BOUNDARIES.md')
if (existsSync(bPath)) {
  const md = readFileSync(bPath, 'utf8')
  for (const line of md.split('\n')) {
    if (!line.startsWith('|')) continue
    const cells = line.split('|').map((c) => c.trim())
    if (cells.length < 3) continue
    const tablesCell = cells[1]
    const ownerCell = cells[2]
    const owner = ownerCell.match(/\*\*([^*]+)\*\*/)?.[1]?.trim()
    if (!owner) continue
    const tables = [...tablesCell.matchAll(/`([a-z_0-9]+)`/g)].map((m) => m[1])
    if (!tables.length) continue
    boundariesFound = true
    for (const t of tables) ownership.set(t, owner)
  }
}

// ── nodes ─────────────────────────────────────────────────────────────────────
const nodes = []
const push = (n) => { nodes.push(n); return n.id }

for (const m of migrations) {
  push({
    id: `mig:${m.stamp}`,
    kind: 'migration',
    label: m.seq ? `${m.seq} ${m.slug.replace(/^\d+_/, '')}` : m.slug,
    stamp: m.stamp,
    seq: m.seq,
    // when it was really written, per git — null if never committed
    addedAt: addDates.get(m.file) ?? null,
    file: `supabase/migrations/${m.file}`,
    detail: m.header,
    seedsFlag: m.seedsFlag.filter((f) => /_enabled$/.test(f)),
  })
}
for (const f of allFns) {
  push({ id: `fn:${f}`, kind: 'function', label: f, detail: 'Postgres function' })
}
for (const t of allTables) {
  push({
    id: `table:${t}`, kind: 'table', label: t,
    system: ownership.get(t) ?? null,
    detail: ownership.has(t) ? `sole writer: ${ownership.get(t)}` : 'no sole-writer entry in SYSTEM_BOUNDARIES',
  })
}
for (const f of allFlags) {
  push({ id: `flag:${f}`, kind: 'flag', label: f, detail: 'game_config feature flag' })
}
for (const s of new Set(ownership.values())) {
  push({ id: `system:${s}`, kind: 'system', label: s, detail: 'system owner (SYSTEM_BOUNDARIES)' })
}

// ── edges ─────────────────────────────────────────────────────────────────────
const edges = []
const link = (source, target, type, note) => edges.push({ source, target, type, ...(note ? { note } : {}) })

// migration -> symbol
for (const m of migrations) {
  const mid = `mig:${m.stamp}`
  for (const f of m.createsFn) link(mid, `fn:${f}`, 'creates')
  for (const t of m.createsTable) link(mid, `table:${t}`, 'creates')
  for (const t of m.altersTable) if (tableSet.has(t)) link(mid, `table:${t}`, 'alters')
  for (const f of m.dropsFn) if (fnSet.has(f)) link(mid, `fn:${f}`, 'drops')
  for (const f of m.seedsFlag) if (/_enabled$/.test(f)) link(mid, `flag:${f}`, 'seeds')
  for (const f of m.readsFlag) if (allFlags.includes(f)) link(mid, `flag:${f}`, 'gated-by')
}

// THE KEY EDGE the map exists for:
// migration -> migration, when a later migration re-creates a function an
// earlier one defined. This is what "head now 0194 over 0038" means, derived.
const fnHistory = new Map() // fn -> [stamps in order]
for (const m of migrations) {
  for (const f of m.createsFn) {
    const prior = fnHistory.get(f) ?? []
    if (prior.length) {
      link(`mig:${m.stamp}`, `mig:${prior[prior.length - 1]}`, 'supersedes', f)
    }
    fnHistory.set(f, [...prior, m.stamp])
  }
}
// migration -> migration, when a later migration alters a table an earlier created.
const tableOrigin = new Map()
for (const m of migrations) for (const t of m.createsTable) if (!tableOrigin.has(t)) tableOrigin.set(t, m.stamp)
for (const m of migrations) {
  for (const t of m.altersTable) {
    const origin = tableOrigin.get(t)
    if (origin && origin !== m.stamp) link(`mig:${m.stamp}`, `mig:${origin}`, 'extends', t)
  }
}

// function -> function calls, and function -> table reads/writes.
// Scan each CREATE FUNCTION body for references to other known symbols.
for (const m of migrations) {
  const re = /create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?([a-z_][a-z0-9_]*)([\s\S]*?)(?=create\s+(?:or\s+replace\s+)?function|\Z)/gi
  for (const match of m.body.matchAll(re)) {
    const owner = strip(match[1])
    const chunk = match[2] ?? ''
    const seen = new Set()
    for (const ref of chunk.matchAll(/\b([a-z_][a-z0-9_]{3,})\b/g)) {
      const name = ref[1].toLowerCase()
      if (NOISE.has(name) || seen.has(name)) continue
      seen.add(name)
      if (fnSet.has(name) && name !== owner) link(`fn:${owner}`, `fn:${name}`, 'calls')
      else if (tableSet.has(name)) link(`fn:${owner}`, `table:${name}`, 'touches')
    }
  }
}

// table -> system ownership
for (const [t, s] of ownership) if (tableSet.has(t)) link(`table:${t}`, `system:${s}`, 'owned-by')

// ── de-dupe ───────────────────────────────────────────────────────────────────
const nodeIds = new Set(nodes.map((n) => n.id))
const seenEdge = new Set()
const cleanEdges = edges.filter((e) => {
  if (!nodeIds.has(e.source) || !nodeIds.has(e.target)) return false
  const k = `${e.source}|${e.target}|${e.type}|${e.note ?? ''}`
  if (seenEdge.has(k)) return false
  seenEdge.add(k)
  return true
})

const graph = {
  generatedFrom: 'repo scan (no production knowledge)',
  counts: {
    migrations: migrations.length,
    functions: allFns.length,
    tables: allTables.length,
    flags: allFlags.length,
    systems: new Set(ownership.values()).size,
    nodes: nodes.length,
    edges: cleanEdges.length,
  },
  boundariesParsed: boundariesFound,
  nodes,
  edges: cleanEdges,
}

mkdirSync(dirname(OUT), { recursive: true })
writeFileSync(OUT, JSON.stringify(graph, null, 1))

console.log(`Byeharu project map — repo scan`)
console.table(graph.counts)
const byType = {}
for (const e of cleanEdges) byType[e.type] = (byType[e.type] ?? 0) + 1
console.log('\nedge types:')
for (const [t, c] of Object.entries(byType).sort((a, b) => b[1] - a[1])) console.log(`  ${String(c).padStart(5)}  ${t}`)
console.log(`\nsystems from SYSTEM_BOUNDARIES: ${boundariesFound ? [...new Set(ownership.values())].join(', ') : 'NOT PARSED'}`)
console.log(`\n-> ${OUT}`)
