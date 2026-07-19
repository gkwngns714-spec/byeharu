import { test, expect } from '@playwright/test'
import type { ReactElement } from 'react'
import { territoryAt } from '../src/features/map/territoryAt'
import { territoryLayer, type TerritoryRingLocation } from '../src/features/map/territoryLayer'
import { WORLD_TO_VIEWBOX_SCALE } from '../src/features/map/openSpaceTransform'

// S2 TERRITORY — pure specs for the ONE territory-containment resolver (composes the ONE shared
// distance(); no second formula anywhere in these modules) and the GalaxyMap wiring proof via the
// SAME pure `territoryLayer` element-descriptor helper the map renders (the teamMarkers.spec.ts /
// galaxyShipLayer.spec.ts convention). No hooks run, no DB, no fabricated backend.

const norm = (p: { x: number; y: number }) => p // identity stub; positions pass through unchanged
const NO_ZONES: ReadonlySet<string> = new Set() // no location owns a danger_zone → no ring suppression

const loc = (o: Partial<TerritoryRingLocation> = {}): TerritoryRingLocation => ({
  id: 'loc-1',
  x: 0,
  y: 0,
  territory_radius: 25,
  location_type: 'trade_outpost',
  activity_type: 'none',
  reward_tier: 1,
  base_difficulty: 0,
  ...o,
})

// ── territoryAt — containment, boundary, precedence ─────────────────────────────────────────────────
test('territoryAt: inside → the location; outside → null; boundary is INCLUSIVE', () => {
  const t = loc()
  expect(territoryAt({ x: 10, y: 10 }, [t])).toBe(t) // dist ≈ 14.14 < 25
  expect(territoryAt({ x: 26, y: 0 }, [t])).toBeNull() // dist 26 > 25
  expect(territoryAt({ x: 25, y: 0 }, [t])).toBe(t) // dist 25 == 25 — exactly on the boundary
})

test('territoryAt: overlapping territories resolve to the NEAREST CENTER', () => {
  const big = loc({ id: 'big', territory_radius: 35 })
  const small = loc({ id: 'small', x: 20, y: 0, territory_radius: 15 })
  // (5,0) is inside BOTH (d(big)=5, d(small)=15 — on small's boundary): the NEAREST wins even
  // though its radius is larger — the point the old smallest-radius rule got wrong (the S4-review
  // LOW: a fleet parked AT a site must resolve to THAT site, never an overlapping neighbour).
  expect(territoryAt({ x: 5, y: 0 }, [big, small])?.id).toBe('big')
  expect(territoryAt({ x: 5, y: 0 }, [small, big])?.id).toBe('big') // order-independent
  // (12,0) is inside both (d(big)=12, d(small)=8) → the small one is nearest
  expect(territoryAt({ x: 12, y: 0 }, [big, small])?.id).toBe('small')
  // (-30,0) is outside the small ring but inside the big one → the big one
  expect(territoryAt({ x: -30, y: 0 }, [big, small])?.id).toBe('big')
})

test('territoryAt: equal distances tie-break to the smallest radius, then the lowest id', () => {
  // equidistant (d=10 to both), different radii → the most specific (smallest radius) wins
  const wide = loc({ id: 'wide', x: -10, y: 0, territory_radius: 30 })
  const tight = loc({ id: 'tight', x: 10, y: 0, territory_radius: 12 })
  expect(territoryAt({ x: 0, y: 0 }, [wide, tight])?.id).toBe('tight')
  expect(territoryAt({ x: 0, y: 0 }, [tight, wide])?.id).toBe('tight')
  // equidistant AND equal radii → deterministic lowest id, order-independent
  const a = loc({ id: 'aa', territory_radius: 25 })
  const b = loc({ id: 'bb', x: 1, y: 0, territory_radius: 25 })
  expect(territoryAt({ x: 0.5, y: 0 }, [b, a])?.id).toBe('aa')
  expect(territoryAt({ x: 0.5, y: 0 }, [a, b])?.id).toBe('aa')
})

test('territoryAt: fail closed — null/zero/non-finite radius never contains; non-finite point → null', () => {
  expect(territoryAt({ x: 0, y: 0 }, [loc({ territory_radius: null })])).toBeNull()
  expect(territoryAt({ x: 0, y: 0 }, [loc({ territory_radius: 0 })])).toBeNull()
  expect(territoryAt({ x: 0, y: 0 }, [loc({ territory_radius: Number.NaN })])).toBeNull()
  expect(territoryAt({ x: Number.NaN, y: 0 }, [loc()])).toBeNull()
  expect(territoryAt({ x: 0, y: 0 }, [])).toBeNull()
})

// ── territoryLayer — the GalaxyMap wiring proof (element-tree convention) ───────────────────────────
type RingProps = { cx: number; cy: number; r: number; fill?: string; stroke?: string; strokeWidth?: number }
const ringCircles = (g: ReactElement): RingProps[] =>
  ((g.props as { children: ReactElement[] }).children ?? []).map((c) => c.props as RingProps)

test('layer: one WORLD-TRUE ring per territory — r = territory_radius * WORLD_TO_VIEWBOX_SCALE, NOT /k', () => {
  const t = loc({ x: 100, y: 200, territory_radius: 25 })
  for (const k of [1, 4]) {
    const layer = territoryLayer({ locations: [t], norm, k, zonedLocationIds: NO_ZONES })
    expect(layer).toHaveLength(1)
    const circles = ringCircles(layer[0])
    expect(circles).toHaveLength(2) // fill disc + dashed boundary
    for (const c of circles) {
      expect({ cx: c.cx, cy: c.cy }).toEqual({ cx: 100, cy: 200 })
      expect(c.r).toBe(25 * WORLD_TO_VIEWBOX_SCALE) // 1.25 viewBox units at EVERY zoom (world-true)
    }
    // only the stroke weight is screen-constant
    const boundary = circles.find((c) => c.fill === 'none')!
    expect(boundary.strokeWidth).toBe(1 / k)
  }
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

test('layer: tone composes markerStyle — hostile ring is the danger token; port ring the accent token', () => {
  const hostile = loc({ id: 'h', location_type: 'pirate_hunt', activity_type: 'hunt_pirates', territory_radius: 35 })
  const port = loc({ id: 'p', territory_radius: 25 })
  // neither hostile nor port owns a danger_zone here → hostile keeps its ring, so its tone is asserted
  const [hg, pg] = territoryLayer({ locations: [hostile, port], norm, k: 1, zonedLocationIds: NO_ZONES })
  expect(ringCircles(hg)[0].fill).toBe('var(--color-danger)')
  expect(ringCircles(pg)[0].fill).toBe('var(--color-accent)')
})

test('layer: NULL/non-positive territory renders nothing — the pre-0217 map is byte-identical', () => {
  expect(territoryLayer({ locations: [loc({ territory_radius: null })], norm, k: 1, zonedLocationIds: NO_ZONES })).toEqual([])
  expect(territoryLayer({ locations: [loc({ territory_radius: 0 })], norm, k: 1, zonedLocationIds: NO_ZONES })).toEqual([])
  expect(territoryLayer({ locations: [], norm, k: 1, zonedLocationIds: NO_ZONES })).toEqual([])
})
