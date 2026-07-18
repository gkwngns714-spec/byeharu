import { test, expect } from '@playwright/test'
import type { ReactElement } from 'react'
import { miningFieldRangeLayer } from '../src/features/map/miningFieldLayer'
import { WORLD_TO_VIEWBOX_SCALE } from '../src/features/map/openSpaceTransform'
import type { MiningField } from '../src/features/mining/miningTypes'

// MINING-FIELD-MARKERS — pure spec for the field range-ring layer (the territoryLayer/
// teamMarkersLayer element-descriptor convention: pure, hook-free, GalaxyMap and this spec call the
// SAME function). No hooks run, no DB, no fabricated backend.

const norm = (p: { x: number; y: number }) => p // identity stub; positions pass through unchanged

const field = (o: Partial<MiningField> = {}): MiningField => ({
  name: 'Sparse Ore Belt',
  space_x: 100,
  space_y: 200,
  ...o,
})

type RingProps = { cx: number; cy: number; r: number; fill?: string; stroke?: string; strokeWidth?: number }
const ringCircles = (g: ReactElement): RingProps[] =>
  ((g.props as { children: ReactElement[] }).children ?? []).map((c) => c.props as RingProps)

test('layer: one WORLD-TRUE ring per field — r = radius * WORLD_TO_VIEWBOX_SCALE, NOT /k', () => {
  const f = field()
  for (const k of [1, 4]) {
    const layer = miningFieldRangeLayer({ fields: [f], norm, k, radius: 750 })
    expect(layer).toHaveLength(1)
    const circles = ringCircles(layer[0])
    expect(circles).toHaveLength(2) // fill disc + dashed boundary
    for (const c of circles) {
      expect({ cx: c.cx, cy: c.cy }).toEqual({ cx: 100, cy: 200 })
      expect(c.r).toBe(750 * WORLD_TO_VIEWBOX_SCALE) // world-true at EVERY zoom
    }
    // only the stroke weight is screen-constant
    const boundary = circles.find((c) => c.fill === 'none')!
    expect(boundary.strokeWidth).toBe(1 / k)
  }
})

test('layer: rings project through the map norm and stay pointer-transparent', () => {
  const layer = miningFieldRangeLayer({
    fields: [field({ space_x: 10, space_y: 20 })],
    norm: (p) => ({ x: p.x + 1, y: p.y + 1 }), // non-identity: proves projection happens
    k: 1,
    radius: 750,
  })
  const g = layer[0]
  expect((g.props as { style: { pointerEvents: string } }).style.pointerEvents).toBe('none')
  expect((g.props as Record<string, unknown>)['data-testid']).toBe('mining-field-range-Sparse Ore Belt')
  expect(ringCircles(g)[0]).toMatchObject({ cx: 11, cy: 21 })
})

test('layer: multiple fields each get their own ring, in input order', () => {
  const a = field({ name: 'Alpha', space_x: 0, space_y: 0 })
  const b = field({ name: 'Bravo', space_x: 500, space_y: 500 })
  const layer = miningFieldRangeLayer({ fields: [a, b], norm, k: 1, radius: 750 })
  expect(layer).toHaveLength(2)
  expect((layer[0].props as Record<string, unknown>)['data-testid']).toBe('mining-field-range-Alpha')
  expect((layer[1].props as Record<string, unknown>)['data-testid']).toBe('mining-field-range-Bravo')
})

test('layer: fail closed — non-positive/non-finite radius or no fields renders nothing', () => {
  expect(miningFieldRangeLayer({ fields: [field()], norm, k: 1, radius: 0 })).toEqual([])
  expect(miningFieldRangeLayer({ fields: [field()], norm, k: 1, radius: -5 })).toEqual([])
  expect(miningFieldRangeLayer({ fields: [field()], norm, k: 1, radius: Number.NaN })).toEqual([])
  expect(miningFieldRangeLayer({ fields: [], norm, k: 1, radius: 750 })).toEqual([])
})
