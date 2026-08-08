import { test, expect } from '@playwright/test'
import type { ReactElement } from 'react'
import {
  ARENA_MIN_RADIUS,
  combatFocusWorldPoints,
  focusableEncounterId,
  spatialCombatLayer,
  resolveSpatialUnits,
  resolveFireLines,
  resolveHitSplats,
  resolveRenderPoints,
  unitWeaponRange,
} from '../src/features/map/spatialCombatLayer'
import { resolveCombatActors } from '../src/features/map/combatActors'
import { WORLD_TO_VIEWBOX_SCALE } from '../src/features/map/openSpaceTransform'
import type { CombatEvent, CombatUnit } from '../src/features/combat/combatTypes'

// COMBAT-S4 — pure spec for the spatial-combat map layer (the territoryLayer/miningFieldRangeLayer/
// teamMarkers element-descriptor convention: pure, hook-free, GalaxyMap and this spec call the SAME
// function). No hooks run, no DB, no fabricated backend.

const norm = (p: { x: number; y: number }) => p // identity stub; positions pass through unchanged

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
  pos_x: 100,
  pos_y: 200,
  move_speed: 5,
  side: 'player',
  weapons_json: [{ range: 300 }],
  ...o,
})

const salvo = (o: Partial<CombatEvent> = {}): CombatEvent => ({
  id: 1,
  encounter_id: 'e1',
  tick_number: 7,
  seq: 0,
  event_type: 'missile_salvo',
  source: 'player',
  target: 'pirate',
  projectile_type: 'weapon',
  projectile_count: 1,
  impact_delay_ms: 100,
  payload_json: { unit_id: 'u1', target_id: 'u2' },
  created_at: '2026-07-19T00:00:00Z',
  ...o,
})

// THE FLEET FOLD, applied at the call sites. The layer no longer folds or places — it renders the
// ACTORS it is handed (combatActors.resolveCombatActors: one glyph per player fleet, one per living
// enemy hull), and every shot/number looks its unit up in the render points those actors define. So
// these two helpers stand exactly where GalaxyMap stands, and the specs below drive the SAME path
// the app does rather than a shape only a test can produce.
interface LayerArgs {
  units: CombatUnit[]
  events: CombatEvent[]
  norm: (p: { x: number; y: number }) => { x: number; y: number }
  k: number
  pxScale?: number
}
const layer = (a: LayerArgs) => spatialCombatLayer({ ...a, actors: resolveCombatActors(a.units) })
const pointsOf = (units: CombatUnit[]) => resolveRenderPoints(resolveCombatActors(units))

// ── unitWeaponRange ──
test('unitWeaponRange: MAX finite positive range; null when no ranged weapon', () => {
  expect(unitWeaponRange({ weapons_json: [{ range: 120 }, { range: 300 }, { range: 80 }] })).toBe(300)
  expect(unitWeaponRange({ weapons_json: [] })).toBeNull()
  expect(unitWeaponRange({ weapons_json: [{ range: null }, { range: 0 }] })).toBeNull()
  expect(unitWeaponRange({ weapons_json: undefined })).toBeNull()
})

// ── resolveSpatialUnits: the fail-closed data gate ──
test('resolveSpatialUnits: keeps only positioned + alive rows (dark = empty)', () => {
  const rows = [
    unit({ id: 'a', pos_x: 1, pos_y: 2 }),
    unit({ id: 'dark', pos_x: null, pos_y: null }), // non-spatial (dark) → dropped
    unit({ id: 'dead', pos_x: 5, pos_y: 6, alive_count: 0 }), // destroyed → dropped
  ]
  const views = resolveSpatialUnits(rows)
  expect(views.map((v) => v.id)).toEqual(['a'])
})

test('resolveSpatialUnits: a whole roster with NO positions (spatial dark) resolves to []', () => {
  const dark = [unit({ id: 'x', pos_x: null, pos_y: null }), unit({ id: 'y', pos_x: null, pos_y: null })]
  expect(resolveSpatialUnits(dark)).toEqual([])
})

test('resolveSpatialUnits: side + hpFrac derived, sorted by id', () => {
  const views = resolveSpatialUnits([
    unit({ id: 'b', side: 'enemy', hp_current: 50, hp_max: 100 }),
    unit({ id: 'a', side: 'player', hp_current: 100, hp_max: 100 }),
  ])
  expect(views.map((v) => v.id)).toEqual(['a', 'b']) // deterministic order
  expect(views.find((v) => v.id === 'b')).toMatchObject({ side: 'enemy', hpFrac: 0.5 })
  expect(views.find((v) => v.id === 'a')).toMatchObject({ side: 'player', hpFrac: 1 })
})

// ── the layer: fail-closed ──
test('layer: no spatial units → [] (byte-identical map; dark by data)', () => {
  expect(layer({ units: [], events: [], norm, k: 1 })).toEqual([])
  expect(layer({ units: [unit({ pos_x: null, pos_y: null })], events: [], norm, k: 1 })).toEqual([])
})

// ── the layer: range rings are world-true, glyphs are side-distinct ──
type Props = Record<string, unknown>
const byTestId = (els: ReactElement[], id: string) =>
  els.find((e) => (e.props as Props)['data-testid'] === id)

// ── THE REACH REGION — what is drawn IS the fire rule ─────────────────────────────────────────────
// REPOINTED. This used to assert ONE dashed circle per actor, centred on its drawn point, with the
// radius of its longest gun — which is exactly the defect the owner reported: "the range circle,
// outer circle when fighting, did not even touch a fleet yet it shot." The engine's fire gate
// measures EACH HULL from ITS OWN position, so a fleet's reachable set is the UNION of its hulls'
// discs and a single lead-centred circle cannot state it. The assertion follows the real behaviour.
const discsOf = (els: ReactElement[], key: string) => {
  const g = byTestId(els, `spatial-combat-range-${key}`)
  if (!g) return []
  // createElement collapses a SINGLE child out of the array form, so normalise before reading.
  const kids = (g.props as { children: ReactElement | ReactElement[] }).children
  const list = Array.isArray(kids) ? kids : kids ? [kids] : []
  return list.map((c) => c.props as { cx: number; cy: number; r: number; fill: string })
}

test('layer: a lone armed hull still gets exactly ONE world-true disc (r = range * SCALE, NOT /k)', () => {
  for (const k of [1, 4]) {
    const els = layer({ units: [unit({ id: 'u1', weapons_json: [{ range: 300 }] })], events: [], norm, k })
    const discs = discsOf(els, 'fleet-e1')
    expect(discs).toHaveLength(1)
    expect(discs[0].r).toBe(300 * WORLD_TO_VIEWBOX_SCALE) // world-true at every zoom
    expect(discs[0].cx).toBe(100)
  }
})

test('THE RING IS THE RULE — every hull that can fire contributes its OWN disc, from its OWN place', () => {
  // THE MEASURED PRODUCTION ENCOUNTER, from the owner's most recent live fight: four alive hulls of
  // range 5, the elected LEAD at (-53.13, 103.74), six alive enemies. TWO of the six were inside a
  // lead-centred circle of radius 5 and FOUR were outside it at 5.06-6.86 — yet all six were
  // legitimately shootable, because the escorts sit on a CHORD and reach further forward than the
  // lead, which sits a full formation radius back.
  const LEAD = { x: -53.13, y: 103.74 }
  const REACH = 5
  const hull = (id: string, dx: number, dy: number, aggro = 0) =>
    unit({ id, pos_x: LEAD.x + dx, pos_y: LEAD.y + dy, aggro_priority: aggro, weapons_json: [{ range: REACH }] })
  const hulls = [hull('p0', 0, 0, 100), hull('p1', 3, 0), hull('p2', 0, 3), hull('p3', -2, 2)]
  // Six hostiles: two inside the lead's own circle, four OUTSIDE it but inside a real hull's reach.
  const foes = [
    { x: 3.2, y: 0 }, // 3.20 from the lead
    { x: 0, y: 3.5 }, // 3.50
    { x: 5.06, y: 0 }, // 5.06 — 2.06 from the escort at +3x
    { x: 5.6, y: 0.3 }, // 5.61 — 2.62
    { x: 6.2, y: -0.5 }, // 6.22 — 3.24
    { x: 6.86, y: 0.2 }, // 6.86 — 3.87
  ].map((o, i) =>
    unit({ id: `e${i}`, side: 'enemy', aggro_priority: null, pos_x: LEAD.x + o.x, pos_y: LEAD.y + o.y }),
  )
  const rows = [...hulls, ...foes]
  const els = layer({ units: rows, events: [], norm, k: 1 })
  const discs = discsOf(els, 'fleet-e1')
  expect(discs, 'one disc per living armed hull, not one for the fleet').toHaveLength(4)

  // THE PROPERTY: every enemy the ENGINE would let some hull fire on is inside what is DRAWN.
  // (`norm` is the identity here and the radii carry the world→viewBox scale, so the containment
  // test is done in the drawn space, against the rendered circles themselves.)
  const covered = (p: { x: number; y: number }) =>
    discs.some((d) => Math.hypot(p.x - d.cx, p.y - d.cy) <= d.r / WORLD_TO_VIEWBOX_SCALE)
  const shootable = (p: { x: number; y: number }) =>
    hulls.some((h) => Math.hypot(p.x - (h.pos_x as number), p.y - (h.pos_y as number)) <= REACH)
  for (const f of foes) {
    const at = { x: f.pos_x as number, y: f.pos_y as number }
    expect(shootable(at), 'the fixture must be a fight where every hostile IS reachable').toBe(true)
    expect(covered(at), 'an enemy that can be shot must be inside the drawn reach').toBe(true)
  }
  // …and the RETIRED answer really did lie: only TWO of the six sat inside a lead-centred circle of
  // the fleet's longest range, which is what the owner watched shoot at things it did not touch.
  const insideLeadCircle = foes.filter(
    (f) => Math.hypot((f.pos_x as number) - LEAD.x, (f.pos_y as number) - LEAD.y) <= REACH,
  )
  expect(insideLeadCircle).toHaveLength(2)
})

test('a DEAD hull contributes no reach — a wreck is not a gun the fleet still has', () => {
  const els = layer({
    units: [
      unit({ id: 'p0', pos_x: 0, pos_y: 0, weapons_json: [{ range: 5 }] }),
      unit({ id: 'p1', pos_x: 40, pos_y: 0, alive_count: 0, hp_current: 0, weapons_json: [{ range: 5 }] }),
    ],
    events: [],
    norm,
    k: 1,
  })
  expect(discsOf(els, 'fleet-e1')).toHaveLength(1)
})

test('layer: an unarmed actor draws a glyph but NO range ring', () => {
  const els = layer({ units: [unit({ id: 'u1', weapons_json: [] })], events: [], norm, k: 1 })
  expect(byTestId(els, 'spatial-combat-range-fleet-e1')).toBeUndefined()
  expect(byTestId(els, 'spatial-combat-unit-fleet-e1')).toBeDefined()
})

test('layer: player vs enemy glyphs are visually distinct (tone + silhouette) and pointer-transparent', () => {
  const els = layer({
    units: [unit({ id: 'p', side: 'player' }), unit({ id: 'e', side: 'enemy', pos_x: 40 })],
    events: [],
    norm,
    k: 1,
  })
  const pg = byTestId(els, 'spatial-combat-unit-fleet-e1')!
  const eg = byTestId(els, 'spatial-combat-unit-unit-e')!
  expect((pg.props as Props)['data-side']).toBe('player')
  expect((eg.props as Props)['data-side']).toBe('enemy')
  expect((pg.props as { style: { pointerEvents: string } }).style.pointerEvents).toBe('none')
  // REPOINTED. The group used to be [polygon, hull-track, hull-fill] and the silhouette was an inline
  // `points` string built right here in the layer — one of the FOUR places a fleet's shape was
  // hard-coded. The first child is now the ONE ship glyph (map/shipGlyph), and its form/tone come
  // from map/shipVisual, so this test is about the SIDES reading differently rather than about which
  // triangle the layer happens to type out.
  const ship = (g: ReactElement) =>
    (g.props as { children: ReactElement[] }).children[0].props as {
      fill: string
      d: string
      'data-ship-form': string
    }
  expect(ship(pg)['data-ship-form']).toBe('paths')
  expect(ship(pg).fill).toBe('var(--color-accent)')
  expect(ship(eg).fill).toBe('var(--color-danger)')
  expect(ship(pg).d).not.toBe(ship(eg).d) // ours noses UP, a raider comes DOWN at us
})

// ── the per-unit HULL PIP: health as a quantity, not a shade ──────────────────────────────────────
// The glyph's fill opacity was the only per-unit health cue, and a 30%-hull ship differs from a
// 60%-hull one by a shade nobody can read mid-fight. The pip is the server's own hp_current/hp_max.
test('layer: each living ACTOR draws a hull pip whose width is its remaining fraction', () => {
  const els = layer({
    units: [
      unit({ id: 'a', hp_current: 25, hp_max: 100 }),
      unit({ id: 'b', side: 'enemy', pos_x: 60, hp_current: 100, hp_max: 100 }),
    ],
    events: [],
    norm,
    k: 1,
  })
  const pip = (key: string) => {
    const g = byTestId(els, `spatial-combat-unit-${key}`)!
    const kids = (g.props as { children: ReactElement[] }).children
    return kids.find((c) => (c.props as Props)['data-testid'] === `spatial-combat-hull-${key}`)!
      .props as { width: number }
  }
  expect(pip('fleet-e1').width).toBeCloseTo(pip('unit-b').width * 0.25, 6)
})

test('layer: positions project through norm (non-identity proves projection)', () => {
  const els = layer({
    units: [unit({ id: 'u1', pos_x: 10, pos_y: 20, weapons_json: [{ range: 300 }] })],
    events: [],
    norm: (p) => ({ x: p.x + 1, y: p.y + 1 }),
    k: 1,
  })
  expect(discsOf(els, 'fleet-e1')[0]).toMatchObject({ cx: 11, cy: 21 })
})

// ── resolveFireLines: latest-tick spatial salvos only ──
test('resolveFireLines: draws the latest tick, resolving both endpoints to live positions', () => {
  const points = pointsOf([
    unit({ id: 'u1', side: 'player', pos_x: 0, pos_y: 0 }),
    unit({ id: 'u2', side: 'enemy', pos_x: 100, pos_y: 0 }),
  ])
  const events = [
    salvo({ id: 1, tick_number: 6, payload_json: { unit_id: 'u1', target_id: 'u2' } }), // older tick
    salvo({ id: 2, tick_number: 7, payload_json: { unit_id: 'u1', target_id: 'u2' } }), // latest
  ]
  const lines = resolveFireLines(events, points)
  expect(lines).toHaveLength(1)
  expect(lines[0]).toMatchObject({ sourceSide: 'player', x1: 0, y1: 0, x2: 100, y2: 0 })
})

test('resolveFireLines: ignores dark-path salvos (no unit_id) and shots at vanished targets', () => {
  const points = pointsOf([unit({ id: 'u1', side: 'player', pos_x: 0, pos_y: 0 })])
  const aggregate = salvo({ id: 3, tick_number: 7, payload_json: { damage: 42, wave: 1 } }) // dark path
  const orphan = salvo({ id: 4, tick_number: 7, payload_json: { unit_id: 'u1', target_id: 'gone' } })
  expect(resolveFireLines([aggregate, orphan], points)).toEqual([])
})

// ── HITSPLATS — the OSRS read: damage numbers over whoever took them ─────────────────────────────────
// The server has emitted everything needed since 0234: hull_damage {unit_id, damage} and
// unit_destroyed {unit_id, count} (0261:777-789). These tests pin that the layer only FORMATS them.

const dmg = (o: Partial<CombatEvent> = {}): CombatEvent => ({
  id: 1,
  encounter_id: 'e1',
  tick_number: 7,
  seq: 0,
  event_type: 'hull_damage',
  source: 'pirate',
  target: 'player',
  projectile_type: null,
  projectile_count: null,
  impact_delay_ms: null,
  payload_json: { unit_id: 'a', damage: 12 },
  created_at: '',
  ...o,
})

test('a hitsplat floats over the unit that TOOK the damage, carrying the server number', () => {
  const points = pointsOf([unit({ id: 'a', pos_x: 1, pos_y: 2 })])
  const splats = resolveHitSplats([dmg()], points)
  expect(splats).toHaveLength(1)
  expect(splats[0].damage).toBe(12)
  expect(splats[0].x).toBe(1)
  expect(splats[0].y).toBe(2)
  expect(splats[0].destroyed).toBe(false)
})

test('only the LATEST tick splats — old numbers clear instead of piling up', () => {
  const points = pointsOf([unit({ id: 'a', pos_x: 0, pos_y: 0 })])
  const splats = resolveHitSplats(
    [dmg({ id: 1, tick_number: 6, payload_json: { unit_id: 'a', damage: 5 } }),
     dmg({ id: 2, tick_number: 9, payload_json: { unit_id: 'a', damage: 33 } })],
    points,
  )
  expect(splats).toHaveLength(1)
  expect(splats[0].damage).toBe(33)
})

test('a splat whose unit has no position draws NOTHING — never a number over empty space', () => {
  const points = pointsOf([unit({ id: 'a', pos_x: null, pos_y: null })])
  expect(resolveHitSplats([dmg()], points)).toEqual([])
})

test('AGGREGATE damage events are ignored — they carry `group`, not a positioned unit_id', () => {
  const points = pointsOf([unit({ id: 'a', pos_x: 0, pos_y: 0 })])
  const aggregate = dmg({ payload_json: { group: 'some_unit_type', damage: 40 } })
  expect(resolveHitSplats([aggregate], points)).toEqual([])
})

// REPOINTED, and STRENGTHENED. This test used to REQUIRE the collapse — "damage AND destruction in
// one tick collapse to ONE splat" — which is the defect stated as a property. Collapsing is what
// hid the killing blow's number behind the ✕ and, in the multi-hit case below, hid an entire hit.
// The RS3 read is one splat per hit: the number that killed, AND the mark that it killed.
test('the killing blow shows BOTH: the damage that landed and the kill mark', () => {
  const points = pointsOf([unit({ id: 'a', pos_x: 0, pos_y: 0, alive_count: 0, hp_current: 0 })])
  const splats = resolveHitSplats(
    [dmg({ id: 1, seq: 0, payload_json: { unit_id: 'a', damage: 20 } }),
     dmg({ id: 2, seq: 1, event_type: 'unit_destroyed', payload_json: { unit_id: 'a', count: 1 } })],
    points,
  )
  expect(splats).toHaveLength(2)
  expect(splats[0]).toMatchObject({ damage: 20, destroyed: false, index: 0, count: 2 })
  expect(splats[1]).toMatchObject({ damage: null, destroyed: true, index: 1, count: 2 })
})

// ── THE DEFECTS THE OLD RESOLVER SHIPPED ──────────────────────────────────────────────────────────
test('TWO hits on one hull in one tick are TWO numbers — never the last one alone', () => {
  const points = pointsOf([unit({ id: 'a', pos_x: 0, pos_y: 0 })])
  // the production pair from tick 17: 4.136 + 4.286 = 8.4 taken, rendered as a single "4"
  const splats = resolveHitSplats(
    [dmg({ id: 1, seq: 0, payload_json: { unit_id: 'a', damage: 4.136 } }),
     dmg({ id: 2, seq: 1, payload_json: { unit_id: 'a', damage: 4.286 } })],
    points,
  )
  expect(splats.map((s) => s.damage)).toEqual([4.136, 4.286])
  expect(splats.map((s) => s.index)).toEqual([0, 1])
  expect(splats.every((s) => s.count === 2)).toBe(true)
})

test('a unit that DIED this tick still carries its splats — it is not silently gone', () => {
  // alive_count 0 is the row state at the very tick that kills a stack, so an alive-only anchor
  // lookup dropped both the final number and the ✕. resolveSpatialUnits must still hide the GLYPH.
  const dead = [unit({ id: 'a', pos_x: 3, pos_y: 4, alive_count: 0, hp_current: 0 })]
  expect(resolveSpatialUnits(dead)).toEqual([])
  const splats = resolveHitSplats([dmg({ payload_json: { unit_id: 'a', damage: 9 } })], pointsOf(dead))
  expect(splats).toHaveLength(1)
  expect(splats[0]).toMatchObject({ x: 3, y: 4, damage: 9 })
})

test('LATEST TICK is per ENCOUNTER — a second, higher-tick fight cannot blank a newer one', () => {
  const points = pointsOf([
    unit({ id: 'a', encounter_id: 'new', pos_x: 0, pos_y: 0 }),
    unit({ id: 'z', encounter_id: 'old', pos_x: 50, pos_y: 50 }),
  ])
  const splats = resolveHitSplats(
    [dmg({ id: 1, encounter_id: 'new', tick_number: 2, payload_json: { unit_id: 'a', damage: 7 } }),
     dmg({ id: 2, encounter_id: 'old', tick_number: 80, payload_json: { unit_id: 'z', damage: 3 } })],
    points,
  )
  // a global max of 80 used to erase the new fight's only splat
  expect(splats.map((s) => s.unitId).sort()).toEqual(['a', 'z'])
})

test('fire lines are per-encounter too, and the KILLING salvo still draws', () => {
  const points = pointsOf([
    unit({ id: 'p', encounter_id: 'new', pos_x: 0, pos_y: 0 }),
    unit({ id: 'e', encounter_id: 'new', side: 'enemy', pos_x: 5, pos_y: 0, alive_count: 0 }), // died this tick
    unit({ id: 'o', encounter_id: 'old', pos_x: 90, pos_y: 90 }),
  ])
  const lines = resolveFireLines(
    [salvo({ id: 1, encounter_id: 'new', tick_number: 2, payload_json: { unit_id: 'p', target_id: 'e' } }),
     salvo({ id: 2, encounter_id: 'old', tick_number: 80, payload_json: { unit_id: 'o', target_id: 'o' } })],
    points,
  )
  expect(lines).toHaveLength(2)
  expect(lines[0]).toMatchObject({ x1: 0, y1: 0, x2: 5, y2: 0 })
})

// ── FRAMING THE FIGHT (the camera answer, not a drawing one) ──────────────────────────────────────
test('combatFocusWorldPoints: pads each hull by its own reach, scoped to ONE encounter', () => {
  const units = [
    unit({ id: 'a', encounter_id: 'e1', pos_x: 100, pos_y: 100, weapons_json: [{ range: 6 }] }),
    unit({ id: 'b', encounter_id: 'e2', pos_x: 9000, pos_y: 9000, weapons_json: [{ range: 6 }] }),
  ]
  const pts = combatFocusWorldPoints(units, 'e1')
  // the other fight contributes nothing — framing two distant battles frames neither
  expect(pts.every((p) => Math.abs(p.x - 100) <= ARENA_MIN_RADIUS)).toBe(true)
  // a hull with no weapon still gets the arena floor, so a degenerate fight is not framed to a point
  const bare = combatFocusWorldPoints([unit({ id: 'c', pos_x: 0, pos_y: 0, weapons_json: [] })], 'e1')
  expect(bare).toContainEqual({ x: -ARENA_MIN_RADIUS, y: -ARENA_MIN_RADIUS })
  expect(combatFocusWorldPoints(units, null)).toEqual([])
})

test('focusableEncounterId: the NEWEST live fight that actually has ships on the map', () => {
  const units = [unit({ id: 'a', encounter_id: 'e2', pos_x: 1, pos_y: 1 })]
  const encounters = [
    { id: 'e1', status: 'active' }, // live but aggregate — nothing to frame
    { id: 'e2', status: 'active' },
  ]
  expect(focusableEncounterId(encounters, units)).toBe('e2')
  expect(focusableEncounterId([{ id: 'e2', status: 'completed' }], units)).toBeNull()
  expect(focusableEncounterId(encounters, [])).toBeNull()
})

test('the layer renders a splat element per damaged unit, on top of the glyphs', () => {
  const units = [unit({ id: 'a', pos_x: 0, pos_y: 0 }), unit({ id: 'b', side: 'enemy', pos_x: 9, pos_y: 9 })]
  const els = layer({ units, events: [dmg()], norm, k: 1 })
  const ids = els.map((e) => (e.props as Record<string, unknown>)['data-testid']).filter(Boolean) as string[]
  const splatIdx = ids.findIndex((s) => s.startsWith('spatial-combat-splat-'))
  expect(splatIdx).toBeGreaterThan(-1)
  // drawn last => a number is never hidden behind the ship it belongs to
  expect(splatIdx).toBe(ids.length - 1)
})
