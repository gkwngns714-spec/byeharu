import { test, expect } from '@playwright/test'
import { MAP_PASSTHROUGH_ATTR, isMapBackground } from '../src/features/map/mapBackground'

// THE ONE BACKGROUND AUTHORITY. GalaxyMap asks this before it will treat a pointer-up as a map
// gesture (the double-tap command-hub summon, and the pirate route-planner's waypoint taps).
//
// It replaces an inline `e.target !== svg` identity test that silently depended on every drawn layer
// being pointerEvents:'none'. When the danger-zone fill started hit-testing, that dependency deleted
// BOTH gestures across the whole area of every zone — the owner hit it as "i can't send a fleet to
// zone since it is pressed and info is shown". These specs pin the contract that replaced it.

/** Minimal duck-typed stand-in: the module only ever calls getAttribute. */
const el = (attrs: Record<string, string> = {}) =>
  ({ getAttribute: (k: string) => attrs[k] ?? null }) as unknown as EventTarget

const svg = {} as SVGSVGElement

test('the svg itself IS the background — the original behaviour, unchanged', () => {
  expect(isMapBackground(svg, svg)).toBe(true)
})

test('an element that DECLARES passthrough counts as background', () => {
  expect(isMapBackground(el({ [MAP_PASSTHROUGH_ATTR]: 'true' }), svg)).toBe(true)
})

test('everything else is NOT background — fails closed, exactly as before', () => {
  // A marker, a panel, a label: anything that has not opted in keeps swallowing the gesture, which is
  // the whole point (tapping a port must not also summon the hub at that point).
  expect(isMapBackground(el(), svg)).toBe(false)
  expect(isMapBackground(el({ [MAP_PASSTHROUGH_ATTR]: 'false' }), svg)).toBe(false)
  // Only the exact string 'true' opts in — a present-but-empty attribute is not a declaration.
  expect(isMapBackground(el({ [MAP_PASSTHROUGH_ATTR]: '' }), svg)).toBe(false)
})

test('a null target, a missing svg, or a non-Element target never reads as background', () => {
  expect(isMapBackground(null, svg)).toBe(false)
  expect(isMapBackground(svg, null)).toBe(false)
  expect(isMapBackground(el({ [MAP_PASSTHROUGH_ATTR]: 'true' }), null)).toBe(false)
  expect(isMapBackground({} as EventTarget, svg)).toBe(false)
})

test('identity beats the marker: the svg is background even with no attributes at all', () => {
  // Guards against a future refactor that drops the identity arm and relies on marking the svg.
  expect(isMapBackground(svg, svg)).toBe(true)
  expect(isMapBackground(svg, {} as SVGSVGElement)).toBe(false)
})
