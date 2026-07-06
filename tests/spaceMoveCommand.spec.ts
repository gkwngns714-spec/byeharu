import { test, expect } from '@playwright/test'
import {
  SPACE_MOVE_RPC,
  buildSpaceMoveRpcArgs,
  roundHalfAwayFromZero,
  canonicalizeWorldTarget,
  classifyPointerGesture,
  spaceMoveErrorMessage,
  createSpaceMoveController,
  TAP_MAX_TRAVEL_PX,
  TAP_MAX_DURATION_MS,
  type SpaceMoveResult,
  type SpaceMoveControllerDeps,
} from '../src/features/map/spaceMoveCommand'
import type { WorldCoord } from '../src/features/map/openSpaceTransform'

// OSN-3 S6C — pure proofs for the empty-space coordinate command logic + controller. No browser/page,
// no DB, no network — the controller's `rpc` is injected, so these tests PROVE the command boundary
// (only the S6A RPC name, coords + request-id payload only, idempotency lifecycle) without any DB.
// Run: `npm run verify:osn:s6c`.

// ── Canonical integer-grid rounding (must mirror the S6A server: round = half-AWAY-from-zero) ─────────
test('roundHalfAwayFromZero matches Postgres round(numeric)', () => {
  expect(roundHalfAwayFromZero(0.5)).toBe(1)
  expect(roundHalfAwayFromZero(-0.5)).toBe(-1)
  expect(roundHalfAwayFromZero(2.5)).toBe(3)
  expect(roundHalfAwayFromZero(-2.5)).toBe(-3)
  expect(roundHalfAwayFromZero(2.4)).toBe(2)
  expect(roundHalfAwayFromZero(-2.6)).toBe(-3)
  expect(roundHalfAwayFromZero(0)).toBe(0)
  expect(Number.isNaN(roundHalfAwayFromZero(NaN))).toBe(true)
  expect(Number.isNaN(roundHalfAwayFromZero(Infinity))).toBe(true)
})

test('canonicalizeWorldTarget rounds both axes to the integer grid', () => {
  expect(canonicalizeWorldTarget({ x: 1234.5, y: -6789.5 })).toEqual({ x: 1235, y: -6790 })
  expect(canonicalizeWorldTarget({ x: -0.5, y: 0.49 })).toEqual({ x: -1, y: 0 })
})

// ── RPC boundary: name + exact argument shape (NO location id, NO target_kind, NO ship/player id) ─────
test('SPACE_MOVE_RPC is the S6A wrapper and the only command name', () => {
  expect(SPACE_MOVE_RPC).toBe('command_main_ship_space_move')
})

test('buildSpaceMoveRpcArgs carries ONLY the coordinate target + request id', () => {
  const args = buildSpaceMoveRpcArgs({ x: 100, y: -200 }, 'req-abc')
  expect(args).toEqual({ p_target_x: 100, p_target_y: -200, p_request_id: 'req-abc' })
  // exactly three keys — no p_location / p_location_id / p_target_kind / p_ship / p_player can sneak in
  expect(Object.keys(args).sort()).toEqual(['p_request_id', 'p_target_x', 'p_target_y'])
  const keys = Object.keys(args)
  expect(keys.some((k) => /location/i.test(k))).toBe(false)
  expect(keys.some((k) => /target_kind/i.test(k))).toBe(false)
  expect(keys.some((k) => /ship|player/i.test(k))).toBe(false)
})

// ── Gesture ownership: tap vs pan; multi-touch never targets ──────────────────────────────────────────
test('classifyPointerGesture: short stationary single tap → tap', () => {
  expect(classifyPointerGesture({ travelPx: 0, durationMs: 50, maxPointers: 1 })).toBe('tap')
  expect(classifyPointerGesture({ travelPx: TAP_MAX_TRAVEL_PX, durationMs: TAP_MAX_DURATION_MS, maxPointers: 1 })).toBe('tap')
})

test('classifyPointerGesture: drag beyond travel threshold → pan', () => {
  expect(classifyPointerGesture({ travelPx: TAP_MAX_TRAVEL_PX + 0.01, durationMs: 50, maxPointers: 1 })).toBe('pan')
})

test('classifyPointerGesture: long press beyond duration threshold → pan', () => {
  expect(classifyPointerGesture({ travelPx: 1, durationMs: TAP_MAX_DURATION_MS + 1, maxPointers: 1 })).toBe('pan')
})

test('classifyPointerGesture: multi-touch is NEVER a tap', () => {
  expect(classifyPointerGesture({ travelPx: 0, durationMs: 10, maxPointers: 2 })).toBe('pan')
})

test('classifyPointerGesture: non-finite samples → pan (no accidental selection)', () => {
  expect(classifyPointerGesture({ travelPx: NaN, durationMs: 10, maxPointers: 1 })).toBe('pan')
  expect(classifyPointerGesture({ travelPx: 1, durationMs: NaN, maxPointers: 1 })).toBe('pan')
})

// ── Error copy mapping ────────────────────────────────────────────────────────────────────────────────
test('spaceMoveErrorMessage maps known codes and falls back safely', () => {
  expect(spaceMoveErrorMessage('out_of_bounds')).toMatch(/navigable region/i)
  expect(spaceMoveErrorMessage('must_stop_first')).toMatch(/already travelling/i)
  expect(spaceMoveErrorMessage('ship_destroyed')).toMatch(/repaired/i)
  expect(spaceMoveErrorMessage('feature_disabled')).toMatch(/not available/i)
  expect(spaceMoveErrorMessage('weird_unknown', 'server said so')).toBe('server said so')
  expect(spaceMoveErrorMessage(null)).toMatch(/not available to move/i)
})

// ── Controller helpers ────────────────────────────────────────────────────────────────────────────────
function makeIds() {
  let n = 0
  const ids: string[] = []
  const gen = () => {
    const id = `req-${++n}`
    ids.push(id)
    return id
  }
  return { gen, ids, count: () => n }
}

function makeRpc(handler?: (target: WorldCoord, requestId: string) => SpaceMoveResult) {
  const calls: Array<{ target: WorldCoord; requestId: string }> = []
  const rpc: SpaceMoveControllerDeps['rpc'] = async (target, requestId) => {
    calls.push({ target, requestId })
    return handler ? handler(target, requestId) : { ok: true, target_x: target.x, target_y: target.y }
  }
  return { rpc, calls }
}

// ── Flag-dark: submit sends NO rpc ────────────────────────────────────────────────────────────────────
test('flag-false: submit sends no RPC and creates no movement state', async () => {
  const { rpc, calls } = makeRpc()
  const { gen } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => false })
  c.selectTarget({ x: 100, y: 100 })
  await c.submit()
  expect(calls.length).toBe(0) // never invoked the RPC while dark
  expect(c.getState().phase).toBe('previewing') // unchanged by the no-op submit
})

// ── Selection: within-bounds preview vs out-of-bounds rejection (no silent clamp) ────────────────────
test('selectTarget: within bounds → previewing (canonical); out of bounds → rejected', () => {
  const { rpc } = makeRpc()
  const { gen } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })

  c.selectTarget({ x: 12.5, y: -33.5 })
  let s = c.getState()
  expect(s.phase).toBe('previewing')
  expect(s.targetWithinBounds).toBe(true)
  expect(s.target).toEqual({ x: 13, y: -34 }) // canonical, NOT clamped

  c.selectTarget({ x: 10001, y: 0 })
  s = c.getState()
  expect(s.phase).toBe('rejected')
  expect(s.targetWithinBounds).toBe(false)
  expect(s.target).toEqual({ x: 10001, y: 0 }) // preserved (no clamp to 10000)
  expect(s.errorCode).toBe('out_of_bounds')

  // out-of-bounds is not submittable
  // (submit early-returns because targetWithinBounds is false — proven below)
})

test('submit does nothing for an out-of-bounds selection', async () => {
  const { rpc, calls } = makeRpc()
  const { gen } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })
  c.selectTarget({ x: 99999, y: 0 })
  await c.submit()
  expect(calls.length).toBe(0)
})

// ── Confirm: calls ONLY the injected rpc with (target, requestId); success reconciles serverTarget ────
test('confirm calls the rpc once with the canonical target + a request id; success reconciles', async () => {
  const { rpc, calls } = makeRpc((t) => ({ ok: true, target_x: t.x, target_y: t.y, movement_id: 'm1' }))
  const { gen, count } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })
  c.selectTarget({ x: 250.5, y: -250.5 })
  await c.submit()
  expect(calls.length).toBe(1)
  expect(calls[0].target).toEqual({ x: 251, y: -251 })
  expect(calls[0].requestId).toBe('req-1')
  expect(count()).toBe(1)
  const s = c.getState()
  expect(s.phase).toBe('success')
  expect(s.serverTarget).toEqual({ x: 251, y: -251 }) // reconciled from the server response
  // The success CONSUMES the key: keeping it would make the next confirmed move replay this
  // command's server receipt (no new movement — a silent no-op).
  expect(s.requestId).toBe(null)
})

// ── A SUCCESS consumes the request id: the next confirmed move is a fresh command, never a replay ─────
test('after a successful move the next submit sends a DIFFERENT request id', async () => {
  const { rpc, calls } = makeRpc((t) => ({ ok: true, target_x: t.x, target_y: t.y }))
  const { gen, count } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })
  c.selectTarget({ x: 100, y: 100 })
  await c.submit() // move #1 succeeds
  expect(c.getState().phase).toBe('success')
  c.selectTarget({ x: 100, y: 100 }) // SAME destination again (e.g. return to a held point later)
  await c.submit() // move #2 — must be a distinct idempotent command
  expect(calls.length).toBe(2)
  expect(calls[0].requestId).toBe('req-1')
  expect(calls[1].requestId).toBe('req-2')
  expect(count()).toBe(2)
})

// ── Duplicate confirm blocked while a request is in flight ────────────────────────────────────────────
test('duplicate confirm is blocked while pending → exactly one RPC', async () => {
  let resolve: ((r: SpaceMoveResult) => void) | null = null
  const calls: Array<{ requestId: string }> = []
  const rpc: SpaceMoveControllerDeps['rpc'] = (_t, requestId) => {
    calls.push({ requestId })
    return new Promise<SpaceMoveResult>((res) => {
      resolve = res
    })
  }
  const { gen } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })
  c.selectTarget({ x: 10, y: 10 })
  const p1 = c.submit() // enters 'submitting' synchronously, then awaits
  const p2 = c.submit() // must be a no-op while pending
  expect(c.getState().phase).toBe('submitting')
  resolve!({ ok: true, target_x: 10, target_y: 10 })
  await Promise.all([p1, p2])
  expect(calls.length).toBe(1)
})

// ── Retry reuses the SAME request id; a changed target gets a NEW one ─────────────────────────────────
test('retry of the same destination reuses the request id', async () => {
  const { rpc, calls } = makeRpc(() => ({ ok: false, code: 'over_travel_cap' }))
  const { gen, count } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })
  c.selectTarget({ x: 5000, y: 5000 })
  await c.submit() // fails
  expect(c.getState().phase).toBe('error')
  await c.submit() // retry — same target, no re-selection
  expect(calls.length).toBe(2)
  expect(calls[0].requestId).toBe('req-1')
  expect(calls[1].requestId).toBe('req-1') // reused
  expect(count()).toBe(1) // only one id ever generated
})

test('changing the selected target generates a NEW request id', async () => {
  const { rpc, calls } = makeRpc(() => ({ ok: false, code: 'over_travel_cap' }))
  const { gen, count } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })
  c.selectTarget({ x: 100, y: 100 })
  await c.submit()
  c.selectTarget({ x: 200, y: 200 }) // different destination → invalidates the prior id
  expect(c.getState().requestId).toBeNull()
  await c.submit()
  expect(calls[0].requestId).toBe('req-1')
  expect(calls[1].requestId).toBe('req-2')
  expect(count()).toBe(2)
})

test('re-selecting the SAME destination keeps the request id (so a re-tap can retry)', async () => {
  const { rpc, calls } = makeRpc(() => ({ ok: false, code: 'over_travel_cap' }))
  const { gen } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })
  c.selectTarget({ x: 100.4, y: 100.4 }) // canonical (100,100)
  await c.submit()
  c.selectTarget({ x: 99.6, y: 99.6 }) // also canonical (100,100) — same destination
  await c.submit()
  expect(calls[0].requestId).toBe('req-1')
  expect(calls[1].requestId).toBe('req-1')
})

// ── Error mapping + thrown rpc → network ──────────────────────────────────────────────────────────────
test('server failure maps the code to a friendly message', async () => {
  const { rpc } = makeRpc(() => ({ ok: false, code: 'must_stop_first' }))
  const { gen } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })
  c.selectTarget({ x: 1, y: 1 })
  await c.submit()
  const s = c.getState()
  expect(s.phase).toBe('error')
  expect(s.errorCode).toBe('must_stop_first')
  expect(s.errorMessage).toMatch(/already travelling/i)
})

test('a thrown rpc resolves to a network error (request id preserved for idempotent retry)', async () => {
  const calls: string[] = []
  const rpc: SpaceMoveControllerDeps['rpc'] = async (_t, requestId) => {
    calls.push(requestId)
    throw new Error('boom')
  }
  const { gen } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })
  c.selectTarget({ x: 1, y: 1 })
  await c.submit()
  expect(c.getState().phase).toBe('error')
  expect(c.getState().errorCode).toBe('network')
  expect(c.getState().requestId).toBe('req-1')
  await c.submit() // retry reuses the same id
  expect(calls).toEqual(['req-1', 'req-1'])
})

// ── clear resets the surface ──────────────────────────────────────────────────────────────────────────
test('clear resets to idle with no target or request id', () => {
  const { rpc } = makeRpc()
  const { gen } = makeIds()
  const c = createSpaceMoveController({ rpc, genRequestId: gen, isEnabled: () => true })
  c.selectTarget({ x: 1, y: 1 })
  c.clear()
  expect(c.getState()).toMatchObject({ phase: 'idle', target: null, requestId: null, serverTarget: null })
})
