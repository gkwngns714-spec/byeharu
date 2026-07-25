// WORLD EDITOR — TYPED-ZONE EFFECTS: the pure client authority for what a zone DOES. Props in →
// value out. NO React, no DOM, no storage, no network — the worldEditorChrome / worldEditorDraftGuard
// pure-module idiom, unit-tested directly (tests/zoneEffects.spec.ts).
//
// THE MODEL (owner's decision, 2026-07-25 — see docs/ZONE_PLATFORM_REVIEW.md):
//     GEOMETRY  — WHERE can something happen?   (danger_zones.boundary)
//     IDENTITY  — WHAT is this zone?            (danger_zones.zone_kind)
//     EFFECTS   — WHAT does it DO, and HOW?     (this module ⟷ the zone_effect_* tables)
//
// EFFECTS ARE COMPOSABLE, NOT A SWITCH ON IDENTITY. A zone carries a SET of effects, so "a mining
// zone that also spawns" is one zone with two effects — never a new kind, never a special case.
// Presence of an effect is the existence of its config, never a NULL-riddled sentinel on the core.
//
// PARITY IS THE WHOLE POINT OF THE null SEMANTICS. Every knob is an OPTIONAL per-zone override of the
// identically-named global game_config value; `null` means "inherit the global". An all-null config
// therefore reproduces today's behaviour exactly — parity is a property of the DATA, not a promise
// about future code. `resolvePirateKnobs` is the ONE place that coalescing happens on the client, and
// it mirrors the SQL `coalesce(zone_override, global)` exactly.
//
// THE SERVER REMAINS THE AUTHORITY. `validatePirateEffect` mirrors the zone_effect_pirate CHECK
// constraints so the editor can refuse an impossible value before a round-trip, but it is ADVISORY:
// the database rejects the same values independently, and a disagreement is a bug in this file.

/** The effect kinds that exist. Grows ONE sibling at a time, each with its own table, its own runtime
 *  gate and its own slice — adding a kind never edits an existing one. */
export const ZONE_EFFECT_KINDS = ['pirate'] as const

export type ZoneEffectKind = (typeof ZONE_EFFECT_KINDS)[number]

/** Plain-language nouns (map-UX law #4/#5: the owner's words, no schema keys). */
export const ZONE_EFFECT_LABELS: Record<ZoneEffectKind, string> = {
  pirate: 'Pirate interception',
}

// ── the pirate effect ───────────────────────────────────────────────────────────────────────────

/** The five risk knobs, as OPTIONAL per-zone overrides. `null` = inherit the global.
 *  1:1 with the zone_effect_pirate columns. */
export interface PirateEffectConfig {
  readonly base_risk: number | null
  readonly min_risk: number | null
  readonly max_risk: number | null
  readonly exposure_floor: number | null
  readonly stat_reference: number | null
}

/** The config a freshly-added pirate effect starts from: inherit everything. Identical to what the
 *  0273 backfill wrote for every existing zone. */
export const EMPTY_PIRATE_EFFECT: PirateEffectConfig = {
  base_risk: null,
  min_risk: null,
  max_risk: null,
  exposure_floor: null,
  stat_reference: null,
}

/** The same five knobs with every value RESOLVED (no nulls) — what the risk curve actually reads. */
export type PirateRiskKnobs = { readonly [K in keyof PirateEffectConfig]: number }

/** The global game_config fallbacks, with the SAME literal defaults
 *  `pirate_intercept_compute_risk` coalesces to. Keep these in step with 0233. */
export const PIRATE_RISK_GLOBAL_DEFAULTS: PirateRiskKnobs = {
  base_risk: 0.35,
  min_risk: 0.02,
  max_risk: 0.9,
  exposure_floor: 0.15,
  stat_reference: 120,
}

/** The ONE coalescing step: per-zone override wins, else the global. Mirrors the SQL exactly, so an
 *  all-null config resolves to the globals unchanged. */
export function resolvePirateKnobs(
  config: PirateEffectConfig,
  globals: PirateRiskKnobs = PIRATE_RISK_GLOBAL_DEFAULTS,
): PirateRiskKnobs {
  return {
    base_risk: config.base_risk ?? globals.base_risk,
    min_risk: config.min_risk ?? globals.min_risk,
    max_risk: config.max_risk ?? globals.max_risk,
    exposure_floor: config.exposure_floor ?? globals.exposure_floor,
    stat_reference: config.stat_reference ?? globals.stat_reference,
  }
}

/** The interception risk curve, transcribed from `pirate_intercept_compute_risk` (0233):
 *
 *    risk = greatest(min_risk,
 *             least(max_risk,
 *               base_risk × (stat_reference / (stat_reference + max(combined_stats, 0)))
 *                         × min(1, max(exposure_floor, exposure_fraction))))
 *
 *  Both sides are IEEE-754 doubles, so this agrees with Postgres bit-for-bit on the same inputs —
 *  that equality is proven against the real function in scripts/typed-zone-foundation-proof.sql.
 *  PREVIEW ONLY: the server stays the authority for any risk that actually reaches a player. */
export function computePirateRisk(
  knobs: PirateRiskKnobs,
  combinedStats: number,
  exposureFraction: number,
): number {
  const falloff = knobs.stat_reference / (knobs.stat_reference + Math.max(combinedStats, 0))
  const exposure = Math.min(1, Math.max(knobs.exposure_floor, exposureFraction))
  return Math.max(knobs.min_risk, Math.min(knobs.max_risk, knobs.base_risk * falloff * exposure))
}

// ── validation (advisory; the CHECK constraints are the authority) ───────────────────────────────

/** One problem with a proposed effect config. `field` is the knob at fault, or null when the problem
 *  is a relationship between knobs. */
export interface ZoneEffectProblem {
  readonly field: keyof PirateEffectConfig | null
  readonly message: string
}

const UNIT_KNOBS = ['base_risk', 'min_risk', 'max_risk', 'exposure_floor'] as const

/** Mirror of the zone_effect_pirate CHECKs: the four unit knobs sit in [0,1] when set,
 *  stat_reference is strictly positive when set, and a set min/max pair may not be inverted.
 *  A null is ALWAYS valid — it means "inherit", which is the parity-preserving default. */
export function validatePirateEffect(config: PirateEffectConfig): ZoneEffectProblem[] {
  const problems: ZoneEffectProblem[] = []
  for (const field of UNIT_KNOBS) {
    const value = config[field]
    if (value === null) continue
    if (!Number.isFinite(value) || value < 0 || value > 1) {
      problems.push({ field, message: `${field.replace(/_/g, ' ')} must be between 0 and 1.` })
    }
  }
  if (config.stat_reference !== null) {
    if (!Number.isFinite(config.stat_reference) || config.stat_reference <= 0) {
      problems.push({ field: 'stat_reference', message: 'Stat reference must be greater than 0.' })
    }
  }
  if (
    config.min_risk !== null &&
    config.max_risk !== null &&
    Number.isFinite(config.min_risk) &&
    Number.isFinite(config.max_risk) &&
    config.min_risk > config.max_risk
  ) {
    problems.push({ field: null, message: 'Minimum risk cannot exceed maximum risk.' })
  }
  return problems
}

/** True when a config carries no override at all — i.e. it inherits every global and is therefore
 *  behaviour-neutral. The 0273 backfill wrote exactly this for every existing zone. */
export function isInheritedPirateEffect(config: PirateEffectConfig): boolean {
  return (
    config.base_risk === null &&
    config.min_risk === null &&
    config.max_risk === null &&
    config.exposure_floor === null &&
    config.stat_reference === null
  )
}
