import { test, expect } from '@playwright/test'
import type { ReactElement } from 'react'
import {
  ARENA_MIN_RADIUS,
  combatFocusWorldPoints,
  focusableEncounterId,
  spatialCombatLayer,
  resolvePositionedUnits,
  resolveSpatialUnits,
  resolveFireLines,
  resolveHitSplats,
  unitWeaponRange,
  type SpatialUnitView,
} from '../src/features/map/spatialCombatLayer'
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
  expect(spatialCombatLayer({ units: [], events: [], norm, k: 1 })).toEqual([])
  expect(
    spatialCombatLayer({ units: [unit({ pos_x: null, pos_y: null })], events: [], norm, k: 1 }),
  ).toEqual([])
})

// ── the layer: range rings are world-true, glyphs are side-distinct ──
type Props = Record<string, unknown>
const byTestId = (els: ReactElement[], id: string) =>
  els.find((e) => (e.props as Props)['data-testid'] === id)

test('layer: one world-true range ring per armed unit (r = range * SCALE, NOT /k)', () => {
  for (const k of [1, 4]) {
    const els = spatialCombatLayer({ units: [unit({ id: 'u1', weapons_json: [{ range: 300 }] })], events: [], norm, k })
    const ring = byTestId(els, 'spatial-combat-range-u1')!
    const rp = ring.props as { r: number; strokeWidth: number; fill: string }
    expect(rp.r).toBe(300 * WORLD_TO_VIEWBOX_SCALE) // world-true at every zoom
    expect(rp.fill).toBe('none')
    expect(rp.strokeWidth).toBe(1 / k) // only line weight is screen-constant
  }
})

test('layer: an unarmed unit draws a glyph but NO range ring', () => {
  const els = spatialCombatLayer({ units: [unit({ id: 'u1', weapons_json: [] })], events: [], norm, k: 1 })
  expect(byTestId(els, 'spatial-combat-range-u1')).toBeUndefined()
  expect(byTestId(els, 'spatial-combat-unit-u1')).toBeDefined()
})

test('layer: player vs enemy glyphs are visually distinct (tone + silhouette) and pointer-transparent', () => {
  const els = spatialCombatLayer({
    units: [unit({ id: 'p', side: 'player' }), unit({ id: 'e', side: 'enemy' })],
    events: [],
    norm,
    k: 1,
  })
  const pg = byTestId(els, 'spatial-combat-unit-p')!
  const eg = byTestId(els, 'spatial-combat-unit-e')!
  expect((pg.props as Props)['data-side']).toBe('player')
  expect((eg.props as Props)['data-side']).toBe('enemy')
  expect((pg.props as { style: { pointerEvents: string } }).style.pointerEvents).toBe('none')
  // The glyph group is [polygon, hull-track, hull-fill] since the per-unit hull pip landed; the
  // silhouette is the FIRST child. Reading children[0] rather than `children` keeps this test about
  // the silhouette instead of about how many things a unit draws.
  const poly = (g: ReactElement) =>
    (g.props as { children: ReactElement[] }).children[0].props as { fill: string; points: string }
  expect(poly(pg).fill).toBe('var(--color-accent)')
  expect(poly(eg).fill).toBe('var(--color-danger)')
  expect(poly(pg).points).not.toBe(poly(eg).points) // up- vs down-pointing triangle
})

// ── the per-unit HULL PIP: health as a quantity, not a shade ──────────────────────────────────────
// The glyph's fill opacity was the only per-unit health cue, and a 30%-hull ship differs from a
// 60%-hull one by a shade nobody can read mid-fight. The pip is the server's own hp_current/hp_max.
test('layer: each living unit draws a hull pip whose width is its remaining fraction', () => {
  const els = spatialCombatLayer({
    units: [unit({ id: 'a', hp_current: 25, hp_max: 100 }), unit({ id: 'b', hp_current: 100, hp_max: 100 })],
    events: [],
    norm,
    k: 1,
  })
  const pip = (id: string) => {
    const g = byTestId(els, `spatial-combat-unit-${id}`)!
    const kids = (g.props as { children: ReactElement[] }).children
    return kids.find((c) => (c.props as Props)['data-testid'] === `spatial-combat-hull-${id}`)!
      .props as { width: number }
  }
  expect(pip('a').width).toBeCloseTo(pip('b').width * 0.25, 6)
})

test('layer: positions project through norm (non-identity proves projection)', () => {
  const els = spatialCombatLayer({
    units: [unit({ id: 'u1', pos_x: 10, pos_y: 20, weapons_json: [{ range: 300 }] })],
    events: [],
    norm: (p) => ({ x: p.x + 1, y: p.y + 1 }),
    k: 1,
  })
  const ring = byTestId(els, 'spatial-combat-range-u1')!
  expect(ring.props as { cx: number; cy: number }).toMatchObject({ cx: 11, cy: 21 })
})

// ── resolveFireLines: latest-tick spatial salvos only ──
test('resolveFireLines: draws the latest tick, resolving both endpoints to live positions', () => {
  const views: SpatialUnitView[] = [
    { id: 'u1', encounterId: 'e1', side: 'player', x: 0, y: 0, range: 300, hpFrac: 1, alive: true },
    { id: 'u2', encounterId: 'e1', side: 'enemy', x: 100, y: 0, range: 120, hpFrac: 1, alive: true },
  ]
  const events = [
    salvo({ id: 1, tick_number: 6, payload_json: { unit_id: 'u1', target_id: 'u2' } }), // older tick
    salvo({ id: 2, tick_number: 7, payload_json: { unit_id: 'u1', target_id: 'u2' } }), // latest
  ]
  const lines = resolveFireLines(events, views)
  expect(lines).toHaveLength(1)
  expect(lines[0]).toMatchObject({ sourceSide: 'player', x1: 0, y1: 0, x2: 100, y2: 0 })
})

test('resolveFireLines: ignores dark-path salvos (no unit_id) and shots at vanished targets', () => {
  const views: SpatialUnitView[] = [
    { id: 'u1', encounterId: 'e1', side: 'player', x: 0, y: 0, range: 300, hpFrac: 1, alive: true },
  ]
  const aggregate = salvo({ id: 3, tick_number: 7, payload_json: { damage: 42, wave: 1 } }) // dark path
  const orphan = salvo({ id: 4, tick_number: 7, payload_json: { unit_id: 'u1', target_id: 'gone' } })
  expect(resolveFireLines([aggregate, orphan], views)).toEqual([])
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
  const views = resolveSpatialUnits([unit({ id: 'a', pos_x: 1, pos_y: 2 })])
  const splats = resolveHitSplats([dmg()], views)
  expect(splats).toHaveLength(1)
  expect(splats[0].damage).toBe(12)
  expect(splats[0].x).toBe(1)
  expect(splats[0].y).toBe(2)
  expect(splats[0].destroyed).toBe(false)
})

test('only the LATEST tick splats — old numbers clear instead of piling up', () => {
  const views = resolveSpatialUnits([unit({ id: 'a', pos_x: 0, pos_y: 0 })])
  const splats = resolveHitSplats(
    [dmg({ id: 1, tick_number: 6, payload_json: { unit_id: 'a', damage: 5 } }),
     dmg({ id: 2, tick_number: 9, payload_json: { unit_id: 'a', damage: 33 } })],
    views,
  )
  expect(splats).toHaveLength(1)
  expect(splats[0].damage).toBe(33)
})

test('a splat whose unit has no position draws NOTHING — never a number over empty space', () => {
  const views = resolveSpatialUnits([unit({ id: 'a', pos_x: null, pos_y: null })])
  expect(resolveHitSplats([dmg()], views)).toEqual([])
})

test('AGGREGATE damage events are ignored — they carry `group`, not a positioned unit_id', () => {
  const views = resolveSpatialUnits([unit({ id: 'a', pos_x: 0, pos_y: 0 })])
  const aggregate = dmg({ payload_json: { group: 'some_unit_type', damage: 40 } })
  expect(resolveHitSplats([aggregate], views)).toEqual([])
})

// REPOINTED, and STRENGTHENED. This test used to REQUIRE the collapse — "damage AND destruction in
// one tick collapse to ONE splat" — which is the defect stated as a property. Collapsing is what
// hid the killing blow's number behind the ✕ and, in the multi-hit case below, hid an entire hit.
// The RS3 read is one splat per hit: the number that killed, AND the mark that it killed.
test('the killing blow shows BOTH: the damage that landed and the kill mark', () => {
  const views = resolvePositionedUnits([unit({ id: 'a', pos_x: 0, pos_y: 0, alive_count: 0, hp_current: 0 })])
  const splats = resolveHitSplats(
    [dmg({ id: 1, seq: 0, payload_json: { unit_id: 'a', damage: 20 } }),
     dmg({ id: 2, seq: 1, event_type: 'unit_destroyed', payload_json: { unit_id: 'a', count: 1 } })],
    views,
  )
  expect(splats).toHaveLength(2)
  expect(splats[0]).toMatchObject({ damage: 20, destroyed: false, index: 0, count: 2 })
  expect(splats[1]).toMatchObject({ damage: null, destroyed: true, index: 1, count: 2 })
})

// ── THE DEFECTS THE OLD RESOLVER SHIPPED ──────────────────────────────────────────────────────────
test('TWO hits on one hull in one tick are TWO numbers — never the last one alone', () => {
  const views = resolvePositionedUnits([unit({ id: 'a', pos_x: 0, pos_y: 0 })])
  // the production pair from tick 17: 4.136 + 4.286 = 8.4 taken, rendered as a single "4"
  const splats = resolveHitSplats(
    [dmg({ id: 1, seq: 0, payload_json: { unit_id: 'a', damage: 4.136 } }),
     dmg({ id: 2, seq: 1, payload_json: { unit_id: 'a', damage: 4.286 } })],
    views,
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
  const splats = resolveHitSplats([dmg({ payload_json: { unit_id: 'a', damage: 9 } })], resolvePositionedUnits(dead))
  expect(splats).toHaveLength(1)
  expect(splats[0]).toMatchObject({ x: 3, y: 4, damage: 9 })
})

test('LATEST TICK is per ENCOUNTER — a second, higher-tick fight cannot blank a newer one', () => {
  const views = resolvePositionedUnits([
    unit({ id: 'a', encounter_id: 'new', pos_x: 0, pos_y: 0 }),
    unit({ id: 'z', encounter_id: 'old', pos_x: 50, pos_y: 50 }),
  ])
  const splats = resolveHitSplats(
    [dmg({ id: 1, encounter_id: 'new', tick_number: 2, payload_json: { unit_id: 'a', damage: 7 } }),
     dmg({ id: 2, encounter_id: 'old', tick_number: 80, payload_json: { unit_id: 'z', damage: 3 } })],
    views,
  )
  // a global max of 80 used to erase the new fight's only splat
  expect(splats.map((s) => s.unitId).sort()).toEqual(['a', 'z'])
})

test('fire lines are per-encounter too, and the KILLING salvo still draws', () => {
  const views = resolvePositionedUnits([
    unit({ id: 'p', encounter_id: 'new', pos_x: 0, pos_y: 0 }),
    unit({ id: 'e', encounter_id: 'new', side: 'enemy', pos_x: 5, pos_y: 0, alive_count: 0 }), // died this tick
    unit({ id: 'o', encounter_id: 'old', pos_x: 90, pos_y: 90 }),
  ])
  const lines = resolveFireLines(
    [salvo({ id: 1, encounter_id: 'new', tick_number: 2, payload_json: { unit_id: 'p', target_id: 'e' } }),
     salvo({ id: 2, encounter_id: 'old', tick_number: 80, payload_json: { unit_id: 'o', target_id: 'o' } })],
    views,
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
  const els = spatialCombatLayer({ units, events: [dmg()], norm, k: 1 })
  const ids = els.map((e) => (e.props as Record<string, unknown>)['data-testid']).filter(Boolean) as string[]
  const splatIdx = ids.findIndex((s) => s.startsWith('spatial-combat-splat-'))
  expect(splatIdx).toBeGreaterThan(-1)
  // drawn last => a number is never hidden behind the ship it belongs to
  expect(splatIdx).toBe(ids.length - 1)
})
