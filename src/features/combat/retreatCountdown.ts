// THE RETREAT COUNTDOWN — the ONE derivation of "how long until this fleet is out", and the ONE
// place that decides what to say when nobody knows.
//
// ── THE MEASURED DEFECT ────────────────────────────────────────────────────────────────────────────
// MissionScreen used to hand the panel `game.config['retreat_delay_seconds'] ?? 20`. Three facts
// make that a confident lie rather than a harmless default:
//   · the LIVE value is 8, not 20 — migration 20260617000028_retreat_delay_8s.sql sets the row to
//     '8', and every combat tick since has read `coalesce(cfg_num('retreat_delay_seconds'), 8)`
//     (0299:429, 0310, 0316…). The 20 was 0016/0020's number, retired years of migrations ago. So
//     the fallback was not "roughly right"; it was 2.5x the real window.
//   · fetchGameConfig (lib/catalog.ts:33-41) builds a plain record from whatever rows came back, so
//     a key is simply ABSENT on a partial read — `??` cannot tell "missing" from "never fetched".
//   · the number is read at the single worst moment in the game: the player is deciding whether
//     they can get out before the next exchange lands. A countdown that says 20 when the fleet
//     actually breaks away at 8 does not merely mislead — it invites them to sit in the fight.
//
// ── THE RULE ───────────────────────────────────────────────────────────────────────────────────────
// AN UNKNOWN RENDERS AS NO CLAIM, NEVER AS A PLAUSIBLE NUMBER — the repairEconomy.ts posture
// (foldRepairRate returns null and the desk shows an em-dash rather than a price it cannot stand
// behind, ship/repairEconomy.ts:48-51). There is deliberately NO arithmetic path from a missing
// config value to a displayed number here: the fold answers null, the resolver short-circuits on
// null BEFORE it touches the clock, and the sentence it returns contains no duration at all.
//
// Nothing here mirrors the server's retreat RULE — the engine owns when the fleet actually leaves
// (`now() - retreat_started_at >= retreat_delay_seconds`). This states the server's own window back
// to the player, or says nothing about it.
//
// PURE. No React, no fetch, no clock: `nowMs` is passed in.

/**
 * Fold a public-read `game_config.retreat_delay_seconds` value → a non-negative number of seconds,
 * or null when the key is absent / unreadable / junk / negative.
 *
 * ZERO IS A REAL WINDOW (the fleet breaks away on the next tick) and folds to 0, not to null — the
 * foldRepairRate distinction between "the owner set it to nothing" and "we never read it".
 */
export function foldRetreatDelaySeconds(value: unknown): number | null {
  const n = value === null || value === undefined || value === '' ? NaN : Number(value)
  return Number.isFinite(n) && n >= 0 ? n : null
}

export interface RetreatCountdownView {
  /** whole seconds until the fleet breaks away, or null when the window is UNKNOWN — the surface
   *  must print no duration in that case, and `text` already doesn't. */
  secondsLeft: number | null
  /** the one sentence every retreating surface prints. */
  text: string
}

/** What the fleet is told when the retreat window cannot be known: that it is leaving and that it
 *  is still in danger — both true from the encounter row alone — and not one word about when. */
const NO_WINDOW_TEXT =
  'Retreating — your fleet is breaking away. Warning: it can still take damage until it escapes.'

const withCount = (left: string) =>
  `Retreating — fleet breaks away in ${left}. Warning: it can still take damage until it escapes.`

/**
 * The retreat sentence for one encounter that is ALREADY retreating (the caller owns that gate —
 * combatPhase.selectCombatPhase is its one authority; nothing here re-reads `status`).
 *
 * Null delay, or a retreat start the client cannot read, → the no-window sentence. Both are the
 * same kind of unknown and neither is allowed to reach the clock: `secondsLeft` stays null.
 */
export function resolveRetreatCountdown(args: {
  retreatStartedAt: string | null
  delaySeconds: number | null
  nowMs: number
}): RetreatCountdownView {
  const { retreatStartedAt, delaySeconds, nowMs } = args
  if (delaySeconds === null || !Number.isFinite(delaySeconds)) {
    return { secondsLeft: null, text: NO_WINDOW_TEXT }
  }
  const startedMs = retreatStartedAt === null ? NaN : new Date(retreatStartedAt).getTime()
  if (!Number.isFinite(startedMs) || !Number.isFinite(nowMs)) {
    return { secondsLeft: null, text: NO_WINDOW_TEXT }
  }
  const left = Math.ceil(delaySeconds - (nowMs - startedMs) / 1000)
  // Past the window (or a clock that disagrees) is not an unknown — the fleet IS leaving, and the
  // server's next tick completes it. "a moment…" is the existing copy for exactly that state.
  return { secondsLeft: left, text: withCount(left > 0 ? `${left}s` : 'a moment…') }
}
