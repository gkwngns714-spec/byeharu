// ENGAGEMENT ANCHOR — the ONE client answer to "where is this fight, physically?"
//
// ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────────────────
// Migration 0293 split encounter POSITION from encounter IDENTITY: combat_encounters gained
// engagement_x/engagement_y, and combat_create_group_encounter became the ONE resolver —
// `coalesce(p_engagement_x, l.x)` (0293:255): the intercept's ambush point when one was supplied,
// the linked location's centre otherwise. Since 0294 the SERVER derives every combat position from
// exactly that anchor — the tick resolves `v_anchor_x := coalesce(e.engagement_x, loc.x)` (0294:424)
// and seeds/moves every combat_units row around it.
//
// The client must answer the SAME question the SAME way or it draws things where the battle is not.
// An ambush anchor sits on the ZONE EDGE by construction, not at the site centre: on the owner's
// production encounters at Snare (site centre (-45,120)) the fights are 20-30 world units away —
// wider than the whole battle's footprint since 0313 cut weapon ranges to 25-30. A badge pinned to
// the site centre is then a badge pointing at empty space while the fleet burns somewhere else.
//
// ── WHAT THIS LEAF IS FOR — AND WHAT IT IS NOT ─────────────────────────────────────────────────────
// The anchor is where a fight STARTED. It is NOT where the fleet currently is: the units seeded
// around it then MOVE (0313/0314), so within a tick or two the formation has walked 20-30 units off
// it. "Where is this fleet right now" is a different question with a different answer, owned by
// map/fleetFightPosition (the centroid of the fleet's own living, positioned units). This module
// deliberately does not answer it, and no badge positions itself from the anchor.
//
// Its two live jobs, both still ONE authority apiece:
//   • `resolveEncounterAnchor` — map/ambushEncounterNotice's ambush-vs-hunt test: an anchor OFF the
//     linked location's centre means the fleet was dragged into this fight en route (0293's own rule).
//     That question is about the fight's ORIGIN, which is exactly what the anchor records.
//   • `liveEncounterForFleet` / `isLiveEncounter` / `LIVE_ENCOUNTER_STATUSES` — the shared "which
//     encounter is this fleet's, and is it live" selection, read by the notice and by
//     map/fleetFightPosition. Neither re-derives the live-status set or the ambiguity rule.
//
// ── FAIL CLOSED ────────────────────────────────────────────────────────────────────────────────────
// A missing / NULL / non-finite engagement anchor is neither an error nor a licence to guess: it
// degrades to the site centre, which is precisely where the server itself falls back. A SITE whose
// own coordinates are unusable yields null, so no caller can emit NaN into an SVG transform (a NaN
// in a transform silently blanks the element). More than one live encounter for one fleet is a
// broken invariant (the DB's `one_active_encounter_per_fleet` partial unique index, 0014:35, forbids
// it) — it resolves to NO encounter rather than an arbitrary one, so the reader falls back to the
// centre instead of anchoring on a coin flip.
//
// Pure — no React/DOM/fetch/clock. Proven in tests/encounterAnchor.spec.ts.

/** The structural slice of a combat_encounters row needed to PLACE a fight. */
export interface EncounterAnchorLite {
  /** 0293's engagement anchor. Absent when read from a server that predates the column. */
  engagement_x?: number | null
  engagement_y?: number | null
}

/** The structural slice of the fight's owning location (MapLocation / AmbushLocationLite satisfy it). */
export interface AnchorSite {
  x: number
  y: number
}

export interface EncounterAnchor {
  /** WORLD coordinates — the same domain as locations.x/y and combat_units.pos_x/pos_y. Always finite. */
  x: number
  y: number
  /** 'engagement' = the server stamped a usable anchor; 'site' = fell back to the location's centre. */
  source: 'engagement' | 'site'
  /** True only when a finite engagement anchor sits away from the site centre — 0293's ambush tell. */
  offSite: boolean
}

// Both coordinates originate as the SAME stored doubles (the intercept stamps locations-derived or
// path-derived values; a hunt copies locations.x/y verbatim) and cross the wire as JSON numbers, so
// equality is genuinely exact. The epsilon exists only to absorb JSON round-tripping, never to make a
// nearby ambush read as a hunt: a real ambush point sits at the zone boundary, world units away.
export const SAME_POINT_EPSILON = 1e-6

const isFiniteNumber = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/**
 * Where this encounter physically is, in world coordinates.
 *
 * Mirrors the server's `coalesce(engagement_x, locations.x)` exactly. `null` ONLY when the site
 * itself carries unusable coordinates — the one case where there is no defensible point at all.
 */
export function resolveEncounterAnchor(
  encounter: EncounterAnchorLite | null | undefined,
  site: AnchorSite,
): EncounterAnchor | null {
  if (!isFiniteNumber(site.x) || !isFiniteNumber(site.y)) return null
  const ex = encounter?.engagement_x
  const ey = encounter?.engagement_y
  // Fail closed on a half-populated anchor too: one finite coordinate is not a point.
  if (!isFiniteNumber(ex) || !isFiniteNumber(ey)) {
    return { x: site.x, y: site.y, source: 'site', offSite: false }
  }
  const offSite =
    Math.abs(ex - site.x) > SAME_POINT_EPSILON || Math.abs(ey - site.y) > SAME_POINT_EPSILON
  return { x: ex, y: ey, source: 'engagement', offSite }
}

// A fight is LIVE in exactly the two states combatApi.fetchActiveEncounters reads and CombatMapCard
// treats as live — a retreating fleet is still being shot at. ONE set, so every reader agrees.
export const LIVE_ENCOUNTER_STATUSES: ReadonlySet<string> = new Set(['active', 'retreating'])

export function isLiveEncounter(encounter: { status: string }): boolean {
  return LIVE_ENCOUNTER_STATUSES.has(encounter.status)
}

/** The structural slice needed to decide WHICH encounter belongs to a given fleet. */
export interface FleetEncounterLite extends EncounterAnchorLite {
  /** combat_encounters.id — what combat_units.encounter_id points back at, so a reader can select
   *  THIS fight's own units (map/fleetFightPosition). */
  id: string
  status: string
  /** combat_encounters.fleet_id → fleets.id (0014:13, a NOT NULL FK). */
  fleet_id: string
}

/**
 * This fleet's live fight, or null.
 *
 * Fail closed on every ambiguity: no fleet id, no match, an ended encounter, or MORE THAN ONE live
 * encounter for the fleet (a broken invariant — see the header) all answer null. A caller that gets
 * null must fall back to a defined position of its own; it must never invent one.
 */
export function liveEncounterForFleet<T extends FleetEncounterLite>(
  encounters: readonly T[],
  fleetId: string | null | undefined,
): T | null {
  if (!fleetId) return null
  let found: T | null = null
  for (const e of encounters) {
    if (e.fleet_id !== fleetId || !isLiveEncounter(e)) continue
    if (found !== null) return null // two live fights for one fleet → no anchor, never a coin flip
    found = e
  }
  return found
}
