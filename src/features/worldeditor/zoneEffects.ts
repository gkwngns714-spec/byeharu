// WORLD EDITOR — TYPED-ZONE EFFECTS: the AUTHORING-side descriptor for what a zone does. Props in →
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
// Presence of an effect is the existence of its config row, never a NULL-riddled sentinel on the core.
// Identity does NOT imply effect presence: a pirate-identity zone may carry no pirate-interception
// effect, and that is legal. The 0273 backfill was a one-time parity migration, not an invariant.
//
// ── WHAT THIS MODULE DELIBERATELY DOES NOT CONTAIN ──────────────────────────────────────────────
// NO knob coalescing and NO risk mathematics. Those are RUNTIME semantics and the database owns them:
// the typed-zone risk helper and dispatcher are versioned PostgreSQL functions, and the shadow
// comparison against the deployed 0233 runtime happens INSIDE the database. A second implementation
// under src/ would either become a competing authority or silently drift from the one that decides
// real player outcomes. It was written once and deliberately removed — do not reintroduce it.
//
// What DOES belong here: effect descriptors for authoring, config types, advisory form validation,
// display labels, and payload projection. Validation here is a courtesy that spares the owner a
// round-trip; the zone_effect_pirate_intercept CHECK constraints are the authority, and they are
// strictly stronger (they also reject NaN and the infinities, which Postgres orders above all reals).

/** The effect kinds that exist. Grows ONE sibling at a time, each with its own table, its own runtime
 *  gate and its own slice — adding a kind never edits an existing one.
 *  Named for the BEHAVIOUR, not the zone's identity: 'pirate' is faction language, while
 *  'pirate_intercept' is the thing those five risk knobs actually do. */
//  Each entry has a `zone_effect_<name>` table server-side; the registry and those tables must stay
//  1:1, because "an effect is present iff its row exists" is only true of effects the client knows
//  about. An effect table without an entry here is invisible to the editor.
export const ZONE_EFFECT_KINDS = [
  'pirate_intercept',
  'combat',
  'mining',
  'exploration',
] as const

export type ZoneEffectKind = (typeof ZONE_EFFECT_KINDS)[number]

/** Plain-language nouns (map-UX law #4/#5: the owner's words, no schema keys). */
export const ZONE_EFFECT_LABELS: Record<ZoneEffectKind, string> = {
  pirate_intercept: 'Pirate interception',
  combat: 'Combat encounters',
  mining: 'Mining yield',
  exploration: 'Exploration rewards',
}

// ── the pirate-interception effect ──────────────────────────────────────────────────────────────

/** The five risk knobs, as OPTIONAL per-zone overrides. `null` = inherit the global.
 *  1:1 with the zone_effect_pirate_intercept columns. */
export interface PirateInterceptEffectOverrides {
  readonly base_risk: number | null
  readonly min_risk: number | null
  readonly max_risk: number | null
  readonly exposure_floor: number | null
  readonly stat_reference: number | null
}

/** The overrides a freshly-added effect starts from: inherit everything. Identical to what the 0273
 *  backfill wrote for every existing zone, which is why that backfill changed no behaviour. */
export const EMPTY_PIRATE_INTERCEPT_OVERRIDES: PirateInterceptEffectOverrides = {
  base_risk: null,
  min_risk: null,
  max_risk: null,
  exposure_floor: null,
  stat_reference: null,
}

/** The override field names, in schema order — the ONE list the form and the validator share. */
export const PIRATE_INTERCEPT_OVERRIDE_FIELDS = [
  'base_risk',
  'min_risk',
  'max_risk',
  'exposure_floor',
  'stat_reference',
] as const

/** Owner-facing labels for the authoring form. */
export const PIRATE_INTERCEPT_FIELD_LABELS: Record<keyof PirateInterceptEffectOverrides, string> = {
  base_risk: 'Base risk',
  min_risk: 'Minimum risk',
  max_risk: 'Maximum risk',
  exposure_floor: 'Exposure floor',
  stat_reference: 'Stat reference',
}

// ── validation (advisory; the CHECK constraints are the authority) ───────────────────────────────

/** One problem with a proposed override set. `field` is the knob at fault, or null when the problem
 *  is a relationship between knobs. */
export interface ZoneEffectProblem {
  readonly field: keyof PirateInterceptEffectOverrides | null
  readonly message: string
}

const UNIT_KNOBS = ['base_risk', 'min_risk', 'max_risk', 'exposure_floor'] as const

/** Mirror of the zone_effect_pirate_intercept CHECKs: the four unit knobs sit in [0,1] when set,
 *  stat_reference is strictly positive when set, no value may be NaN or infinite, and a set min/max
 *  pair may not be inverted. A null is ALWAYS valid — it means "inherit", which is the
 *  parity-preserving default.
 *  ADVISORY ONLY: this spares a round-trip; the database rejects the same values independently, and
 *  any disagreement is a bug in this file rather than a licence to store the value. */
export function validatePirateInterceptOverrides(
  overrides: PirateInterceptEffectOverrides,
): ZoneEffectProblem[] {
  const problems: ZoneEffectProblem[] = []
  for (const field of UNIT_KNOBS) {
    const value = overrides[field]
    if (value === null) continue
    if (!Number.isFinite(value) || value < 0 || value > 1) {
      problems.push({
        field,
        message: `${PIRATE_INTERCEPT_FIELD_LABELS[field]} must be a number between 0 and 1.`,
      })
    }
  }
  if (overrides.stat_reference !== null) {
    if (!Number.isFinite(overrides.stat_reference) || overrides.stat_reference <= 0) {
      problems.push({
        field: 'stat_reference',
        message: `${PIRATE_INTERCEPT_FIELD_LABELS.stat_reference} must be a number greater than 0.`,
      })
    }
  }
  if (
    overrides.min_risk !== null &&
    overrides.max_risk !== null &&
    Number.isFinite(overrides.min_risk) &&
    Number.isFinite(overrides.max_risk) &&
    overrides.min_risk > overrides.max_risk
  ) {
    problems.push({ field: null, message: 'Minimum risk cannot exceed maximum risk.' })
  }
  return problems
}

/** True when an override set carries nothing at all — i.e. it inherits every global and is therefore
 *  behaviour-neutral. The 0273 backfill wrote exactly this for every existing zone. */
export function isInheritedPirateInterceptEffect(
  overrides: PirateInterceptEffectOverrides,
): boolean {
  return PIRATE_INTERCEPT_OVERRIDE_FIELDS.every((field) => overrides[field] === null)
}

/** The row payload an authoring command would send: only the overrides, never a resolved value.
 *  Resolution (coalescing an override against the global) is the database's job — projecting a
 *  resolved number from the client would smuggle runtime semantics back into src/. */
export function projectPirateInterceptOverrides(
  overrides: PirateInterceptEffectOverrides,
): PirateInterceptEffectOverrides {
  return {
    base_risk: overrides.base_risk,
    min_risk: overrides.min_risk,
    max_risk: overrides.max_risk,
    exposure_floor: overrides.exposure_floor,
    stat_reference: overrides.stat_reference,
  }
}
