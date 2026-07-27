// COMBAT PHASE — the ONE derivation of "what is this encounter doing right now".
//
// WHY THIS FILE EXISTS. A live encounter has three phases and the server signals them through
// columns that must be read TOGETHER, not one at a time:
//
//   status = 'retreating'          -> the fleet is breaking off (still taking fire)
//   enemy_integrity_current <= 0   -> the enemy side is WIPED and the next wave has not spawned yet
//   next_wave_at                   -> when it will
//
// The middle one is the trap. `process_combat_ticks` clears the enemy side to zero the moment a wave
// is cleared and stamps next_wave_at = now() + wave_transition_seconds (default 3s); for those few
// seconds EVERY enemy number on the row is a placeholder zero. A surface that prints them without
// knowing why tells the player "ENEMY 0 ships · integrity 0/285" and explains nothing.
// ActiveCombatPanel already derived all of this inline; CombatMapCard never got it and showed the
// zeros. This module is that derivation, extracted — ONE authority, composed by both surfaces.
// Neither may re-derive it: the phase spec asserts the raw column reads appear here and nowhere else.
//
// THE CLOCK IS DELIBERATELY SEPARATE. The phase itself is a pure function of the row and needs no
// clock at all, so a surface that shows no countdown (the map card, which is a glanceable corner
// readout) never has to invent one. Only the countdown needs the time, and it is its own leaf.
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
  /** The enemy side is wiped and the next wave has not spawned. While true, enemy_integrity_current,
   *  enemy_integrity_max and the enemy alive-count are ALL placeholder zeros and no surface may
   *  print them — say "next wave incoming" instead. Deliberately independent of isRetreating: a
   *  fleet that retreats between waves faces the same placeholder zeros. */
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

/**
 * Whole seconds until the next wave lands — the ONLY clock-dependent part of the phase, so the
 * caller supplies `nowMs` (a ticking clock, never a read taken during render). Returns 0 when the
 * server recorded no next_wave_at, and goes 0-or-negative once the moment has passed but the 3s cron
 * has not yet spawned the wave; callers render a countdown only while it is > 0.
 */
export function nextWaveSeconds(encounter: { next_wave_at: string | null }, nowMs: number): number {
  return encounter.next_wave_at
    ? Math.ceil((new Date(encounter.next_wave_at).getTime() - nowMs) / 1000)
    : 0
}

/**
 * The pause copy. Pass `null` from a surface that deliberately shows no countdown — the map card is
 * a corner readout and a second-by-second number there is noise, not information.
 */
export function nextWaveText(seconds: number | null): string {
  return seconds !== null && seconds > 0
    ? `${NEXT_WAVE_INCOMING} in ${seconds}s…`
    : `${NEXT_WAVE_INCOMING}…`
}
