#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════════════════════════════
// check-ingress-preconditions — DOES THE PRECONDITION ACTUALLY REACH THE BLOCK THAT NEEDS IT?
// ═══════════════════════════════════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS. 0346 gives an enemy body an INGRESS phase: it spawns at its zone's city and
// travels in over combat_enemy_ingress_ticks ticks instead of being placed on the engagement
// boundary outright. Every exact-damage, first-salvo and aggregation pin in the proof suites is
// about a body that is ALREADY at that boundary, so each suite owns the knob at 0 in-txn — the
// proofs-never-assert-ambient-defaults law — and the engine is then byte-identical for them.
//
// That repoint was made once and STILL missed a suite, and CI found it, not me:
//
//     TEAMHUNT FAIL: tick player_damage is distinct from sum(attack_snapshot) (member aggregation pin)
//
// The knob write for team-command-proof.sql had landed inside `pg_temp.wipe_tick` — a HELPER, which
// runs only when it is called, and which TEAMHUNT never calls. Nine sibling suites took the same
// line in their determinism preamble and were fine. **A precondition a block never executes is not
// a precondition**, and that is a STRUCTURAL property, so it can be checked without a database.
//
// WHAT THIS CAN AND CANNOT DO — stated plainly rather than oversold. It cannot tell whether an
// assertion's PREMISE is still true; that is a behavioural question and only the disposable-Postgres
// leg answers it. What it checks is the one mechanical tell behind both misses so far: a suite that
// puts enemy bodies on a field and does NOT own the ingress duration, at the top level, before the
// first statement that could spawn one. Four failure shapes:
//
//   A. NEVER SET       — spawns bodies, never owns the knob
//   B. INSIDE A HELPER — owns it in a pg_temp function body, which runs only when called (TEAMHUNT)
//   C. SET TOO LATE    — a top-level tick drive or staging call precedes the knob write
//   D. WIPED           — a wholesale game_config delete/truncate could put the seed back
//
// ACTIVATION AND PRODUCTION-VERIFY SCRIPTS ARE EXCLUDED BY NAME, deliberately: they run against a
// real database where the ingress is meant to be LIVE, and forcing it to 0 there would be a lie
// about the thing they exist to verify.
//
// USAGE:  node scripts/check-ingress-preconditions.mjs [--dir scripts]
// EXIT 0 = every body-spawning suite owns the precondition. EXIT 1 = a finding.

import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const dirArg = process.argv.indexOf('--dir')
const DIR = dirArg !== -1 ? process.argv[dirArg + 1] : HERE

const KNOB = 'combat_enemy_ingress_ticks'
// Scripts that legitimately run against a live database, where the ingress must NOT be pinned off.
const EXCLUDE = /^(activate-|verify-|encounter-canary-readiness)/

const spawnRe = /process_combat_ticks\(\)|pressure_refill\(|pressure_fill\(|combat_spawn_wave_units\(/
const knobRe = new RegExp(`set_game_config\\('${KNOB}'`)

/** Which construct encloses line i: a pg_temp function body, a do-block, or file top level. */
function enclosing(lines, i) {
  for (let j = i; j >= 0; j--) {
    if (/create\s+or\s+replace\s+function\s+pg_temp\./i.test(lines[j])) return 'fn'
    if (/^\s*do\s+\$[a-z0-9]*\$/i.test(lines[j])) return 'do'
  }
  return 'top'
}

const findings = []
const ok = []

for (const f of readdirSync(DIR).filter((x) => x.endsWith('.sql')).sort()) {
  if (EXCLUDE.test(f)) continue
  // Comments AND single-quoted string literals are stripped first, and both strips are load-bearing:
  //   · prose that merely NAMES process_combat_ticks() is not a drive — this file's own explanatory
  //     comments would otherwise flag every suite they appear in;
  //   · 'public.combat_spawn_wave_units(' inside strpos() is a catalog TEXT PROBE asserting which
  //     function composes the spawn authority, not a call — elite-stat-wiring and encounter-resolver
  //     both open with one, and reading it as a spawn put the "first drive" 100+ lines too early.
  // Both were observed as false positives on a real run, not anticipated.
  // TWO VIEWS, and they must stay two. The knob write IS a string literal
  // (set_game_config('combat_enemy_ingress_ticks', ...)), so stripping literals for the knob search
  // erases the very thing being looked for and reports every suite as never-setting it — observed,
  // not imagined. Comments-only for the knob; comments AND literals for the spawn search.
  const raw = readFileSync(join(DIR, f), 'utf8').split('\n')
  const lines = raw.map((l) => l.replace(/--.*$/, ''))
  const code = lines.map((l) => l.replace(/'(?:[^']|'')*'/g, "''"))
  if (!code.some((l) => spawnRe.test(l))) continue

  const knobIdx = lines.findIndex((l) => knobRe.test(l))
  let firstDrive = -1
  for (let i = 0; i < code.length; i++) {
    if (!spawnRe.test(code[i])) continue
    if (enclosing(lines, i) === 'fn') continue // runs when CALLED; its line number proves no ordering
    firstDrive = i
    break
  }
  const wiped = code.findIndex((l) => /delete\s+from\s+(public\.)?game_config|truncate\s+(public\.)?game_config/i.test(l))

  if (knobIdx === -1) {
    findings.push(`A [${f}]: puts enemy bodies on a field and never owns ${KNOB}. Under 0346 its bodies spawn at the zone's city, so any pin that reads damage or geometry on the tick a body appears is measuring a fleet that could not reach it.`)
  } else if (enclosing(lines, knobIdx) === 'fn') {
    findings.push(`B [${f}:${knobIdx + 1}]: owns ${KNOB} INSIDE a pg_temp helper, which runs only when that helper is called. This is the TEAMHUNT defect verbatim — nine sibling suites set it in their preamble and were fine. Move it to the suite's top-level determinism preamble.`)
  } else if (firstDrive !== -1 && firstDrive < knobIdx) {
    findings.push(`C [${f}]: a top-level spawn/drive at line ${firstDrive + 1} PRECEDES the knob write at line ${knobIdx + 1}. That first body arrives under the live ingress.`)
  } else if (wiped !== -1) {
    findings.push(`D [${f}:${wiped + 1}]: a wholesale game_config delete/truncate may restore the seeded ingress duration behind the suite's back.`)
  } else {
    ok.push(`${f}: knob line ${knobIdx + 1}${firstDrive === -1 ? ', no top-level drive' : `, first top-level drive line ${firstDrive + 1}`}`)
  }
}

// NON-VACUITY. If the scan matched no suites at all — a moved directory, a renamed knob, a broken
// regex — every check above passes by finding nothing, which reads exactly like success.
if (ok.length + findings.length === 0) {
  console.error(`FAIL: check-ingress-preconditions found NO body-spawning suite in ${DIR}. Either the directory is wrong or the detector is broken; either way this run proves nothing and is refused rather than reported as clean.`)
  process.exit(1)
}

for (const o of ok) console.log(`  · ok  ${o}`)
if (findings.length === 0) {
  console.log(`check-ingress-preconditions OK: ${ok.length} body-spawning suite(s), each owning ${KNOB} before its first spawn.`)
  process.exit(0)
}
for (const f of findings) console.error(`\nFAIL ${f}`)
console.error(`\ncheck-ingress-preconditions: ${findings.length} finding(s)`)
process.exit(1)
