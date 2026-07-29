import { test, expect } from '@playwright/test'
import { buildZoneInfo } from '../src/features/map/zoneInfoModel'
import { dangerZoneLayer } from '../src/features/map/dangerZoneLayer'
import type { DangerZoneLite } from '../src/features/map/pirateApi'
import type { MapLocation } from '../src/features/map/mapTypes'

// ZONE INFO — "click a danger zone, see what it is" (owner, 2026-07-29). Pure specs: the model
// decides every word, and the layer decides whether a zone is a tap target at all.

const loc = (over: Partial<MapLocation> = {}): MapLocation => ({
  id: 'loc-1',
  name: 'Reaver',
  location_type: 'hunting_ground',
  x: 10,
  y: 10,
  base_difficulty: 5,
  reward_tier: 2,
  activity_type: 'hunt_pirates',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  territory_radius: null,
  ...over,
} as MapLocation)

/** A closed 100×100 square ring (first point repeated), exactly the shape get_danger_zones returns. */
const SQUARE: [number, number][] = [
  [0, 0],
  [100, 0],
  [100, 100],
  [0, 100],
  [0, 0],
]

const zone = (over: Partial<DangerZoneLite> = {}): DangerZoneLite => ({
  id: 'z-1',
  name: 'The Snare',
  source: 'drawn',
  location_id: null,
  ring: SQUARE,
  revision: 3,
  ...over,
})

// ── the words ────────────────────────────────────────────────────────────────────────────────────

test('the zone names itself, and the warning says what actually happens to you', () => {
  const info = buildZoneInfo(zone(), [])
  expect(info.id).toBe('z-1')
  expect(info.title).toBe('The Snare')
  expect(info.warning).toBe('Pirates hunt here. A fleet crossing this zone is almost always attacked.')
})

test('a blank name falls back to plain words — never a raw id in front of a player', () => {
  expect(buildZoneInfo(zone({ name: '   ' }), []).title).toBe('Unnamed danger zone')
  expect(buildZoneInfo(zone({ name: '' }), []).title).not.toContain('z-1')
})

test('a bound zone says WHERE by name; an unbound one says open space', () => {
  const bound = buildZoneInfo(zone({ location_id: 'loc-1' }), [loc()])
  expect(bound.rows).toContainEqual({ label: 'Where', value: 'Around Reaver' })
  const loose = buildZoneInfo(zone({ location_id: null }), [loc()])
  expect(loose.rows).toContainEqual({ label: 'Where', value: 'Open space' })
})

test('an unresolvable location_id degrades to open space — never a guessed name', () => {
  // Fail closed: the zone points at a location this client cannot see (RLS, stale read, deleted).
  const info = buildZoneInfo(zone({ location_id: 'loc-missing' }), [loc()])
  expect(info.rows).toContainEqual({ label: 'Where', value: 'Open space' })
})

test('size is the equal-area diameter, and the closing duplicate vertex does not distort it', () => {
  // 100×100 = 10000 world units of area → 2*sqrt(10000/pi) ≈ 112.8 across.
  const info = buildZoneInfo(zone(), [])
  expect(info.rows).toContainEqual({ label: 'Size', value: 'About 113 across' })
  // The same square WITHOUT the repeated closing point must describe identically.
  const open = buildZoneInfo(zone({ ring: SQUARE.slice(0, -1) }), [])
  expect(open.rows).toEqual(info.rows)
})

test('a zone with no usable ring simply omits the size row rather than printing a zero', () => {
  for (const ring of [null, [] as [number, number][], [[0, 0], [1, 1]] as [number, number][]]) {
    const info = buildZoneInfo(zone({ ring }), [])
    expect(info.rows.some((r) => r.label === 'Size')).toBe(false)
    expect(info.rows).toContainEqual({ label: 'Where', value: 'Open space' })
  }
})

test('NO authoring jargon reaches the player — source, provenance, revision and the id stay out', () => {
  // The whole point of the play-test language rule. Guards the class, not one string.
  const info = buildZoneInfo(zone({ source: 'circle', location_id: 'loc-1' }), [loc()])
  const printed = [info.title, info.warning, ...info.rows.flatMap((r) => [r.label, r.value])].join(' ').toLowerCase()
  for (const banned of ['drawn', 'circle', 'provenance', 'revision', 'source', 'z-1', 'loc-1', 'polygon']) {
    expect(printed).not.toContain(banned)
  }
})

// ── the tap target ───────────────────────────────────────────────────────────────────────────────

const norm = (p: { x: number; y: number }) => p

test('WITHOUT a handler the layer is scenery — nothing is hit-testable (today, byte for byte)', () => {
  const els = dangerZoneLayer({ zones: [zone()], norm, k: 1 })
  expect(els).toHaveLength(1)
  const fill = (els[0].props as { children: { props: Record<string, unknown> }[] }).children[0].props
  expect(fill.onClick).toBeUndefined()
  expect(fill.style).toBeUndefined()
  expect(fill['data-testid']).toBeUndefined()
})

test('WITH a handler the FILL becomes a pointer target and reports the whole zone', () => {
  let got: DangerZoneLite | null = null
  const els = dangerZoneLayer({ zones: [zone()], norm, k: 1, onSelect: (z) => (got = z) })
  const fill = (els[0].props as { children: { props: Record<string, unknown> }[] }).children[0].props
  expect((fill.style as { pointerEvents: string; cursor: string }).pointerEvents).toBe('auto')
  expect((fill.style as { cursor: string }).cursor).toBe('pointer')
  ;(fill.onClick as () => void)()
  expect(got).not.toBeNull()
  expect((got as unknown as DangerZoneLite).id).toBe('z-1')
})

test('the OUTLINE never hit-tests, so a boundary click cannot be stolen from a marker under it', () => {
  const els = dangerZoneLayer({ zones: [zone()], norm, k: 1, onSelect: () => {} })
  const kids = (els[0].props as { children: { props: Record<string, unknown> }[] }).children
  expect(kids[1].props.style).toBeUndefined()
  expect(kids[1].props.onClick).toBeUndefined()
  // ...and the group itself stays inert so only the fill opts in.
  expect((els[0].props as { style: { pointerEvents: string } }).style.pointerEvents).toBe('none')
})

test('the hit path is NOT focusable — a focused SVG path gets a filled browser focus ring over the blob', () => {
  // Caught in the local build: role/tabIndex made the clicked zone render white with a black halo.
  // LocationMarker (:64-68), the map's existing clickable, carries neither. Guards the regression.
  const fill = (
    dangerZoneLayer({ zones: [zone()], norm, k: 1, onSelect: () => {} })[0].props as {
      children: { props: Record<string, unknown> }[]
    }
  ).children[0].props
  expect(fill.tabIndex).toBeUndefined()
  expect(fill.role).toBeUndefined()
})

test('an interactive zone carries an SVG <title> — the accessible name, and a hover tooltip', () => {
  const kids = (
    dangerZoneLayer({ zones: [zone()], norm, k: 1, onSelect: () => {} })[0].props as {
      children: (null | { type: string; props: { children: string } })[]
    }
  ).children
  const title = kids[2]
  expect(title).not.toBeNull()
  expect(title?.type).toBe('title')
  expect(title?.props.children).toBe('The Snare')
  // Scenery has no title node at all — nothing to hover, nothing to name.
  const scenery = (
    dangerZoneLayer({ zones: [zone()], norm, k: 1 })[0].props as { children: (null | unknown)[] }
  ).children
  expect(scenery[2]).toBeNull()
})

test('hover and selection READ on the map: fill and outline both strengthen, selected strongest', () => {
  const read = (args: Parameters<typeof dangerZoneLayer>[0]) => {
    const kids = (dangerZoneLayer(args)[0].props as { children: { props: Record<string, number> }[] }).children
    return { fill: kids[0].props.opacity, stroke: kids[1].props.strokeOpacity, width: kids[1].props.strokeWidth }
  }
  const base = { zones: [zone()], norm, k: 1, onSelect: () => {} }
  const idle = read(base)
  const hovered = read({ ...base, hoveredId: 'z-1' })
  const selected = read({ ...base, selectedId: 'z-1' })
  expect(hovered.fill).toBeGreaterThan(idle.fill)
  expect(selected.fill).toBeGreaterThan(hovered.fill)
  expect(hovered.stroke).toBeGreaterThan(idle.stroke)
  expect(selected.stroke).toBeGreaterThan(hovered.stroke)
  expect(selected.width).toBeGreaterThan(idle.width)
})

test('hover/selection ids are IGNORED while the layer is scenery (no handler → no affordance)', () => {
  const kids = (
    dangerZoneLayer({ zones: [zone()], norm, k: 1, hoveredId: 'z-1', selectedId: 'z-1' })[0].props as {
      children: { props: Record<string, number> }[]
    }
  ).children
  expect(kids[0].props.opacity).toBe(0.1)
  expect(kids[1].props.strokeOpacity).toBe(0.55)
})

test('hovering reports the id in, and null out, so the caller can drive the highlight', () => {
  const seen: (string | null)[] = []
  const els = dangerZoneLayer({ zones: [zone()], norm, k: 1, onSelect: () => {}, onHoverChange: (id) => seen.push(id) })
  const fill = (els[0].props as { children: { props: Record<string, unknown> }[] }).children[0].props
  ;(fill.onPointerEnter as () => void)()
  ;(fill.onPointerLeave as () => void)()
  expect(seen).toEqual(['z-1', null])
})

test('a ring with fewer than 3 points draws nothing at all (no invisible tap target)', () => {
  expect(dangerZoneLayer({ zones: [zone({ ring: null })], norm, k: 1, onSelect: () => {} })).toEqual([])
  expect(dangerZoneLayer({ zones: [zone({ ring: [[0, 0], [1, 1]] })], norm, k: 1, onSelect: () => {} })).toEqual([])
})
