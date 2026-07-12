// C2-3 — PURE captain-progression helpers (no React/DOM/fetch; the haulBoard/teamCaptains idiom).
//
// Mirrors the SERVER curve exactly (migration 0177, maintained inline by captain_xp_accrue):
//     level = 1 + floor(sqrt(xp / 100))
// so the client-side thresholds are xpForLevel(L) = (L−1)² × 100 (level 2 at 100 xp, 3 at 400,
// 4 at 900, …). DISPLAY-ONLY: the server's level column stays authoritative — captainProgress()
// trusts the SERVER level and clamps the xp-into-level fraction to [0,1] even if xp and level
// momentarily disagree (a mid-accrual read); the client never "corrects" a level.
//
// THE DARK STORY (captainProgressVisible): while captain_growth_enabled is false the accrual (the
// sole xp/level writer) has never run, so every captain projects xp=0/level=1 — and a level-1
// 0-xp captain shows NO bar (visible=false) unless the caller explicitly passes growthVisible
// (a future lit-flag signal; no client flag constant exists today). Rows whose projection does
// not carry xp/level at all (a pre-0181 envelope) are never visible. So today's UI is
// byte-identical. Unit-tested in tests/captainProgress.spec.ts.

/** The [D] curve base (0177): level thresholds are (level−1)² × this. */
export const XP_LEVEL_BASE = 100

/** Lifetime xp at which `level` begins: (level−1)² × 100. Levels below 1 clamp to 1 (→ 0 xp). */
export function xpForLevel(level: number): number {
  const lv = Number.isFinite(level) ? Math.max(1, Math.floor(level)) : 1
  return (lv - 1) * (lv - 1) * XP_LEVEL_BASE
}

/** The server curve, client-side: 1 + floor(sqrt(xp / 100)); non-finite/negative xp → 1. */
export function levelForXp(xp: number): number {
  if (!Number.isFinite(xp) || xp <= 0) return 1
  return 1 + Math.floor(Math.sqrt(xp / XP_LEVEL_BASE))
}

export interface CaptainProgress {
  /** The (server-authoritative) level, floored to an integer ≥ 1. */
  level: number
  /** Lifetime xp at this level's start / the next level's threshold. */
  floorXp: number
  nextXp: number
  /** xp earned inside this level, clamped to [0, span]. */
  intoLevel: number
  /** xp this level spans (nextXp − floorXp; always > 0). */
  span: number
  /** intoLevel / span — the bar fill, clamped to [0, 1]. */
  fraction: number
}

/** Progress toward the next level from the SERVER-projected (xp, level) pair. Defensive: a
 *  malformed level falls back to 1, a malformed xp to 0, and intoLevel clamps into the level's
 *  span (the server level wins over a momentarily-disagreeing xp). */
export function captainProgress(xp: number, level: number): CaptainProgress {
  const lv = Number.isFinite(level) && level >= 1 ? Math.floor(level) : 1
  const x = Number.isFinite(xp) && xp > 0 ? xp : 0
  const floorXp = xpForLevel(lv)
  const nextXp = xpForLevel(lv + 1)
  const span = nextXp - floorXp
  const intoLevel = Math.min(Math.max(0, x - floorXp), span)
  return { level: lv, floorXp, nextXp, intoLevel, span, fraction: intoLevel / span }
}

/** Render gate for the XP bar/level chip: the projection must CARRY finite xp/level (post-0181
 *  envelopes only), level ≥ 1, and there must be something to show — xp > 0, level > 1, or an
 *  explicit growthVisible signal. While captain_growth_enabled is false every captain is
 *  level-1/0-xp and growthVisible is never passed → nothing renders (the dark story). */
export function captainProgressVisible(
  c: { xp?: number | null; level?: number | null },
  growthVisible = false,
): boolean {
  const { xp, level } = c
  if (typeof xp !== 'number' || !Number.isFinite(xp)) return false
  if (typeof level !== 'number' || !Number.isFinite(level)) return false
  if (level < 1) return false
  return xp > 0 || level > 1 || growthVisible
}
