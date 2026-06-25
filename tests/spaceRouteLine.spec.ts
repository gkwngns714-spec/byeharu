import { test, expect } from '@playwright/test'
import { SpaceRoutePresentation } from '../src/features/map/SpaceRouteLine'
import type { ActiveSpaceRoute } from '../src/features/map/spaceRouteModel'
import { worldToViewBox } from '../src/features/map/openSpaceTransform'

// OSN-3 S6B-ROUTE — pure proofs for the presentational route. SpaceRoutePresentation is hook-free, so
// calling it returns its React element tree for inspection (no browser/page/DB). The route is one thing
// (outbound open-space) — no returning/base styling. Run via `npm run verify:osn:s6b-route`.

type El = { type: unknown; props: Record<string, unknown> }
function* walk(node: unknown): Generator<El> {
  if (node == null || typeof node !== 'object') return
  if (Array.isArray(node)) { for (const n of node) yield* walk(n); return }
  const el = node as El
  if (el.props) { yield el; if ('children' in el.props) yield* walk(el.props.children) }
}
function findByTestId(root: unknown, id: string): El | undefined {
  for (const el of walk(root)) if (el.props?.['data-testid'] === id) return el
  return undefined
}
function firstOfType(root: unknown, type: string): El | undefined {
  for (const el of walk(root)) if (el.type === type) return el
  return undefined
}
function textOf(node: unknown): string {
  let s = ''
  const rec = (n: unknown): void => {
    if (n == null) return
    if (typeof n === 'string' || typeof n === 'number') { s += String(n); return }
    if (Array.isArray(n)) { n.forEach(rec); return }
    if (typeof n === 'object' && (n as El).props) rec((n as El).props.children)
  }
  rec(node)
  return s
}

const ORIGIN = { x: 1000, y: 2000 }
const TARGET = { x: 3000, y: -4000 }
const route = (over: Partial<ActiveSpaceRoute> = {}): ActiveSpaceRoute => ({
  origin: ORIGIN, target: TARGET,
  departAt: '2026-01-01T00:00:00Z', arriveAt: '2999-01-01T00:00:00Z', ...over,
})

test('endpoints project through the fixed worldToViewBox transform (co-register with marker fixed-space)', () => {
  const tree = SpaceRoutePresentation({ route: route(), k: 1 })
  const line = firstOfType(tree, 'line')!
  const a = worldToViewBox(ORIGIN)
  const b = worldToViewBox(TARGET)
  expect(line.props.x1).toBeCloseTo(a.x, 9)
  expect(line.props.y1).toBeCloseTo(a.y, 9)
  expect(line.props.x2).toBeCloseTo(b.x, 9)
  expect(line.props.y2).toBeCloseTo(b.y, 9)
  const dest = findByTestId(tree, 'space-route-destination')!
  const ring = firstOfType(dest, 'circle')!
  expect(ring.props.cx).toBeCloseTo(b.x, 9)
  expect(ring.props.cy).toBeCloseTo(b.y, 9)
})

test('route group is pointer-inert', () => {
  const root = findByTestId(SpaceRoutePresentation({ route: route(), k: 1 }), 'space-route')!
  expect((root.props.style as Record<string, unknown>).pointerEvents).toBe('none')
})

test('committed destination is present and distinct from the S6C prospective-target marker', () => {
  const tree = SpaceRoutePresentation({ route: route(), k: 1 })
  expect(findByTestId(tree, 'space-route-destination')).toBeTruthy()
  expect(findByTestId(tree, 's6c-space-move-target')).toBeUndefined()
})

test('outbound-only presentation: forward arrow, never a return arrow', () => {
  const txt = textOf(SpaceRoutePresentation({ route: route(), k: 1 }))
  expect(txt).toContain('→')
  expect(txt).not.toContain('↩')
})

test('ETA shows a countdown for a future arrival', () => {
  const txt = textOf(SpaceRoutePresentation({ route: route({ arriveAt: '2999-01-01T00:00:00Z' }), k: 1 }))
  expect(txt).toMatch(/\d+\s*(m|s)/) // a real countdown, e.g. "59s" or "10m 00s"
  expect(txt.toLowerCase()).not.toContain('arrived')
})

test('elapsed/invalid arrival shows neutral "arriving…", never claims arrival', () => {
  const past = textOf(SpaceRoutePresentation({ route: route({ arriveAt: '2000-01-01T00:00:00Z' }), k: 1 }))
  expect(past).toContain('arriving')
  expect(past.toLowerCase()).not.toContain('arrived')
  const bad = textOf(SpaceRoutePresentation({ route: route({ arriveAt: 'not-a-date' }), k: 1 }))
  expect(bad).toContain('arriving')
})
