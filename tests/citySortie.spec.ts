import { test, expect } from '@playwright/test'
import {
  combatFocusWorldPoints,
  resolveSpatialUnits,
} from '../src/features/map/spatialCombatLayer'
import {
  fitCameraToWorldPoints,
  worldPointsFramed,
} from '../src/features/map/galaxyCamera'
import { motionPoint, observeCombatUnits, type CombatMotion } from '../src/features/map/combatMotion'
import type { CombatUnit } from '../src/features/combat/combatTypes'

// ── 0346 — THEY COME FROM THE CITY: the CLIENT half, pinned ──────────────────────────────────────
//
// 0346 moved the enemy's ORIGIN from a ring around the fight to the zone's own city, so a raider now
// APPEARS tens of world units away and travels in over a fixed number of ticks. The owner's whole ask is that they can WATCH that
// happen — "when a wave start, i want ships to appear from the city" — which makes "is an inbound
// raider visible" a REQUIREMENT of that migration, not a nice-to-have.
//
// The answer, established by reading the client rather than hoping, is that no client file needed to
// change: the fetch is unfiltered, the fight camera's bounding box is built from EVERY positioned
// unit of the encounter, GalaxyMap re-frames whenever that box leaves the view, and a newly-seen id
// appears where it is instead of being tweened in from somewhere else.
//
// THIS FILE EXISTS BECAUSE "NO CHANGE WAS NEEDED" IS A CLAIM WITH NO GUARD. Every one of those four
// facts is a pure function's behaviour, and any of them could be narrowed by a later slice — a
// viewport cull "for performance", a camera that only frames the player side, a spawn tween — with
// nothing failing. Each would silently restore exactly the defect 0346 exists to remove: raiders
// fighting off-screen while the player stares at empty space. That is not hypothetical; the owner
// already hit the off-screen version of it once, and reported it as "When enemy ship is destroyed, i
// teleport to some random place inside the zone."
//
// NO WALL CLOCK, NO AMBIENT PRECONDITION. Every fixture states its own positions and timestamps, and
// every call passes an explicit nowMs.

/** Snare, measured on production 2026-08-09: the city sits at (-45, 120) and the owner's real
 *  encounter 49acbae0 fought at about (-57, 101) — 22.5 world units out. Those two points are the
 *  fixture, because they are the actual geometry the migration was measured against. */
const CITY = { x: -45, y: 120 }
const FIGHT = { x: -57, y: 101 }
/** Snare's live synthetic weapon range: enemy_synthetic_range_base 3.6 + difficulty 10 x 0.04. */
const RAIDER_RANGE = 4
/** 0346 originates a body AT the city itself — not on a ring around it, not on a bearing from it. */
const SPAWN = { x: CITY.x, y: CITY.y }
/** combat_enemy_ingress_ticks = 6, so one tick of the run-in covers a sixth of the gap. */
const INGRESS_TICKS = 6

const unit = (o: Partial<CombatUnit> = {}): CombatUnit => ({
  id: 'u1',
  encounter_id: 'e1',
  unit_type_id: null,
  main_ship_id: 'ship-1',
  ship_hp: 100,
  initial_count: 1,
  alive_count: 1,
  hp_max: 100,
  hp_current: 100,
  pos_x: FIGHT.x,
  pos_y: FIGHT.y,
  move_speed: 1,
  side: 'player',
  weapons_json: [{ range: 5 }],
  ...o,
})

const fleet = unit({ id: 'p1', side: 'player', pos_x: FIGHT.x, pos_y: FIGHT.y })
const raider = unit({
  id: 'e-raider',
  side: 'enemy',
  main_ship_id: null,
  pos_x: SPAWN.x,
  pos_y: SPAWN.y,
  move_speed: 1,
  weapons_json: [{ range: RAIDER_RANGE }],
})

test('a raider spawned at its own city is a drawable unit — nothing culls it by distance', () => {
  const views = resolveSpatialUnits([fleet, raider])
  expect(views.map((v) => v.id).sort()).toEqual(['e-raider', 'p1'])
  // and it really is far away: this fixture would be pointless if the two stood together.
  const gap = Math.hypot(SPAWN.x - FIGHT.x, SPAWN.y - FIGHT.y)
  expect(gap).toBeGreaterThan(20)
})

test('the fight camera frames the city the raiders come from, not just the fight', () => {
  const pts = combatFocusWorldPoints([fleet, raider], 'e1')
  expect(pts.length).toBeGreaterThan(0)
  // The box must reach the muster point. Padding is each unit's own reach, so the box extends at
  // least to the raider's position in both axes.
  const minX = Math.min(...pts.map((p) => p.x))
  const maxY = Math.max(...pts.map((p) => p.y))
  expect(minX).toBeLessThanOrEqual(Math.min(FIGHT.x, SPAWN.x))
  expect(maxY).toBeGreaterThanOrEqual(Math.max(FIGHT.y, SPAWN.y))
  // ...and the camera fitted to that box actually frames it.
  expect(worldPointsFramed(pts, fitCameraToWorldPoints(pts))).toBe(true)
})

test('a camera framing only the fight does NOT frame the inbound raider — so GalaxyMap re-frames', () => {
  // This is the exact decision at GalaxyMap.tsx:455-465: the camera held from before the raider
  // appeared must report NOT-framed, or the re-fit never runs and the sortie happens off-screen.
  const beforeArrival = combatFocusWorldPoints([fleet], 'e1')
  const heldCamera = fitCameraToWorldPoints(beforeArrival)
  const afterArrival = combatFocusWorldPoints([fleet, raider], 'e1')
  expect(worldPointsFramed(afterArrival, heldCamera)).toBe(false)
  // and the re-fit settles: the new camera frames the fight AND the city, and asking again is stable
  // (the follow effect must not oscillate once it has re-framed).
  const refit = fitCameraToWorldPoints(afterArrival)
  expect(worldPointsFramed(afterArrival, refit)).toBe(true)
})

test('a raider APPEARS at the city — its first observation is not tweened in from anywhere', () => {
  const t0 = 1_000_000
  const m0: CombatMotion = observeCombatUnits({}, [fleet], t0)
  const m1: CombatMotion = observeCombatUnits(m0, [fleet, raider], t0 + 3000)
  // a newly-seen id renders AT its own position on the tick it is first seen
  expect(motionPoint(m1, 'e-raider', t0 + 3000)).toEqual({ x: SPAWN.x, y: SPAWN.y })
  // ...and still there a moment later: a spawn has a zero-length window, so there is nothing to play
  expect(motionPoint(m1, 'e-raider', t0 + 4500)).toEqual({ x: SPAWN.x, y: SPAWN.y })
})

test('the sortie in is INTERPOLATED — the run-in animates between two observed server positions', () => {
  const t0 = 1_000_000
  const step = 3000
  const m1 = observeCombatUnits({}, [fleet, raider], t0)
  // one tick later the raider has closed a SIXTH of the gap — the ingress step is
  // distance / remaining ticks, and combat_enemy_ingress_ticks is 6.
  const legStep = (SPAWN.y - FIGHT.y) / INGRESS_TICKS
  const closed = { ...raider, pos_y: SPAWN.y - legStep }
  const m2 = observeCombatUnits(m1, [fleet, closed], t0 + step)
  const mid = motionPoint(m2, 'e-raider', t0 + step + step / 2)
  expect(mid).not.toBeNull()
  // strictly BETWEEN the two observed points — not snapped to either end, and never past the new one
  expect(mid!.y).toBeLessThan(SPAWN.y)
  expect(mid!.y).toBeGreaterThan(SPAWN.y - legStep)
  // and it lands exactly on the observed position when the step is spent — never extrapolating past
  const landed = motionPoint(m2, 'e-raider', t0 + step + step)
  expect(landed).toEqual({ x: closed.pos_x, y: closed.pos_y })
})
