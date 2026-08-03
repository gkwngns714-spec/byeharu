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
// This layer holds no clock. It re-renders whenever `units` / `events` change, and useCombat (mounted
// once in AppShell, exposed via useShellState) re-polls both every ~1.5s — the combat tick cadence. So:
//   • enemy pirates spawn on a RING around the engagement anchor — one distinct point per unit, half
//     a slot off the player escort ring (0336; before it EVERY unit of a wave was inserted at the
//     anchor itself, so a whole wave drew as ONE dot). That ring's radius is the player formation ring
//     PLUS the wave's own weapon range plus one, so every pirate starts strictly outside its own reach
//     of every player ship and therefore CLOSEs toward the fleet instead of kiting from the first tick
//     → their pos_x/pos_y update each tick → the dots visibly march inward each poll (the "spawn on
//     the ring → close" beat). Expect one to two silent closing polls before the first fire line.
//   • kiting player ships back away to their range edge — their SHORTEST gun's edge, never their
//     longest (0336), so a two-gun ship holds where both barrels bear → their dots slide out each tick.
//   • a weapon that fired THIS tick emits a combat_event (missile_salvo, payload {unit_id,target_id})
//     → a fire line is drawn source→target for the latest tick's shots, fading with the next poll.
import { createElement, type ReactElement } from 'react'
import type { CombatEvent, CombatUnit } from '../combat/combatTypes'
import { WORLD_TO_VIEWBOX_SCALE } from './openSpaceTransform'

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
function latestTickByEncounter(
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

/** PURE: combat_events + the current unit positions → the fire lines for the latest tick OF EACH
 *  ENCOUNTER. A spatial fire event is a 'missile_salvo' whose payload carries {unit_id, target_id}
 *  (0234's spatial fire hunk); the aggregate-combat missile_salvo (dark path) has no unit_id, so it
 *  is naturally ignored. Both endpoints must resolve to a POSITIONED unit — a shot at a unit that
 *  was never on the map draws nothing (never a guessed line), but a shot at one that DIED this tick
 *  still draws, because that is the shot the player most wants to see. Only each encounter's highest
 *  tick_number is drawn, so old salvos fade as the poll advances. */
export function resolveFireLines(
  events: readonly CombatEvent[],
  units: readonly SpatialUnitView[],
): FireLineView[] {
  const posById = new Map(units.map((u) => [u.id, u]))
  const latest = latestTickByEncounter(
    events,
    (e) => e.event_type === 'missile_salvo' && !!e.payload_json && e.payload_json['unit_id'] != null,
  )
  if (latest.size === 0) return []
  const out: FireLineView[] = []
  for (const e of events) {
    if (e.event_type !== 'missile_salvo') continue
    if (latest.get(e.encounter_id) !== e.tick_number) continue
    const p = e.payload_json ?? {}
    const src = posById.get(String(p['unit_id'] ?? ''))
    const tgt = posById.get(String(p['target_id'] ?? ''))
    if (!src || !tgt) continue // one endpoint gone → no line
    out.push({ key: `${e.id}`, sourceSide: src.side, x1: src.x, y1: src.y, x2: tgt.x, y2: tgt.y })
  }
  return out
}

const SIDE_COLOR = { player: 'var(--color-accent)', enemy: 'var(--color-danger)' } as const

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
  /** 0-based slot among the splats landing on THIS unit this tick, and how many there are. Two hits
   *  on one hull must read as two numbers side by side, so the layer fans them from these. */
  index: number
  count: number
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
 *  ignored — they have no position to float over. */
export function resolveHitSplats(
  events: readonly CombatEvent[],
  units: readonly SpatialUnitView[],
): HitSplatView[] {
  const posById = new Map(units.map((u) => [u.id, u]))
  const isHit = (e: CombatEvent) =>
    (e.event_type === 'hull_damage' || e.event_type === 'unit_destroyed') &&
    !!e.payload_json &&
    e.payload_json['unit_id'] != null
  const latest = latestTickByEncounter(events, isHit)
  if (latest.size === 0) return []

  // Deterministic order: the server's own (seq, id) sequence within the tick. Events arrive
  // newest-id-first from the API, so without this the fan could re-order between polls.
  const landed = events
    .filter((e) => isHit(e) && latest.get(e.encounter_id) === e.tick_number)
    .sort((a, b) => a.seq - b.seq || a.id - b.id)

  const out: HitSplatView[] = []
  const perUnit = new Map<string, number>()
  for (const e of landed) {
    const p = e.payload_json ?? {}
    const id = String(p['unit_id'] ?? '')
    const u = posById.get(id)
    if (!u) continue
    const index = perUnit.get(id) ?? 0
    perUnit.set(id, index + 1)
    const destroyed = e.event_type === 'unit_destroyed'
    const raw = Number(p['damage'])
    out.push({
      key: `splat-${e.id}`,
      unitId: id,
      x: u.x,
      y: u.y,
      // A destroy event carries a `count`, never a damage figure — it is a kill MARK, not a number.
      damage: destroyed || !Number.isFinite(raw) ? null : raw,
      side: u.side,
      destroyed,
      index,
      count: 0, // filled below, once every splat on this unit is known
    })
  }
  for (const s of out) s.count = perUnit.get(s.unitId) ?? 1
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
const GLYPH_PX = 7
const PIP_W_PX = 22
const PIP_H_PX = 3.5
const PIP_LIFT_PX = 13

/** The pure, hook-free GalaxyMap spatial-combat layer (the element-helper convention). Returns element
 *  DESCRIPTORS only — no hooks — so the unit spec calls this SAME function and inspects the tree. No
 *  positioned units → [] (the map is byte-identical to today; dark by data). Order: range rings first
 *  (scenery), then fire lines, then unit glyphs + their hull pips, then this tick's damage numbers on
 *  the very top. */
export function spatialCombatLayer(args: {
  units: readonly CombatUnit[]
  events: readonly CombatEvent[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
  /** CSS px per viewBox unit — `viewBoxDisplayRect(rect).scale`, measured by GalaxyMap from its own
   *  element. Omitted / non-positive → 1, i.e. the historic ÷k sizing. */
  pxScale?: number
}): ReactElement[] {
  // viewBox units per CSS pixel, at the current camera and letterbox. The ONE place this layer turns
  // a wanted screen size into the number an SVG attribute takes.
  const scale = args.pxScale && Number.isFinite(args.pxScale) && args.pxScale > 0 ? args.pxScale : 1
  const px = (cssPx: number) => cssPx / (args.k * scale)
  // TWO SETS, ONE FILTER. `positioned` is every row that has a place on the map; `views` is the
  // living subset that draws a glyph. Splats and fire lines anchor on the former so the blow that
  // KILLS a ship still lands somewhere visible — see resolveHitSplats' header.
  const positioned = resolvePositionedUnits(args.units)
  if (positioned.length === 0) return [] // dark / no active spatial battle → nothing
  const views = positioned.filter((u) => u.alive)

  const out: ReactElement[] = []

  // ── 1) Weapon RANGE rings (world-true, faint, under the glyphs) ──
  for (const u of views) {
    if (u.range == null) continue // no ranged weapon → no ring
    const p = args.norm({ x: u.x, y: u.y })
    const ringR = u.range * WORLD_TO_VIEWBOX_SCALE // world-true: viewBox units, NOT /k
    const color = SIDE_COLOR[u.side]
    out.push(
      createElement('circle', {
        key: `spatial-range-${u.id}`,
        'data-testid': `spatial-combat-range-${u.id}`,
        cx: p.x,
        cy: p.y,
        r: ringR,
        fill: 'none',
        stroke: color,
        strokeOpacity: 0.35,
        strokeWidth: 1 / args.k,
        strokeDasharray: `${3 / args.k} ${3 / args.k}`,
        style: { pointerEvents: 'none' as const },
      }),
    )
  }

  // ── 2) FIRE lines (source→target, this tick's salvos), over rings, under glyphs ──
  const lines = resolveFireLines(args.events, positioned)
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

  // ── 3) Unit GLYPHS on top: player = accent chevron, enemy = danger triangle (screen-constant /k),
  // each under its own HULL PIP — a two-tone bar of the server's hp_current/hp_max.
  //
  // The pip exists because "am I winning?" is a per-hull question as well as a per-fleet one, and
  // the fill-opacity dimming that used to be the only per-unit health cue is not readable as a
  // QUANTITY: a 30%-hull ship and a 60%-hull ship differ by a shade. The card's two bars say how
  // the fleets stand; these say which ship is about to go. Both read the same server columns.
  for (const u of views) {
    const p = args.norm({ x: u.x, y: u.y })
    const r = px(GLYPH_PX)
    const color = SIDE_COLOR[u.side]
    // Enemy pirates point DOWN (inbound from centre); player ships point UP — a distinct silhouette at
    // a glance, not just a hue. Health dims the fill (a battered unit reads as failing).
    const points =
      u.side === 'enemy'
        ? `${p.x},${p.y + r} ${p.x + r},${p.y - r} ${p.x - r},${p.y - r}` // down-pointing triangle
        : `${p.x},${p.y - r} ${p.x + r},${p.y + r} ${p.x - r},${p.y + r}` // up-pointing triangle
    const pipW = px(PIP_W_PX)
    const pipH = px(PIP_H_PX)
    const pipY = p.y - px(PIP_LIFT_PX)
    out.push(
      createElement(
        'g',
        {
          key: `spatial-unit-${u.id}`,
          'data-testid': `spatial-combat-unit-${u.id}`,
          'data-side': u.side,
          'data-hp-frac': u.hpFrac.toFixed(3),
          style: { pointerEvents: 'none' as const },
        },
        createElement('polygon', {
          points,
          fill: color,
          fillOpacity: 0.35 + 0.55 * u.hpFrac, // battered = fainter
          stroke: color,
          strokeWidth: 1,
          vectorEffect: 'non-scaling-stroke' as const,
        }),
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
          'data-testid': `spatial-combat-hull-${u.id}`,
          x: p.x - pipW / 2,
          y: pipY,
          width: pipW * u.hpFrac,
          height: pipH,
          fill: u.hpFrac > 0.5 ? 'var(--color-success)' : u.hpFrac > 0.25 ? 'var(--color-warning)' : 'var(--color-danger)',
        }),
      ),
    )
  }

  // ── 4) HITSPLATS on very top: this tick's damage numbers, floating over whoever took them ──
  // Screen-constant (/k) like every glyph: a damage number is UI, not geometry, so it must stay
  // legible at any zoom. Drawn last so a number is never hidden behind the ship it belongs to.
  // A hull hit TWICE this tick shows BOTH numbers, fanned about the hull's centre in the server's
  // own seq order — one splat per hit is the whole point (see resolveHitSplats).
  for (const s of resolveHitSplats(args.events, positioned)) {
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
