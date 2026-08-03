import type { CombatEvent } from './combatTypes'

// THE BATTLE FEED'S ROW SELECTION — pure, so it lives beside the component rather than inside it.

const waveOf = (e: CombatEvent): string => {
  const w = e.payload_json?.['wave']
  return `${e.encounter_id}:${typeof w === 'number' ? w : Number(w ?? 0)}`
}

/**
 * The feed rows, newest first, with each WAVE announced exactly once.
 *
 * Production emits `wave_spawned` for wave 1 TWICE — verified on live encounters, one row at t0 and
 * one at t1 — so the very first thing the feed ever said, it said twice, which reads as two waves
 * arriving and tells a new player they are already behind. Collapsing repeats of the same
 * (encounter, wave) is presentation, not truth-editing: the second row carries no fact the first did
 * not. The duplicate EMISSION is a server defect and is reported as one; this only stops the feed
 * repeating it.
 *
 * Every other event type passes through untouched. Two hull_damage rows really are two hits, and
 * merging those is precisely the defect the map's splats were rewritten to undo — so the dedupe is
 * deliberately keyed to `wave_spawned` alone and never generalised.
 */
export function feedRows(events: readonly CombatEvent[], limit = 14): CombatEvent[] {
  const seenWave = new Set<string>()
  const out: CombatEvent[] = []
  for (const e of events.slice().sort((a, b) => b.id - a.id)) {
    if (e.event_type === 'wave_spawned') {
      const key = waveOf(e)
      if (seenWave.has(key)) continue
      seenWave.add(key)
    }
    out.push(e)
    if (out.length >= limit) break
  }
  return out
}
