// COMBAT PHASE — the ONE derivation of "what is this encounter doing right now".
//
// WHY THIS FILE EXISTS. A live encounter has three phases and the server signals them through
// columns that must be read TOGETHER, not one at a time:
//
//   status = 'retreating'          -> the fleet is breaking off (still taking fire)
//   enemy_integrity_current <= 0   -> the enemy side is EMPTY right now
//
// The second one is the trap. `process_combat_ticks` clears the enemy side to zero the moment the
// field is emptied; while it is empty EVERY enemy number on the row is a placeholder zero. A surface
// that prints them without knowing why tells the player "ENEMY 0 ships · integrity 0/285" and
// explains nothing. ActiveCombatPanel already derived all of this inline; CombatMapCard never got it
// and showed the zeros. This module is that derivation, extracted — ONE authority, composed by every
// surface. None may re-derive it: the phase spec asserts the raw column reads appear here and nowhere
// else.
//
// ── ██ THE CLOCK THAT USED TO LIVE HERE IS DELETED ██ ────────────────────────────────────────────
// `nextWaveSeconds` / `nextWaveText` counted down to `combat_encounters.next_wave_at`. Migration 0344
// deleted the wave PAUSE from both arms of the tick ("the next_wave_at pause, which exists to pace a
// thing that no longer happens" — its own deletion list, item 7) but left the tail UPDATE that STAMPS
// the column (0299:999) in place. So next_wave_at is still written and read by NOBODY, and a client
// counting down to it was counting down to a moment at which nothing is scheduled to happen — a
// plausible countdown that lies, which is worse than a frozen number.
//
// The real clock is the pressure clock, and it is its own leaf: `combat/reinforcementClock.ts`. The
// phase stays a pure function of the row and still needs no time at all, which is exactly why the
// countdown was never part of it.
//
// PURE. No React, no clock of its own, no fetch, no combat math — it decides nothing the server has
// not already decided, it only names what the row says.

/** The three phases a live encounter can be in, in the precedence the panels have always used. */
export type CombatPhase = 'retreating' | 'next_wave' | 'fighting'

/** The row fields the phase is derived from — kept structural so both CombatEncounter and a test
 *  fixture satisfy it without either surface passing a whole encounter it does not need to. */
export interface CombatPhaseInput {
  status: string
  enemy_integrity_current: number
}

export interface CombatPhaseView {
  /** Retreating wins over between-waves wins over fighting. */
  phase: CombatPhase
  /** The one label both surfaces print: 'Retreating' | 'Next wave incoming' | 'In combat'. */
  label: string
  /** status === 'retreating'. A retreating fleet is still in the fight and still takes damage. */
  isRetreating: boolean
  /** THE FIELD IS EMPTY RIGHT NOW. While true, enemy_integrity_current, enemy_integrity_max and the
   *  enemy alive-count are ALL placeholder zeros and no surface may print them — say "next wave
   *  incoming" instead, which is honest here for a reason worth stating: the engine spawns on a due
   *  slot only while `population < effective_cap`, and an empty field is under every cap there is.
   *  Deliberately independent of isRetreating: a fleet retreating across an empty field faces the
   *  same placeholder zeros. */
  betweenWaves: boolean
}

/** Decide an encounter's phase. Pure function of the row; no clock involved. */
export function selectCombatPhase(encounter: CombatPhaseInput): CombatPhaseView {
  const isRetreating = encounter.status === 'retreating'
  const betweenWaves = encounter.enemy_integrity_current <= 0
  const phase: CombatPhase = isRetreating ? 'retreating' : betweenWaves ? 'next_wave' : 'fighting'
  return { phase, label: PHASE_LABEL[phase], isRetreating, betweenWaves }
}

/** The one phrase for the inter-wave pause, so every surface says the same thing. */
export const NEXT_WAVE_INCOMING = 'Next wave incoming'

const PHASE_LABEL: Record<CombatPhase, string> = {
  retreating: 'Retreating',
  next_wave: NEXT_WAVE_INCOMING,
  fighting: 'In combat',
}
