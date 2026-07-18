import { test, expect } from '@playwright/test'
import { SpaceMoveTargetMarker } from '../src/features/map/SpaceMoveTarget'
import { worldToViewBox, type WorldCoord } from '../src/features/map/openSpaceTransform'

// OSN-3 S6C origin, 4A-POST trimmed — pure proofs for the LIVE coordinate target marker (reused by
// the fleet coordinate-go under its own testid). The per-ship SpaceMoveControls panel was deleted
// with the per-ship movement client. The component is hook-free, so calling it directly returns its
// React element tree for inspection (no browser/page/DB). Run: `npm run verify:osn:s6c`.

type El = { type: unknown; props: Record<string, unknown> }

function* walk(node: unknown): Generator<El> {
  if (node == null || typeof node !== 'object') return
  if (Array.isArray(node)) {
    for (const n of node) yield* walk(n)
    return
  }
  const el = node as El
  if (el.props) {
    yield el
    if ('children' in el.props) yield* walk(el.props.children)
  }
}
function hasType(root: unknown, type: string): boolean {
  for (const el of walk(root)) if (el.type === type) return true
  return false
}

// ── Marker: fixed-domain projection, pointer-transparent, no place-name text ─────────────────────────
test('SpaceMoveTargetMarker projects through the fixed transform and is pointer-transparent', () => {
  const target: WorldCoord = { x: 0, y: 0 }
  const el = SpaceMoveTargetMarker({ target, k: 1 }) as unknown as El
  expect(el.type).toBe('g')
  expect(el.props['data-testid']).toBe('s6c-space-move-target')
  expect((el.props.style as { pointerEvents?: string }).pointerEvents).toBe('none')

  const expected = worldToViewBox(target) // (500,500)
  let circle: El | undefined
  for (const c of walk(el)) if (c.type === 'circle') circle = c
  expect(circle).toBeTruthy()
  expect(circle!.props.cx).toBe(expected.x)
  expect(circle!.props.cy).toBe(expected.y)
  expect(circle!.props.fill).toBe('none') // hollow — not a filled location dot / ship chevron
  // no <text> → no copy that could be read as a place/location name
  expect(hasType(el, 'text')).toBe(false)
})

test('SpaceMoveTargetMarker honors a distinct fixed-space point (not the origin)', () => {
  const target: WorldCoord = { x: 8000, y: -8000 }
  const el = SpaceMoveTargetMarker({ target, k: 2 }) as unknown as El
  const expected = worldToViewBox(target) // (900,900)
  let circle: El | undefined
  for (const c of walk(el)) if (c.type === 'circle') circle = c
  expect(circle!.props.cx).toBe(expected.x)
  expect(circle!.props.cy).toBe(expected.y)
})

test('SpaceMoveTargetMarker overrides testId + stroke for the fleet-go reuse', () => {
  const el = SpaceMoveTargetMarker({
    target: { x: 100, y: 100 },
    k: 1,
    testId: 'fleet-go-target',
    stroke: 'var(--color-accent)',
  }) as unknown as El
  expect(el.props['data-testid']).toBe('fleet-go-target')
  let circle: El | undefined
  for (const c of walk(el)) if (c.type === 'circle') circle = c
  expect(circle!.props.stroke).toBe('var(--color-accent)')
})
