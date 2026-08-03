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
// ── THE RULE ───────────────────────────────────────────────────────────────────────────────────────
// THE BADGE SITS ON A REAL SHIP. Never a mean, never a midpoint, never a synthesised point.
// Specifically: the fleet's own living, positioned player unit that is NEAREST THE ENEMY — the point
// of attack, which is what "where is my fleet fighting" actually asks. Priority, one order, ONE place:
//
//   1. nearest (by min distance to ANY living positioned enemy unit of this same encounter)
//   2. no living positioned enemy → nearest the ENGAGEMENT ANCHOR (where the fight started)
//   3. no living positioned player unit at all → the caller's own resting point, unchanged
//
// Enemies never contribute a coordinate. They are the distance TARGET and nothing else; the answer
// is always one of OUR hulls. Because the returned point is copied off a unit row, it is a MEMBER of
// the input set — the spec asserts exactly that, which is the invariant that makes "an average"
// structurally impossible to reintroduce.
//
// ── STABILITY: WHAT THE BADGE DOES BETWEEN TWO 1.5s POLLS ──────────────────────────────────────────
// "Nearest" can change tick to tick, and a label that teleports between hulls every poll is its own
// bug. Two properties handle it, both PURE — the answer stays a function of the current rows alone:
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
// Nothing here re-derives liveness, positional validity, encounter selection or the anchor.
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
import { resolveSpatialUnits, type SpatialUnitView } from './spatialCombatLayer'

/** World units within which two hulls count as the SAME distance from the target, so the badge does
 *  not change ship on server jitter. See the STABILITY section of the header for why this exists,
 *  why it is not cross-tick hysteresis, and why 0316's five-times-tighter arena divided it by 5. */
export const NEAREST_SHIP_MARGIN = 0.2

export interface FleetFightPosition {
  /** WORLD coordinates — the same domain as locations.x/y and combat_units.pos_x/pos_y. Always finite.
   *  On the 'unit' arm these are copied VERBATIM off a combat_units row: the point is a real ship's
   *  position, not a value derived from several. */
  x: number
  y: number
  /** 'unit'     = a real living, positioned ship of this fleet — the one at the point of attack.
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
