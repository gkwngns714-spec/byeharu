// WHERE IS THIS FLEET WHILE IT FIGHTS — the ONE rule, shared by every badge that can draw a fleet
// during combat. Pure; no React/DOM/fetch/clock. Proven in tests/fleetFightPosition.spec.ts.
//
// ── THE BUG THIS EXISTS TO KILL ────────────────────────────────────────────────────────────────────
// The owner, first: "when fighting, my fleet location and the fighting location differs, meaning that
// my fleet location and the point of attack is different." The badge was pinned to the fleet row's
// own parked point while that fleet's OWN SHIPS — drawn by spatialCombatLayer from
// combat_units.pos_x/pos_y — stood 20-30 world units away. The same fleet, rendered twice, in two
// places. (0313 cut weapon ranges to 25-30, which is what made the mover's close/kite arms fire at
// all; the pos_x writers are 0234/0294/0311/0314/0336. 0313 started the movement, it did not author
// it; 0336 is the writer that put a wave's units on a RING instead of all on one point.)
//
// The first fix put the badge on the CENTROID of those ships. The owner, after it shipped:
// "the fleet arrived at combat zone, it fights but in a different location. This is not fixed."
// Measured on that exact production fight:
//
//     enemies : 3 units at EXACTLY one point, spread 0.0 x 0.0, 5.0 from the engagement anchor
//     player  : 4 units spread 36.2 x 22.3, 20.7-28.1 from the anchor, 10.1-21.2 from their centroid
//     badge   : on that centroid — a point where NO SHIP IS, ~16.3 from the enemy stack
//
// A centroid is only meaningful for a CLUSTER. A scattered formation's mean is empty space between
// the ships, so the badge floated in the gap while the shooting happened at the enemy stack. The
// centroid was the wrong KIND of answer, not a mistuned one.
//
// ── THE SECOND BUG: "I TELEPORT WHEN AN ENEMY DIES" ────────────────────────────────────────────────
// The owner, playing: "When enemy ship is destroyed, i teleport to some random place inside the zone.
// This should not happen."
//
// It was deterministic, it was client-side, and it was this file. The rule below USED to be "our own
// living hull NEAREST THE ENEMY", i.e. an ARGMIN OVER THE LIVING ENEMY SET. `resolveSpatialUnits`
// drops a unit the instant `alive_count` hits 0, so a kill CHANGES THE TARGET SET; a changed target
// set re-runs the argmin; a different hull wins; and the fleet's point is suddenly hull B's
// coordinates instead of hull A's. Nothing tweens across that, because `combatMotion.smoothCombatUnits`
// keyframes PER UNIT ID — swapping row A for row B reads B's position directly. One frame, a whole
// formation away.
//
// MEASURED against live production config (`spatial_formation_ring_radius = 6`):
//     lead ↔ escort           6.00 world units
//     adjacent escorts        4.59
//     opposite ring slots     8.49
// instantly, against a legitimate maximum of `min(move_speed)` = 0.2-1.0 units per 3 s tick. A 5x-40x
// overshoot, so it does not read as movement at all — it reads as a teleport, which is the word the
// owner used. WORST CASE IS THE LAST KILL OF A WAVE: with `foes.length === 0` the target used to flip
// to the ENGAGEMENT ANCHOR, i.e. from "the hull furthest forward" to "the hull nearest where the
// fight started" — a guaranteed maximal jump, fired exactly on the kill that clears the wave.
//
// WHY IT ONLY *LOOKED* LIKE A TELEPORT AFTER THE FOLD, and why the old justification is dead:
// `map/combatActors.ts` folds the four player rows into ONE glyph. Before that fold, a hull-swap put
// the marker on a ship the player could SEE, so it read as "the badge moved to that ship". The fold
// deleted the other hulls from the screen, so the same swap now lands on apparently empty space. The
// header above rejects the centroid because "the badge floats in the gap between THE VISIBLE SHIPS" —
// that argument was about a gap between things on screen, AND THE FOLD DELETED THE VISIBLE SHIPS, so
// the justification for aiming at the enemy died with them, exactly as 0311's teleport justification
// died with 0316. What is left is the category error: this function answers "WHERE IS THE POINT OF
// ATTACK" and both its callers ask it "WHERE IS THE FLEET". Before the fold those were the same
// visible thing. They are not any more.
//
// ── THE RULE ───────────────────────────────────────────────────────────────────────────────────────
// THE BADGE SITS ON A REAL SHIP. Never a mean, never a midpoint, never a synthesised point. And
// WHERE THE FLEET IS IS A FUNCTION OF THE FLEET — never of its enemies. Priority, one order, ONE place:
//
//   1. THE FLEET'S ELECTED LEAD — 0315's own decision, read off `aggro_priority` through the ONE lead
//      authority `combatMotion.resolveEncounterLead` (100 on exactly one player hull per formation,
//      verified on production). Nothing about the enemy is an input to this arm, so killing one
//      CANNOT move the fleet: the answer changes only when the fleet's own lead moves, dies, or is
//      re-elected by the server.
//   2. lead dead / unpositioned → nearest (by min distance to ANY living positioned enemy unit of
//      this same encounter), then nearest the ENGAGEMENT ANCHOR when no enemy is left. This is the
//      OLD rule, kept ONLY as a fallback: it still answers a real hull, and a fleet whose lead is
//      gone has no better claim to a particular hull than "the one in contact".
//   3. no living positioned player unit at all → the caller's own resting point, unchanged
//
// Enemies never contribute a coordinate. On the fallback arm they are the distance TARGET and nothing
// else; on the primary arm they are not consulted at all. The answer is always one of OUR hulls, and
// because the returned point is copied off a unit row it is a MEMBER of the input set — the spec
// asserts exactly that, which is the invariant that makes "an average" structurally impossible to
// reintroduce.
//
// ── STABILITY: WHAT THE BADGE DOES BETWEEN TWO 1.5s POLLS ──────────────────────────────────────────
// The lead arm is stable BY CONSTRUCTION: 0315 elects the lead once per encounter and writes the
// decision onto the row, so it is a server fact that survives every kill, every wave and every poll.
// Everything below is about the FALLBACK arm, where "nearest" can still change tick to tick and a
// label that teleports between hulls every poll is its own bug. Two properties handle it, both PURE —
// the answer stays a function of the current rows alone:
//
//   • DETERMINISTIC ORDER. Candidates arrive id-sorted from resolveSpatialUnits, so array order is
//     never an input; the same rows always answer the same hull, at any re-render.
//   • A STABILITY MARGIN. Every hull within NEAREST_SHIP_MARGIN world units of the true minimum is a
//     contender, and the LOWEST-ID contender wins. Two ships trading the lead by centimetres of
//     server jitter therefore do not trade the badge — it stays locked to one hull until another is
//     a full world unit closer. The choice is still measured against the TRUE minimum (not against
//     the incumbent), so it can never ratchet away down a chain of sub-margin steps: the chosen hull
//     is provably never more than the margin behind the nearest one.
//
// JITTER BEHAVIOUR BEING SHIPPED, stated plainly: the badge changes hull only when the contender set's
// lowest id changes — i.e. when a different ship becomes nearer by more than the margin, or when the
// holder dies or leaves the fight. It can still flap if a ship hovers exactly on the margin boundary,
// and both endpoints of that flap are REAL SHIPS in the same battle, so the badge is never in empty
// space either way. That bound was chosen over cross-tick hysteresis deliberately: hysteresis needs a
// remembered previous choice, which would put mutable state in a pure leaf, thread it through both
// call sites and React, go stale the moment the remembered hull is destroyed, and make the answer
// depend on call history instead of on the rows — a second source of truth about where the fleet is.
// NEAREST_SHIP_MARGIN IS A WORLD-UNIT DISTANCE AND IT SCALES WITH THE ARENA. It was 1 while weapon
// ranges were 25-30 (0313) — ~4% of a weapon's reach. 0316 divided every combat distance by 5
// (ranges 5-6, formation ring 6), so the margin divides with them: 0.2, the same ~4% of reach and
// the same fraction of the ring. Left at 1 it would have become a fifth of the whole engagement —
// the badge would have stuck to one hull across most of the fight, which is the bug this constant
// exists to bound, not the behaviour it exists to give. A swap inside it is noise, not news.
//
// ── ONE AUTHORITY, COMPOSED — NOT A THIRD POSITION PATH ────────────────────────────────────────────
//   • which encounter is this fleet's   → combat/encounterAnchor.liveEncounterForFleet
//   • where the fight started            → combat/encounterAnchor.resolveEncounterAnchor — the SAME
//     coalesce(engagement_x, site) the server uses (0293:255 / 0294:424)
//   • which units are drawable and alive → map/spatialCombatLayer.resolveSpatialUnits — the SAME
//     filter that decides which glyphs exist. The badge therefore cannot sit on a ship the player
//     cannot see, and cannot ignore one they can.
//   • WHICH HULL LEADS THIS FLEET        → map/combatMotion.resolveEncounterLead, which already reads
//     0315's `aggro_priority` for the ordnance fallback. There is ONE lead election in the client and
//     it is the server's; this adds a second CALLER, not a second rule. It is imported from
//     combatMotion rather than copied, and combatMotion imports neither this file nor the layer, so
//     no cycle is created.
// Nothing here re-derives liveness, positional validity, encounter selection, the anchor or the lead.
//
// ── ONE POSITION, TWO CALLERS, MOVING TOGETHER BY CONSTRUCTION ─────────────────────────────────────
// The fleet's combat GLYPH (map/combatActors.ts) and the fleet's named BADGE (map/fleetPresence.ts)
// both get their point from this function and from nowhere else. That is not a convention to be
// remembered — it is pinned in tests/fleetFightPosition.spec.ts, which drives both callers over the
// same rows and asserts they answer the identical coordinate. Two places drawing one fleet is the
// original defect at the top of this file; it cannot come back while that spec is green.
//
// ── FAIL CLOSED ────────────────────────────────────────────────────────────────────────────────────
// No live encounter, or no positioned living player unit → the caller's own fallback, unchanged. A
// non-finite FALLBACK yields null so the caller drops the badge entirely: never NaN into an SVG
// transform (a NaN blanks the element), never (0,0), never a guessed point.
import type { CombatUnit } from '../combat/combatTypes'
import {
  liveEncounterForFleet,
  resolveEncounterAnchor,
  type FleetEncounterLite,
} from '../combat/encounterAnchor'
import { resolveEncounterLead } from './combatMotion'
import { resolveSpatialUnits, type SpatialUnitView } from './spatialCombatLayer'

/** FALLBACK ARM ONLY (the lead is dead or unpositioned): world units within which two hulls count as
 *  the SAME distance from the target, so the badge does not change ship on server jitter. See the
 *  STABILITY section of the header for why this exists, why it is not cross-tick hysteresis, and why
 *  0316's five-times-tighter arena divided it by 5. */
export const NEAREST_SHIP_MARGIN = 0.2

export interface FleetFightPosition {
  /** WORLD coordinates — the same domain as locations.x/y and combat_units.pos_x/pos_y. Always finite.
   *  On the 'unit' arm these are copied VERBATIM off a combat_units row: the point is a real ship's
   *  position, not a value derived from several. */
  x: number
  y: number
  /** 'unit'     = a real living, positioned ship of this fleet — its elected LEAD, or (only once the
   *               lead is gone) the hull in contact.
   *  'fallback' = the caller's own resting position (no live fight, or no positioned ships). */
  source: 'unit' | 'fallback'
  /** combat_units.id of the ship the badge stands on; null on the fallback arm. The primary key of
   *  the answer — a caller (or a spec) can check membership by identity, not by proximity. */
  unitId: string | null
  /** True whenever the fleet has a LIVE encounter, positioned or not — a fleet in an aggregate
   *  (unpositioned) fight is still fighting and must still say so, it just cannot be placed. */
  fighting: boolean
}

const isFiniteNumber = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

interface Point {
  x: number
  y: number
}

const distance = (a: Point, b: Point): number => Math.hypot(a.x - b.x, a.y - b.y)

/** Distance from one hull to the CLOSEST target — min over the set, never an average over it. */
const distanceToNearest = (u: Point, targets: readonly Point[]): number => {
  let best = Number.POSITIVE_INFINITY
  for (const t of targets) {
    const d = distance(u, t)
    if (d < best) best = d
  }
  return best
}

/**
 * Where to draw this fleet, given everything already on the map.
 *
 * `fallback` is where the caller would draw it with no fight in play — the site's centre for a fleet
 * present at a combat location, the fleet's own space_x/space_y for one parked in open space. It is
 * returned verbatim on every non-positioned path, so a caller that passes no encounters/units keeps
 * today's behaviour exactly. It also stands in as the fight's site for the anchor read, mirroring the
 * server's own `coalesce(engagement_x, location.x)`.
 */
export function resolveFleetFightPosition(input: {
  fleetId: string | null | undefined
  encounters: readonly FleetEncounterLite[]
  units: readonly CombatUnit[]
  fallback: { x: number; y: number }
}): FleetFightPosition | null {
  const { x: fx, y: fy } = input.fallback
  // The caller's own position is unusable → there is no defensible point at all. Draw nothing.
  if (!isFiniteNumber(fx) || !isFiniteNumber(fy)) return null
  const rest = (fighting: boolean): FleetFightPosition => ({
    x: fx,
    y: fy,
    source: 'fallback',
    unitId: null,
    fighting,
  })

  const encounter = liveEncounterForFleet(input.encounters, input.fleetId)
  if (!encounter) return rest(false)

  // This fleet's OWN battle only: a second encounter's units must never drag the badge — neither as
  // a candidate hull nor as a target to aim at.
  const mine = input.units.filter((u) => u.encounter_id === encounter.id)
  // resolveSpatialUnits is the ONE positioned-and-alive filter (the glyph filter), and it returns
  // rows id-sorted; `side` comes from it too, so an enemy can never be chosen as our own ship.
  const spatial = resolveSpatialUnits(mine)
  const ours = spatial.filter((u) => u.side === 'player')
  if (ours.length === 0) return rest(true) // fighting, but aggregate/dark — nothing to stand on

  // ── WHERE THE FLEET IS: ON ITS OWN ELECTED LEAD ────────────────────────────────────────────────
  // "When enemy ship is destroyed, i teleport to some random place inside the zone." This branch is
  // the answer to that: the enemy rows are not read at all here, so no kill — not the first of a
  // wave and not the last — can change which hull the fleet is drawn on. 0315 elected this hull once,
  // server-side, and wrote the decision onto the row; the client composes that decision and never
  // re-derives one. `mine` is already this encounter's rows, and the elected lead is only USED if it
  // is still in `ours` (living AND positioned), so the fleet is never pinned to a wreck or to a row
  // with no coordinates.
  const lead = resolveEncounterLead(mine, encounter.id)
  const standing = lead ? ours.find((u) => u.id === lead.id) : undefined
  if (standing) {
    return { x: standing.x, y: standing.y, source: 'unit', unitId: standing.id, fighting: true }
  }

  // ── FALLBACK ONLY: the lead is dead or unpositioned ────────────────────────────────────────────
  // Everything below is the pre-fold rule, demoted. It still answers a REAL hull of ours, which is
  // why it is a defensible last resort — but it is reached only when the fleet has no lead left to
  // stand on, so its enemy-set dependency (the teleport above) can no longer fire on a live formation.
  //
  // THE TARGET — never the answer. Living positioned enemies when the fight has any (the point of
  // attack); otherwise where the fight started, resolved by the SAME rule the server uses.
  const foes = spatial.filter((u) => u.side === 'enemy')
  let targets: readonly Point[]
  if (foes.length > 0) {
    targets = foes
  } else {
    const anchor = resolveEncounterAnchor(encounter, { x: fx, y: fy })
    if (!anchor) return rest(true) // unreachable: fx/fy are finite, so the site is usable
    targets = [anchor]
  }

  // Argmin over the TRUE minimum, then the lowest-id hull inside the stability margin of it. Both
  // passes read the same scores, so the chosen hull is never more than the margin behind the nearest.
  const scores = ours.map((u) => distanceToNearest(u, targets))
  let nearest = Number.POSITIVE_INFINITY
  for (const s of scores) if (s < nearest) nearest = s
  if (!Number.isFinite(nearest)) return rest(true) // no usable target distance → stay put
  const cut = nearest + NEAREST_SHIP_MARGIN
  const picked = scores.findIndex((s) => s <= cut)
  if (picked < 0) return rest(true) // unreachable: the argmin itself always clears the cut
  const hull: SpatialUnitView = ours[picked]

  // Copied VERBATIM off the unit row — the badge IS that ship. resolveSpatialUnits already
  // guaranteed both coordinates finite, so no NaN can reach an SVG transform.
  return { x: hull.x, y: hull.y, source: 'unit', unitId: hull.id, fighting: true }
}
