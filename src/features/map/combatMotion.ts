// COMBAT THAT FLOWS — the pure motion layer for an on-map battle. No React, no DOM, no clock: every
// function here takes `nowMs` as an argument, so the specs drive it with their own clock and nothing
// can reintroduce a `Date.now()` read during render.
//
// ── THE DEFECT ────────────────────────────────────────────────────────────────────────────────────
// The owner: "all the combat looks so laggy, not smooth." It was not lag. `process-combat-ticks` is
// a pg_cron job on `3 seconds` (verified active on production, with measured tick gaps of
// 3014-3042 ms), the client polls combat every ~1.5 s (combat/useCombat.ts:92), and NOTHING between
// those two facts and the screen interpolated a unit's position. A ship crossing to its firing
// position was drawn at A for three seconds and then at B — a step function, once per tick. The map
// already had the answer for fleet TRAVEL (map/movementInterpolation.ts, composed at
// GalaxyMap.tsx:506-510); combat simply never composed it.
//
// ── COMPOSE, DO NOT WRITE A SECOND SMOOTHER ───────────────────────────────────────────────────────
// `movementInterpolation` was ALREADY the one authority for "where is this thing between two known
// points at time t". Its published shape took a `fleet_movements` row with ISO `depart_at`/
// `arrive_at`, which combat cannot produce: a combat keyframe's bounds are CLIENT CLOCK READINGS
// (when this client first saw the row), and stringifying those into ISO would have been a fake
// server timestamp. So the LERP was lifted out of that module into `segmentProgress` /
// `interpolateSegment` over plain millisecond bounds, and the ISO functions became adapters that
// parse and delegate. Fleet travel is repointed at the generalised form; there is still exactly ONE
// lerp in the codebase, now with two callers. This file composes it and defines no interpolation of
// its own — not for a unit, not for a shell in flight.
//
// ── NEVER INVENT MOTION THE SERVER DID NOT ORDER ──────────────────────────────────────────────────
// Every rendered position is strictly BETWEEN two positions this client actually observed, because
// `segmentProgress` clamps to [0,1]: before the window it is the first observation, after it the
// second, never past. There is no velocity, no dead reckoning, no prediction of the next tick. The
// consequences are the anti-proofs in tests/combatMotion.spec.ts:
//   • a unit that STOPS stops — an unchanged position leaves its keyframe untouched, so it does not
//     restart a tween and does not drift;
//   • a SPAWN is not tweened from nowhere — a unit seen for the first time gets a zero-length window
//     at its own position, which reads as "already arrived";
//   • a DEATH is not tweened — a row that leaves the observation set is dropped, so an id that comes
//     back is a spawn again, and a dead unit's last known point is whatever the server last wrote.
//
// ── HOW LONG IS A STEP? THE SERVER SAYS ───────────────────────────────────────────────────────────
// `combat_units.updated_at` is written by the SAME statement that writes pos_x/pos_y on every tick,
// so the gap between two consecutive values IS the tick interval, measured off the server rather
// than assumed by the client. A step is played over that gap, which means the tween finishes exactly
// as the next one is due — continuous motion with no hard-coded 3000 anywhere, and no clock-skew
// exposure, because only the DURATION crosses the wire while the window is opened on the local clock
// at the moment of observation.
import type { CombatEvent, CombatUnit, CombatWeapon } from '../combat/combatTypes'
import { interpolateSegment, segmentProgress, type TimedSegment } from './movementInterpolation'

const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)

// ── UNIT MOTION ───────────────────────────────────────────────────────────────────────────────────

/** One unit's keyframe: the two OBSERVED positions and the local window the step is played over. */
export interface UnitMotion {
  fromX: number
  fromY: number
  toX: number
  toY: number
  /** local clock ms — when this client first saw `to`. */
  startMs: number
  /** local clock ms — `startMs` + the server's own measured step duration. */
  endMs: number
  /** the server's `updated_at` for `to`, in ms; null when the row carried none. The NEXT observation
   *  subtracts this to learn how long the server took, which is why it is refreshed even on a tick
   *  where the position did not move. */
  serverAtMs: number | null
}

/** unit id → keyframe. Rebuilt (never mutated) on every observation, so it is safe to hold in state. */
export type CombatMotion = Readonly<Record<string, UnitMotion>>

/** Bounds on a step's playback window. A measured gap outside them is a broken cadence (a stalled
 *  cron, a clock jump, a first move after a long pause), and playing a step over it would either
 *  flash or crawl. Clamping keeps the motion inside one plausible tick either way; it never changes
 *  WHERE the unit goes, only how long the trip is drawn to take. */
export const STEP_MIN_MS = 250
export const STEP_MAX_MS = 6000
/** Used only when the server timestamps are missing/unusable — production's measured tick is 3.0 s. */
export const STEP_DEFAULT_MS = 3000

const parseMs = (iso: string | null | undefined): number | null => {
  if (typeof iso !== 'string' || iso === '') return null
  const ms = Date.parse(iso)
  return Number.isFinite(ms) ? ms : null
}

const stepDurationMs = (prevServerAtMs: number | null, serverAtMs: number | null): number => {
  if (prevServerAtMs === null || serverAtMs === null || serverAtMs <= prevServerAtMs) return STEP_DEFAULT_MS
  return Math.max(STEP_MIN_MS, Math.min(STEP_MAX_MS, serverAtMs - prevServerAtMs))
}

/**
 * THE REDUCER: fold one observation of the combat rows into the keyframe ledger.
 *
 * Pure — `(prev, units, nowMs) → next`. Call it once per poll, with the local clock reading at the
 * moment the rows arrived. Three cases, and they are the whole behaviour:
 *
 *   NEW id      → a zero-length window at its own position. A spawn appears where it is; it is never
 *                 tweened in from another unit's place or from the origin.
 *   SAME point  → the keyframe is left ALONE (only `serverAtMs` advances, so the next real step can
 *                 still measure the server's cadence). A stopped unit therefore holds its position
 *                 exactly; nothing restarts, nothing drifts.
 *   MOVED       → a fresh window from the PREVIOUSLY OBSERVED point to the new one, opened now and
 *                 closed after the server's own measured step. `from` is the previous OBSERVATION,
 *                 never the mid-tween render point, which is what makes the rendered path provably
 *                 lie between two real server positions.
 *
 * A row with no usable position is not tracked, and an id absent from `units` is DROPPED — a
 * despawn leaves no ghost keyframe behind for a recycled id to be tweened from.
 */
export function observeCombatUnits(
  prev: CombatMotion,
  units: readonly CombatUnit[],
  nowMs: number,
): CombatMotion {
  const next: Record<string, UnitMotion> = {}
  for (const u of units) {
    if (!finite(u.pos_x) || !finite(u.pos_y)) continue
    const x = u.pos_x
    const y = u.pos_y
    const serverAtMs = parseMs(u.updated_at)
    const p = prev[u.id]
    if (!p) {
      next[u.id] = { fromX: x, fromY: y, toX: x, toY: y, startMs: nowMs, endMs: nowMs, serverAtMs }
    } else if (p.toX === x && p.toY === y) {
      next[u.id] = serverAtMs === null ? p : { ...p, serverAtMs }
    } else {
      next[u.id] = {
        fromX: p.toX,
        fromY: p.toY,
        toX: x,
        toY: y,
        startMs: nowMs,
        endMs: nowMs + stepDurationMs(p.serverAtMs, serverAtMs),
        serverAtMs,
      }
    }
  }
  return next
}

/** Where a tracked unit is at `nowMs`, composed straight off the one interpolation primitive.
 *  Untracked (or an unusable keyframe) → null, so the caller can keep the server's raw position
 *  rather than be handed a guess. */
export function motionPoint(motion: CombatMotion, unitId: string, nowMs: number): { x: number; y: number } | null {
  const m = motion[unitId]
  if (!m) return null
  return interpolateSegment(m, nowMs)
}

/** Is anything still mid-step at `nowMs`? The animation loop's OWN stop condition: once every step
 *  has landed there is nothing left to redraw until the next poll, so the frame loop can sleep for
 *  most of each 3 s tick instead of burning the phone's battery on identical frames. */
export function anyUnitInMotion(motion: CombatMotion, nowMs: number): boolean {
  for (const id in motion) if (motion[id].endMs > nowMs) return true
  return false
}

/**
 * The combat rows with their positions moved to where they are at `nowMs`.
 *
 * ── WHY THE ROWS, AND NOT THE GLYPHS ──────────────────────────────────────────────────────────────
 * `resolveSpatialUnits` (spatialCombatLayer) is the ONE positioned-and-alive filter, and it is not
 * this layer's alone: map/fleetFightPosition.ts composes it to stand the fleet BADGE on a real ship,
 * copying that ship's x/y verbatim. Smoothing inside the map layer would have moved the glyphs and
 * left the badge on the raw server point — the same fleet drawn twice in two places, which is the
 * exact defect fleetFightPosition exists to kill. Smoothing the ROWS instead means every consumer of
 * that one filter — the glyphs, the badge, the hull pips, the hitsplat anchors — reads the same
 * moved position and they cannot disagree, with no fork of the filter and no edit to its other
 * callers.
 *
 * Rows without positions pass through untouched, so a map with no spatial battle is byte-identical.
 */
export function smoothCombatUnits(
  units: readonly CombatUnit[],
  motion: CombatMotion,
  nowMs: number,
): CombatUnit[] {
  return units.map((u) => {
    if (!finite(u.pos_x) || !finite(u.pos_y)) return u
    const p = motionPoint(motion, u.id, nowMs)
    if (!p || !finite(p.x) || !finite(p.y)) return u // never a guessed position
    if (p.x === u.pos_x && p.y === u.pos_y) return u // identity when nothing moved (no needless alloc)
    return { ...u, pos_x: p.x, pos_y: p.y }
  })
}

// ── ORDNANCE ──────────────────────────────────────────────────────────────────────────────────────
//
// The owner: "overall, i see nothing, i see just numbers, a health bar going down. I want to see an
// ammo of some sort - based on what i fit, if nothing, default by command ship."
//
// EVERY ROUND IS A REAL SHOT. There is one, and only one, source: a `missile_salvo` combat_event of
// the encounter's latest tick carrying {unit_id, target_id} — the same evidence the fire line and
// the hitsplat already draw from (0299's spatial fire hunk, verified live on production). No
// decorative shots, none on a tick where nothing fired, and none between two units that are not both
// on the map.
//
// WHAT THE SHOT LOOKS LIKE COMES OFF THE FITTING, through the server:
//   • WHICH GUN — `combat_events.projectile_type` is written as the firing weapon's own
//     `module_type_id`, so the shot names its weapon; that entry is then found in the firing unit's
//     `weapons_json`.
//   • HOW LONG IT FLIES — `combat_events.impact_delay_ms`, ALWAYS, including when it is 0 (the
//     server rounds to an integer, so a point-blank shot legitimately lands immediately). A faster
//     gun's round arrives sooner because its round IS faster; nothing here re-derives that, and a
//     row that carries no delay at all gets the playback floor rather than a computed duration.
//   • HOW HEAVY IT IS — the weapon's share of its ship's volley, `power_i / Σ power`, which is
//     exactly what 0331 defines `weapons_json[i].power` to be. Dimensionless by construction, so it
//     needs no invented reference scale: one gun throws the whole volley in one round, two guns
//     throw half each.
//
// WHAT IS *NOT* AVAILABLE, stated rather than invented: nothing in `weapons_json`, in
// `combat_events`, or in the public `module_types` catalog names a weapon's APPEARANCE — there is no
// class, kind, tint or icon column anywhere on that path. So two guns whose numbers are close look
// close, and the live catalog's guns are close (autocannon_battery 5/60/10 vs its Mk-II 6/64/18, vs
// the 0262 fallback 5/60/15 and the pirate synthetic 4/50/5 — all verified on production). Rather
// than hash a module id into a made-up shape, this draws every round from the numbers that really do
// differ and reports the gap.

/** Presentation playback rate for a shot's flight, and the window it is held inside.
 *
 *  Production's measured impact delays are 0-120 ms (0316 cut every combat distance by five, so the
 *  shots are short). Played at true rate a round would exist for six frames once every three
 *  seconds — invisible, i.e. the defect again. The flight is therefore played SLOWED, exactly the
 *  same kind of decision the map already makes when it sends the CAMERA to a battle that is five
 *  world units across instead of drawing the battle bigger than it is: the endpoints and the
 *  relative speeds stay the server's, only the playback rate is presentation. A faster gun's round
 *  still lands first. */
export const SHOT_TIME_SCALE = 4
export const SHOT_MIN_MS = 280
export const SHOT_MAX_MS = 900
/** How much of the flight the round's trail spans — the round's OWN recent path, not a new effect:
 *  the trail's tail is simply where the same interpolation says it was that fraction ago. */
export const SHOT_TRAIL_FRACTION = 0.18

/** event id → the local clock ms this client FIRST saw that fire event. A tick's events stay the
 *  latest tick for a full 3 s and arrive again on every 1.5 s poll, so without this the flight would
 *  restart on each poll and the round would judder back to the muzzle. */
export type ShotSightings = Readonly<Record<number, number>>

/** THE REDUCER for fire events: remember when each salvo was first seen, forget the ones that are
 *  gone. Pure. An event already known keeps its ORIGINAL sighting (a shot in flight is never
 *  restarted); an event no longer in hand is dropped so the map cannot grow. */
export function observeShots(
  prev: ShotSightings,
  events: readonly CombatEvent[],
  nowMs: number,
): ShotSightings {
  const next: Record<number, number> = {}
  for (const e of events) {
    if (e.event_type !== 'missile_salvo') continue
    if (!e.payload_json || e.payload_json['unit_id'] == null) continue
    next[e.id] = prev[e.id] ?? nowMs
  }
  return next
}

/** A weapon entry we can actually characterise: it must carry the two numbers the round is drawn
 *  from. A rangeless/speedless entry (a mining rig, a malformed row) is not ordnance. */
const usableWeapon = (w: CombatWeapon | undefined | null): w is CombatWeapon =>
  !!w && finite(w.projectile_speed) && w.projectile_speed > 0

/**
 * The 0315 LEAD of one encounter, as the SERVER elected it.
 *
 * 0315 resolves the lead once per encounter by `is_command_ship desc, max_hp desc, main_ship_id asc`
 * and writes the decision onto the row as `aggro_priority` — 100 for the lead, 0 for every escort
 * (verified on production: exactly one 100 per player formation). This reads that decision. It does
 * NOT re-derive "the command ship" client-side: `is_command_ship` is never consulted here, and if
 * the election ever changes its keys this keeps agreeing with it for free.
 *
 * Ties (an impossible-but-guarded double 100) break on the lowest id, so the answer is deterministic
 * across polls.
 */
export function resolveEncounterLead(
  units: readonly CombatUnit[],
  encounterId: string,
): CombatUnit | null {
  let best: CombatUnit | null = null
  for (const u of units) {
    if (u.encounter_id !== encounterId) continue
    if (u.side === 'enemy') continue // an enemy pack holds no formation and elects no lead
    if (!finite(u.aggro_priority)) continue
    if (
      best === null ||
      u.aggro_priority > (best.aggro_priority as number) ||
      (u.aggro_priority === best.aggro_priority && u.id < best.id)
    ) {
      best = u
    }
  }
  return best
}

/** What a round is made of, and where that description came from. */
export interface OrdnanceProfile {
  /** world units per second — the gun's own `projectile_speed`, carried through as part of WHAT the
   *  round is (it is also what makes a `weapons_json` entry ordnance at all: `usableWeapon`). It is
   *  NOT used to time the flight — the server's `impact_delay_ms` is the sole authority for that,
   *  see `flightMs`. Deriving a duration from this field again would be the copy coming back. */
  speed: number
  /** this gun's share of its ship's volley, `power_i / Σ power` (0331), in [0,1]. 1 for a lone gun. */
  share: number
  /** the weapon's `module_type_id`, carried through so a caller can key on the shot's identity. */
  weaponId: string | null
  /** 'own'  — the firing ship's own fitting.
   *  'lead' — the ship had nothing this map can characterise, so the fleet's elected lead answered. */
  source: 'own' | 'lead'
}

const profileFrom = (u: CombatUnit | null | undefined, weaponId: string | null, source: 'own' | 'lead'): OrdnanceProfile | null => {
  const list = u?.weapons_json ?? []
  const usable = list.filter(usableWeapon)
  if (usable.length === 0) return null
  // The gun the server says fired, when it names one; otherwise this ship's first usable gun.
  const w = (weaponId !== null && usable.find((e) => e.module_type_id === weaponId)) || usable[0]
  const total = usable.reduce((sum, e) => sum + (finite(e.power) && e.power > 0 ? e.power : 0), 0)
  const own = finite(w.power) && w.power > 0 ? w.power : 0
  return {
    speed: w.projectile_speed as number,
    share: total > 0 ? own / total : 1,
    weaponId: w.module_type_id ?? null,
    source,
  }
}

/**
 * What the shot LOOKS like: the firing ship's own fitting, and failing that the fleet's lead.
 *
 * The owner's rule in their words — "based on what i fit, if nothing, default by command ship." The
 * fallback composes `resolveEncounterLead`, i.e. the server's own election, never a client-side
 * guess at which hull is in charge. Neither the ship nor its lead carrying a characterisable gun →
 * null, and the caller draws no round: a shot with no describable ordnance is not invented.
 *
 * KNOWN LIMIT, worth stating because it is a server fact and not an oversight: 0262 already
 * substitutes a synthetic `basic_player_weapon` for a player ship with nothing fitted, so from the
 * client's side "fitted nothing" and "fitted the fallback module" are the same row. Whether a
 * fitting was substituted is knowable only from the `combat_player_fallback_weapon_module_type_id`
 * knob, which is server-side and not on any read this map makes — so this does not pretend to tell
 * them apart, and the lead fallback fires on a genuinely uncharacterisable weapons_json.
 */
export function resolveOrdnanceProfile(
  firing: CombatUnit | null | undefined,
  lead: CombatUnit | null,
  weaponId: string | null,
): OrdnanceProfile | null {
  return profileFrom(firing, weaponId, 'own') ?? profileFrom(lead, weaponId, 'lead')
}

/** One round in flight this frame. World coordinates; the layer projects them like everything else. */
export interface OrdnanceView {
  key: string
  /** the combat_events row this round IS — one shot, one event, never a decorative extra. */
  eventId: number
  /** the ACTOR keys the round leaves from and flies to. */
  sourceKey: string
  targetKey: string
  side: 'player' | 'enemy'
  /** where the round is now, and where it was a moment ago (the tail of its own trail). */
  x: number
  y: number
  tailX: number
  tailY: number
  /** 0..1 along its flight — 1 means it has arrived (and this frame is its last). */
  progress: number
  /** the gun's share of its ship's volley — how heavy the round is drawn. */
  share: number
  /** where the description came from; 'lead' means the firing ship had nothing to describe. */
  profileSource: 'own' | 'lead'
}

/**
 * HOW LONG THE ROUND IS IN THE AIR — the SERVER's `impact_delay_ms`, and nothing else.
 *
 * MEASURED DEFECT (fixed here): the guard used to be `impact_delay_ms > 0`, and failing it the
 * client re-computed `1000 * dist / profile.speed` — the server's own formula, copied. That branch
 * was NOT a legacy fallback, it was reachable in ordinary play:
 *   · the tick writes `round(1000 * v_target_dist / nullif(v_w_pspeed,0))::integer`
 *     (20260618000234_combat_spatial_tick.sql:820, carried forward to 0299:876-884) — an INTEGER,
 *   · and 0316 cut every combat distance by five, so production's measured delays are 0-120 ms
 *     (0316:153 says so in those words).
 *   So a point-blank shot writes exactly 0 — a REAL answer meaning "it lands immediately" — the
 *   `> 0` guard read that as missing, and the copy ran instead, over the client's own Math.hypot of
 *   the INTERPOLATED (smoothed, mid-flight) endpoints, which is not the distance the server fired
 *   at. Two authorities for one number, and in a close fight the wrong one won.
 *
 * ZERO IS HONOURED. It clamps up to SHOT_MIN_MS the same way any too-short flight does, because a
 * round still has to be on screen for a few frames — that is playback (SHOT_TIME_SCALE's own
 * decision, stated above), not a re-derived stat. A row carrying NO delay (null / non-finite) is
 * the only genuine unknown, and it gets the same floor: the salvo row proves the shot happened so
 * it is still drawn, but nothing about its duration is computed from data the client does not have.
 * `dist` and the profile's speed are deliberately NOT parameters any more — there is no arithmetic
 * path from client geometry to a flight time. Pinned by tests/combatMotion.spec.ts.
 */
const flightMs = (e: CombatEvent): number => {
  const serverMs = finite(e.impact_delay_ms) && e.impact_delay_ms >= 0 ? e.impact_delay_ms : null
  if (serverMs === null) return SHOT_MIN_MS
  return Math.max(SHOT_MIN_MS, Math.min(SHOT_MAX_MS, serverMs * SHOT_TIME_SCALE))
}

/** The positioned view a round needs of its two endpoints — structurally the map layer's
 *  `RenderPoint`, i.e. the point of the ACTOR that unit renders as. Since the fleet fold a shot
 *  therefore leaves the FLEET and lands on the FLEET, from the one substitution that made the fold
 *  total, with no second notion of "where does this unit's stuff go". */
export interface ShotEndpoint {
  /** the actor's key. */
  key: string
  side: 'player' | 'enemy'
  x: number
  y: number
}

/**
 * PURE: the rounds in the air at `nowMs`, from the latest tick's real salvos.
 *
 * `latestTickByEncounter` is passed in rather than recomputed, so this and the fire lines and the
 * hitsplats all answer "the latest exchange" from ONE decision — with two battles running, a global
 * max silently blanks the younger fight, which is a defect the layer already fixed once.
 *
 * A round flies between its two endpoints' CURRENT positions, which are already smoothed by the
 * ledger above, so the shell leaves a moving hull and tracks a moving target — one authority for
 * "where is this thing at time t", used by the ships and by what they shoot.
 */
export function resolveOrdnance(args: {
  events: readonly CombatEvent[]
  latestTick: ReadonlyMap<string, number>
  endpoints: ReadonlyMap<string, ShotEndpoint>
  /** the raw unit rows — the lead election reads `aggro_priority`, which the endpoint view drops. */
  units: readonly CombatUnit[]
  sightings: ShotSightings
  nowMs: number
}): OrdnanceView[] {
  const out: OrdnanceView[] = []
  const unitById = new Map(args.units.map((u) => [u.id, u]))
  const leadByEncounter = new Map<string, CombatUnit | null>()
  for (const e of args.events) {
    if (e.event_type !== 'missile_salvo') continue
    if (args.latestTick.get(e.encounter_id) !== e.tick_number) continue
    const p = e.payload_json ?? {}
    if (p['unit_id'] == null) continue
    const src = args.endpoints.get(String(p['unit_id']))
    const tgt = args.endpoints.get(String(p['target_id'] ?? ''))
    if (!src || !tgt) continue // one end is not on the map → no round (never a guessed lane)
    const seen = args.sightings[e.id]
    if (!finite(seen)) continue // unobserved: the sighting ledger has not taken it yet
    if (!leadByEncounter.has(e.encounter_id)) {
      leadByEncounter.set(e.encounter_id, resolveEncounterLead(args.units, e.encounter_id))
    }
    const firing = unitById.get(String(p['unit_id']))
    const profile = resolveOrdnanceProfile(
      firing,
      leadByEncounter.get(e.encounter_id) ?? null,
      e.projectile_type,
    )
    if (!profile) continue // nothing to describe the round with → draw none
    const seg: TimedSegment = {
      fromX: src.x,
      fromY: src.y,
      toX: tgt.x,
      toY: tgt.y,
      startMs: seen,
      endMs: seen + flightMs(e),
    }
    const t = segmentProgress(seg, args.nowMs)
    const now = interpolateSegment(seg, args.nowMs)
    if (t === null || !now) continue
    if (t >= 1) continue // landed — the hitsplat is the rest of this shot's story
    const tail = interpolateSegment(seg, args.nowMs - SHOT_TRAIL_FRACTION * (seg.endMs - seg.startMs))
    out.push({
      key: `shot-${e.id}`,
      eventId: e.id,
      sourceKey: src.key,
      targetKey: tgt.key,
      side: src.side,
      x: now.x,
      y: now.y,
      tailX: tail?.x ?? now.x,
      tailY: tail?.y ?? now.y,
      progress: t,
      share: profile.share,
      profileSource: profile.source,
    })
  }
  return out.sort((a, b) => a.eventId - b.eventId)
}

/**
 * PURE: WHEN each of this tick's shots lands, keyed by the victim and the shot's ordinal among the
 * shots at that victim.
 *
 * The damage number belongs to the round that carried it, so it appears when the round arrives —
 * otherwise the figure floats over a hull while the shell that caused it is still in the air, which
 * says the damage came from nowhere. The pairing is the SERVER's own sequence and nothing else: a
 * tick's events are ordered by (seq, id) exactly as `process_combat_ticks` wrote them, and the k-th
 * salvo aimed at a hull is the k-th damage row landing on it.
 *
 * A damage row with no matching salvo (the aggregate arm, a shot whose endpoints left the map) gets
 * no entry and its splat shows immediately: a real damage row is never hidden waiting for a visual.
 */
export function resolveShotArrivals(args: {
  events: readonly CombatEvent[]
  latestTick: ReadonlyMap<string, number>
  endpoints: ReadonlyMap<string, ShotEndpoint>
  units: readonly CombatUnit[]
  sightings: ShotSightings
}): ReadonlyMap<string, number> {
  const out = new Map<string, number>()
  const unitById = new Map(args.units.map((u) => [u.id, u]))
  const leadByEncounter = new Map<string, CombatUnit | null>()
  const perTarget = new Map<string, number>()
  const salvos = args.events
    .filter(
      (e) =>
        e.event_type === 'missile_salvo' &&
        args.latestTick.get(e.encounter_id) === e.tick_number &&
        !!e.payload_json &&
        e.payload_json['unit_id'] != null,
    )
    .sort((a, b) => a.seq - b.seq || a.id - b.id)
  for (const e of salvos) {
    const p = e.payload_json ?? {}
    const src = args.endpoints.get(String(p['unit_id']))
    const targetId = String(p['target_id'] ?? '')
    const tgt = args.endpoints.get(targetId)
    if (!src || !tgt) continue
    const seen = args.sightings[e.id]
    if (!finite(seen)) continue
    if (!leadByEncounter.has(e.encounter_id)) {
      leadByEncounter.set(e.encounter_id, resolveEncounterLead(args.units, e.encounter_id))
    }
    const profile = resolveOrdnanceProfile(
      unitById.get(String(p['unit_id'])),
      leadByEncounter.get(e.encounter_id) ?? null,
      e.projectile_type,
    )
    if (!profile) continue
    const k = perTarget.get(targetId) ?? 0
    perTarget.set(targetId, k + 1)
    out.set(`${targetId}#${k}`, seen + flightMs(e))
  }
  return out
}

/** Is any round still in the air at `nowMs`? The other half of the frame loop's stop condition. */
export function anyShotInFlight(sightings: ShotSightings, nowMs: number): boolean {
  for (const id in sightings) if (sightings[id] + SHOT_MAX_MS > nowMs) return true
  return false
}
