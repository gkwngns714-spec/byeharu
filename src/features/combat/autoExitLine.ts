// THE SAFETY LINE, MADE VISIBLE — the ONE derivation of "when does this fleet pull itself out?".
//
// ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────────────────
// Migration 0310 gave every fleet an automatic exit: `ship_groups.auto_exit_enabled` +
// `auto_exit_hp_pct` (default ON at 30%). The tick reads them fresh every 3 seconds and calls
// `presence_request_leave` the moment remaining hull falls to or below the line (0310:427-450).
// It decided real fights in production and NOTHING in the client ever said so: `grep auto_exit
// src/features/combat/` returned zero hits. A fleet that entered a fight already under its
// threshold auto-exited on tick 1 — which 0310's own header calls out as deliberate and protective
// (:423-425) — and the player saw a battle end for no stated reason.
//
// ── THE DENOMINATOR IS NOT GUESSED ─────────────────────────────────────────────────────────────────
// 0310's live denominator is `sum(main_ship_instances.max_hp)` over the encounter's own player
// member units (0310:445-448). Since 0331 that is EXACTLY `combat_encounters.player_integrity_max`:
// the builder seeds `combat_units.hp_max` from `m.max_hp` (0331:551) and the encounter's
// `player_integrity_max` is the sum of it (0331:580-582), which 0331's own comment states in those
// words — "player_integrity_max equals 0310's live denominator exactly" (:579). So the threshold
// below is read off the encounter row the client already has; no capacity is re-derived, no hp is
// re-summed, and nothing here computes combat.
//
// PURE. No React, no fetch, no clock. It states what the row and the setting already say.

/** The fleet's 0310 setting, as `ship_groups` stores it. */
export interface AutoExitSetting {
  enabled: boolean
  /** percent of FULL CAPACITY, CHECK-constrained to [5,95] by the table (0310:246-247) */
  pct: number
}

/** The encounter fields the line is read from — structural so a fixture satisfies it without
 *  passing a whole row. */
export interface AutoExitEncounterInput {
  status: string
  player_integrity_current: number
  player_integrity_max: number
}

export interface AutoExitLineView {
  /** the configured percent, verbatim */
  pct: number
  /** the hull value the fleet breaks off at — capacity × pct/100, in the SAME units as the bar */
  hull: number
  /** hull ÷ capacity, i.e. pct/100 clamped to [0,1] — where to draw the tick on a 0..1 bar */
  frac: number
  /** the fleet is AT or BELOW its line right now: the next tick pulls it out (or already has) */
  reached: boolean
  /** not there yet, but within a quarter of the line — the "brace" state, so the player can act
   *  BEFORE the decision is taken away from them */
  close: boolean
  /** the one sentence every surface prints. Never claims causation for a retreat it cannot see the
   *  cause of — it states the fleet's position relative to the line and what the line does. */
  text: string
}

/** How far above the line still counts as "close" — a quarter of the threshold. Chosen so a fleet
 *  gets roughly one exchange of warning at the damage rates the tick deals, not so wide that the
 *  warning is on for most of a healthy fight. */
export const AUTO_EXIT_CLOSE_MARGIN = 0.25

/**
 * The visible safety line for one encounter, or null when there is nothing honest to say:
 * the setting is unknown (never read, or the read failed), the fleet has it switched OFF, or the
 * encounter carries no usable capacity. Null means "say nothing" — never "no line".
 */
export function resolveAutoExitLine(
  encounter: AutoExitEncounterInput,
  setting: AutoExitSetting | null | undefined,
): AutoExitLineView | null {
  if (!setting || !setting.enabled) return null
  const pct = setting.pct
  if (!Number.isFinite(pct) || pct <= 0 || pct >= 100) return null
  const cap = encounter.player_integrity_max
  if (!Number.isFinite(cap) || cap <= 0) return null
  const cur = encounter.player_integrity_current
  if (!Number.isFinite(cur)) return null

  const hull = cap * (pct / 100)
  const reached = cur <= hull
  const close = !reached && cur <= hull * (1 + AUTO_EXIT_CLOSE_MARGIN)
  const pctText = `${Math.round(pct)}%`
  const hullText = Math.round(hull).toLocaleString()

  const text = reached
    ? encounter.status === 'retreating'
      ? `Below the ${pctText} line — your fleet is breaking off.`
      : `At the ${pctText} line — your fleet pulls out on the next exchange.`
    : close
      ? `Close to the ${pctText} auto-retreat line (${hullText} hull).`
      : `Auto-retreat at ${pctText} hull (${hullText}).`

  return { pct, hull, frac: Math.max(0, Math.min(1, pct / 100)), reached, close, text }
}
