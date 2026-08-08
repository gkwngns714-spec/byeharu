// THE FLEET IS THE COMBAT ACTOR — the fold from one glyph PER SHIP to one glyph PER FLEET.
//
// Pure; no React/DOM/fetch/clock. It sits BETWEEN the two existing authorities and re-derives
// neither: `spatialCombatLayer.resolvePositionedUnits` decides which rows are on the map, and
// `fleetFightPosition.resolveFleetFightPosition` decides where a fighting fleet stands. Both are
// composed. It is its own module rather than part of the layer so that the layer can take the actors
// as an argument and import only their TYPE — otherwise the layer and fleetFightPosition would
// import each other at runtime, and a cycle between two leaves is exactly the tangle these files
// exist to avoid.
import type { CombatUnit } from '../combat/combatTypes'
import type { FleetEncounterLite } from '../combat/encounterAnchor'
import { resolveFleetFightPosition } from './fleetFightPosition'
import { fleetFormHull } from './shipVisual'
import { resolvePositionedUnits } from './spatialCombatLayer'

// ── WHY ─────────────────────────────────────────────────────────────────
//
// The owner: "why are there four ships? because i have 4 ships in fleet? no, show only fleet. it is
// as a whole."
//
// `combat_units` is one row PER SHIP — measured on production, the owner's fleet is four rows on
// every recent encounter — and this layer used to draw one glyph per row. That is the shape being
// rejected. The rows stay exactly as they are: they carry hp, losses, per-ship damage and 0336's
// engine work, and every number below is still summed off them. What changes is PRESENTATION: the
// player's fleet is ONE actor, drawn ONCE.
//
// WHERE THE ONE GLYPH STANDS — composed, not re-derived. map/fleetFightPosition is already the ONE
// authority for "where is this fleet while it fights" (the fleet's own 0315-ELECTED LEAD; the
// nearest-the-enemy rule survives only as its fallback, for a fleet whose lead is dead). The fleet
// glyph asks it, so the glyph and the fleet BADGE that authority also places are the same point by
// construction — they cannot separate. Everything it documents is inherited along with its answer,
// which is the price of having one authority instead of two.
//
// THIS FOLD IS WHY THE LEAD RULE EXISTS. While each hull drew its own glyph, a marker that hopped
// between hulls landed on a ship the player could see. Folding the hulls away made the same hop land
// on empty space — "when enemy ship is destroyed, i teleport to some random place inside the zone" —
// so the position rule had to stop being a function of the ENEMY set. See fleetFightPosition's header.
//
// THE ENEMY SIDE IS NOT FOLDED, deliberately. A pirate pack is not a fleet: the rows carry no
// fleet_id, elect no lead (`aggro_priority` is NULL on every enemy row — verified on production), and
// each hostile lives, closes and dies independently. HOW MANY are still shooting is the player's
// central read of a fight and folding it away would delete it. The owner's complaint was about seeing
// four of THEIR OWN, and that is what this folds.

/** ONE HULL'S REACH, stated as an OFFSET from the actor's drawn point.
 *
 *  ── WHY THE RING NEEDED THIS (the owner: "the range circle, outer circle when fighting, did not
 *  even touch a fleet yet it shot") ────────────────────────────────────────────────────────────────
 *  The drawn ring used to be ONE circle: centred on the fleet's drawn point (its elected LEAD) with
 *  the radius of the fleet's longest gun. But the ENGINE's fire gate measures EACH HULL from ITS OWN
 *  position. Measured on the owner's most recent live encounter — 4 alive hulls of range 5, the lead
 *  at (-53.13, 103.74), 6 alive enemies at 3.20 / 3.50 / 3.54 / 3.91 / 5.06 … 6.86 from that lead —
 *  the drawn circle enclosed 2 of the 6 while ALL SIX were legitimately shootable. Escorts sit on a
 *  CHORD and reach further forward than the lead, which sits a full formation RADIUS back. (That is
 *  the same inversion 0336's proof fixtures were caught on: escorts open a fight; the lead is the
 *  LAST hull that can reach.)
 *
 *  So a lead-centred circle cannot state a fleet's reach — not with a bigger radius either, because
 *  the true set is the UNION of the hulls' own discs and a circle is not that shape. The offsets are
 *  carried so the layer can draw the union itself, and what is DRAWN is then exactly what FIRES. */
export interface HullReach {
  /** world offset from the actor's drawn point to this hull's own position */
  dx: number
  dy: number
  /** that hull's own max weapon range in world units; null = unarmed, and it reaches nothing */
  range: number | null
}

/** ONE GLYPH — a player FLEET, or a single enemy hull. */
export interface CombatActorView {
  /** stable render key: `fleet-<encounterId>` or `unit-<unitId>`. */
  key: string
  kind: 'fleet' | 'unit'
  encounterId: string
  side: 'player' | 'enemy'
  x: number
  y: number
  /** the actor's reach — the max weapon range across the hulls still alive in it. The FURTHEST this
   *  actor can shoot, which is a real fact about it; it is NOT the drawn region (see `reach`). */
  range: number | null
  /** EVERY still-alive hull's own reach, as an offset from `x`/`y`. One entry for an enemy (itself);
   *  one per living hull for a fleet. The union of these discs is what the fire gate allows, and it
   *  is therefore what the layer draws. */
  reach: readonly HullReach[]
  /** WHAT THIS ACTOR IS, as the server names it: the representative `hull_type_id` for a fleet, the
   *  `unit_type_id` for a hostile. The key map/shipVisual turns into a form; null when nothing on the
   *  wire says (a fleet with no hull lookup in hand) — which shipVisual handles as `known: false`. */
  typeId: string | null
  /** Σ `hp_max` over EVERY positioned row this glyph stands for — the actor's BULK, which is what the
   *  size bands rank. The same denominator `hpFrac` uses, so a fleet's size and its condition can
   *  never be computed from two different sets of rows. */
  mass: number
  /** Σ hp_current ÷ Σ hp_max over EVERY positioned row this glyph stands for. A destroyed ship
   *  contributes 0 current and its FULL max, so a fleet that has lost a hull can never read as
   *  untouched — the aggregate is bounded above by the truth, never flattered by it. */
  hpFrac: number
  /** how many of its hulls are still alive, and how many it brought. `3 / 4` is drawn on the glyph:
   *  one actor, and the losses inside it still stated rather than hidden. */
  shipsAlive: number
  ships: number
  /** every positioned combat_units id this glyph stands for — what re-anchors that ship's damage
   *  numbers and its shots onto the actor. */
  unitIds: readonly string[]
  /** false = every hull in it is destroyed. No glyph is drawn, but it is still an anchor, so the
   *  blow that emptied the last hull has somewhere to land. */
  alive: boolean
}

/**
 * PURE: the rows → the GLYPHS. One per player fleet, one per living enemy hull.
 *
 * Composes `resolvePositionedUnits` (the one positional filter) and `resolveFleetFightPosition` (the
 * one "where is this fleet" rule); it re-derives neither. `encounters` supplies the fleet identity
 * those rules need — with none in hand for a group, the fleet still stands on a REAL SHIP of its own
 * (the fallback handed to that same authority), never on a mean and never on a synthesised point.
 */
export function resolveCombatActors(
  units: readonly CombatUnit[],
  encounters: readonly FleetEncounterLite[] = [],
  /** `main_ship_id` → `hull_type_id`. IDENTITY ONLY, and it adds NO read: `hull_type_id` is already
   *  on the wire as `FleetPosition.class` (get_my_fleet_positions, 0200), which the map already
   *  fetches every poll for the Port hub and the fleet roster. `combat_units` names the SHIP but not
   *  its class, so this is the join the client already had the data for and was throwing away.
   *  Omitted → every fleet's `typeId` is null and shipVisual draws its honest generic form. */
  hullTypeByShip: ReadonlyMap<string, string | null> = new Map(),
): CombatActorView[] {
  const positioned = resolvePositionedUnits(units)
  if (positioned.length === 0) return []
  const rowById = new Map(units.map((u) => [u.id, u]))
  const out: CombatActorView[] = []

  // Enemies: one actor per POSITIONED hull, alive or not. See the header for why they are not
  // folded. A destroyed one keeps its entry with `alive: false` — it draws no glyph, but the shot
  // that killed it and the number that killed it still have to land somewhere the player can see.
  // That is the same rule the fleet arm follows and the reason resolvePositionedUnits keeps a dead
  // row at all.
  for (const u of positioned) {
    if (u.side !== 'enemy') continue
    out.push({
      key: `unit-${u.id}`,
      kind: 'unit',
      encounterId: u.encounterId,
      side: 'enemy',
      x: u.x,
      y: u.y,
      range: u.range,
      // A hostile IS one hull, so its drawn reach is its own disc, centred on itself. The union
      // degenerates to exactly the single circle the layer always drew for an enemy.
      reach: u.alive ? [{ dx: 0, dy: 0, range: u.range }] : [],
      typeId: rowById.get(u.id)?.unit_type_id ?? null,
      mass: Math.max(0, rowById.get(u.id)?.hp_max ?? 0),
      hpFrac: u.hpFrac,
      shipsAlive: u.alive ? 1 : 0,
      ships: 1,
      unitIds: [u.id],
      alive: u.alive,
    })
  }

  // Players: one actor per FIGHT, because one fight is one fleet (combat_encounters.fleet_id, and
  // the DB's one_active_encounter_per_fleet index makes that one-to-one).
  const byEncounter = new Map<string, typeof positioned>()
  for (const u of positioned) {
    if (u.side !== 'player') continue
    const list = byEncounter.get(u.encounterId)
    if (list) list.push(u)
    else byEncounter.set(u.encounterId, [u])
  }
  for (const [encounterId, members] of byEncounter) {
    const alive = members.filter((m) => m.alive)
    // The fallback is a REAL SHIP of this fleet — the lowest-id living hull, or the lowest-id hull
    // at all once none are living. resolveFleetFightPosition returns it verbatim when it cannot
    // reach its primary rule, so every arm of this answer is one of our own hulls.
    const stand = alive[0] ?? members[0]
    const encounter = encounters.find((e) => e.id === encounterId)
    const placed = resolveFleetFightPosition({
      fleetId: encounter?.fleet_id ?? null,
      encounters,
      units,
      fallback: { x: stand.x, y: stand.y },
    })
    let hpNow = 0
    let hpMax = 0
    for (const m of members) {
      const row = rowById.get(m.id)
      if (!row) continue
      hpNow += Math.max(0, row.hp_current)
      hpMax += Math.max(0, row.hp_max)
    }
    let range: number | null = null
    for (const m of alive) if (m.range !== null) range = range === null ? m.range : Math.max(range, m.range)
    const px = placed?.x ?? stand.x
    const py = placed?.y ?? stand.y
    // THE FLEET'S TRUE REACH, hull by hull, relative to the point it is DRAWN on. Not the lead's
    // circle — see HullReach's header for the measured encounter where that enclosed 2 of 6 legally
    // shootable enemies. Only LIVING hulls contribute: a wreck's gun is not a reach the fleet has,
    // which is the same rule `range` above already follows.
    const reach: HullReach[] = alive.map((m) => ({ dx: m.x - px, dy: m.y - py, range: m.range }))
    // WHICH HULL SPEAKS FOR THE FLEET — the bulkiest living one, through the ONE rule
    // (shipVisual.fleetFormHull). Deliberately not the elected lead: a lead exists only inside a
    // fight, and the shape has to be the same outside one. `hp_max` is the measured bulk here; the
    // roster path reads the same quantity out of the hull catalog.
    const formHull = fleetFormHull(
      (alive.length > 0 ? alive : members).map((m) => ({
        typeId: hullTypeByShip.get(rowById.get(m.id)?.main_ship_id ?? '') ?? null,
        mass: rowById.get(m.id)?.hp_max ?? null,
        key: m.id,
      })),
    )
    out.push({
      key: `fleet-${encounterId}`,
      kind: 'fleet',
      encounterId,
      side: 'player',
      x: px,
      y: py,
      range,
      reach,
      typeId: formHull,
      mass: hpMax,
      hpFrac: hpMax > 0 ? Math.max(0, Math.min(1, hpNow / hpMax)) : 1,
      shipsAlive: alive.length,
      ships: members.length,
      unitIds: members.map((m) => m.id),
      alive: alive.length > 0,
    })
  }
  return out.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0))
}

