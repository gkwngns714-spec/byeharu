// SAY WHERE THE FLEET IS GOING — ON THE MAP.
//
// ── THE COMPLAINT ─────────────────────────────────────────────────────────────────────────────────
// The owner, playing live: "when figting, i am not able to move my fleet."
//
// ── THE CAUSE ─────────────────────────────────────────────────────────────────────────────────────
// The order was being ACCEPTED and the fleet really was moving. 0337 turned a reposition from a jump
// into a WALK: `command_ship_group_go` only records combat_encounters.reposition_x/reposition_y and
// the tick advances the fleet at its own speed — which at normal map zoom is on the order of a
// sixteenth of a pixel per three-second tick. A player gets one transient success toast and then
// nothing changes on screen for many seconds, which reads as a dead button.
//
// The sentence that closes that gap already existed (resolveRepositionCourse) and was already
// mounted — on the MISSION screen, inside ActiveCombatPanel. A player fighting on the MAP never
// opens it. So the fix is a second MOUNT, never a second implementation.
//
// ── WHAT THESE SPECS PIN ──────────────────────────────────────────────────────────────────────────
// 1. the map card states the course, through the one resolver, gated so silence is the default;
// 2. the card derives NOTHING itself — no distance, no wording, no column read;
// 3. there is exactly ONE producer of that sentence in all of src/;
// 4. the fight's exit is not crowded by it (map-UX law).
//
// The RENDERED proof of the same line belongs in tests/fightReadout.uispec.ts, which mounts the real
// card in Chromium. It cannot live here: CombatMapCard pulls in RetreatControl → combatApi →
// lib/supabase, whose module body calls createClient() and throws under Node without VITE_ env
// (exactly how tests/galaxy.spec.ts fails to load). So this file proves the composition, the same
// way tests/combatMapCard.spec.ts already proves the rest of the card's shape.
import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  resolveRepositionCourse,
  type RepositionCourseInput,
} from '../src/features/combat/repositionCourse'

const here = dirname(fileURLToPath(import.meta.url))
const srcRoot = join(here, '..', 'src')
const src = (rel: string) => readFileSync(join(srcRoot, rel), 'utf8')
const card = src('features/map/CombatMapCard.tsx')
const panel = src('features/combat/ActiveCombatPanel.tsx')

/** Every .ts/.tsx file under src/, as repo-relative POSIX paths — so a "there is only one of these"
 *  claim is made against the whole source tree, not a hand-listed sample that a new copy escapes. */
function allSourceFiles(dir: string = srcRoot): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...allSourceFiles(full))
    else if (/\.tsx?$/.test(entry.name)) out.push(relative(srcRoot, full).split(sep).join('/'))
  }
  return out
}

/** Source with comment lines stripped — so an assertion about what a component RENDERS is not
 *  satisfied by the paragraph explaining why it renders it. (Same helper as combatMapCard.spec.ts;
 *  four lines of local test scaffolding, deliberately not a shared import.) */
const codeOnly = (text: string) =>
  text
    .split(/\r?\n/)
    .filter((l) => !l.trim().startsWith('//') && !l.trim().startsWith('*'))
    .join('\n')

const active: RepositionCourseInput = {
  status: 'active',
  engagement_x: 100,
  engagement_y: 200,
  reposition_x: 130,
  reposition_y: 240,
}

test('the map card states the standing course, through the ONE resolver', () => {
  expect(card).toContain("import { resolveRepositionCourse } from '../combat/repositionCourse'")
  expect(card).toContain('resolveRepositionCourse(e)')
  // it prints the resolver's own sentence — not a sentence of its own assembled from the parts
  expect(codeOnly(card)).toContain('{course.text}')
  expect(card).toContain('combat-map-reposition-')
})

test('no course standing → the card renders NOTHING (clean-map law, silence by default)', () => {
  // The gate is the resolver's null, so every way of having no course collapses to one branch.
  expect(codeOnly(card)).toMatch(/\{course &&/)
  // …and these are the ways, proven on the resolver the gate reads:
  expect(resolveRepositionCourse({ ...active, reposition_x: null, reposition_y: null })).toBeNull()
  expect(resolveRepositionCourse({ ...active, status: 'retreating' })).toBeNull()
  expect(resolveRepositionCourse({ status: 'active', engagement_x: 1, engagement_y: 2 })).toBeNull()
  expect(resolveRepositionCourse(null)).toBeNull()
  // while a reposition order stands, there IS a sentence for the card to print
  expect(resolveRepositionCourse(active)!.text).toBe(
    'Moving to (130, 240) — 50 units to go. The fight moves with the fleet.',
  )
})

test('the card re-derives NOTHING — not the distance, not the wording, not the columns', () => {
  const code = codeOnly(card)
  for (const forbidden of ['reposition_x', 'reposition_y', 'Math.hypot', 'units to go', 'Moving to']) {
    expect(code, `CombatMapCard must not re-derive ${forbidden} — it imports the course`).not.toContain(
      forbidden,
    )
  }
})

test('ONE producer of the course sentence in all of src/ — two mounts, one implementation', () => {
  const files = allSourceFiles()
  // the sentence itself
  const producers = files.filter((f) => src(f).includes('units to go'))
  expect(producers, 'the course sentence must be written in exactly one place').toEqual([
    'features/combat/repositionCourse.ts',
  ])
  // the function that produces it
  const definers = files.filter((f) => /export function resolveRepositionCourse\b/.test(src(f)))
  expect(definers).toEqual(['features/combat/repositionCourse.ts'])
  // …read by exactly the surfaces below, and no third private copy.
  //
  // THE THIRD READER IS NOT A THIRD SURFACE. map/fleetStatusModel calls the resolver as a PREDICATE
  // and nothing else: the map's fleet readout says "In combat — moving into position" and lets the
  // card three inches above it print the distance. Its licence is the assertion right below this
  // one, which holds it to strictly less than the two mounts are allowed — it may not name a column,
  // measure a distance, or restate a single word of the sentence.
  const readers = files.filter(
    (f) => f !== 'features/combat/repositionCourse.ts' && src(f).includes('resolveRepositionCourse('),
  )
  expect(readers.sort()).toEqual([
    'features/combat/ActiveCombatPanel.tsx',
    'features/map/CombatMapCard.tsx',
    'features/map/fleetStatusModel.ts',
  ])
})

test('the fleet readout reads the course as a PREDICATE — it prints not one word of the sentence', () => {
  // The map's fleet panel composes the existence rule ("is a course running?") and stops there. If it
  // ever starts printing the distance it becomes a second fight readout on a screen that already has
  // one, which is the duplication the whole slice was written to avoid.
  const code = codeOnly(src('features/map/fleetStatusModel.ts'))
  for (const forbidden of ['reposition_x', 'reposition_y', 'Math.hypot', 'units to go', 'Moving to']) {
    expect(code, `the fleet readout must not re-derive ${forbidden}`).not.toContain(forbidden)
  }
  // …and it never reaches for `.text`/`.remaining` off the view — the predicate is the whole use.
  expect(code).toMatch(/resolveRepositionCourse\(encounter\)\s*\?/)
})

test('the Mission panel keeps its mount — the map is a second VIEW, not a move', () => {
  // Fixing the map by emptying the Mission screen would trade one silent surface for another.
  expect(panel).toContain('resolveRepositionCourse(encounter)')
  expect(panel).toContain('combat-panel-reposition')
})

test('leaving the fight is not crowded: RetreatControl stays last and stays reachable', () => {
  // Map-UX law — nothing may displace or shrink the one control that stops the fight. The course
  // line is a single 11px paragraph above it, in the same corner card.
  expect(card).toContain('<RetreatControl')
  const code = codeOnly(card)
  expect(
    code.indexOf('{course.text}'),
    'the course line must sit above the retreat control, never after it',
  ).toBeLessThan(code.indexOf('<RetreatControl'))
  // still the card's final element, with its own spacing untouched
  expect(code).toMatch(/<RetreatControl[\s\S]*className="mt-3"[\s\S]*<\/OverlayPanel>/)
})
