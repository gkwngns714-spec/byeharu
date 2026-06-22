import { test, expect } from '@playwright/test'
import { SpaceMoveTargetMarker, SpaceMoveControls, type SpaceMoveEligibility } from '../src/features/map/SpaceMoveTarget'
import { worldToViewBox, type WorldCoord } from '../src/features/map/openSpaceTransform'
import type { SpaceMovePhase } from '../src/features/map/spaceMoveCommand'

// OSN-3 S6C — pure proofs for the presentational pieces. The components are hook-free, so calling them
// directly returns their React element tree for inspection (no browser/page/DB). Run:
// `npm run verify:osn:s6c` (this spec runs alongside spaceMoveCommand.spec.ts).

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
function findByTestId(root: unknown, id: string): El | undefined {
  for (const el of walk(root)) if (el.props?.['data-testid'] === id) return el
  return undefined
}
function textOf(node: unknown): string {
  let s = ''
  const rec = (n: unknown): void => {
    if (n == null) return
    if (typeof n === 'string' || typeof n === 'number') {
      s += String(n)
      return
    }
    if (Array.isArray(n)) {
      n.forEach(rec)
      return
    }
    if (typeof n === 'object' && (n as El).props) rec((n as El).props.children)
  }
  rec(node)
  return s
}
function hasType(root: unknown, type: string): boolean {
  for (const el of walk(root)) if (el.type === type) return true
  return false
}

const noop = () => {}
function controls(over: Partial<Parameters<typeof SpaceMoveControls>[0]> = {}) {
  return SpaceMoveControls({
    enabled: true,
    eligibility: 'eligible' as SpaceMoveEligibility,
    phase: 'idle' as SpaceMovePhase,
    target: null,
    targetWithinBounds: false,
    serverTarget: null,
    errorMessage: null,
    onConfirm: noop,
    onClear: noop,
    ...over,
  }) as unknown
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

// ── Controls: flag-dark is clearly non-actionable (no confirm) ───────────────────────────────────────
test('controls (flag dark): shows an unavailable note, no confirm button', () => {
  const root = controls({ enabled: false })
  expect(findByTestId(root, 's6c-disabled')).toBeTruthy()
  expect(findByTestId(root, 's6c-confirm')).toBeUndefined()
  expect(textOf(root)).toMatch(/not available/i)
})

// ── Controls: eligible + no target → hint, no confirm ─────────────────────────────────────────────────
test('controls (eligible, idle): prompts to tap empty space, no confirm yet', () => {
  const root = controls({ phase: 'idle' })
  expect(findByTestId(root, 's6c-hint')).toBeTruthy()
  expect(findByTestId(root, 's6c-confirm')).toBeUndefined()
  expect(textOf(root)).toMatch(/empty space/i)
})

// ── Controls: previewing a valid target → confirm CTA + empty-space wording ──────────────────────────
test('controls (previewing): shows Move here + coordinate target with empty-space wording', () => {
  const root = controls({ phase: 'previewing', target: { x: 1200, y: -3400 }, targetWithinBounds: true })
  expect(findByTestId(root, 's6c-confirm')).toBeTruthy()
  expect(findByTestId(root, 's6c-clear')).toBeTruthy()
  const t = textOf(root)
  expect(t).toContain('1200, -3400') // the canonical coordinate readout
  expect(t).toMatch(/open-space coordinate/i)
  expect(t).toMatch(/not (to )?a location/i)
})

test('controls (submitting): confirm is disabled and shows progress', () => {
  const root = controls({ phase: 'submitting', target: { x: 1, y: 1 }, targetWithinBounds: true })
  const confirm = findByTestId(root, 's6c-confirm')
  expect(confirm).toBeTruthy()
  expect(confirm!.props.disabled).toBe(true)
  expect(textOf(root)).toMatch(/sending/i)
})

// ── Controls: success reconciles to the server coordinate; no confirm ────────────────────────────────
test('controls (success): shows the server-reconciled open-space coordinate', () => {
  const root = controls({ phase: 'success', serverTarget: { x: 4000, y: 5000 } })
  expect(findByTestId(root, 's6c-success')).toBeTruthy()
  const t = textOf(root)
  expect(t).toContain('4000, 5000')
  expect(t).toMatch(/open-space coordinate/i)
})

// ── Controls: error → retry + clear ───────────────────────────────────────────────────────────────────
test('controls (error): shows the message with Retry and Clear', () => {
  const root = controls({ phase: 'error', errorMessage: 'That destination is too far for a single jump.' })
  expect(findByTestId(root, 's6c-error')).toBeTruthy()
  expect(findByTestId(root, 's6c-retry')).toBeTruthy()
  expect(findByTestId(root, 's6c-clear')).toBeTruthy()
  expect(textOf(root)).toMatch(/too far/i)
})

// ── Controls: rejected (out-of-bounds selection) → visible rejection, no confirm ─────────────────────
test('controls (rejected): out-of-bounds selection is rejected visibly, not submittable', () => {
  const root = controls({ phase: 'rejected', target: { x: 99999, y: 0 }, targetWithinBounds: false })
  expect(findByTestId(root, 's6c-error')).toBeTruthy()
  expect(findByTestId(root, 's6c-confirm')).toBeUndefined()
  expect(textOf(root)).toMatch(/outside the navigable region/i)
})

// ── Controls: ineligible ship states are disabled with a reason, never a confirm ─────────────────────
test('controls (destroyed): disabled with a repair reason', () => {
  const root = controls({ eligibility: 'destroyed' })
  expect(findByTestId(root, 's6c-ineligible')).toBeTruthy()
  expect(findByTestId(root, 's6c-confirm')).toBeUndefined()
  expect(textOf(root)).toMatch(/repair/i)
})

test('controls (in_transit): disabled with a travelling reason', () => {
  const root = controls({ eligibility: 'in_transit' })
  expect(findByTestId(root, 's6c-ineligible')).toBeTruthy()
  expect(findByTestId(root, 's6c-confirm')).toBeUndefined()
  expect(textOf(root)).toMatch(/already travelling/i)
})

// ── Boundary guard: NO state ever implies docking / a location visit ─────────────────────────────────
test('no controls state ever uses docking / location-visit wording', () => {
  const states: Array<Partial<Parameters<typeof SpaceMoveControls>[0]>> = [
    { enabled: false },
    { phase: 'idle' },
    { phase: 'previewing', target: { x: 1, y: 2 }, targetWithinBounds: true },
    { phase: 'submitting', target: { x: 1, y: 2 }, targetWithinBounds: true },
    { phase: 'success', serverTarget: { x: 1, y: 2 } },
    { phase: 'error', errorMessage: 'x' },
    { phase: 'rejected', target: { x: 99999, y: 0 }, targetWithinBounds: false },
    { eligibility: 'destroyed' as SpaceMoveEligibility },
    { eligibility: 'in_transit' as SpaceMoveEligibility },
  ]
  for (const st of states) {
    const t = textOf(controls(st)).toLowerCase()
    expect(t).not.toContain('dock')
    expect(t).not.toContain('visit')
    expect(t).not.toContain('arrive at')
  }
})
