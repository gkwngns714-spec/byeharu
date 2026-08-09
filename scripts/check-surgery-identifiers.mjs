#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════════════════════════════
// check-surgery-identifiers — THE STATIC GATE FOR REPLACE-REWRITER MIGRATIONS
// ═══════════════════════════════════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS. Migration 0346 went RED on all 22 disposable-matrix legs at the apply stage with
//
//     ERROR: "v_extent" is not a known variable (SQLSTATE 42601)
//
// and nothing applied. The FINAL text the migration produced was correct — a needle audit that
// applied every hunk and then inspected the result said so, truthfully. The defect was the
// INTERMEDIATE state: the surgery ran `execute v_new` inside its hunk loop, once per hunk, and hunk
// [S1] deleted the `v_extent` DECLARATION while hunk [S2] deleted its two USES. Between those two
// statements the function existed with the declaration gone and the uses live, and Postgres
// validates a plpgsql body at CREATE time.
//
// So the bug was invisible to "check the end state" and would have been caught by "check every state
// you actually create". That is what this script does, and it is the whole reason it is worth
// keeping: a replace-rewriter does not produce one body, it produces one body PER EXECUTE.
//
// TWO MODES, and the first one needs no database at all:
//
//   1. STRUCTURAL (always). Parse the migration's surgery block and refuse the shape that makes the
//      class possible: executing inside the hunk loop while any single function carries more than
//      one hunk. With one execute per function, applied after every hunk for it has landed, there is
//      no intermediate state to be invalid and hunk ORDER stops being load-bearing. This runs in CI,
//      on any machine, with no credentials.
//
//   2. IDENTIFIER (when the deployed bodies are supplied with --body). Reconstruct what the
//      migration emits — the final body AND, if the migration executes per hunk, every intermediate
//      body — and check in BOTH directions that every plpgsql local it uses is declared and every
//      local it declares is used. Used-but-undeclared is the error above; declared-but-unused is the
//      reverse tell, and it is how you find a hunk that removed the last use of a variable and left
//      the declaration stranded.
//
// USAGE
//   node scripts/check-surgery-identifiers.mjs supabase/migrations/2026...sql
//   node scripts/check-surgery-identifiers.mjs <migration> --body combat_spawn_wave_units=spawn.txt \
//                                                          --body process_combat_ticks=tick.txt
//
// The body files are `pg_get_functiondef()` output dumped read-only from the target database. They
// are deliberately NOT committed: the live engine is the authority, and a checked-in copy would be a
// second one that drifts.
//
// EXIT 0 = clean. EXIT 1 = a finding. EXIT 2 = the migration carries no surgery block to check.

import { readFileSync } from 'node:fs'

const args = process.argv.slice(2)
const migPath = args.find((a) => !a.startsWith('--'))
if (!migPath) {
  console.error('usage: check-surgery-identifiers.mjs <migration.sql> [--body <fname>=<path>]...')
  process.exit(2)
}
const bodies = new Map()
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--body') {
    const [fname, path] = (args[i + 1] ?? '').split('=')
    if (!fname || !path) {
      console.error('--body needs <fname>=<path>')
      process.exit(2)
    }
    bodies.set(fname, readFileSync(path, 'utf8').replace(/\r\n/g, '\n'))
  }
}

const src = readFileSync(migPath, 'utf8').replace(/\r\n/g, '\n')
const findings = []
const notes = []

// ── locate the surgery block ─────────────────────────────────────────────────────────────────────
const blockRe = /do \$rewrite\$([\s\S]*?)end \$rewrite\$;/
const m = blockRe.exec(src)
if (!m) {
  console.log(`check-surgery-identifiers: ${migPath} carries no \`do $rewrite$\` surgery block — nothing to check.`)
  process.exit(2)
}
const block = m[1]

// ── extract the (idx, 'fname', $Xo$old$Xo$, $Xn$new$Xn$) hunk rows ──────────────────────────────
// The house shape is a VALUES list; each hunk's texts are dollar-quoted with a per-hunk tag.
const hunkRe = /\(\s*(\d+)\s*,\s*'([a-z0-9_]+)'\s*,\s*\$([a-z0-9]+)o\$([\s\S]*?)\$\3o\$\s*,\s*\$\3n\$([\s\S]*?)\$\3n\$\s*\)/gi
const hunks = []
let h
while ((h = hunkRe.exec(block)) !== null) {
  hunks.push({ idx: Number(h[1]), fname: h[2], tag: h[3], old: h[4], new: h[5] })
}
if (hunks.length === 0) {
  console.log(`check-surgery-identifiers: ${migPath} has a surgery block but no recognisable hunk rows — nothing to check.`)
  process.exit(2)
}
notes.push(`${hunks.length} hunk(s) over ${new Set(hunks.map((x) => x.fname)).size} function(s)`)

// ── MODE 1: STRUCTURAL — does this migration execute inside its hunk loop? ───────────────────────
// The loop body is everything between `loop` and `end loop;` inside the surgery block. An `execute`
// there means one CREATE per hunk, i.e. one intermediate body per hunk.
const loopBody = (() => {
  const i = block.indexOf('\n  loop\n')
  const j = block.indexOf('end loop;')
  return i >= 0 && j > i ? block.slice(i, j) : ''
})()
const executesPerHunk = /^\s*execute\s/m.test(loopBody)
const perFunctionCounts = new Map()
for (const x of hunks) perFunctionCounts.set(x.fname, (perFunctionCounts.get(x.fname) ?? 0) + 1)
const multiHunk = [...perFunctionCounts.entries()].filter(([, n]) => n > 1)

if (executesPerHunk && multiHunk.length > 0) {
  findings.push(
    `STRUCTURAL: the surgery executes INSIDE its hunk loop while ${multiHunk
      .map(([f, n]) => `public.${f} carries ${n} hunks`)
      .join(', ')}. That creates one intermediate body per hunk, and an intermediate body is a real ` +
      `CREATE that Postgres validates — a hunk that removes a DECLARATION while a later hunk removes ` +
      `its USES is rejected with 42601 even though the final text is correct (0346, PR #403, 22/22 legs ` +
      `red). Accumulate every hunk into an in-memory text per function and execute ONCE per function.`,
  )
} else if (executesPerHunk) {
  notes.push('executes per hunk, but no function carries more than one hunk — no intermediate state exists')
} else {
  notes.push('accumulates and executes once per function — no intermediate body is ever created')
}

// ── MODE 2: IDENTIFIER — declared-vs-used, in both directions ────────────────────────────────────
// plpgsql locals in this repo are `v_*`; parameters are `p_*`. Declarations appear in DECLARE blocks
// (there are nested ones), as `  name type ...;`. This is a convention-aware check, not a parser —
// it is aimed squarely at the class above and says so rather than pretending to be complete.
const stripComments = (s) => s.replace(/--[^\n]*/g, '')

function declaredNames(body) {
  const out = new Set()
  const code = stripComments(body)
  // every DECLARE ... BEGIN region, including nested ones
  const re = /\bdeclare\b([\s\S]*?)\bbegin\b/gi
  let d
  while ((d = re.exec(code)) !== null) {
    for (const line of d[1].split('\n')) {
      const mm = /^\s*(v_[a-z0-9_]+)\s+[a-z]/i.exec(line)
      if (mm) out.add(mm[1].toLowerCase())
    }
  }
  return out
}

function usedNames(body) {
  const out = new Set()
  const code = stripComments(body)
  for (const mm of code.matchAll(/\bv_[a-z0-9_]+\b/gi)) out.add(mm[0].toLowerCase())
  return out
}

function scan(body) {
  const dec = declaredNames(body)
  const use = usedNames(body)
  // a name that appears ONLY on its own declaration line is "declared, never used"
  const code = stripComments(body)
  const usedElsewhere = new Set()
  for (const name of dec) {
    // NOTE: the word-boundary escape MUST come from a template literal (`\\b` -> \b). Writing
    // new RegExp('\bx\b') passes the BACKSPACE character and silently matches nothing, which would
    // make every check here pass vacuously — the exact class of green-that-tests-nothing this repo
    // has been burned by. The self-test at the foot of this file pins it.
    if ([...code.matchAll(new RegExp(`\\b${name}\\b`, 'gi'))].length > 1) usedElsewhere.add(name)
  }
  return {
    declared: dec,
    used: use,
    undeclared: new Set([...use].filter((n) => !dec.has(n))),
    unused: new Set([...dec].filter((n) => !usedElsewhere.has(n))),
  }
}

// A MIGRATION IS ACCOUNTABLE FOR WHAT IT INTRODUCES, NOT FOR WHAT IT INHERITED. Comparing against
// the body as it was found is what keeps this a gate instead of a permanently-red wall of somebody
// else's debt — a proof that is always red stops being read, which is worse than no proof.
function analyse(label, before, after) {
  const b = scan(before)
  const a = scan(after)
  const newUndeclared = [...a.undeclared].filter((n) => !b.undeclared.has(n)).sort()
  const newUnused = [...a.unused].filter((n) => !b.unused.has(n)).sort()
  const inherited = [...a.unused].filter((n) => b.unused.has(n)).sort()
  if (newUndeclared.length) {
    findings.push(
      `IDENTIFIER [${label}]: used but NOT declared — ${newUndeclared.join(', ')}. This is the exact ` +
        `shape of "«name» is not a known variable (SQLSTATE 42601)": Postgres rejects the whole CREATE ` +
        `and the migration applies nothing.`,
    )
  }
  if (newUnused.length) {
    findings.push(
      `IDENTIFIER [${label}]: declared but NEVER used, and THIS migration stranded it — ` +
        `${newUnused.join(', ')}. The reverse tell: a hunk removed the last use and left the ` +
        `declaration behind, so the deletion is half-done.`,
    )
  }
  if (inherited.length) {
    notes.push(`${label}: ${inherited.length} pre-existing stranded declaration(s), inherited not introduced — ${inherited.join(', ')}`)
  }
  return { declared: a.declared.size, used: a.used.size }
}

if (bodies.size > 0) {
  for (const fname of new Set(hunks.map((x) => x.fname))) {
    const before = bodies.get(fname)
    if (!before) {
      findings.push(`IDENTIFIER: no --body supplied for public.${fname}, so its emitted text was not checked.`)
      continue
    }
    let text = before
    const mine = hunks.filter((x) => x.fname === fname).sort((a, b) => a.idx - b.idx)
    for (const hunk of mine) {
      const n = text.split(hunk.old).length - 1
      if (n !== 1) {
        findings.push(`HUNK [${hunk.tag}]: matches ${n} time(s) in public.${fname}, want exactly 1 — the supplied body is not what this migration was sliced against.`)
        text = null
        break
      }
      text = text.replace(hunk.old, hunk.new)
      // EVERY STATE THIS MIGRATION ACTUALLY CREATES HAS TO BE VALID, NOT JUST THE LAST ONE. This is
      // the line that would have caught 0346's red: the final body was clean and the body between
      // hunk [S1] and hunk [S2] was not.
      if (executesPerHunk) analyse(`public.${fname} AFTER HUNK ${hunk.tag} (an intermediate CREATE)`, before, text)
    }
    if (text !== null) {
      const r = analyse(`public.${fname} final`, before, text)
      notes.push(`public.${fname}: ${r.declared} declared, ${r.used} used`)
    }
  }
} else {
  notes.push('no --body supplied: the identifier check was SKIPPED (structural check only)')
}

// ── NON-VACUITY SELFTEST — this runs on EVERY invocation and cannot be skipped ───────────────────
// The whole check rests on one escape. `new RegExp('\bx\b')` passes U+0008 BACKSPACE and matches
// nothing, so every "used" set would come back empty, every name would look stranded and every
// "undeclared" set would look clean — a green that tests nothing. A known-good fixture proves the
// analysis can SEE both failure directions before any real result is believed.
{
  const fixture = 'declare\n  v_used integer;\n  v_stranded integer;\nbegin\n  v_used := v_missing + 1;\nend'
  const s = scan(fixture)
  const ok =
    s.declared.has('v_used') && s.declared.has('v_stranded') &&
    s.undeclared.has('v_missing') && !s.undeclared.has('v_used') &&
    s.unused.has('v_stranded') && !s.unused.has('v_used')
  if (!ok) {
    console.error(
      'FAIL SELFTEST: the identifier analysis cannot see its own fixture — declared=' +
        [...s.declared].join('/') + ' undeclared=' + [...s.undeclared].join('/') +
        ' unused=' + [...s.unused].join('/') +
        '. Every result from this run would be vacuous, so it is refused rather than reported.',
    )
    process.exit(1)
  }
  notes.push('selftest ok: the analysis detects both a used-but-undeclared name and a stranded declaration')
}

// ── report ───────────────────────────────────────────────────────────────────────────────────────
for (const n of notes) console.log(`  · ${n}`)
if (findings.length === 0) {
  console.log(`check-surgery-identifiers OK: ${migPath}`)
  process.exit(0)
}
for (const f of findings) console.error(`\nFAIL ${f}`)
console.error(`\ncheck-surgery-identifiers: ${findings.length} finding(s) in ${migPath}`)
process.exit(1)
