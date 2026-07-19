import { test, expect } from '@playwright/test'
import {
  resolveToViewBox,
  representationWorldPoints,
} from '../src/features/worldeditor/worldEditorGeometry'
import type { MapRepresentation } from '../src/features/worldeditor/worldEditorTypes'
import { worldToViewBox, viewBoxToWorld } from '../src/features/map/openSpaceTransform'

// WORLD EDITOR V1 — the map-representation resolver forwards to the SHARED openSpaceTransform (the ONE
// projection authority, §WE.11) and NEVER invents a second world↔viewBox map. Pure proofs, no DB.
// Run: `npx playwright test worldEditorGeometry.spec.ts`.

test('point representation resolves EXACTLY through the shared worldToViewBox', () => {
  const rep: MapRepresentation = { kind: 'point', world: { x: 250, y: -600 } }
  const resolved = resolveToViewBox(rep)
  expect(resolved.kind).toBe('point')
  if (resolved.kind !== 'point') throw new Error('unreachable')
  expect(resolved.point).toEqual(worldToViewBox({ x: 250, y: -600 }))
})

test('polygon representation resolves each vertex through the shared transform', () => {
  const ring = [{ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 100, y: 100 }]
  const rep: MapRepresentation = { kind: 'polygon', ring }
  const resolved = resolveToViewBox(rep)
  expect(resolved.kind).toBe('polygon')
  if (resolved.kind !== 'polygon') throw new Error('unreachable')
  expect(resolved.ring).toEqual(ring.map((p) => worldToViewBox(p)))
})

test('representationWorldPoints returns the canonical world coords for camera fit', () => {
  expect(representationWorldPoints({ kind: 'point', world: { x: 7, y: 9 } })).toEqual([{ x: 7, y: 9 }])
  const ring = [{ x: 1, y: 2 }, { x: 3, y: 4 }]
  expect(representationWorldPoints({ kind: 'polygon', ring })).toEqual(ring)
})

test('resolve is a true projection — round-trips back to world within float tolerance', () => {
  for (const w of [{ x: 0, y: 0 }, { x: 250, y: -600 }, { x: -9999, y: 9999 }]) {
    const resolved = resolveToViewBox({ kind: 'point', world: w })
    if (resolved.kind !== 'point') throw new Error('unreachable')
    const back = viewBoxToWorld(resolved.point)
    expect(back.x).toBeCloseTo(w.x, 6)
    expect(back.y).toBeCloseTo(w.y, 6)
  }
})
