import { test, expect } from '@playwright/test'
import { worldToViewBox } from '../src/features/map/openSpaceTransform'
import { DevFixedSpacePreview } from '../src/features/map/DevFixedSpacePreview'

// OSN-3 S6B3 — pure proof of the development-only fixed-space preview. No browser/page/DB/network. The
// component is hook-free, so calling it directly returns its React element tree for inspection. Run:
// `npm run verify:osn:s6b3`. (Production ABSENCE of the preview is proven separately by building and
// grepping dist/ for the `s6b3-dev-preview` sentinel — see .github/workflows/verify-s6b3.yml.)

const near = (a: number, b: number, tol = 1e-6) => expect(Math.abs(a - b)).toBeLessThanOrEqual(tol)

test('S6B3: the preview fixture maps to the expected fixed-space viewBox position (900,900)', () => {
  const vb = worldToViewBox({ x: 8000, y: -8000 })
  near(vb.x, 900)
  near(vb.y, 900)
})

type El = { type: unknown; props: Record<string, unknown> }

test('S6B3: preview renders the sentinel, pointer-transparent + aria-hidden, at the fixed-space position', () => {
  const el = DevFixedSpacePreview({ k: 1 }) as unknown as El
  // a single <g> group carrying the unique sentinel + accessibility + pointer behavior
  expect(el.type).toBe('g')
  expect(el.props['data-testid']).toBe('s6b3-dev-preview')
  expect(el.props['aria-hidden']).toBe('true')
  expect((el.props.style as { pointerEvents?: string }).pointerEvents).toBe('none')

  const kids = ((Array.isArray(el.props.children) ? el.props.children : [el.props.children]) as unknown[]).flat() as El[]
  // hollow ring at the fixed-space position (cx/cy === worldToViewBox(fixture) by construction)
  const expected = worldToViewBox({ x: 8000, y: -8000 })
  const circle = kids.find((c) => c && c.type === 'circle')
  expect(circle).toBeTruthy()
  expect(circle!.props.cx).toBe(expected.x)
  expect(circle!.props.cy).toBe(expected.y)
  expect(circle!.props.fill).toBe('none') // hollow — distinct from filled location dots / ship chevron
  // no text/label child → no copy implying a relationship to named locations
  expect(kids.some((c) => c && c.type === 'text')).toBe(false)
})
