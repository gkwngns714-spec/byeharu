// COMBAT-S4 — the SPATIAL-COMBAT map layer: renders an active on-map battle (COMBAT-S3 / migration
// 0234's server core) so the player SEES it. Follows the territoryLayer / miningFieldRangeLayer /
// teamMarkersLayer element-helper convention: PURE, hook-free, returns element descriptors, so
// GalaxyMap and the unit test call the SAME function. Mounted ABOVE the location markers (the units
// are the focus of the frame) and every element is pointer-transparent (a battle is a spectacle, not
// a tap surface — the location marker under it stays the tap target).
//
// ── FAIL-CLOSED BY DATA (the flag is never read here) ────────────────────────────────────────────────
// A unit is "spatial" iff it carries a non-NULL pos_x/pos_y. While spatial_combat_enabled is dark (its
// prod state) NO combat_units row is ever written with a position (0234's creator resets the columns to
// NULL every iteration and only computes them when lit), so `units` filtered to spatial rows is ALWAYS
// empty in a dark world and this layer renders NOTHING — zero visible surface, byte-identical to a map
// without it. This is the SAME "data-gated, not flag-gated" posture as the danger-zone / telegraph
// layers: the client reads no game_config flag; the absence of positioned rows IS the gate.
//
// ── COORDINATE TRUTH ─────────────────────────────────────────────────────────────────────────────────
// A spatial unit's pos_x/pos_y live in the SAME fixed WORLD domain as locations.x/y (0234 seeds the
// command ship at the location centre and displaces escorts / enemies in world units), so positions
// project through the map's ONE `norm` = worldToViewBox, exactly like every marker; the weapon RANGE is
// a real world-unit distance, so its ring radius is `range * WORLD_TO_VIEWBOX_SCALE` viewBox units and
// grows/shrinks with zoom (world-true — the SAME idiom as territory / mining rings). Only stroke width
// and glyph size divide by `k` (line weight / glyph are presentation, pinned to a screen size).
//
// ── WHAT ANIMATES, AND HOW ───────────────────────────────────────────────────────────────────────────
// THIS LAYER STILL HOLDS NO CLOCK — it is handed one. Everything below is a function of the rows in
// hand and the `nowMs` the caller passes, so the specs drive it with their own clock.
//
// The motion itself is NOT done here and is not done twice: map/combatMotion.ts folds each poll into
// a keyframe ledger and hands this layer rows whose pos_x/pos_y have ALREADY been moved to where they
// are at `nowMs`, by composing the one interpolation primitive in map/movementInterpolation.ts. That
// is deliberate — see smoothCombatUnits' header for why the ROWS are smoothed and not the glyphs (the
// fleet badge composes resolveSpatialUnits too, and a badge on the raw point beside a glyph on the
// tweened one is the same fleet drawn twice in two places). So:
//   • enemy pirates spawn at the location centre and CLOSE toward the fleet → each tick's step is
//     played out over the server's own measured tick interval, so they are SEEN crossing.
//   • kiting player ships back away to their range edge → likewise, a slide rather than a jump.
//   • a weapon that fired THIS tick emits a combat_event (missile_salvo, payload {unit_id,target_id})
//     → a fire line marks the lane and a ROUND travels along it, drawn from the firing ship's own
//     weapons_json, arriving exactly when its damage number appears.
// Before this, a position updated on tick arrival was a step function: three seconds at A, then B.
import { createElement, type ReactElement } from 'react'
import type { CombatEvent, CombatUnit } from '../combat/combatTypes'
import type { CombatActorView } from './combatActors'
import {
  resolveOrdnance,
  resolveShotArrivals,
  tickArtifactLive,
  type EventSightings,
} from './combatMotion'
import { WORLD_TO_VIEWBOX_SCALE } from './openSpaceTransform'
import { renderShipVisual } from './shipGlyph'
import { SIDE_TONE, shipVisual } from './shipVisual'

/** The minimal spatial view of a combat unit — the subset the layer projects. Any CombatUnit with a
 *  position satisfies it. Kept explicit so the pure resolver + spec don't depend on the full row. */
export interface SpatialUnitView {
  id: string
  /** the fight this unit belongs to. Present because "the latest tick" is a question about ONE
   *  encounter: with two battles running, a global max silently blanked the lower-tick one. */
  encounterId: string
  side: 'player' | 'enemy'
  x: number
  y: number
  /** max weapon range in world units, or null when the unit carries no ranged weapon (→ no ring). */
  range: number | null
  /** 0..1 health fraction (hp_current / hp_max) — dims a battered unit's glyph. 1 when unknown. */
  hpFrac: number
  /** alive_count > 0. A dead unit draws NO glyph, but it still has a position, and the blow that
   *  killed it still has to land somewhere the player can see — see resolveHitSplats. */
  alive: boolean
}

/** The unit's range ring radius = the MAX `range` across its frozen weapons_json (world units). A unit
 *  with no ranged weapon (empty/rangeless array) returns null → a dot with no ring (honest: it can't
 *  reach out). Pure. */
export function unitWeaponRange(u: Pick<CombatUnit, 'weapons_json'>): number | null {
  let max: number | null = null
  for (const w of u.weapons_json ?? []) {
    const r = w?.range
    if (typeof r === 'number' && Number.isFinite(r) && r > 0) max = max === null ? r : Math.max(max, r)
  }
  return max
}

/** PURE: combat_units → every POSITIONED row, alive or not. This is the ONE positional filter: a
 *  row is "on the map" iff it carries non-NULL finite pos_x/pos_y (the fail-closed dark gate).
 *  Liveness is carried as a FLAG rather than applied here, because the two consumers need different
 *  answers from the same fact: a glyph may only be drawn for a living unit, while the damage number
 *  that KILLED one still has to float over the wreck. Order is stable by id so the element tree is
 *  deterministic across polls. */
export function resolvePositionedUnits(units: readonly CombatUnit[]): SpatialUnitView[] {
  const out: SpatialUnitView[] = []
  for (const u of units) {
    if (u.pos_x == null || u.pos_y == null) continue // not spatial → dark fail-closed
    if (!Number.isFinite(u.pos_x) || !Number.isFinite(u.pos_y)) continue
    const hpFrac = u.hp_max > 0 ? Math.max(0, Math.min(1, u.hp_current / u.hp_max)) : 1
    out.push({
      id: u.id,
      encounterId: u.encounter_id,
      side: u.side === 'enemy' ? 'enemy' : 'player',
      x: u.pos_x,
      y: u.pos_y,
      range: unitWeaponRange(u),
      hpFrac,
      alive: u.alive_count > 0,
    })
  }
  return out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
}

/** PURE: the units that draw a GLYPH — positioned AND still alive (a destroyed unit vanishes).
 *  Composes the one positional filter above; it does not repeat it. Every existing consumer
 *  (the glyph/ring pass, fleetFightPosition's "which hull is nearest") means exactly this set. */
export function resolveSpatialUnits(units: readonly CombatUnit[]): SpatialUnitView[] {
  return resolvePositionedUnits(units).filter((u) => u.alive)
}

/** WHERE ONE UNIT'S THINGS RENDER — its actor's point. The ONE substitution that makes the fold
 *  total: a shot leaves the FLEET, a shot lands on the FLEET, and a damage number floats over the
 *  FLEET, because every one of them looks the unit up here instead of reading its own row. */
export interface RenderPoint {
  /** the ACTOR's key — what groups two hits, or two rounds, that belong to the same glyph. */
  key: string
  side: 'player' | 'enemy'
  x: number
  y: number
}

/** PURE: unit id → the point its actor stands on. */
export function resolveRenderPoints(actors: readonly CombatActorView[]): ReadonlyMap<string, RenderPoint> {
  const out = new Map<string, RenderPoint>()
  for (const a of actors) {
    for (const id of a.unitIds) out.set(id, { key: a.key, side: a.side, x: a.x, y: a.y })
  }
  return out
}

/** A fire line to draw this tick: source→target world segment + the firing side (for tone). */
export interface FireLineView {
  key: string
  sourceSide: 'player' | 'enemy'
  x1: number
  y1: number
  x2: number
  y2: number
}

/** PURE: the latest tick_number PER ENCOUNTER among the events a predicate accepts.
 *
 *  THE DEFECT THIS KILLS. Both resolvers below used to scan for ONE global maximum across every
 *  event in hand. `useCombat` fetches events for EVERY live encounter in a single query, and two
 *  simultaneous fights do not share a tick counter — so with an older encounter at t80 and a fresh
 *  one at t2, the global max was 80 and the new battle drew no fire lines and no damage numbers at
 *  all. "The latest exchange" is a question about one fight; it is answered per fight. */
export function latestTickByEncounter(
  events: readonly CombatEvent[],
  accept: (e: CombatEvent) => boolean,
): Map<string, number> {
  const out = new Map<string, number>()
  for (const e of events) {
    if (!accept(e)) continue
    const prev = out.get(e.encounter_id)
    if (prev === undefined || e.tick_number > prev) out.set(e.encounter_id, e.tick_number)
  }
  return out
}

/** A SPATIAL fire event: a missile_salvo naming the unit that fired. The aggregate-combat salvo
 *  (dark path) carries no unit_id and is therefore not one. Exported because the fire lines, the
 *  ordnance and the splat-arrival pairing must all be looking at the SAME set of shots — three
 *  copies of this predicate is how they would drift apart. */
export const isSpatialSalvo = (e: CombatEvent): boolean =>
  e.event_type === 'missile_salvo' && !!e.payload_json && e.payload_json['unit_id'] != null

/** PURE: combat_events + the render points → the fire lines for the latest tick OF EACH ENCOUNTER.
 *  A spatial fire event is a 'missile_salvo' whose payload carries {unit_id, target_id} (0234's
 *  spatial fire hunk). Both endpoints must resolve to a RENDERED point — a shot at a unit that was
 *  never on the map draws nothing (never a guessed line), but a shot at one that DIED this tick
 *  still draws, because that is the shot the player most wants to see. Only each encounter's highest
 *  tick_number is drawn, so old salvos fade as the poll advances.
 *
 *  Since the fleet fold, a player ship's endpoint is its FLEET's point, so a lane runs between the
 *  two things the player can actually see rather than to a hull that is no longer drawn alone. Two
 *  ships of one fleet firing at one target therefore share a lane — which is what a volley is. */
export function resolveFireLines(
  events: readonly CombatEvent[],
  points: ReadonlyMap<string, RenderPoint>,
  /** The exchange's own window (combatMotion.tickArtifactLive). Omitted → no expiry, i.e. exactly the
   *  behaviour before it existed. Supplied, a lane stops being drawn once its exchange is over —
   *  otherwise the last salvo of a fight paints a permanent line at a wreck, for the same reason a
   *  hitsplat used to become permanent (see resolveHitSplats). */
  life?: { sightings: EventSightings; nowMs: number },
): FireLineView[] {
  const latest = latestTickByEncounter(events, isSpatialSalvo)
  if (latest.size === 0) return []
  const out: FireLineView[] = []
  for (const e of events) {
    if (e.event_type !== 'missile_salvo') continue
    if (latest.get(e.encounter_id) !== e.tick_number) continue
    if (life && !tickArtifactLive(life.sightings, e.id, life.nowMs)) continue
    const p = e.payload_json ?? {}
    const src = points.get(String(p['unit_id'] ?? ''))
    const tgt = points.get(String(p['target_id'] ?? ''))
    if (!src || !tgt) continue // one endpoint gone → no line
    out.push({ key: `${e.id}`, sourceSide: src.side, x1: src.x, y1: src.y, x2: tgt.x, y2: tgt.y })
  }
  return out
}

/** The side→token map, composed from the ONE table (map/shipVisual.SIDE_TONE) rather than re-typed
 *  here. It is used for the fire lines, the rounds and the damage numbers as well as the ships, so it
 *  keeps its local name — but there is one set of values, in one file. */
const SIDE_COLOR = SIDE_TONE

/** ONE HIT, ONE NUMBER — the RS3 hitsplat read. */
export interface HitSplatView {
  key: string
  /** the unit that TOOK this hit — the splat's anchor, and what groups the fan-out below */
  unitId: string
  x: number
  y: number
  /** the damage the SERVER dealt; never computed here. null on a pure kill mark (a destroy event
   *  with no damage event of its own). */
  damage: number | null
  /** the side that TOOK the hit, so the splat is coloured by who is hurting */
  side: 'player' | 'enemy'
  /** this splat IS the kill mark — the blow that emptied the stack */
  destroyed: boolean
  /** 0-based slot among the splats landing on THIS GLYPH this tick, and how many there are. Two hits
   *  must read as two numbers side by side, so the layer fans them from these. Grouped by the ACTOR,
   *  not by the unit: since the fleet fold, four hulls' damage lands on one glyph, and fanning per
   *  hull would stack every number at the same point. */
  index: number
  count: number
  /** Local clock ms at which the ROUND that carried this hit arrives, when this splat could be
   *  paired with a real salvo (combatMotion.resolveShotArrivals). null = unpaired, and an unpaired
   *  damage row is shown at once — a real hit is never hidden waiting on a visual. */
  arrivesAtMs: number | null
}

/** PURE: combat_events + the positioned units → this tick's damage numbers, ONE PER HIT.
 *
 *  The server already emits everything needed: since 0314 EVERY landed hit writes its own
 *  `hull_damage` {unit_id, damage} row under the lit event flag (0314:206-213), and a stack that
 *  empties writes `unit_destroyed` {unit_id, count} (0299:930-934). Nothing is derived here — no
 *  damage is computed, no hit is rolled, no total is re-summed.
 *
 *  ── THE TWO DEFECTS THIS REPLACES ────────────────────────────────────────────────────────────────
 *  1. IT SHOWED THE LAST HIT AND HID THE REST. The old resolver keyed a Map by unit_id and
 *     OVERWROTE the entry per event, so a ship hit twice in one tick displayed only the second
 *     number. Measured on a production tick: hits of 4.136 and 4.286 landed on one hull and the map
 *     printed "4" for 8.4 taken. The player could not add up what was happening to them, and the
 *     number they were shown was not any quantity that existed. Now every hull_damage event is its
 *     own splat, and `index`/`count` fan them out so both stay legible — the RS3 read, where a
 *     multi-hit tick shows multiple splats.
 *  2. THE KILLING BLOW RENDERED NOTHING. Anchors were resolved against the ALIVE set, and the tick
 *     that kills a unit is the tick that sets alive_count to 0 — so the unit that just died was
 *     already gone from the lookup and BOTH its final damage number and its ✕ were dropped. Ships
 *     blinked out in silence. Anchors now come from resolvePositionedUnits, which keeps a dead
 *     row's last known position for exactly this frame.
 *
 *  The latest tick is resolved PER ENCOUNTER (see latestTickByEncounter). A splat whose unit never
 *  had a position draws nothing: a number floating over empty space is worse than no number. The
 *  aggregate (non-spatial) damage events carry `group` instead of `unit_id`, so they are naturally
 *  ignored — they have no position to float over.
 *
 *  ── 3. AND THEN IT NEVER LEFT (the owner: "when fleet is destroyed, i want also a damage shown to
 *  be disappeared as well") ────────────────────────────────────────────────────────────────────────
 *  Defect 2's fix is what created this one, and the two are one decision seen from both ends. A
 *  splat is anchored through `points`, which is built from EVERY actor — the dead ones included —
 *  precisely so a killing blow has somewhere to land. But the resolver had a START and no END: a
 *  splat was returned on every frame for as long as its tick remained the encounter's newest.
 *  Mid-fight that is three seconds. **On the blow that empties the field it is forever**: a
 *  destroyed unit is never targeted again (0317), so no later tick carries a hit, so the kill tick
 *  stays "latest" and its number and its ✕ sit on the wreck until something else gets shot — which,
 *  between reinforcements, is not soon. The player's own report of it was a corpse still showing
 *  its damage.
 *  The bound is `life`, and it is deliberately NOT "hide it once the unit is dead": that would blank
 *  the killing blow itself, which is defect 2 coming straight back. The exchange's DRAWING is bounded
 *  by the exchange (combatMotion.TICK_READOUT_MS) — one rule over the whole class of tick artifacts,
 *  shared with the fire lines, and one that cannot fire while a fight is still trading blows. */
export function resolveHitSplats(
  events: readonly CombatEvent[],
  points: ReadonlyMap<string, RenderPoint>,
  /** WHEN each shot lands, keyed `${victimId}#${ordinal}` (combatMotion.resolveShotArrivals). Omitted
   *  → every splat is unpaired and shows immediately, which is exactly the pre-ordnance behaviour. */
  arrivals?: ReadonlyMap<string, number>,
  /** WHEN THE EXCHANGE IS OVER (combatMotion.tickArtifactLive). Omitted → no expiry, i.e. exactly the
   *  behaviour before it existed, which is what every spec that passes no ledger still measures. */
  life?: { sightings: EventSightings; nowMs: number },
): HitSplatView[] {
  const isHit = (e: CombatEvent) =>
    (e.event_type === 'hull_damage' || e.event_type === 'unit_destroyed') &&
    !!e.payload_json &&
    e.payload_json['unit_id'] != null
  const latest = latestTickByEncounter(events, isHit)
  if (latest.size === 0) return []

  // Deterministic order: the server's own (seq, id) sequence within the tick. Events arrive
  // newest-id-first from the API, so without this the fan could re-order between polls.
  const landed = events
    .filter(
      (e) =>
        isHit(e) &&
        latest.get(e.encounter_id) === e.tick_number &&
        (!life || tickArtifactLive(life.sightings, e.id, life.nowMs)),
    )
    .sort((a, b) => a.seq - b.seq || a.id - b.id)

  const out: (HitSplatView & { anchorKey: string })[] = []
  // TWO counters, on purpose. The FAN is grouped by the glyph the number lands on (four hulls, one
  // fleet glyph, four numbers side by side). The shot PAIRING is per victim unit, because that is
  // what the server aimed at and what resolveShotArrivals keyed.
  const perAnchor = new Map<string, number>()
  const perUnit = new Map<string, number>()
  for (const e of landed) {
    const p = e.payload_json ?? {}
    const id = String(p['unit_id'] ?? '')
    const u = points.get(id)
    if (!u) continue
    const index = perAnchor.get(u.key) ?? 0
    perAnchor.set(u.key, index + 1)
    const shotIndex = perUnit.get(id) ?? 0
    perUnit.set(id, shotIndex + 1)
    const destroyed = e.event_type === 'unit_destroyed'
    const raw = Number(p['damage'])
    out.push({
      key: `splat-${e.id}`,
      unitId: id,
      anchorKey: u.key,
      x: u.x,
      y: u.y,
      // A destroy event carries a `count`, never a damage figure — it is a kill MARK, not a number.
      damage: destroyed || !Number.isFinite(raw) ? null : raw,
      side: u.side,
      destroyed,
      index,
      count: 0, // filled below, once every splat on this glyph is known
      // The k-th hit on this hull was carried by the k-th round aimed at it — the server's own
      // (seq, id) order on both sides, paired in combatMotion.resolveShotArrivals.
      arrivesAtMs: arrivals?.get(`${id}#${shotIndex}`) ?? null,
    })
  }
  for (const s of out) s.count = perAnchor.get(s.anchorKey) ?? 1
  return out
}

/** How far out (world units) a fight's frame is padded for a unit with no weapon range at all, and
 *  the floor for every unit's contribution. Post-0316 weapon ranges are 5-6 and the formation ring
 *  is 6, so this frames a whole engagement rather than one hull. */
export const ARENA_MIN_RADIUS = 8

/** PURE: the WORLD points that must be inside the frame for a battle to be legible — every living
 *  positioned unit's position, padded by its own weapon reach.
 *
 *  ── WHY A CAMERA ANSWER AND NOT A DRAWING ONE ────────────────────────────────────────────────────
 *  At the map's own default camera a whole engagement occupies single-digit pixels: post-0316 the
 *  weapon ranges are 5-6 world units and the formation ring is 6, against a world span of 20000.
 *  The alternative fix — drawing the battle at a presentation MULTIPLE of its true size — was
 *  rejected: it would put the ship glyphs somewhere their world coordinates are not, and the fleet
 *  badge stands by law on a real ship's real position (map/fleetFightPosition), so the badge and
 *  the ships it names would separate again. That is precisely the "same fleet drawn twice in two
 *  places" defect fleetFightPosition exists to kill, and it would add a second coordinate authority
 *  to a map that has exactly one (openSpaceTransform). So the fight stays world-true and the CAMERA
 *  goes to it, through the same `fitCameraToWorldPoints` every other framing already uses.
 *
 *  `encounterId` scopes it to ONE battle — framing two distant fights at once frames neither. */
export function combatFocusWorldPoints(
  units: readonly CombatUnit[],
  encounterId: string | null,
): { x: number; y: number }[] {
  if (!encounterId) return []
  const out: { x: number; y: number }[] = []
  for (const u of resolveSpatialUnits(units)) {
    if (u.encounterId !== encounterId) continue
    const r = Math.max(u.range ?? 0, ARENA_MIN_RADIUS)
    out.push({ x: u.x - r, y: u.y - r }, { x: u.x + r, y: u.y + r })
  }
  return out
}

/** PURE: which live encounter the map should frame and offer controls for — the NEWEST one that
 *  actually has ships on the map. `encounters` arrives newest-first (combatApi orders by created_at
 *  desc), so the first positioned match is the fight the player just walked into. null = no
 *  positioned battle, and every combat-only map control stays unmounted. */
export function focusableEncounterId(
  encounters: readonly { id: string; status: string }[],
  units: readonly CombatUnit[],
): string | null {
  const positioned = new Set(resolveSpatialUnits(units).map((u) => u.encounterId))
  for (const e of encounters) {
    if (e.status !== 'active' && e.status !== 'retreating') continue
    if (positioned.has(e.id)) return e.id
  }
  return null
}

// ── THE COMBAT READOUT IS SIZED IN CSS PIXELS, NOT IN viewBox UNITS ───────────────────────────────
// Every glyph on this map is drawn `÷ k`, which makes it constant in VIEWBOX units — and a viewBox
// unit is not a pixel. Under `preserveAspectRatio="xMidYMid meet"` the px-per-viewBox-unit is
// `min(width, height) / 1000`, so on the 390px phone the owner tests at, everything ÷k renders at
// 0.39× its nominal size: the damage number, nominally 10, arrived as 3.9 CSS px — measured. That is
// unreadable, on the one element whose entire job is to be read.
//
// So the combat readout sizes itself in real pixels, from the letterbox scale GalaxyMap measures off
// its own element through the ONE authority for it (openSpaceTransform.viewBoxDisplayRect). It
// re-derives nothing and it moves nothing: POSITIONS stay world-true, only the screen-constant
// chrome is corrected. `pxScale` defaults to 1, which is exactly the old ÷k behaviour for any caller
// that does not measure.
const SPLAT_DISC_PX = 11
const SPLAT_TEXT_PX = 13
const SPLAT_LIFT_PX = 20
/** Horizontal gap between two splats landing on the SAME hull in one tick — wide enough that two
 *  three-digit numbers never touch. */
const SPLAT_FAN_GAP_PX = 26
// GLYPH_PX is GONE. A ship's size is not this file's decision any more — map/shipVisual's ordered
// band table owns it, and its ceiling (FLEET_SIZE_CAP_PX) is exactly the `7 × 1.35` this constant
// used to produce, so nothing on screen got bigger than what shipped.
const PIP_W_PX = 22
const PIP_H_PX = 3.5
const PIP_LIFT_PX = 13
/** A round's radius, in CSS px, at the two ends of a weapon's share of its ship's volley (0331). A
 *  lone gun throws the whole volley in one round (share 1 → the larger); two guns throw half each. */
const SHOT_MIN_R_PX = 2.2
const SHOT_MAX_R_PX = 5
/** Perpendicular spacing between rounds sharing one lane — a volley reads as several rounds. */
const SHOT_LANE_GAP_PX = 7
/** The reach region's boundary, in CSS px. Half of each stroke falls inside the region and is masked
 *  away (see the edge pass), so the visible band is half this. */
const REACH_EDGE_PX = 2.4

/** One disc of a reach region, ALREADY PROJECTED — viewBox coordinates and a viewBox radius. */
export interface ReachDisc {
  cx: number
  cy: number
  r: number
}

/**
 * PURE: the discs → ONE path whose interior is exactly their UNION.
 *
 * ── WHY A PATH EXISTS BESIDE THE CIRCLES (the owner: "my fleet range shape in blue is weird") ──────
 * The region drawn was N separate filled `<circle>`s under one group opacity. That composites to a
 * flat union with no darkened laps — but it has NO BOUNDARY, and without one a four-lobed cloud at
 * 14% opacity does not read as a thing, it reads as a smudge. Measured on the owner's own encounter
 * `49acbae0`: four hulls spanning 5.1 × 4.2 world units, every weapon range 5 — a formation as wide
 * as its own reach, so the discs make a lumpy scalloped cloud ~15 units across with no edge at all,
 * while the fleet itself is drawn as ONE glyph. One actor, four unoutlined lobes: those two
 * decisions contradicted each other on screen.
 *
 * THE ANSWER IS AN EDGE, NOT A DIFFERENT SHAPE. The union IS the fire rule — the engine gates each
 * hull from its OWN position — so shrinking it to a circle, or smoothing it, would put the drawing
 * back to lying (that circle enclosed 2 of 6 legally shootable enemies; see HullReach's header).
 * What changes is only that the region now has a silhouette: this path, stroked and masked to its own
 * exterior, so the internal arcs where the discs overlap are cut away and only the OUTER boundary
 * survives. One region, one edge, exactly the same set of points inside it.
 *
 * Each disc is one closed subpath of two half-arcs, all wound the same way, so `fill-rule="nonzero"`
 * fills the union in a single paint (no seams, no double-covered laps) and the whole thing masks as
 * one shape. The format is deliberately regular enough to read back — tests/spatialCombatLayer.spec.ts
 * parses it to check containment against the same discs it passed in.
 */
export function reachRegionPath(discs: readonly ReachDisc[]): string {
  return discs
    .map(
      (d) =>
        `M${d.cx - d.r},${d.cy}A${d.r},${d.r} 0 1,0 ${d.cx + d.r},${d.cy}A${d.r},${d.r} 0 1,0 ${d.cx - d.r},${d.cy}Z`,
    )
    .join('')
}

/** The pure, hook-free GalaxyMap spatial-combat layer (the element-helper convention). Returns element
 *  DESCRIPTORS only — no hooks — so the unit spec calls this SAME function and inspects the tree. No
 *  positioned units → [] (the map is byte-identical to today; dark by data). Order: range rings first
 *  (scenery), then fire lines, then unit glyphs + their hull pips, then this tick's damage numbers on
 *  the very top. */
export function spatialCombatLayer(args: {
  /** the ACTORS — one glyph per player FLEET, one per living enemy hull (combatActors.ts). The layer
   *  renders what it is given: it neither folds nor places, so there is one authority for each. */
  actors: readonly CombatActorView[]
  /** the rows ALREADY smoothed to `nowMs` by combatMotion.smoothCombatUnits — read here only for the
   *  weapons the ordnance is drawn from and the lead it falls back to. */
  units: readonly CombatUnit[]
  events: readonly CombatEvent[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
  /** CSS px per viewBox unit — `viewBoxDisplayRect(rect).scale`, measured by GalaxyMap from its own
   *  element. Omitted / non-positive → 1, i.e. the historic ÷k sizing. */
  pxScale?: number
  /** When each fire event was first seen (combatMotion.observeShots) + the clock to render at.
   *  Omitted → no ordnance and no splat delay, i.e. byte-identical to the pre-ordnance layer. */
  sightings?: EventSightings
  nowMs?: number
}): ReactElement[] {
  // viewBox units per CSS pixel, at the current camera and letterbox. The ONE place this layer turns
  // a wanted screen size into the number an SVG attribute takes.
  const scale = args.pxScale && Number.isFinite(args.pxScale) && args.pxScale > 0 ? args.pxScale : 1
  const px = (cssPx: number) => cssPx / (args.k * scale)
  const actors = args.actors
  if (actors.length === 0) return [] // dark / no active spatial battle → nothing
  // TWO SETS, ONE FOLD. `actors` is every glyph the fight has; `views` is the living subset that
  // draws one. An all-destroyed fleet keeps its entry so the blow that emptied it still lands
  // somewhere visible — see resolveHitSplats' header.
  const views = actors.filter((a) => a.alive)

  // ONE decision about which exchange is "the latest", shared by the lines, the rounds and the
  // numbers. `points` is the ONE substitution behind the fleet fold: every shot and every damage
  // number looks its unit up here, so nothing can render at a hull that is no longer drawn alone.
  const nowMs = args.nowMs ?? 0
  const sightings = args.sightings ?? {}
  const latestSalvoTick = latestTickByEncounter(args.events, isSpatialSalvo)
  const points = resolveRenderPoints(actors)
  const shotArgs = {
    events: args.events,
    latestTick: latestSalvoTick,
    endpoints: points,
    units: args.units,
    sightings,
  }
  const arrivals = args.sightings ? resolveShotArrivals(shotArgs) : undefined
  // THE EXCHANGE'S OWN WINDOW — passed to every artifact of a tick, so the lines and the numbers
  // expire together. Absent ledger → undefined → no expiry anywhere (the pre-D7 behaviour, which is
  // what a caller that keeps no sightings still gets).
  const life = args.sightings ? { sightings, nowMs } : undefined

  const out: ReactElement[] = []

  // ── 1) THE REACH REGION — what this actor can actually shoot (world-true, faint, under the glyphs)
  //
  // THE OWNER: "the range circle, outer circle when fighting, did not even touch a fleet yet it shot."
  //
  // It was ONE circle on the fleet's drawn point (its elected LEAD) with the radius of the fleet's
  // longest gun. The engine's fire gate measures EACH HULL from ITS OWN position, so on the owner's
  // last live encounter — 4 hulls of range 5, six enemies at 3.20-6.86 from the lead — the drawn
  // circle held 2 of 6 while all 6 were legitimately shootable. The lead sits a formation RADIUS
  // back; its escorts sit on a CHORD and reach further forward than it does.
  //
  // The fix is not a bigger circle: the set the gate allows is the UNION of the hulls' own discs, and
  // that is not circular. So the union is what is drawn — one disc per living hull
  // (CombatActorView.reach), FILLED and composited under a single group opacity, which is what makes
  // overlapping discs render as one flat region with no internal seams and no darkened laps. WHAT IS
  // DRAWN IS NOW THE RULE: nothing inside the region is out of reach and nothing outside it can fire.
  //
  // ── AND THEN THE OWNER LOOKED AT IT: "my fleet range shape in blue is weird." ───────────────────
  // The set was right and the DRAWING was still not a thing you could read. A flat 14% wash with no
  // boundary is a smudge, and on the owner's real geometry — a formation as wide as its own reach —
  // it is a lumpy four-lobed smudge, standing under a fleet that is drawn as ONE glyph. The union is
  // not negotiable (it is the rule), so what it was missing is an EDGE: a second pass strokes the
  // same discs as ONE path and masks that stroke to the region's own exterior, which deletes every
  // internal arc and leaves precisely the outer silhouette. Same points inside, now with a border —
  // one actor, one region, one outline.
  //
  // An enemy is one hull, so its region degenerates to exactly the single circle it always had, and
  // its edge to that circle's own outline.
  for (const u of views) {
    const reaching = u.reach.filter((r): r is { dx: number; dy: number; range: number } =>
      typeof r.range === 'number' && Number.isFinite(r.range) && r.range > 0,
    )
    if (reaching.length === 0) continue // nothing aboard reaches out → no region (honest: it cannot)
    const color = SIDE_COLOR[u.side]
    // PROJECTED ONCE, USED TWICE. The fill and the edge are two renderings of ONE set of discs, so
    // they cannot disagree about where the region is. World-true radii: viewBox units, NOT /k — a
    // reach is a real distance and scales with zoom, the same idiom as the territory/mining rings.
    const discs: ReachDisc[] = reaching.map((d) => {
      const p = args.norm({ x: u.x + d.dx, y: u.y + d.dy })
      return { cx: p.x, cy: p.y, r: d.range * WORLD_TO_VIEWBOX_SCALE }
    })
    out.push(
      createElement(
        'g',
        {
          key: `spatial-range-${u.key}`,
          'data-testid': `spatial-combat-range-${u.key}`,
          'data-hulls': String(discs.length),
          opacity: 0.14, // group-level: the discs union instead of stacking into hot spots
          style: { pointerEvents: 'none' as const },
        },
        ...discs.map((d, i) =>
          createElement('circle', {
            key: `reach-${i}`,
            cx: d.cx,
            cy: d.cy,
            r: d.r,
            fill: color,
            fillOpacity: 1,
            stroke: 'none',
          }),
        ),
      ),
    )
    // ── THE SILHOUETTE. One path, stroked, masked to the region's OWN EXTERIOR ────────────────────
    // The mask is white everywhere in the region's box and BLACK over the union itself, so the half
    // of the stroke that falls inside is erased and the arcs buried under a neighbouring disc vanish
    // whole. What is left is the outer boundary and nothing else — the difference between "four
    // circles were drawn here" and "this is the area we cover". It is a SEPARATE element rather than
    // a child of the group above because that group is at 14%, and an outline at 14% is not an
    // outline.
    const d = reachRegionPath(discs)
    const edge = px(REACH_EDGE_PX)
    const pad = edge * 2
    const minX = Math.min(...discs.map((c) => c.cx - c.r)) - pad
    const minY = Math.min(...discs.map((c) => c.cy - c.r)) - pad
    const maxX = Math.max(...discs.map((c) => c.cx + c.r)) + pad
    const maxY = Math.max(...discs.map((c) => c.cy + c.r)) + pad
    const maskId = `reach-edge-mask-${u.key}`
    out.push(
      createElement(
        'g',
        {
          key: `spatial-reach-edge-${u.key}`,
          'data-testid': `spatial-combat-reach-edge-${u.key}`,
          style: { pointerEvents: 'none' as const },
        },
        createElement(
          'defs',
          { key: 'defs' },
          createElement(
            'mask',
            { id: maskId, maskUnits: 'userSpaceOnUse', x: minX, y: minY, width: maxX - minX, height: maxY - minY },
            createElement('rect', {
              key: 'outside',
              x: minX,
              y: minY,
              width: maxX - minX,
              height: maxY - minY,
              fill: '#fff',
            }),
            createElement('path', { key: 'inside', d, fill: '#000', fillRule: 'nonzero' as const }),
          ),
        ),
        createElement('path', {
          key: 'edge',
          d,
          fill: 'none',
          stroke: color,
          strokeOpacity: 0.7,
          // Doubled on purpose: the mask keeps only the outer half, so this renders at REACH_EDGE_PX.
          strokeWidth: edge * 2,
          strokeLinejoin: 'round' as const,
          mask: `url(#${maskId})`,
        }),
      ),
    )
  }

  // ── 2) FIRE lines (source→target, this tick's salvos), over rings, under glyphs ──
  const lines = resolveFireLines(args.events, points, life)
  if (lines.length > 0) {
    out.push(
      createElement(
        'g',
        { key: 'spatial-fire', 'data-testid': 'spatial-combat-fire', style: { pointerEvents: 'none' as const } },
        ...lines.map((l) => {
          const a = args.norm({ x: l.x1, y: l.y1 })
          const b = args.norm({ x: l.x2, y: l.y2 })
          return createElement('line', {
            key: l.key,
            x1: a.x,
            y1: a.y,
            x2: b.x,
            y2: b.y,
            stroke: SIDE_COLOR[l.sourceSide],
            strokeWidth: 1.25,
            strokeOpacity: 0.9,
            strokeLinecap: 'round' as const,
            vectorEffect: 'non-scaling-stroke' as const,
          })
        }),
      ),
    )
  }

  // ── 3) ACTOR GLYPHS on top: ONE per player fleet, one per living enemy hull, each under its own
  // HULL PIP — a two-tone bar of the server's own hp columns, summed across the actor.
  //
  // THE SHAPE IS NOT DECIDED HERE. It used to be: two inline `points` strings, an up-pointing
  // triangle for us and a down-pointing one for them, sized `px(7) × 1.35` for a fleet — while the
  // map badge for that SAME fleet drew a `5/k` diamond in teamMarkers, and a docked one drew no glyph
  // at all. One fleet, three appearances, three files. The owner: "the fleet shape changes when in a
  // combat, and outside combat. I want it to be same." Both inline shapes are DELETED; the form, the
  // size, the tone and the dimming now come from map/shipVisual and are drawn by the one renderer in
  // map/shipGlyph, which the map badge calls too. The state can still add DECORATION — the pip below,
  // the hull count, the badge's danger ring — but it cannot touch the ship.
  //
  // The pip exists because "am I winning?" needs a QUANTITY, and the fill-opacity dimming that used
  // to be the only cue is not one: a 30%-hull actor and a 60%-hull actor differ by a shade. The
  // card's two bars say how the sides stand; this says how close this actor is to going.
  //
  // A FLEET ALSO STATES ITS HULLS — "3/4" beside the glyph. Folding four ships into one glyph must
  // not hide that one of them is gone: the pip already falls by the dead ship's full share (the
  // aggregate counts its max and none of its current), and the count says it in words as well.
  for (const u of views) {
    const p = args.norm({ x: u.x, y: u.y })
    // THE one policy call. Bulk decides size, the hull id decides the form, the side decides the tone,
    // and the fleet's own summed condition decides the dimming — all of it in map/shipVisual.
    const visual = shipVisual({
      typeId: u.typeId,
      side: u.side,
      kind: u.kind,
      mass: u.mass,
      hpFrac: u.hpFrac,
    })
    const color = SIDE_COLOR[u.side]
    const pipW = px(PIP_W_PX)
    const pipH = px(PIP_H_PX)
    const pipY = p.y - px(PIP_LIFT_PX)
    out.push(
      createElement(
        'g',
        {
          key: `spatial-actor-${u.key}`,
          'data-testid': `spatial-combat-unit-${u.key}`,
          'data-side': u.side,
          'data-kind': u.kind,
          'data-hp-frac': u.hpFrac.toFixed(3),
          'data-ships': String(u.ships),
          'data-ships-alive': String(u.shipsAlive),
          'data-type-id': u.typeId ?? '',
          'data-size-px': String(visual.sizePx),
          style: { pointerEvents: 'none' as const },
        },
        renderShipVisual(visual, { x: p.x, y: p.y, k: args.k, pxScale: scale }, 'hull'),
        // the empty track, then the remaining hull over it — no number, no math, just the fraction
        createElement('rect', {
          x: p.x - pipW / 2,
          y: pipY,
          width: pipW,
          height: pipH,
          fill: 'var(--color-app)',
          opacity: 0.75,
        }),
        createElement('rect', {
          'data-testid': `spatial-combat-hull-${u.key}`,
          x: p.x - pipW / 2,
          y: pipY,
          width: pipW * u.hpFrac,
          height: pipH,
          fill: u.hpFrac > 0.5 ? 'var(--color-success)' : u.hpFrac > 0.25 ? 'var(--color-warning)' : 'var(--color-danger)',
        }),
        ...(u.kind === 'fleet'
          ? [
              createElement(
                'text',
                {
                  key: 'hulls',
                  'data-testid': `spatial-combat-hulls-${u.key}`,
                  x: p.x + pipW / 2 + px(4),
                  y: pipY + pipH,
                  fontSize: px(11),
                  textAnchor: 'start' as const,
                  fill: color,
                  fontWeight: 700,
                  style: { userSelect: 'none' as const },
                },
                `${u.shipsAlive}/${u.ships}`,
              ),
            ]
          : []),
      ),
    )
  }

  // ── 3b) ORDNANCE: the rounds themselves, over the hulls that threw them ──
  // "i see nothing, i see just numbers, a health bar going down. I want to see an ammo of some sort."
  // One round per REAL salvo of the latest tick (combatMotion.resolveOrdnance), travelling between
  // its two endpoints' current positions and drawn from the firing ship's own weapons_json — the
  // gun's projectile_speed decides how fast it crosses, its share of the ship's volley how heavy it
  // is, and a ship with nothing this map can describe borrows the elected LEAD's ordnance. The trail
  // is the round's own recent path, not a second effect: its tail is where the same interpolation
  // says the round was a fraction of its flight ago.
  const rounds = args.sightings ? resolveOrdnance({ ...shotArgs, nowMs }) : []
  if (rounds.length > 0) {
    out.push(
      createElement(
        'g',
        {
          key: 'spatial-ordnance',
          'data-testid': 'spatial-combat-ordnance',
          style: { pointerEvents: 'none' as const },
        },
        ...rounds.flatMap((s, i) => {
          // A VOLLEY, NOT A STACK. Since the fleet fold, four hulls shooting one target all leave
          // the same glyph along the same lane, so rounds sharing a lane are spread across it —
          // a perpendicular offset, centred, in screen pixels. Nothing about WHERE the round starts
          // or ends changes; this only stops N rounds drawing on top of each other.
          const lane = rounds.filter((o) => o.sourceKey === s.sourceKey && o.targetKey === s.targetKey)
          const slot = lane.indexOf(s)
          const dx = s.x - s.tailX
          const dy = s.y - s.tailY
          const len = Math.hypot(dx, dy)
          const spread = len > 0 ? (slot - (lane.length - 1) / 2) * px(SHOT_LANE_GAP_PX) : 0
          const nx = len > 0 ? -(dy / len) * spread : 0
          const ny = len > 0 ? (dx / len) * spread : 0
          const head = args.norm({ x: s.x, y: s.y })
          const tail = args.norm({ x: s.tailX, y: s.tailY })
          const color = SIDE_COLOR[s.side]
          const r = px(SHOT_MIN_R_PX + (SHOT_MAX_R_PX - SHOT_MIN_R_PX) * Math.max(0, Math.min(1, s.share)))
          return [
            createElement('line', {
              key: `${s.key}-trail-${i}`,
              x1: tail.x + nx,
              y1: tail.y + ny,
              x2: head.x + nx,
              y2: head.y + ny,
              stroke: color,
              strokeWidth: 2.5,
              strokeOpacity: 0.55,
              strokeLinecap: 'round' as const,
              vectorEffect: 'non-scaling-stroke' as const,
            }),
            createElement('circle', {
              key: s.key,
              'data-testid': `spatial-combat-shot-${s.eventId}`,
              'data-source': s.sourceKey,
              'data-target': s.targetKey,
              'data-profile': s.profileSource,
              cx: head.x + nx,
              cy: head.y + ny,
              r,
              fill: color,
              stroke: 'var(--color-app)',
              strokeWidth: px(0.8),
            }),
          ]
        }),
      ),
    )
  }

  // ── 4) HITSPLATS on very top: this tick's damage numbers, floating over whoever took them ──
  // Screen-constant (/k) like every glyph: a damage number is UI, not geometry, so it must stay
  // legible at any zoom. Drawn last so a number is never hidden behind the ship it belongs to.
  // A hull hit TWICE this tick shows BOTH numbers, fanned about the hull's centre in the server's
  // own seq order — one splat per hit is the whole point (see resolveHitSplats).
  // A number appears when the ROUND that carried it arrives — damage never precedes its own shell.
  // Unpaired splats (arrivesAtMs null) show at once, so no real damage row can be hidden.
  for (const s of resolveHitSplats(args.events, points, arrivals, life)) {
    if (s.arrivesAtMs !== null && nowMs < s.arrivesAtMs) continue
    const p = args.norm({ x: s.x, y: s.y })
    // Coloured by who is BLEEDING — red on your own ship is the RS read: this is hurting you.
    const color = s.side === 'player' ? 'var(--color-danger)' : 'var(--color-accent)'
    const dy = px(SPLAT_LIFT_PX)
    const dx = (s.index - (s.count - 1) / 2) * px(SPLAT_FAN_GAP_PX)
    const cx = p.x + dx
    const cy = p.y - dy
    out.push(
      createElement(
        'g',
        {
          key: `spatial-splat-${s.key}`,
          'data-testid': `spatial-combat-splat-${s.key}`,
          'data-unit': s.unitId,
          'data-kill': s.destroyed ? 'true' : 'false',
          style: { pointerEvents: 'none' as const },
        },
        // a filled disc so the number stays readable over any background; the kill mark gets a ring
        // so a destroyed hull is distinguishable from a big hit at a glance
        createElement('circle', {
          cx,
          cy,
          r: px(SPLAT_DISC_PX),
          fill: color,
          opacity: 0.92,
          stroke: s.destroyed ? 'var(--color-app)' : 'none',
          strokeWidth: s.destroyed ? px(2) : 0,
        }),
        createElement(
          'text',
          {
            x: cx,
            y: cy + px(SPLAT_TEXT_PX * 0.36),
            fontSize: px(SPLAT_TEXT_PX),
            textAnchor: 'middle',
            fill: 'var(--color-app)',
            fontWeight: 700,
            style: { userSelect: 'none' as const },
          },
          // a destroying blow reads as a kill mark, not a number to interpret
          s.destroyed ? '✕' : String(Math.round(s.damage ?? 0)),
        ),
      ),
    )
  }

  return out
}
