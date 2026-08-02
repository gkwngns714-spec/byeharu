// WHERE IS THIS FLEET WHILE IT FIGHTS — the ONE rule, shared by every badge that can draw a fleet
// during combat. Pure; no React/DOM/fetch/clock. Proven in tests/fleetFightPosition.spec.ts.
//
// ── THE BUG THIS EXISTS TO KILL ────────────────────────────────────────────────────────────────────
// The owner: "when fighting, my fleet location and the fighting location differs, meaning that my
// fleet location and the point of attack is different." Measured on the last spatial fight in
// PRODUCTION:
//
//     side     units   min dist from the parked anchor   max
//     enemy      3               5.00                    5.00
//     player     4              21.50                   28.68
//
// The fleet badge sat on the fleet row's own parked point while that fleet's OWN SHIPS — drawn by
// spatialCombatLayer from combat_units.pos_x/pos_y — stood 21.5-28.7 world units away. The SAME
// fleet was rendered twice, in two places. It went from subtle to stark today: 0313 cut weapon
// ranges to 25-30 (so the gap now exceeds the whole battle's footprint) and 0313/0314 made units
// actually move, so the ships walk further from the badge with every tick.
//
// ── THE RULE ───────────────────────────────────────────────────────────────────────────────────────
// While a fleet has a LIVE encounter carrying positioned, living player units, the fleet badge sits
// on the CENTROID of those units — the formation, which moves as they move. Otherwise it falls back
// to exactly where the caller would have drawn it anyway. Two arms, one priority order, ONE place.
//
// The centroid is UNWEIGHTED across unit ROWS on purpose: resolveSpatialUnits emits exactly one glyph
// per row regardless of alive_count, so the unweighted mean is the centre of the glyphs the player
// can actually see. The badge belongs at the middle of the ships on screen, not at a demographic
// centre of mass they cannot perceive.
//
// ── ONE AUTHORITY, COMPOSED — NOT A THIRD POSITION PATH ────────────────────────────────────────────
//   • which encounter is this fleet's   → combat/encounterAnchor.liveEncounterForFleet
//   • which units are drawable and alive → map/spatialCombatLayer.resolveSpatialUnits — the SAME
//     filter that decides which glyphs exist. The badge therefore cannot sit on a ship the player
//     cannot see, and cannot ignore one they can.
// Nothing here re-derives liveness, positional validity, or encounter selection.
//
// ── FAIL CLOSED ────────────────────────────────────────────────────────────────────────────────────
// No live encounter, no positioned living player unit, or an unusable centroid → the caller's own
// fallback, unchanged. A non-finite FALLBACK yields null so the caller drops the badge entirely:
// never NaN into an SVG transform (a NaN blanks the element), never (0,0), never a guessed point.
import type { CombatUnit } from '../combat/combatTypes'
import { liveEncounterForFleet, type FleetEncounterLite } from '../combat/encounterAnchor'
import { resolveSpatialUnits } from './spatialCombatLayer'

export interface FleetFightPosition {
  /** WORLD coordinates — the same domain as locations.x/y and combat_units.pos_x/pos_y. Always finite. */
  x: number
  y: number
  /** 'formation' = the centroid of this fleet's own living, positioned ships — where it IS.
   *  'fallback'  = the caller's own resting position (no live fight, or no positioned ships). */
  source: 'formation' | 'fallback'
  /** True whenever the fleet has a LIVE encounter, positioned or not — a fleet in an aggregate
   *  (unpositioned) fight is still fighting and must still say so, it just cannot be placed. */
  fighting: boolean
}

const isFiniteNumber = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/**
 * Where to draw this fleet, given everything already on the map.
 *
 * `fallback` is where the caller would draw it with no fight in play — the site's centre for a fleet
 * present at a combat location, the fleet's own space_x/space_y for one parked in open space. It is
 * returned verbatim on every non-positioned path, so a caller that passes no encounters/units keeps
 * today's behaviour exactly.
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
  const rest = (fighting: boolean): FleetFightPosition => ({ x: fx, y: fy, source: 'fallback', fighting })

  const encounter = liveEncounterForFleet(input.encounters, input.fleetId)
  if (!encounter) return rest(false)

  // This fleet's OWN battle only: a second encounter's units must never drag the badge.
  const mine = input.units.filter((u) => u.encounter_id === encounter.id)
  // resolveSpatialUnits is the ONE positioned-and-alive filter (the glyph filter); `side` comes from
  // it too, so 'enemy' can never be folded into the player formation.
  const formation = resolveSpatialUnits(mine).filter((u) => u.side === 'player')
  if (formation.length === 0) return rest(true) // fighting, but aggregate/dark — nothing to stand on

  let sx = 0
  let sy = 0
  for (const u of formation) {
    sx += u.x
    sy += u.y
  }
  const cx = sx / formation.length
  const cy = sy / formation.length
  // Belt-and-braces: resolveSpatialUnits already guarantees finite coordinates, so this can only
  // trip on an overflow. Falling back beats emitting a NaN transform.
  if (!isFiniteNumber(cx) || !isFiniteNumber(cy)) return rest(true)
  return { x: cx, y: cy, source: 'formation', fighting: true }
}
