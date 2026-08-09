import type { CombatUnit } from './combatTypes'

// ██ THE REINFORCEMENT CLOCK — the ONE derivation of "when does the next body come, and how full is
//    the field right now". ██
//
// ── WHY THIS FILE EXISTS, AND WHAT IT REPLACES ─────────────────────────────────────────────────────
// The client used to count down to `combat_encounters.next_wave_at`. That column is DEAD as a clock:
// migration 0344 deleted the wave pause from BOTH arms of the tick ("the next_wave_at pause, which
// exists to pace a thing that no longer happens" — 0344's own deletion list, item 7), while the tail
// UPDATE that STAMPS it (`next_wave_at = case when v_cleared then now() + wave_transition_seconds …`,
// 0299:999) was left in place. So the column is still written and read by nobody, and a client
// counting down to it was counting down to a moment at which nothing is scheduled to happen. That is
// worse than a frozen number: it is a plausible countdown that lies.
//
// Reinforcements are a CLOCK now, and it is a different clock:
//
//   next_reinforcement_at   WHEN the next scheduled slot falls due. Sole writer combat_pressure_step.
//   pressure_wave_index     how many scheduled slots have come due at this fight. It advances on
//                           EVERY slot, including ones that spawned nothing.
//   pressure_effective_cap  how many bodies the field can hold RIGHT NOW — STAMPED by the engine in
//                           the same statement that made the spawn decision (0347). A surface SHOWS
//                           this number and never derives one, or it says "3 max" while four ships
//                           stand on the field.
//
// ── ██ WHAT THIS DELIBERATELY DOES NOT SAY: WHETHER A SHIP IS COMING ██ ────────────────────────────
// The engine's rule is `arriving := status='active' and slots_due > 0 and population < effective_cap`
// (0347, public.combat_pressure_field). Both operands are visible to the client, so the UI COULD
// compute it — and it must not, for two independent reasons:
//
//   1. IT WOULD BE A SECOND COPY OF THE ENGINE'S DECISION. One rule in two places drifts; that is the
//      defect this project keeps paying for. The server's own answer is not a forecast either:
//      `slots_due > 0` means the slot is due AT THIS INSTANT, so `arriving` is a now-answer that is
//      true only in the seconds between a slot falling due and the 3s cron firing. There is no server
//      column that says "a ship will arrive at the NEXT slot", because that depends on the field at a
//      moment that has not happened yet.
//   2. IT WOULD BE A PROMISE NOBODY CAN KEEP. A field that is full now can have a hull die two
//      seconds before the slot; a field with room now can fill. Printing "1 ship arriving" or
//      "nothing arrives" is a claim about the future, and a slot that finds the field at its cap is
//      SPENT, NOT BANKED — the player would be told a ship is owed that will never come.
//
// So this leaf reports only facts that cannot be wrong: the countdown, the ordinal, the population,
// and the cap the engine itself used. The RULE relating the last two is stated once, as a rule
// (REINFORCEMENT_RULE below) — always true, never stale — and the player reads the two numbers
// against it. What is DRAWN is the rule.
//
// FAIL CLOSED. combatApi reads `select('*')`, so a server that predates 0344/0347 simply omits these
// columns; absent or unparseable → this returns null and every surface says nothing about
// reinforcements rather than inventing a schedule. Same law as the engagement anchor and the
// standing course.
//
// PURE. No React, no fetch, no clock of its own (`nowMs` is passed in), no combat math.

/** The row fields the clock is read from — structural, so a fixture satisfies it without passing a
 *  whole encounter. */
export interface ReinforcementInput {
  next_reinforcement_at?: string | null
  pressure_wave_index?: number | null
  pressure_effective_cap?: number | null
}

export interface ReinforcementView {
  /** whole seconds until the next scheduled slot, or null once the moment has passed and the cron
   *  has not yet run. Never negative — a negative countdown is not information. */
  seconds: number | null
  /** the one sentence every surface prints for the clock. */
  text: string
  /** how many enemy bodies stand on the field, by the SAME rule the engine counts with; null when
   *  this fight carries no positioned rows and the client therefore cannot honestly count. */
  population: number | null
  /** the cap the ENGINE used, straight off the stamp. null until the fight has evaluated its first
   *  slot — show nothing then, never a guess. */
  cap: number | null
  /** how many scheduled slots have come due at this fight. Not a count of arrivals. */
  slot: number | null
}

/** The mechanic, stated ONCE, as a mechanic. It is true at every instant, so it can never go stale
 *  the way a per-slot verdict would. Every surface that shows the field prints this and no surface
 *  predicts an arrival. */
export const REINFORCEMENT_RULE =
  'A wave brings one more ship only while the field is under its limit. A wave that finds it full is spent, not saved.'

/** The heading both surfaces use for this section, so the fight is described in one vocabulary — and
 *  it is the owner's own word ("next wave incoming"), which is also the engine's: the ordinal this
 *  section prints is `pressure_wave_index`. */
export const REINFORCEMENT_LABEL = 'Next wave'

/**
 * How many enemy bodies are standing, by the engine's own predicate:
 * `sum(alive_count) where side='enemy' and alive_count > 0` (0347, public.combat_pressure_field).
 *
 * Returns null for an encounter with NO positioned rows. The engine's other arm derives a population
 * from scalar integrity there; the client has no honest way to reproduce that (it would need the
 * site's nominal body hp), so it declines rather than guessing — and the caller then shows no field
 * count at all.
 */
export function fieldPopulation(units: readonly CombatUnit[], encounterId: string): number | null {
  const mine = units.filter((u) => u.encounter_id === encounterId)
  const bodied = mine.some((u) => u.pos_x !== null && u.pos_x !== undefined)
  if (!bodied) return null
  let n = 0
  for (const u of mine) {
    if (u.side !== 'enemy') continue
    const alive = u.alive_count ?? 0
    if (alive > 0) n += alive
  }
  return n
}

/**
 * Does this row carry a pressure clock at all?
 *
 * The SAME test resolveReinforcement applies below, exported so a surface can decide whether to run a
 * ticking clock without reading the raw column itself. Without it a caller ends up writing
 * `typeof e.next_reinforcement_at === 'string'` in its own body, which is a second reading of the
 * contract and the first step toward a second countdown.
 */
export function hasReinforcementClock(encounter: ReinforcementInput): boolean {
  const stamp = encounter.next_reinforcement_at
  return typeof stamp === 'string' && stamp !== '' && Number.isFinite(new Date(stamp).getTime())
}

/**
 * The reinforcement readout for one encounter, or null when the row carries no pressure clock at all.
 *
 * `nowMs` is supplied by the caller (a ticking clock, never a `Date.now()` read taken during render).
 */
export function resolveReinforcement(
  encounter: ReinforcementInput,
  units: readonly CombatUnit[],
  encounterId: string,
  nowMs: number,
): ReinforcementView | null {
  if (!hasReinforcementClock(encounter)) return null
  const due = new Date(encounter.next_reinforcement_at as string).getTime()

  const raw = Math.ceil((due - nowMs) / 1000)
  const seconds = raw > 0 ? raw : null

  const cap = finiteOrNull(encounter.pressure_effective_cap)
  const slot = finiteOrNull(encounter.pressure_wave_index)

  return {
    seconds,
    // Past due is a REAL state and it is short: the slot has fallen due and the 3-second cron has
    // not run yet. Saying "due now" is honest; continuing to count down into negatives is not.
    text: seconds === null ? 'Next wave due now' : `Next wave in ${seconds}s`,
    population: fieldPopulation(units, encounterId),
    cap,
    slot,
  }
}

const finiteOrNull = (v: number | null | undefined): number | null =>
  typeof v === 'number' && Number.isFinite(v) ? v : null
