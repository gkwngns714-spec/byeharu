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

// ── the future ────────────────────────────────────────────────────────────────
// Everything above describes what EXISTS. The plans describe what is meant to.
// FULL_CAPACITY_PLAN.md carries two structured lists worth reading:
//   §C — a development queue (### P3 — SALVAGE … *(S/M)*), where the heading
//        itself says whether the slice shipped
//   §B — an activation ladder (**Rung 3 — Trade market.**), the ordered list of
//        human flag-flips still owed
// Both name their migrations and flags in backticks, so they can be wired to the
// real graph instead of floating as decoration.

// '20260618000204' -> 204, so a plan saying "mig 0204" can find its migration.
const seqOf = (stamp) => parseInt(stamp.slice(8), 10)
const migBySeq = new Map(migrations.map((m) => [seqOf(m.stamp), m.stamp]))

// A plan rarely names its flag directly — it names the activation script that
// flips it ("prep shipped: `activate-exploration`"). So follow that one hop and
// read the script, rather than guessing the flag from the rung's title.
const SCRIPTS = join(REPO, 'scripts')
const flagsOfScript = new Map()
function scriptFlags(name) {
  if (flagsOfScript.has(name)) return flagsOfScript.get(name)
  let found = []
  for (const ext of ['.sql', '.sh', '.mjs']) {
    const p = join(SCRIPTS, `${name}${ext}`)
    if (!existsSync(p)) continue
    const src = readFileSync(p, 'utf8')
    found.push(...[...src.matchAll(/'([a-z_0-9]+_enabled)'/g)].map((m) => m[1]))
  }
  found = [...new Set(found)].filter((f) => allFlags.includes(f))
  flagsOfScript.set(name, found)
  return found
}

const refsIn = (text) => {
  const migs = []
  for (const m of text.matchAll(/\bmigs?\.?\s+((?:\d{4})(?:\s*(?:[+/,]|and|–|-)\s*\d{4})*)/gi)) {
    for (const d of m[1].matchAll(/\d{4}/g)) {
      const stamp = migBySeq.get(parseInt(d[0], 10))
      if (stamp) migs.push(stamp)
    }
  }
  const named = [...new Set([...text.matchAll(/`([a-z_0-9]+_enabled)`/g)].map((m) => m[1]))]
    .filter((f) => allFlags.includes(f))
  // Follow any `activate-x` script the text names — but ONLY as a fallback.
  // A script mentions its preconditions as well as its target (e.g.
  // activate-coordinate-travel checks mainship_space_movement_enabled but flips
  // only coordinate travel), so union-ing the two over-collects and would call a
  // pending rung "done". When the plan names a flag outright, trust that.
  const viaScript = []
  for (const s of text.matchAll(/`(activate-[a-z0-9-]+)[`.]/g)) viaScript.push(...scriptFlags(s[1]))
  return {
    migs: [...new Set(migs)],
    flags: named.length ? named : [...new Set(viaScript)],
    named: named.length > 0,
  }
}

const plans = { phases: [], rungs: [] }
const planPath = join(DOCS, 'FULL_CAPACITY_PLAN.md')
if (existsSync(planPath)) {
  const md = readFileSync(planPath, 'utf8')

  // §C — development queue. Split on ### headings, keep the ones that look like
  // a queue slice (P<n>, or a named track like FLEET).
  const secs = md.split(/\n(?=### )/)
  const usedKeys = new Set()
  for (const sec of secs) {
    const head = sec.split('\n')[0]
    // greedy to the LAST ')*' — plan headings nest parens, e.g.
    // "*(M — COMPLETE dark: SHIELD-0/1/2 ALL SHIPPED (migs 0191/0195/0197); …)*"
    const m = head.match(/^###\s+(P\d+|FLEET|[A-Z][A-Z0-9-]{2,})\s+—\s+([^*]+?)\s*(?:\*\((.*)\)\*)?\s*$/)
    if (!m) continue
    let [, key, title, meta = ''] = m
    // The plan reuses a track name for separate slices (### FLEET appears twice).
    // Node ids are `phase:<key>` and MUST be unique — a duplicate id would merge
    // two slices into one node and cross-wire their edges — so suffix repeats.
    for (let i = 2; usedKeys.has(key); i++) key = `${m[1]}-${i}`
    usedKeys.add(key)
    // A slice is only "built" if the heading says so. Anything else is a plan.
    const built = /SHIPPED|COMPLETE|STOCKED/i.test(meta)
    const { migs, flags } = refsIn(sec)
    plans.phases.push({
      key, title: title.trim(), meta: meta.trim(), built,
      migs, flags, detail: sec.slice(0, 420).replace(/\s+/g, ' ').trim(),
    })
  }

  // §B — activation ladder: **Rung 3 — Trade market.** …
  const ladder = md.split(/\n## /).find((s) => /^B\. THE ACTIVATION LADDER/.test(s)) ?? ''
  for (const b of ladder.split(/\n(?=- \*\*Rung )/)) {
    const m = b.match(/^- \*\*Rung ([\d.]+)\s*—\s*([^.(*]+)/)
    if (!m) continue
    const title = m[2].trim()
    const { migs, flags, named } = refsIn(b)
    // Some rungs name neither flag nor script ("Rollback: flag"). Try the one
    // checkable hop left: a script named after the rung. If there is no such
    // script, leave it unlinked — better an honest gap than an invented edge.
    let via = !flags.length ? null : named ? 'named in the plan' : 'read from the activation script the plan names'
    let resolved = flags
    if (!resolved.length) {
      const guess = `activate-${title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')}`
      const f = scriptFlags(guess)
      if (f.length) { resolved = f; via = `inferred from scripts/${guess}.sql` }
    }
    plans.rungs.push({
      key: `Rung ${m[1]}`, order: parseFloat(m[1]), title,
      migs, flags: resolved, via,
      detail: b.slice(0, 420).replace(/\s+/g, ' ').trim(),
    })
  }
}

// ── the build log ─────────────────────────────────────────────────────────────
// docs/DEV_LOG.md is the project's curated job history — one `## YYYY-MM-DD — title`
// entry per slice / fix / wave, newest first. It is the real "what has been built"
// record: migrations only cover database work, so whole frontend arcs (the UI
// rebuild, the renames, the fix batches) would otherwise be invisible to the map.
// Parse every heading into a job, and wire each job to the migrations its title
// names (seq refs like "mig 0206" / "migrations 0161–0164", ranges expanded) so
// the timeline can colour them with real evidence.
const jobs = []
const devLogPath = join(DOCS, 'DEV_LOG.md')
const devLogFound = existsSync(devLogPath)
if (devLogFound) {
  const md = readFileSync(devLogPath, 'utf8')
  for (const h of md.matchAll(/^## (\d{4}-\d{2}-\d{2})\s+—\s+(.+)$/gm)) {
    const [, date, title] = h
    const migs = []
    for (const g of title.matchAll(/\bmig(?:ration)?s?\.?\s+((?:\d{4})(?:\s*(?:[+/,–-]|and)\s*\d{4})*)/gi)) {
      for (const p of g[1].matchAll(/(\d{4})(?:\s*[–-]\s*(\d{4}))?/g)) {
        const a = parseInt(p[1], 10), b = p[2] ? parseInt(p[2], 10) : a
        for (let s = a; s <= Math.min(b, a + 30); s++) {
          const stamp = migBySeq.get(s)
          if (stamp) migs.push(stamp)
        }
      }
    }
    jobs.push({ date, title: title.trim(), migs: [...new Set(migs)] })
  }
  jobs.reverse() // the log is newest-first; history reads oldest-first
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
for (const p of plans.phases) {
  push({
    id: `phase:${p.key}`, kind: 'phase', label: `${p.key} — ${p.title}`,
    planned: !p.built && !p.migs.length,
    size: p.meta, file: 'docs/FULL_CAPACITY_PLAN.md', detail: p.detail,
  })
}
for (const r of plans.rungs) {
  push({
    id: `rung:${r.key}`, kind: 'rung', label: `${r.key} — ${r.title}`,
    order: r.order, via: r.via, file: 'docs/FULL_CAPACITY_PLAN.md',
    detail: r.via ? `Flag link ${r.via}. ${r.detail}` : `No flag or activation script named in the plan for this rung. ${r.detail}`,
  })
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

// plan -> the real things that deliver it
for (const p of plans.phases) {
  for (const stamp of p.migs) link(`phase:${p.key}`, `mig:${stamp}`, 'delivered-by')
  for (const f of p.flags) link(`phase:${p.key}`, `flag:${f}`, 'delivers')
}
for (const r of plans.rungs) {
  for (const f of r.flags) link(`rung:${r.key}`, `flag:${f}`, 'flips')
  for (const stamp of r.migs) link(`rung:${r.key}`, `mig:${stamp}`, 'delivered-by')
}
// the ladder is an ordered chain — rung N waits on rung N-1
const rungsOrdered = [...plans.rungs].sort((a, b) => a.order - b.order)
for (let i = 1; i < rungsOrdered.length; i++) {
  link(`rung:${rungsOrdered[i].key}`, `rung:${rungsOrdered[i - 1].key}`, 'waits-on')
}

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
    phases: plans.phases.length,
    rungs: plans.rungs.length,
    jobs: jobs.length,
    nodes: nodes.length,
    edges: cleanEdges.length,
  },
  boundariesParsed: boundariesFound,
  plansParsed: plans.phases.length > 0,
  nodes,
  edges: cleanEdges,
  jobs,
}

// ── drift guard ───────────────────────────────────────────────────────────────
// Everything here is parsed out of prose whose format nobody promised to keep.
// Rename a heading in FULL_CAPACITY_PLAN.md, reshape the SYSTEM_BOUNDARIES
// table, and rows silently vanish — the 조직도 quietly shrinks while still
// looking authoritative. That already happened once: nested parens in a plan
// heading swallowed P13 (SHIELD) whole, and only a human eye caught it.
//
// So: refuse to write a map that lost things. A scan that finds LESS than the
// committed one is treated as breakage until a human says otherwise.
const problems = []
const warnings = []

if (!boundariesFound) problems.push('SYSTEM_BOUNDARIES.md: parsed no table-owner rows — the 조직도 ownership view would be empty')
if (!plans.phases.length) problems.push('FULL_CAPACITY_PLAN.md: parsed no §C phase headings — the roadmap view would lose the development queue')
if (!plans.rungs.length) problems.push('FULL_CAPACITY_PLAN.md: parsed no §B rungs — the roadmap view would lose the activation ladder')
if (devLogFound && !jobs.length) problems.push('docs/DEV_LOG.md: exists but parsed no `## YYYY-MM-DD — title` entries — the timeline build log would be empty')
if (!devLogFound) warnings.push('docs/DEV_LOG.md: not found — the timeline shows no build log')
if (!addDates.size) warnings.push('git: no migration add-dates — the build-order view degrades to file order')

const rungsNoFlag = plans.rungs.filter((r) => !r.flags.length).map((r) => r.key)
if (rungsNoFlag.length) warnings.push(`rungs with no flag or activation script (shown unlinked): ${rungsNoFlag.join(', ')}`)

// compare against the committed map, if there is one
let prev = null
try { prev = JSON.parse(readFileSync(OUT, 'utf8')) } catch { /* first run */ }
if (prev?.counts) {
  for (const [k, now] of Object.entries(graph.counts)) {
    const before = prev.counts[k]
    if (typeof before !== 'number' || now >= before) continue
    const lost = before - now
    const msg = `${k}: ${before} -> ${now} (lost ${lost})`
    // a big or total collapse is breakage; a small dip may be a real deletion
    if (now === 0 || lost / before > 0.1) problems.push(msg)
    else warnings.push(msg)
  }
}

for (const w of warnings) console.error(`  ! ${w}`)
if (problems.length && !process.argv.includes('--allow-shrink')) {
  console.error('\nSCAN REFUSED — this scan found less than the committed map:\n')
  for (const p of problems) console.error(`  ✗ ${p}`)
  console.error('\nEither a doc format changed and a parser needs fixing, or things were'
    + '\ngenuinely deleted. If the loss is real, re-run with --allow-shrink.'
    + `\n${OUT} left untouched.\n`)
  process.exit(1)
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
