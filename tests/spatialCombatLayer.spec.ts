import { test, expect } from '@playwright/test'
import type { ReactElement } from 'react'
import {
  spatialCombatLayer,
  resolveSpatialUnits,
  resolveFireLines,
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
  const poly = (g: ReactElement) => (g.props as { children: ReactElement }).children.props as { fill: string; points: string }
  expect(poly(pg).fill).toBe('var(--color-accent)')
  expect(poly(eg).fill).toBe('var(--color-danger)')
  expect(poly(pg).points).not.toBe(poly(eg).points) // up- vs down-pointing triangle
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
    { id: 'u1', side: 'player', x: 0, y: 0, range: 300, hpFrac: 1 },
    { id: 'u2', side: 'enemy', x: 100, y: 0, range: 120, hpFrac: 1 },
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
  const views: SpatialUnitView[] = [{ id: 'u1', side: 'player', x: 0, y: 0, range: 300, hpFrac: 1 }]
  const aggregate = salvo({ id: 3, tick_number: 7, payload_json: { damage: 42, wave: 1 } }) // dark path
  const orphan = salvo({ id: 4, tick_number: 7, payload_json: { unit_id: 'u1', target_id: 'gone' } })
  expect(resolveFireLines([aggregate, orphan], views)).toEqual([])
})
