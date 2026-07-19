import { test, expect } from '@playwright/test'
import type { ReactElement } from 'react'
import { territoryLayer, type TerritoryRingLocation } from '../src/features/map/territoryLayer'
import { WORLD_TO_VIEWBOX_SCALE } from '../src/features/map/openSpaceTransform'

// S2 TERRITORY — pure spec for the territory-ring layer (the miningFieldLayer/teamMarkersLayer
// element-descriptor convention: pure, hook-free, GalaxyMap and this spec call the SAME function).
// No hooks run, no DB, no fabricated backend.

const norm = (p: { x: number; y: number }) => p // identity stub; positions pass through unchanged
const NO_ZONES: ReadonlySet<string> = new Set() // no location owns a danger_zone (default)

const loc = (o: Partial<TerritoryRingLocation> = {}): TerritoryRingLocation => ({
  id: 'loc-1',
  x: 100,
  y: 200,
  territory_radius: 750,
  location_type: 'trade_outpost',
  activity_type: 'none',
  reward_tier: 0,
  base_difficulty: 0,
  ...o,
})

type RingProps = { cx: number; cy: number; r: number; fill?: string; stroke?: string; strokeWidth?: number }
const ringCircles = (g: ReactElement): RingProps[] =>
  ((g.props as { children: ReactElement[] }).children ?? []).map((c) => c.props as RingProps)
const testIds = (layer: ReactElement[]): unknown[] =>
  layer.map((g) => (g.props as Record<string, unknown>)['data-testid'])

test('layer: one WORLD-TRUE ring per non-hostile location — r = radius * WORLD_TO_VIEWBOX_SCALE, NOT /k', () => {
  const l = loc()
  for (const k of [1, 4]) {
    const layer = territoryLayer({ locations: [l], norm, k, zonedLocationIds: NO_ZONES })
    expect(layer).toHaveLength(1)
    const circles = ringCircles(layer[0])
    expect(circles).toHaveLength(2) // fill disc + dashed boundary
    for (const c of circles) {
      expect({ cx: c.cx, cy: c.cy }).toEqual({ cx: 100, cy: 200 })
      expect(c.r).toBe(750 * WORLD_TO_VIEWBOX_SCALE) // world-true at EVERY zoom
    }
    const boundary = circles.find((c) => c.fill === 'none')!
    expect(boundary.strokeWidth).toBe(1 / k) // only the stroke weight is screen-constant
  }
})

test('layer: ports/safe/resource locations keep their ring (never gated by zones)', () => {
  const port = loc({ id: 'port', location_type: 'trade_outpost' })
  const safe = loc({ id: 'safe', location_type: 'safe_zone' })
  const mine = loc({ id: 'mine', location_type: 'mining_site' })
  // even if a zone were bound to one, a non-hostile location is never suppressed:
  const layer = territoryLayer({ locations: [port, safe, mine], norm, k: 1, zonedLocationIds: new Set(['port', 'safe', 'mine']) })
  expect(testIds(layer)).toEqual(['territory-ring-port', 'territory-ring-safe', 'territory-ring-mine'])
})

test('layer: hostile location WITH its own danger_zone renders NO ring — the polygon represents it', () => {
  // pirate_hunt / pirate_den by type, and any location running the hunt_pirates activity: all hostile.
  const hunt = loc({ id: 'hunt', location_type: 'pirate_hunt' })
  const den = loc({ id: 'den', location_type: 'pirate_den' })
  const activityHostile = loc({ id: 'act', location_type: 'safe_zone', activity_type: 'hunt_pirates' })
  for (const hostile of [hunt, den, activityHostile]) {
    const zoned = new Set([hostile.id]) // this pirate site owns a danger_zone → ring suppressed
    expect(territoryLayer({ locations: [hostile], norm, k: 1, zonedLocationIds: zoned })).toEqual([])
  }
})

test('layer: hostile location WITHOUT a danger_zone KEEPS its ring — never zero regions on a pirate site', () => {
  // The #217 regression: a hostile site with no bound zone was suppressed AND had no polygon → nothing
  // drawn. Now the ring survives so the site still shows exactly one region.
  const hunt = loc({ id: 'hunt', location_type: 'pirate_hunt' })
  const den = loc({ id: 'den', location_type: 'pirate_den' })
  const activityHostile = loc({ id: 'act', location_type: 'safe_zone', activity_type: 'hunt_pirates' })
  for (const hostile of [hunt, den, activityHostile]) {
    const layer = territoryLayer({ locations: [hostile], norm, k: 1, zonedLocationIds: NO_ZONES })
    expect(testIds(layer)).toEqual([`territory-ring-${hostile.id}`])
  }
})

test('layer: mixed set — only hostile sites that OWN a zone are suppressed; the rest keep rings, in order', () => {
  const port = loc({ id: 'port', location_type: 'trade_outpost' })
  const pirateZoned = loc({ id: 'pirate-zoned', location_type: 'pirate_den' }) // has a zone → suppressed
  const pirateBare = loc({ id: 'pirate-bare', location_type: 'pirate_hunt' }) // no zone → keeps ring
  const safe = loc({ id: 'safe', location_type: 'safe_zone' })
  const layer = territoryLayer({
    locations: [port, pirateZoned, pirateBare, safe],
    norm,
    k: 1,
    zonedLocationIds: new Set(['pirate-zoned']),
  })
  expect(testIds(layer)).toEqual(['territory-ring-port', 'territory-ring-pirate-bare', 'territory-ring-safe'])
})

test('layer: rings project through the map norm and stay pointer-transparent', () => {
  const layer = territoryLayer({
    locations: [loc({ x: 10, y: 20 })],
    norm: (p) => ({ x: p.x + 1, y: p.y + 1 }), // non-identity: proves projection happens
    k: 1,
    zonedLocationIds: NO_ZONES,
  })
  const g = layer[0]
  expect((g.props as { style: { pointerEvents: string } }).style.pointerEvents).toBe('none')
  expect((g.props as Record<string, unknown>)['data-testid']).toBe('territory-ring-loc-1')
  expect(ringCircles(g)[0]).toMatchObject({ cx: 11, cy: 21 })
})

test('layer: fail closed — null/non-positive/non-finite radius or no locations renders nothing', () => {
  const z = NO_ZONES
  expect(territoryLayer({ locations: [loc({ territory_radius: null })], norm, k: 1, zonedLocationIds: z })).toEqual([])
  expect(territoryLayer({ locations: [loc({ territory_radius: 0 })], norm, k: 1, zonedLocationIds: z })).toEqual([])
  expect(territoryLayer({ locations: [loc({ territory_radius: -5 })], norm, k: 1, zonedLocationIds: z })).toEqual([])
  expect(territoryLayer({ locations: [loc({ territory_radius: Number.NaN })], norm, k: 1, zonedLocationIds: z })).toEqual([])
  expect(territoryLayer({ locations: [], norm, k: 1, zonedLocationIds: z })).toEqual([])
})
