import { STAT_DEFINITION_ROWS, type StatDefinitionRow } from './statRegistry.generated'

// STAT LIFECYCLE — THE ONE CLIENT AUTHORITY on whether a stat may be shown as a player benefit.
//
// THE RULING THIS ENFORCES (owner, 2026-08-04):
//   "A dormant stat must not be represented as an effective player benefit."
//   "Do not fix this by adding another hardcoded list of dead stat identifiers. Presentation must
//    read lifecycle from the canonical stat metadata introduced by 0340, or from a generated/typed
//    projection whose sole authority is that metadata. The frontend must not independently maintain
//    a conflicting active-stat allowlist."
//
// So there is exactly one lifecycle answer on the client, it comes from statRegistry.generated.ts,
// and that file comes from migration 0340's seed and nowhere else. THIS FILE CONTAINS NO LIST OF
// STAT IDENTIFIERS — every set below is derived. tests/statLifecycle.spec.ts scans src/ and fails
// on any re-introduced hand-written dormant/active stat array, including one added here.
//
// THIS FOLD RETIRED (spaghetti, named plainly): teamSkillset.ts carried DORMANT_STAT_KEYS — a
// hand-maintained mirror of `stat_definitions.lifecycle = 'dormant'`, added by the previous slice —
// and portShop.ts carried STAT_LABELS, a second stat-name vocabulary. Two files independently
// asserting which stats are in play and what they are called is precisely the duplicate authority
// 0340 exists to delete. Both are folded onto this module in the same change.
//
// PURE: no React, no DOM, no network (the portShop.ts / zoneEffects.ts pure-module idiom).

export type { StatDefinitionRow }

/** The three standings migration 0340 declares (0340:176-197). There is no fourth. */
export type StatLifecycle = 'active' | 'dormant' | 'deprecated'

/** What PRESENTATION is allowed to do with a stat.
 *
 *   effective — lifecycle 'active': something in the game DECIDES with it, so it may be shown as a
 *               working player benefit.
 *   legacy    — lifecycle 'deprecated': still computed for its existing readers, forbidden to any
 *               NEW gameplay effect, and labelled legacy wherever it is shown.
 *   dormant   — lifecycle 'dormant': catalogued with no consumer of any kind. Hidden from ordinary
 *               player effective-stat summaries; in an owner-facing authoring surface it may be
 *               shown, but only carrying its dormant marker.
 *   unknown   — the stat is not in the registry at all, or its lifecycle is a value 0340's CHECK
 *               does not admit. FAILS CLOSED: treated exactly like dormant, never like active. */
export type StatStanding = 'effective' | 'legacy' | 'dormant' | 'unknown'

/** The registry, in display_order. */
export const STAT_DEFINITIONS: readonly StatDefinitionRow[] = STAT_DEFINITION_ROWS

const BY_ID = new Map(STAT_DEFINITIONS.map((d) => [d.statId, d]))
// catalog_key is UNIQUE in the registry (0340:149), so this map is total and lossless.
const BY_CATALOG_KEY = new Map(STAT_DEFINITIONS.map((d) => [d.catalogKey, d]))

/** THE lifecycle → standing mapping, and the ONLY place it happens.
 *
 *  FAIL CLOSED AT BOTH ENDS, the client mirror of stat_lifecycle_in_scope (0340:791-801): "an
 *  unknown lifecycle is NOT in any scope: a value the table somehow admitted is treated as absent
 *  rather than as active." A permissive default here would let a future lifecycle value — or a
 *  mis-parsed projection — advertise a dead stat as a working benefit, which is the one outcome
 *  this whole architecture exists to make impossible. */
export function standingOfLifecycle(lifecycle: string): StatStanding {
  switch (lifecycle) {
    case 'active':
      return 'effective'
    case 'deprecated':
      return 'legacy'
    case 'dormant':
      return 'dormant'
    default:
      return 'unknown'
  }
}

/** The registry row for a stat OUTPUT id (`mining_yield`), or null when it is not registered. */
export function statById(statId: string): StatDefinitionRow | null {
  return BY_ID.get(statId) ?? null
}

/** The registry row for a catalog INPUT key (`mining` — what a stats_json actually writes), or null.
 *  The two vocabularies are both 0340's (stat_id is what the fold EMITS, catalog_key is what the
 *  catalogs WRITE — 0340:271-273), so the join lives here and not in each catalog surface. */
export function statByCatalogKey(catalogKey: string): StatDefinitionRow | null {
  return BY_CATALOG_KEY.get(catalogKey) ?? null
}

/** Standing of a stat OUTPUT id. An unregistered id is 'unknown' — fail closed. */
export function standingOfStatId(statId: string): StatStanding {
  const def = BY_ID.get(statId)
  return def === undefined ? 'unknown' : standingOfLifecycle(def.lifecycle)
}

/** Standing of a catalog INPUT key. An unregistered key is 'unknown' — fail closed. */
export function standingOfCatalogKey(catalogKey: string): StatStanding {
  const def = BY_CATALOG_KEY.get(catalogKey)
  return def === undefined ? 'unknown' : standingOfLifecycle(def.lifecycle)
}

/** May this stat be presented to a player as a WORKING benefit? True only for 'active'. */
export function isEffectiveStatId(statId: string): boolean {
  return standingOfStatId(statId) === 'effective'
}

/** Is this stat legacy — shown for its existing readers, never offered as a new gameplay effect? */
export function isLegacyStatId(statId: string): boolean {
  return standingOfStatId(statId) === 'legacy'
}

/** May this stat carry a NUMBER on an ordinary player surface at all?
 *
 *  'effective' yes, 'legacy' yes but marked (deprecated stats keep their existing display readers —
 *  0340:408-409 names TeamDossier.tsx as cargo_capacity's). 'dormant' and 'unknown' NEVER: showing
 *  a number is what promises an effect. */
export function isPlayerVisibleStatId(statId: string): boolean {
  const standing = standingOfStatId(statId)
  return standing === 'effective' || standing === 'legacy'
}

/** The registry's own display name for a stat, or null when it is not registered. Never invented —
 *  a name the registry does not carry is not a name this client is entitled to make up. */
export function statDisplayName(statId: string): string | null {
  return BY_ID.get(statId)?.displayName ?? null
}

/** The registry's display name for a catalog INPUT key, or null when unregistered. */
export function catalogKeyDisplayName(catalogKey: string): string | null {
  return BY_CATALOG_KEY.get(catalogKey)?.displayName ?? null
}

/** The one sentence an owner-facing surface says beside a dormant definition. The editor MAY show
 *  dormant content — authoring and diagnostics need it — but it must never read as an active
 *  effect, so the marker and the "no consumer" fact travel together. */
export const DORMANT_MARKER = 'Dormant'
export const DORMANT_NOTE = 'No gameplay consumer today — this value changes nothing yet.'
export const LEGACY_MARKER = 'legacy'

/** Every registered stat id, in display_order. Derived — never a written list. */
export const ALL_STAT_IDS: readonly string[] = STAT_DEFINITIONS.map((d) => d.statId)

/** The stats a player may see a number for, in display_order. Derived from lifecycle. */
export const PLAYER_VISIBLE_STAT_IDS: readonly string[] = STAT_DEFINITIONS.filter((d) =>
  isPlayerVisibleStatId(d.statId),
).map((d) => d.statId)

/** The dormant stats, in display_order. Derived from lifecycle — this is NOT a maintained list, it
 *  is what the registry says today, and it moves the moment 0340's successor promotes a stat. */
export const DORMANT_STAT_IDS: readonly string[] = STAT_DEFINITIONS.filter(
  (d) => standingOfStatId(d.statId) === 'dormant',
).map((d) => d.statId)

/** The deprecated (legacy) stats, in display_order. Derived. */
export const LEGACY_STAT_IDS: readonly string[] = STAT_DEFINITIONS.filter(
  (d) => standingOfStatId(d.statId) === 'legacy',
).map((d) => d.statId)

/** Does the LEGACY FOLD emit this stat in its per-member envelope?
 *
 *  Registry-derived, not asserted: a `multiplier_bonus` stat is folded rather than summed (that is
 *  `speed`, which the client keeps separately as the fleet MINIMUM), and a stat that SUPERSEDES
 *  another is a canonical replacement target whose conversion is not activated (that is
 *  cargo_volume_m3 — 0340:424-437 gives it empty permitted lists precisely so nothing reaches it),
 *  so the deployed calculate_expedition_stats envelope carries neither. Everything else the fold
 *  emits and the client may sum for display. */
export function isLegacyEnvelopeStat(def: StatDefinitionRow): boolean {
  return def.combinationClass === 'additive' && def.supersedesStatId === null
}

/** The stat ids the deployed fold emits as additive per-member totals, in display_order. */
export const LEGACY_ENVELOPE_STAT_IDS: readonly string[] = STAT_DEFINITIONS.filter(
  isLegacyEnvelopeStat,
).map((d) => d.statId)
