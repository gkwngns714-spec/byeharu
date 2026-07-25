import { test, expect } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  compareCandidates,
  hitTestAt,
  markerRadiusInWorld,
  needsDisambiguation,
  primaryCandidate,
} from '../src/features/worldeditor/worldEditorHitTest'
import type { LayerItem } from '../src/features/worldeditor/worldEditorTypes'

// WORLD EDITOR — MAP HIT-TESTING. The reported defect: a pirate_hunt location and its danger zone are
// co-located, polygons draw UNDER points, and each shape stopped propagation — so clicking the zone
// silently selected the LOCATION and the zone appeared unselectable.
// These tests pin the fix AND the reason it is not "raise the polygon": both entities are legitimate
// targets at the same coordinate, so the hit-test must surface BOTH and let the caller disambiguate.
// Run: `npx playwright test worldEditorHitTest.spec.ts`.

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(
  join(here, '..', 'src', 'features', 'worldeditor', 'worldEditorHitTest.ts'),
  'utf8',
)

const zone = (id: string, label = 'Blackden'): LayerItem => ({
  layer: 'zones',
  id,
  label,
  representation: {
    kind: 'polygon',
    ring: [
      { x: 0, y: 0 },
      { x: 100, y: 0 },
      { x: 100, y: 100 },
      { x: 0, y: 100 },
    ],
  },
  tone: 'var(--color-warning)',
  glyph: 'circle',
})

const location = (id: string, at = { x: 50, y: 50 }, label = 'Blackden'): LayerItem => ({
  layer: 'locations',
  id,
  label,
  representation: { kind: 'point', world: at },
  tone: 'var(--color-accent)',
  glyph: 'circle',
})

// ── the reported defect ─────────────────────────────────────────────────────────────────────────
test('REGRESSION: a location inside its co-located zone yields BOTH candidates, not just the marker', () => {
  const hits = hitTestAt([zone('z1'), location('l1')], { x: 50, y: 50 }, 10)
  expect(hits.map((h) => h.layer)).toEqual(['locations', 'zones'])
  expect(needsDisambiguation(hits)).toBe(true)
})

test('clicking the zone AWAY from the marker yields the zone alone — no ceremony', () => {
  const hits = hitTestAt([zone('z1'), location('l1')], { x: 10, y: 90 }, 10)
  expect(hits).toHaveLength(1)
  expect(hits[0].layer).toBe('zones')
  expect(needsDisambiguation(hits)).toBe(false)
  expect(primaryCandidate(hits)?.id).toBe('z1')
})

test('clicking bare map yields nothing — the caller reads that as a deselect', () => {
  const hits = hitTestAt([zone('z1'), location('l1')], { x: 500, y: 500 }, 10)
  expect(hits).toEqual([])
  expect(needsDisambiguation(hits)).toBe(false)
  expect(primaryCandidate(hits)).toBeNull()
})

// ── ordering ────────────────────────────────────────────────────────────────────────────────────
test('the smaller, more deliberate target leads: point before circle before polygon', () => {
  const circleZone: LayerItem = {
    layer: 'zones',
    id: 'c1',
    label: 'Ring',
    representation: { kind: 'circle', center: { x: 50, y: 50 }, radius: 40 },
    tone: 'var(--color-warning)',
    glyph: 'circle',
  }
  const hits = hitTestAt([zone('z1'), circleZone, location('l1')], { x: 50, y: 50 }, 10)
  expect(hits.map((h) => h.shape)).toEqual(['point', 'circle', 'polygon'])
  expect(primaryCandidate(hits)?.shape).toBe('point')
})

test('ordering is TOTAL and stable — identical clicks never reshuffle a chooser', () => {
  const items = [zone('z2', 'Beta'), zone('z1', 'Alpha'), location('l2', { x: 50, y: 50 }, 'Beta'), location('l1', { x: 50, y: 50 }, 'Alpha')]
  const a = hitTestAt(items, { x: 50, y: 50 }, 10)
  const b = hitTestAt([...items].reverse(), { x: 50, y: 50 }, 10)
  expect(a).toEqual(b)
  // and within a shape, label then id
  expect(a.filter((h) => h.shape === 'point').map((h) => h.label)).toEqual(['Alpha', 'Beta'])
})

test('compareCandidates is antisymmetric, so any sort is deterministic', () => {
  const p = { layer: 'locations', id: 'a', label: 'A', shape: 'point' } as const
  const q = { layer: 'zones', id: 'b', label: 'B', shape: 'polygon' } as const
  expect(compareCandidates(p, q)).toBeLessThan(0)
  expect(compareCandidates(q, p)).toBeGreaterThan(0)
  expect(compareCandidates(p, { ...p })).toBe(0)
})

// ── marker radius / zoom ────────────────────────────────────────────────────────────────────────
test('REGRESSION: the marker radius converts BOTH ways — viewBox AND world', () => {
  // The first version of this divided by k only, leaving the radius in viewBox units. Because
  // world→viewBox is a large factor here, the hit area collapsed and a click landing exactly on a
  // marker missed it. Verified live before the fix.
  expect(markerRadiusInWorld(19, 1, 1)).toBe(19)
  expect(markerRadiusInWorld(19, 19, 1)).toBe(1)
  // with a world→viewBox factor of 0.05, a 19-unit marker covers 380 world units at k=1
  expect(markerRadiusInWorld(19, 1, 0.05)).toBeCloseTo(380, 6)
  expect(markerRadiusInWorld(19, 2, 0.05)).toBeCloseTo(190, 6)
})

test('a marker stays hittable at high zoom, and stops being hittable when it should', () => {
  const r = (k: number) => markerRadiusInWorld(19, k, 1)
  expect(hitTestAt([location('l1')], { x: 55, y: 50 }, r(1))).toHaveLength(1)
  expect(hitTestAt([location('l1')], { x: 55, y: 50 }, r(10))).toHaveLength(0)
})

test('a zero or negative scale cannot produce a nonsense radius', () => {
  expect(markerRadiusInWorld(19, 0, 1)).toBe(19)
  expect(markerRadiusInWorld(19, -1, 1)).toBe(19)
  expect(markerRadiusInWorld(19, 1, 0)).toBe(19)
  expect(markerRadiusInWorld(19, 1, -1)).toBe(19)
})

// ── geometry edge cases ─────────────────────────────────────────────────────────────────────────
test('a degenerate ring (fewer than 3 vertices) is never a hit', () => {
  const degenerate: LayerItem = {
    layer: 'zones',
    id: 'd1',
    label: 'Sliver',
    representation: { kind: 'polygon', ring: [{ x: 0, y: 0 }, { x: 10, y: 10 }] },
    tone: 'var(--color-warning)',
    glyph: 'circle',
  }
  expect(hitTestAt([degenerate], { x: 5, y: 5 }, 10)).toEqual([])
})

test('a point just outside a circle zone is not a hit', () => {
  const circleZone: LayerItem = {
    layer: 'zones',
    id: 'c1',
    label: 'Ring',
    representation: { kind: 'circle', center: { x: 0, y: 0 }, radius: 10 },
    tone: 'var(--color-warning)',
    glyph: 'circle',
  }
  expect(hitTestAt([circleZone], { x: 9, y: 0 }, 1)).toHaveLength(1)
  expect(hitTestAt([circleZone], { x: 11, y: 0 }, 1)).toHaveLength(0)
})

test('overlapping zones of different kinds ALL surface — none is silently dropped', () => {
  const a = zone('z1', 'Alpha')
  const b: LayerItem = { ...zone('z2', 'Beta'), layer: 'zones' }
  const hits = hitTestAt([a, b], { x: 50, y: 50 }, 10)
  expect(hits).toHaveLength(2)
  expect(hits.map((h) => h.id).sort()).toEqual(['z1', 'z2'])
})

// ── structural ──────────────────────────────────────────────────────────────────────────────────
test('the module is PURE and reuses the ONE geometry authority rather than re-deriving it', () => {
  expect(source).not.toMatch(/\bfrom 'react'|useState|document\.|window\.|fetch\(|localStorage/)
  expect(source).toMatch(/from '\.\/zoneGeometryMath'/)
  // no second point-in-polygon implementation
  expect(source).not.toMatch(/Math\.atan2|crossing|winding/i)
})

test('it decides WHAT was hit, never what the UI should do about it', () => {
  // strip comments first: the header legitimately NAMES the sibling chrome module as the idiom it
  // follows, which is documentation, not a dependency on it.
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
  expect(code).not.toMatch(/setSelected|openTool|Chrome|dialog/)
  // its only import is the geometry authority and its own types
  const imports = code.match(/^import .*$/gm) ?? []
  expect(imports).toHaveLength(2)
  expect(imports.join('\n')).toMatch(/zoneGeometryMath/)
  expect(imports.join('\n')).toMatch(/worldEditorTypes/)
})
