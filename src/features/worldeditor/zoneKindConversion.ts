// WORLD EDITOR — ZONE KIND CONVERSION: may this zone become that kind? Props in → verdict out.
// NO React, no DOM, no storage, no network — the worldEditorChrome / worldEditorDraftGuard
// pure-module idiom, unit-tested directly (tests/zoneKindConversion.spec.ts).
//
// ── WHAT IT IS FOR, AND WHAT IT IS NOT ──────────────────────────────────────────────────────────
// The server (zone_kind_change, 0285) REFUSES a conversion while the zone still carries an effect the
// target kind does not permit — because a zone converted from pirate to mining that keeps its
// pirate_intercept effect is a "mining" zone that still intercepts fleets. That refusal is the
// authority and this module cannot weaken it.
//
// This exists so the editor can say so BEFORE the round-trip: disable the option, name the effects in
// the way, and let the owner remove them deliberately. A form that offers a choice the server will
// certainly reject is a form that wastes a click and teaches the owner to distrust it.
//
// ── THE RULE IS DATA, MIRRORED FROM THE SERVER'S TABLE ──────────────────────────────────────────
// zone_kind_permitted_effects (0285) is the authority. This is a mirror of it, and a test asserts the
// two agree — because a mirror that silently drifts is worse than no mirror: the editor would then
// confidently permit something the server rejects, which is the failure mode this module removes.
//
// IT NEVER DELETES ANYTHING. Like the server, it reports what is in the way; removing an effect is a
// separate, deliberate act (zone_effect_remove). Destroying authored configuration to satisfy a
// rename is not a convenience — it is data loss with a friendly name.

import type { ZoneEffectKind } from './zoneEffects'

/** The zone identities this world recognises — 1:1 with the widened danger_zones.zone_kind CHECK. */
export const ZONE_KINDS = ['pirate', 'combat', 'mining', 'exploration'] as const

export type ZoneKind = (typeof ZONE_KINDS)[number]

/** Plain-language names for the authoring form (map-UX law #4/#5). */
export const ZONE_KIND_LABELS: Record<ZoneKind, string> = {
  pirate: 'Pirate',
  combat: 'Combat',
  mining: 'Mining',
  exploration: 'Exploration',
}

/** Which effects a zone of a given kind may carry — the mirror of zone_kind_permitted_effects.
 *  A kind may legitimately permit MORE than its namesake later (a mining zone that also spawns); when
 *  that happens it is one row on the server and one entry here, and the agreement test keeps them
 *  honest. */
export const ZONE_KIND_PERMITTED_EFFECTS: Record<ZoneKind, readonly ZoneEffectKind[]> = {
  pirate: ['pirate_intercept'],
  combat: ['combat'],
  mining: ['mining'],
  exploration: ['exploration'],
}

/** Why a conversion cannot proceed, or that it can. `blockingEffects` is what the owner must remove
 *  first — named, never removed automatically. */
export type KindConversionVerdict =
  | { readonly kind: 'allowed' }
  | { readonly kind: 'already-that-kind' }
  | { readonly kind: 'unknown-kind' }
  | { readonly kind: 'blocked'; readonly blockingEffects: readonly ZoneEffectKind[] }

export function isZoneKind(value: string): value is ZoneKind {
  return (ZONE_KINDS as readonly string[]).includes(value)
}

/** The effects a zone currently carries that `target` does not permit, in a stable order so the UI
 *  never reshuffles between renders. */
export function blockingEffectsFor(
  target: ZoneKind,
  carried: readonly ZoneEffectKind[],
): ZoneEffectKind[] {
  const permitted = ZONE_KIND_PERMITTED_EFFECTS[target]
  return carried.filter((e) => !permitted.includes(e)).sort()
}

/** The ONE verdict. Mirrors the server's order of judgement so the editor and the command agree about
 *  WHY something is refused, not merely that it is. */
export function planKindConversion(
  current: string,
  target: string,
  carried: readonly ZoneEffectKind[],
): KindConversionVerdict {
  if (!isZoneKind(target)) return { kind: 'unknown-kind' }
  const blocking = blockingEffectsFor(target, carried)
  // Blocking is reported BEFORE the no-op case: a zone that is already this kind AND carries a
  // foreign effect has a real problem worth surfacing, and hiding it behind "already that kind"
  // would leave the inconsistency invisible.
  if (blocking.length > 0) return { kind: 'blocked', blockingEffects: blocking }
  if (current === target) return { kind: 'already-that-kind' }
  return { kind: 'allowed' }
}

/** Owner-facing explanation. Names every blocker and says plainly that nothing is removed for them —
 *  the server will not do it either, and implying otherwise would set up a nasty surprise. */
export function explainKindConversion(
  verdict: KindConversionVerdict,
  target: string,
  effectLabel: (effect: ZoneEffectKind) => string,
): string {
  switch (verdict.kind) {
    case 'allowed':
      return `Change this zone to ${target}.`
    case 'already-that-kind':
      return 'This zone is already that kind.'
    case 'unknown-kind':
      return 'That is not a zone kind this world recognises.'
    case 'blocked': {
      const names = verdict.blockingEffects.map(effectLabel).join(', ')
      return `Remove ${names} first — a ${target} zone cannot carry ${
        verdict.blockingEffects.length === 1 ? 'it' : 'them'
      }, and they are not removed for you.`
    }
  }
}
