// HP AUTO-EXIT (0310) — the pure client model for the fleet's combat safety line.
//
// THE HOUSE PATTERN: this file DECIDES, the panel RENDERS, teamApi DISPATCHES. No React, no DOM,
// no IO — unit-tested in tests/teamAutoExit.spec.ts.
//
// WHAT THE FEATURE IS (the owner's core combat law): combat here has no win state — waves escalate
// forever, and the whole skill is leaving at the right moment. Each fleet (backend: ship_group)
// carries a persisted safety line: when auto-exit is ON and the fleet's remaining hull in a fight
// drops to the set percent of its ships' FULL HULL CAPACITY (the server sums
// main_ship_instances.max_hp — never the damaged hull the fleet happened to enter with, which
// would compound across un-repaired fights), the server pulls it out of combat on its own — the
// exact same retreat the Retreat button starts, risk window included. A fleet entering a fight
// already below the line therefore leaves on the FIRST tick. OFF means the pre-0310 world: it
// fights until destroyed, force-extracted, or manually retreated.
//
// THE COPY BELOW MUST SAY WHAT THE SERVER MEANS. The first draft said "drops to 30%" with no
// qualifier while the server measured the entry hull — a rule the player read one way and the
// engine ran another. tests/teamAutoExit.spec.ts pins the capacity qualifier into the sentence.
//
// THE SERVER IS THE AUTHORITY. These bounds MIRROR the ship_groups CHECK and the
// set_group_auto_exit validation ([5,95]) so the UI can disable a doomed Save — they never replace
// the server's answer. The client additionally restricts input to whole percents (a UX choice; the
// server accepts any numeric in range).

export const AUTO_EXIT_PCT_MIN = 5
export const AUTO_EXIT_PCT_MAX = 95
/** The server-side column default (0310) — what every fleet starts with. */
export const AUTO_EXIT_PCT_DEFAULT = 30

/** One fleet's persisted setting, as read from ship_groups (owner-RLS). */
export interface AutoExitSetting {
  enabled: boolean
  pct: number
}

/** Draft-percent parse: whole percents in [5,95] only. Fail-closed — anything else is invalid. */
export function parseAutoExitPct(draft: string): { ok: true; pct: number } | { ok: false } {
  const t = draft.trim()
  if (!/^\d{1,3}$/.test(t)) return { ok: false }
  const n = Number(t)
  if (!Number.isInteger(n) || n < AUTO_EXIT_PCT_MIN || n > AUTO_EXIT_PCT_MAX) return { ok: false }
  return { ok: true, pct: n }
}

/**
 * Whether the Save control should be live for a percent draft, and the hint when it isn't.
 * Save is for the PERCENT only — the toggle dispatches immediately (an off switch that waits for a
 * second button is an off switch that fails when it matters).
 */
export function autoExitSaveAvailability(
  current: AutoExitSetting,
  draft: string,
): { canSave: boolean; hint: string | null } {
  const parsed = parseAutoExitPct(draft)
  if (!parsed.ok) {
    return {
      canSave: false,
      hint: `Use a whole number from ${AUTO_EXIT_PCT_MIN} to ${AUTO_EXIT_PCT_MAX}.`,
    }
  }
  if (parsed.pct === current.pct) return { canSave: false, hint: null } // nothing to save
  return { canSave: true, hint: null }
}

/**
 * The one summary sentence the panel renders under the control. Plain words, by design law:
 * no "home", no "base", no "win", no jargon — this is a safety line, not a victory condition.
 */
export function autoExitSummary(setting: AutoExitSetting): string {
  if (!setting.enabled) {
    return 'Off — this fleet keeps fighting until you order it out or it is destroyed.'
  }
  return `This fleet pulls out of combat on its own once its hull falls to ${setting.pct}% of full strength — same retreat as the Retreat button, so it still takes fire on the way out. If it starts a fight already under the line, it leaves right away.`
}
