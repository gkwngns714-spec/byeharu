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
// authority for "where is this fleet while it fights" (its own living ship NEAREST THE ENEMY, with a
// stability margin so the answer does not flap between hulls). The fleet glyph asks it, so the glyph
// and the fleet BADGE that authority also places are the same point by construction — they cannot
// separate. Its documented jitter behaviour is inherited along with its answer, which is the price of
// having one authority instead of two.
//
// THE ENEMY SIDE IS NOT FOLDED, deliberately. A pirate pack is not a fleet: the rows carry no
// fleet_id, elect no lead (`aggro_priority` is NULL on every enemy row — verified on production), and
// each hostile lives, closes and dies independently. HOW MANY are still shooting is the player's
// central read of a fight and folding it away would delete it. The owner's complaint was about seeing
// four of THEIR OWN, and that is what this folds.

/** ONE GLYPH — a player FLEET, or a single enemy hull. */
export interface CombatActorView {
  /** stable render key: `fleet-<encounterId>` or `unit-<unitId>`. */
  key: string
  kind: 'fleet' | 'unit'
  encounterId: string
  side: 'player' | 'enemy'
  x: number
  y: number
  /** the actor's reach — the max weapon range across the hulls still alive in it. */
  range: number | null
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
    out.push({
      key: `fleet-${encounterId}`,
      kind: 'fleet',
      encounterId,
      side: 'player',
      x: placed?.x ?? stand.x,
      y: placed?.y ?? stand.y,
      range,
      hpFrac: hpMax > 0 ? Math.max(0, Math.min(1, hpNow / hpMax)) : 1,
      shipsAlive: alive.length,
      ships: members.length,
      unitIds: members.map((m) => m.id),
      alive: alive.length > 0,
    })
  }
  return out.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0))
}

