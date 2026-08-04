#!/usr/bin/env node
// ── A DUPLICATE MIGRATION VERSION IS A SILENT PRODUCTION NO-OP ──────────────────────────────────
//
// WHY THIS EXISTS (audit, 2026-08-04): duplicate versions have landed FOUR times in this repo —
// b813fa9 (0332/0333), 90b075b (0318/0319), 43065d1 (0251/0253), 11acbfc (0317/0331) — and every
// one was caught by a human eye. Nothing in .github/workflows or scripts checked for it.
//
// The failure mode, in the repo's own words (b813fa9): "A duplicate version is not a merge conflict
// git would surface: both files land, schema_migrations keys on the VERSION, so whichever applies
// second is recorded as already-applied and SILENTLY SKIPPED on production. The whole slice would
// deploy as a no-op." Green CI, merged PR, deployed nothing.
//
// This runs inside the `build` job deliberately. As of 2026-08-04 `build` is the ONLY required
// status check on main, so it is the only place a guard can actually block a merge rather than
// merely notify. Every other proof in this repo can go red and the merge still proceeds.
//
// Checks two things and nothing else, so it cannot become a maintenance burden:
//   1. no two migration files share a version prefix
//   2. every migration filename is well-formed (a 14-digit version + a name)
// It deliberately does NOT enforce contiguity: the chain has 15 legitimate gaps (192, 223-225,
// 251, 253, 321-329), some from renumbered slices. A gap is a decision; a collision is a bug.

import { readdirSync } from 'node:fs'
import { join } from 'node:path'

const DIR = join(import.meta.dirname, '..', 'supabase', 'migrations')
const NAME = /^(\d{14})_([A-Za-z0-9_.-]+)\.sql$/

const files = readdirSync(DIR).filter((f) => f.endsWith('.sql')).sort()
const byVersion = new Map()
const malformed = []

for (const file of files) {
  const m = NAME.exec(file)
  if (!m) {
    malformed.push(file)
    continue
  }
  const version = m[1]
  if (!byVersion.has(version)) byVersion.set(version, [])
  byVersion.get(version).push(file)
}

const collisions = [...byVersion.entries()].filter(([, group]) => group.length > 1)
const problems = []

for (const [version, group] of collisions) {
  problems.push(
    `DUPLICATE VERSION ${version} — ${group.length} files share it:\n` +
      group.map((f) => `    ${f}`).join('\n') +
      `\n    Only one would apply. The other is recorded as already-applied and SILENTLY SKIPPED\n` +
      `    on production, deploying as a no-op with everything green. Renumber one of them.`,
  )
}

for (const file of malformed) {
  problems.push(
    `MALFORMED MIGRATION NAME — ${file}\n` +
      `    Expected <14-digit version>_<name>.sql. The Supabase CLI keys schema_migrations on the\n` +
      `    version prefix; a name it cannot parse is a migration whose apply state is undefined.`,
  )
}

if (problems.length > 0) {
  console.error(`\nMIGRATION VERSION CHECK FAILED — ${problems.length} problem(s)\n`)
  for (const p of problems) console.error(`  ${p}\n`)
  process.exit(1)
}

console.log(`migration version check ok: ${files.length} migrations, ${byVersion.size} distinct versions, no collisions`)
