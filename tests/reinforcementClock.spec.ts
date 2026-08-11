import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  REINFORCEMENT_LABEL,
  REINFORCEMENT_RULE,
  fieldPopulation,
  resolveReinforcement,
} from '../src/features/combat/reinforcementClock'
import type { CombatUnit } from '../src/features/combat/combatTypes'

// ██ THE REINFORCEMENT CLOCK — pure unit proof of the clock that REPLACED a dead one. ██
//
// The client used to count down to `combat_encounters.next_wave_at`. Migration 0344 deleted the wave
// pause that column paced (its own deletion list, item 7) and left the tail UPDATE that stamps it
// standing (0299:999) — so the column is written and read by nobody, and the countdown pointed at a
// moment when nothing is scheduled to happen. Every property the old countdown's tests held
// (rounding up, never NaN, the past-due state, advancing only with the supplied clock) is re-proved
// here against the clock that is real, plus the one that matters most and had no test at all:
//
//   ██ THE UI NEVER SAYS WHETHER A SHIP IS COMING. ██
//
// The engine's rule is `status='active' and slots_due > 0 and population < effective_cap` (0347,
// public.combat_pressure_field). Both operands are visible to the client, so it COULD compute it —
// and it must not: one rule in two places drifts, and the answer is about a moment that has not
// happened (a full field can lose a hull two seconds before the slot). A slot that finds the field at
// its cap is SPENT, NOT BANKED, so a promise of an arrival is a debt nobody owes.
//
// No browser, no page, no DB. Run: `npx playwright test reinforcementClock.spec.ts`.

const NOW = Date.parse('2026-08-09T12:00:00Z')
const at = (secondsFromNow: number) => new Date(NOW + secondsFromNow * 1000).toISOString()

const ENC = 'enc-1'
const row = (over: Record<string, unknown> = {}) => ({
  next_reinforcement_at: at(12),
  pressure_wave_index: 4,
  pressure_effective_cap: 4,
  pressure_next_wave_size: 2,
  ...over,
})

const unit = (over: Partial<CombatUnit>): CombatUnit =>
  ({
    id: `u-${Math.random()}`,
    encounter_id: ENC,
    unit_type_id: 'pirate_raider',
    ship_hp: 10,
    initial_count: 1,
    alive_count: 1,
    hp_max: 10,
    hp_current: 10,
    pos_x: 500,
    pos_y: 500,
    side: 'enemy',
    ...over,
  }) as CombatUnit

// ── THE COUNTDOWN ────────────────────────────────────────────────────────────────────────────────

test('no recorded next_reinforcement_at → NOTHING, never a guessed schedule', () => {
  // Fail closed: a pre-0344 server simply omits the column, and the surface then says nothing about
  // reinforcements rather than inventing one.
  expect(resolveReinforcement(row({ next_reinforcement_at: null }), [], ENC, NOW)).toBeNull()
  expect(resolveReinforcement(row({ next_reinforcement_at: undefined }), [], ENC, NOW)).toBeNull()
  expect(resolveReinforcement(row({ next_reinforcement_at: '' }), [], ENC, NOW)).toBeNull()
  expect(resolveReinforcement(row({ next_reinforcement_at: 'not-a-date' }), [], ENC, NOW)).toBeNull()
})

test('seconds round UP, so a 2.1s wait never reads as 2s and then stalls', () => {
  expect(resolveReinforcement(row({ next_reinforcement_at: at(2.1) }), [], ENC, NOW)!.seconds).toBe(3)
})

test('a live countdown reads with the seconds, in the owner’s own word', () => {
  const v = resolveReinforcement(row({ next_reinforcement_at: at(3) }), [], ENC, NOW)!
  expect(v.seconds).toBe(3)
  expect(v.text).toBe('Next wave in 3s')
})

test('past due is a REAL state and it says so — it never counts into negatives', () => {
  // The slot has fallen due and the 3-second cron has not run yet. That is a short, honest state.
  const v = resolveReinforcement(row({ next_reinforcement_at: at(-4) }), [], ENC, NOW)!
  expect(v.seconds).toBeNull()
  expect(v.text).toBe('Next wave due now')
})

test('the countdown advances with the supplied clock and nothing else', () => {
  const e = row({ next_reinforcement_at: at(3) })
  expect(resolveReinforcement(e, [], ENC, NOW)!.seconds).toBe(3)
  expect(resolveReinforcement(e, [], ENC, NOW + 1000)!.seconds).toBe(2)
})

// ── THE CAP IS SHOWN, NEVER DERIVED ──────────────────────────────────────────────────────────────

test('the effective cap is the ENGINE’s stamp, passed straight through', () => {
  expect(resolveReinforcement(row({ pressure_effective_cap: 7 }), [], ENC, NOW)!.cap).toBe(7)
})

test('a cap the fight has not evaluated yet is NULL — show nothing, never a guess', () => {
  // 0347: pressure_effective_cap is null until the first slot has been evaluated. A client that
  // filled that in with the site's base cap would say "3 max" while four ships stood on the field.
  for (const bad of [null, undefined, Number.NaN]) {
    expect(resolveReinforcement(row({ pressure_effective_cap: bad }), [], ENC, NOW)!.cap).toBeNull()
  }
})

// ── THE WAVE'S SIZE IS SHOWN, NEVER DERIVED (0350) ───────────────────────────────────────────────

test('the next wave’s SIZE is the ENGINE’s stamp, passed straight through', () => {
  // 0350: the wave itself grows — 1 + floor(ordinal / growth_every), stamped onto
  // combat_encounters.pressure_next_wave_size by public.combat_pressure_step. Before it, every slot
  // delivered exactly one body no matter how high the ceiling climbed, which is the defect the owner
  // caught ("only 1 ships are comming out from the city").
  expect(resolveReinforcement(row({ pressure_next_wave_size: 3 }), [], ENC, NOW)!.waveSize).toBe(3)
  expect(resolveReinforcement(row({ pressure_next_wave_size: 1 }), [], ENC, NOW)!.waveSize).toBe(1)
})

test('a size the fight has not evaluated yet is NULL — show nothing, never a guess', () => {
  // The stamp is NULL until this fight's first slot has been evaluated, and on any pre-0350 server
  // the column is simply absent from `select('*')`. Same fail-closed law as the cap.
  for (const bad of [null, undefined, Number.NaN]) {
    expect(resolveReinforcement(row({ pressure_next_wave_size: bad }), [], ENC, NOW)!.waveSize).toBeNull()
  }
  const { pressure_next_wave_size: _dropped, ...preServer } = row()
  expect(resolveReinforcement(preServer, [], ENC, NOW)!.waveSize).toBeNull()
})

test('the size is READ, never re-banded — the ordinal cannot be used to compute it', () => {
  // The band needs `growth_every`, which is deliberately NOT on the wire. A leaf that derived the
  // size from the ordinal would be a second authority saying "1 ship" while three come out of the
  // city, so a stamp of 2 at ordinal 9 is reported as 2 and the ordinal is never consulted.
  const v = resolveReinforcement(row({ pressure_wave_index: 9, pressure_next_wave_size: 2 }), [], ENC, NOW)!
  expect(v.slot).toBe(9)
  expect(v.waveSize).toBe(2)
})

test('the ordinal is the SCHEDULED slot count, passed through as-is', () => {
  expect(resolveReinforcement(row({ pressure_wave_index: 6 }), [], ENC, NOW)!.slot).toBe(6)
  expect(resolveReinforcement(row({ pressure_wave_index: 0 }), [], ENC, NOW)!.slot).toBe(0)
  expect(resolveReinforcement(row({ pressure_wave_index: null }), [], ENC, NOW)!.slot).toBeNull()
})

// ── THE POPULATION, BY THE ENGINE'S OWN PREDICATE ────────────────────────────────────────────────

test('population sums alive_count over ENEMY rows — a unit row is a STACK, not one ship', () => {
  const units = [
    unit({ side: 'enemy', alive_count: 2 }),
    unit({ side: 'enemy', alive_count: 1 }),
    unit({ side: 'player', alive_count: 4 }),
  ]
  expect(fieldPopulation(units, ENC)).toBe(3)
})

test('a destroyed enemy row counts for nothing', () => {
  const units = [unit({ side: 'enemy', alive_count: 0 }), unit({ side: 'enemy', alive_count: 2 })]
  expect(fieldPopulation(units, ENC)).toBe(2)
})

test('rows of ANOTHER encounter are not this fight’s field', () => {
  const units = [unit({ side: 'enemy', alive_count: 3, encounter_id: 'enc-other' }), unit({ side: 'enemy', alive_count: 1 })]
  expect(fieldPopulation(units, ENC)).toBe(1)
})

test('an encounter with NO positioned rows declines to count rather than guessing', () => {
  // The engine's other arm derives a population from scalar integrity; reproducing that needs the
  // site's nominal body hp, which the client does not have. Null → the surface shows no field count.
  const units = [unit({ side: 'enemy', alive_count: 2, pos_x: null, pos_y: null })]
  expect(fieldPopulation(units, ENC)).toBeNull()
  expect(resolveReinforcement(row(), units, ENC, NOW)!.population).toBeNull()
})

test('an empty field is 0, which is a NUMBER — not "unknown"', () => {
  // The distinction is load-bearing: 0 of 4 is the most informative state the readout ever shows.
  const units = [unit({ side: 'enemy', alive_count: 0 }), unit({ side: 'player', alive_count: 2 })]
  expect(fieldPopulation(units, ENC)).toBe(0)
})

// ── ██ THE REFUSAL ██ ────────────────────────────────────────────────────────────────────────────

test('the view carries NO verdict about the next slot — only the two operands and the rule', () => {
  // A field standing exactly AT its cap: the state where a client-side computation would be most
  // tempted to say "nothing arrives", and where it would be most wrong.
  const units = [unit({ side: 'enemy', alive_count: 4 })]
  const v = resolveReinforcement(row({ pressure_effective_cap: 4 }), units, ENC, NOW)!
  expect(v.population).toBe(4)
  expect(v.cap).toBe(4)
  // Nothing in the shape is a verdict. If a field like this is ever added, this is where it fails.
  // waveSize is a SIZE, not a verdict: it is what the engine scheduled, not what will land.
  expect(Object.keys(v).sort()).toEqual(['cap', 'population', 'seconds', 'slot', 'text', 'waveSize'])
  expect(v.text, 'the clock states time, never an outcome').not.toMatch(/arriv|spawn|nothing|full|ship/i)
})

test('a wave BIGGER than the room left is still reported at its own size, with no verdict', () => {
  // The engine clamps on delivery — `least(wave_size, room)` — and a client that clamped too would
  // be a second copy of that decision, deciding it against a field that will have changed by the
  // slot. The readout states the scheduled size and the room; the rule relates them.
  const units = [unit({ side: 'enemy', alive_count: 4 })]
  const v = resolveReinforcement(row({ pressure_effective_cap: 4, pressure_next_wave_size: 3 }), units, ENC, NOW)!
  expect(v.waveSize).toBe(3)
  expect(v.population).toBe(4)
  expect(v.cap).toBe(4)
  expect(v.text).toBe('Next wave in 12s')
})

test('the RULE is stated once, as a rule — true at every instant, so it can never go stale', () => {
  // ██ 0350 CORRECTED THIS SENTENCE. ██ It used to read "A wave brings one more ship only while the
  // field is under its limit…", and the first clause became FALSE the day the wave itself started
  // growing: a wave brings as many bodies as its band says, clamped by the room. The needles below
  // pin the corrected wording, and the refusal below pins that the old clause cannot come back.
  expect(REINFORCEMENT_RULE).toBe(
    'A wave brings as many ships as the field has room for. What does not fit is spent, not saved.',
  )
  expect(REINFORCEMENT_RULE).toContain('room for')
  expect(REINFORCEMENT_RULE).toContain('spent, not saved')
  expect(REINFORCEMENT_RULE, 'the pre-0350 claim of ONE ship per wave is gone').not.toMatch(/one more ship|under its limit/i)
  // It is a general statement, not a reading of any particular row.
  expect(REINFORCEMENT_RULE).not.toMatch(/\d/)
  expect(REINFORCEMENT_LABEL).toBe('Next wave')
})

// ── ONE AUTHORITY: both combat surfaces compose it ───────────────────────────────────────────────

const here = dirname(fileURLToPath(import.meta.url))
const src = (rel: string) => readFileSync(join(here, '..', 'src', rel), 'utf8')

// Probed on the CODE, not the prose: every one of these files explains in comments WHY the column is
// not read there, and a naive substring check would fail the build on that explanation.
const codeOnly = (t: string) =>
  t
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split(/\r?\n/)
    .filter((l) => !l.trim().startsWith('//'))
    .join('\n')

/** EVERY surface that says anything about the next wave. Adding one to the client means adding it
 *  here — that is what keeps "one authority" from decaying into "one authority plus a shortcut". */
const WAVE_SURFACES = [
  'features/combat/ActiveCombatPanel.tsx',
  'features/map/CombatMapCard.tsx',
  // ██ THE THIRD MOUNT, AND THE DEFECT IT FIXES ██ — owner, playing 2026-08-09: *"when a wave
  // starts, i see no timer that indicates next wave"*. The clock was never broken; it was rendered
  // only inside the two surfaces above, and the map's tab shell mounts AT MOST ONE BODY, so a player
  // on the FLEETS tab (where he was) saw `selectCombatPhase`'s timeless "Next wave incoming" and no
  // number. The pinned fight row is on screen in EVERY tab state, so the countdown joined it —
  // through this same leaf, never a fourth derivation.
  'features/map/MapOverlayTabs.tsx',
] as const

test('every surface that speaks about the next wave reads it through this leaf and re-derives nothing', () => {
  for (const rel of WAVE_SURFACES) {
    const surface = src(rel)
    expect(surface, `${rel} must compose the leaf`).toContain('resolveReinforcement(')
    expect(codeOnly(surface), `${rel} must not re-derive the countdown`).not.toContain('next_reinforcement_at')
    // …and none of them may assemble a schedule from the cadence instead of reading the stamp.
    expect(codeOnly(surface), `${rel} must not invent a schedule`).not.toMatch(/reinforcement_interval|wave_interval/)
  }
})

test('no surface — and not the leaf itself — ever names the band’s period', () => {
  // 0350 renamed `cap_growth_every` to `growth_every` and made that one column govern the WAVE's
  // size as well as the field's cap. It is not on the wire, deliberately: the ONLY honest client
  // answer is the engine's stamp, and anything that named the period would be recomputing the band.
  for (const rel of [...WAVE_SURFACES, 'features/combat/reinforcementClock.ts']) {
    expect(codeOnly(src(rel)), `${rel} must not re-band the wave size`)
      .not.toMatch(/cap_growth_every|growth_every|wave_size_ceiling/)
  }
})

test('the panel prints the wave’s SIZE beside the countdown, from the stamp', () => {
  // The size is the number the owner caught the game lying about ("only 1 ships are comming out from
  // the city"), so the surface that owns the wave section says it — reading the leaf, never a band.
  const panel = codeOnly(src('features/combat/ActiveCombatPanel.tsx'))
  expect(panel, 'the panel shows the scheduled size').toContain('wave.waveSize')
  expect(panel, 'and reads it from the leaf, not the row').not.toContain('pressure_next_wave_size')
})

test('the RULE is printed by the two surfaces that show the field, and the pinned row stays a signal', () => {
  // The rule explains the FIELD against the CAP, so it belongs wherever those two numbers are. The
  // pinned fight row deliberately carries neither — it is the one fact that decays with time, plus
  // the way out — so restating the rule there would be noise on a surface that is always on screen.
  for (const rel of ['features/combat/ActiveCombatPanel.tsx', 'features/map/CombatMapCard.tsx']) {
    expect(src(rel), `${rel} must print the rule beside the field it explains`).toContain('REINFORCEMENT_RULE')
  }
  const row = codeOnly(src('features/map/MapOverlayTabs.tsx'))
  expect(row, 'the pinned row shows no field count').not.toContain('wave.population')
  expect(row, 'the pinned row shows no cap').not.toContain('wave.cap')
  expect(row, 'the pinned row does not restate the rule').not.toContain('REINFORCEMENT_RULE')
  // It prints the leaf's OWN sentence and composes nothing of its own around it.
  expect(row).toContain('wave.text')
})

test('the leaf stays pure — no React, no clock of its own, no fetch', () => {
  const source = src('features/combat/reinforcementClock.ts')
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  expect(code, 'the strip did not eat the code').toContain('export function resolveReinforcement')
  for (const forbidden of ['react', 'Date.now(', 'setInterval', 'setTimeout', 'supabase', 'Math.random']) {
    expect(code, `reinforcementClock.ts must not contain ${forbidden}`).not.toContain(forbidden)
  }
})
