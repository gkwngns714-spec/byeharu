import { test, expect } from '@playwright/test'
import {
  SPACE_STOP_RPC,
  STOP_TRANSIT_RPC,
  buildSpaceStopRpcArgs,
  isActiveCoordinateTransit,
  isActiveLegacyOutboundTransit,
  parseStopTransitResult,
  spaceStopErrorMessage,
  createSpaceStopController,
  type SpaceStopResult,
} from '../src/features/map/spaceStopCommand'

// OSN-4 — pure proofs for the Stop-mid-travel client surface. No browser/page/DB.

// ── Stop arg BUILDER shape: idempotency key ONLY (no coordinates). TRADE-FLEET-0C §2.5 adds the explicit
//    p_main_ship_id at the wrapper (commandMainShipSpaceStop), NOT in this pure builder, so it stays intact. ─
test('OSN-4: the Stop arg builder carries only the request id (no coordinates)', () => {
  expect(SPACE_STOP_RPC).toBe('command_main_ship_space_stop')
  const args = buildSpaceStopRpcArgs('req-1')
  expect(Object.keys(args).sort()).toEqual(['p_request_id'])
  expect(args.p_request_id).toBe('req-1')
})

// ── Constraint 1: the Stop CTA visibility predicate is flag-INDEPENDENT and requires a real active
//    coordinate transit (in_transit + moving + target_kind='space'). ─────────────────────────────────
test('OSN-4: isActiveCoordinateTransit is flag-independent and requires a real coordinate transit', () => {
  // A real active coordinate transit → CTA eligible (note: NO flag is consulted here at all).
  expect(isActiveCoordinateTransit({ spatialState: 'in_transit', spaceMovementStatus: 'moving', spaceMovementTargetKind: 'space' })).toBe(true)
  // Not in transit / no movement / wrong target kind → not eligible.
  expect(isActiveCoordinateTransit({ spatialState: 'in_space', spaceMovementStatus: 'moving', spaceMovementTargetKind: 'space' })).toBe(false)
  expect(isActiveCoordinateTransit({ spatialState: 'in_transit', spaceMovementStatus: null, spaceMovementTargetKind: 'space' })).toBe(false)
  expect(isActiveCoordinateTransit({ spatialState: 'in_transit', spaceMovementStatus: 'moving', spaceMovementTargetKind: 'location' })).toBe(false)
  expect(isActiveCoordinateTransit({ spatialState: undefined, spaceMovementStatus: undefined, spaceMovementTargetKind: undefined })).toBe(false)
})

// ── Constraint 1 (the mandatory case): a move exists → flag disabled → Stop CTA remains available while
//    ALL initiation controls (target-selection / new-move, gated on the flag) are absent. We model the two
//    gates exactly as GalaxyMap does: initiation = flagEnabled; Stop = isActiveCoordinateTransit. ───────
test('OSN-4: move exists + flag disabled → Stop CTA available, initiation controls absent', () => {
  const flagEnabled = false // emergency disable AFTER the move began
  const ship = { spatialState: 'in_transit', spaceMovementStatus: 'moving', spaceMovementTargetKind: 'space' }
  const stopCtaVisible = isActiveCoordinateTransit(ship) // flag-INDEPENDENT
  const initiationVisible = flagEnabled // GalaxyMap gates targeting/new-move on sm.enabled (the flag)
  expect(stopCtaVisible).toBe(true) // in-flight safety: Stop survives the disable
  expect(initiationVisible).toBe(false) // no target selection / new-move / general OSN command UI
})

// ── Dark today: with no active coordinate movement (the only possible state while the flag is false),
//    the CTA predicate is false → fully dark in production. ────────────────────────────────────────────
test('OSN-4: no active coordinate movement → Stop CTA dark', () => {
  expect(isActiveCoordinateTransit({ spatialState: 'home', spaceMovementStatus: undefined, spaceMovementTargetKind: undefined })).toBe(false)
  expect(isActiveCoordinateTransit({ spatialState: 'at_location', spaceMovementStatus: undefined, spaceMovementTargetKind: undefined })).toBe(false)
})

// ── UX-CLEANUP item 3: LEGACY transit stop (halt → return home; command_main_ship_stop_transit 0149) ──
test('item 3: the legacy stop RPC name is pinned to the deployed function', () => {
  expect(STOP_TRANSIT_RPC).toBe('command_main_ship_stop_transit')
})

test('item 3: isActiveLegacyOutboundTransit — moving + outbound mission only', () => {
  // The stoppable case: the main-ship fleet is moving on an outbound (non-return) mission.
  expect(isActiveLegacyOutboundTransit({ fleetStatus: 'moving', missionType: 'rally' })).toBe(true)
  // A return leg has nothing to stop (it is already heading home).
  expect(isActiveLegacyOutboundTransit({ fleetStatus: 'moving', missionType: 'return_home' })).toBe(false)
  // Not moving / no movement row / unknown → dark.
  expect(isActiveLegacyOutboundTransit({ fleetStatus: 'present', missionType: 'rally' })).toBe(false)
  expect(isActiveLegacyOutboundTransit({ fleetStatus: 'returning', missionType: 'return_home' })).toBe(false)
  expect(isActiveLegacyOutboundTransit({ fleetStatus: 'moving', missionType: null })).toBe(false)
  expect(isActiveLegacyOutboundTransit({ fleetStatus: undefined, missionType: undefined })).toBe(false)
})

test('item 3: parseStopTransitResult maps the server envelope onto the shared stop contract', () => {
  // A successful halt → outcome 'stopped' (the shared CTA shows the stopped message).
  expect(parseStopTransitResult({ ok: true, stopped: true, movement_id: 'm1' })).toEqual({ ok: true, outcome: 'stopped' })
  // Every idempotent no-op (cron settled first / duplicate / due) → outcome 'arrived'.
  for (const reason of ['already_settled', 'already_returning', 'arrived']) {
    expect(parseStopTransitResult({ ok: true, stopped: false, reason })).toEqual({ ok: true, outcome: 'arrived' })
  }
  // Rejections pass through code + server message; a missing message falls back to client copy.
  expect(parseStopTransitResult({ ok: false, code: 'feature_disabled', message: 'Main-ship movement is not available yet.' }))
    .toEqual({ ok: false, code: 'feature_disabled', message: 'Main-ship movement is not available yet.' })
  expect(parseStopTransitResult({ ok: false, code: 'not_authenticated' }))
    .toEqual({ ok: false, code: 'not_authenticated', message: spaceStopErrorMessage('not_authenticated') })
  // Malformed input fails closed to a safe error, never a fabricated success.
  for (const bad of [null, 42, [], {}, { ok: 'yes' }, { ok: false }]) {
    const res = parseStopTransitResult(bad)
    expect(res.ok).toBe(false)
    if (!res.ok) expect(res.code).toBe('unavailable')
  }
})

// ── Controller: idempotent submit (reuses the request id on retry), success + error transitions ───────
test('OSN-4: controller submit is idempotent (one request id reused across retries)', async () => {
  const ids: string[] = []
  let call = 0
  const rpc = async (requestId: string): Promise<SpaceStopResult> => {
    ids.push(requestId)
    call += 1
    if (call === 1) return { ok: false, code: 'unavailable', message: 'transient' } // first attempt fails
    return { ok: true, outcome: 'stopped', movement_id: 'm1', stop_x: 5, stop_y: -5 }
  }
  let n = 0
  const c = createSpaceStopController({ rpc, genRequestId: () => `req-${++n}` })
  await c.submit()
  expect(c.getState().phase).toBe('error')
  expect(c.getState().requestId).toBe('req-1') // in-error retry keeps its key
  await c.submit() // retry
  expect(c.getState().phase).toBe('done')
  expect(c.getState().outcome).toBe('stopped')
  // SAME request id reused for the retry (idempotency key stable across retries of the same Stop).
  expect(ids).toEqual(['req-1', 'req-1'])
  // The success CONSUMES the key: a consumed key kept here would make the next Stop (a new transit)
  // replay this Stop's server receipt — the "second Stop no-ops" live bug.
  expect(c.getState().requestId).toBe(null)
})

// ── The regression: a second Stop on a NEW transit must be a FRESH idempotent command, never a replay
//    of the consumed key (the server replays the receipt for a (ship, request_id) pair verbatim). ─────
test('OSN-4: after a successful stop the next submit sends a DIFFERENT request id', async () => {
  const ids: string[] = []
  const rpc = async (requestId: string): Promise<SpaceStopResult> => {
    ids.push(requestId)
    return { ok: true, outcome: 'stopped', movement_id: `m${ids.length}` }
  }
  let n = 0
  const gen = () => `req-${++n}`
  const c = createSpaceStopController({ rpc, genRequestId: gen })
  await c.submit() // stop #1 (trip 1)
  expect(c.getState().phase).toBe('done')
  await c.submit() // stop #2 (trip 2 — the controller instance survives across transits)
  expect(c.getState().phase).toBe('done')
  // genRequestId ran again: the second Stop is a distinct command, not a receipt replay.
  expect(n).toBe(2)
  expect(ids).toEqual(['req-1', 'req-2'])
  expect(ids[0]).not.toBe(ids[1])
})

// ── Controller maps an 'arrived' outcome (due-at-stop boundary) and a feature_disabled rejection ──────
test('OSN-4: controller surfaces arrived outcome and rejection codes', async () => {
  const arrived = createSpaceStopController({
    rpc: async () => ({ ok: true, outcome: 'arrived', movement_id: 'm', target_x: 10, target_y: 10 }),
    genRequestId: () => 'r',
  })
  await arrived.submit()
  expect(arrived.getState().outcome).toBe('arrived')

  const disabled = createSpaceStopController({
    rpc: async () => ({ ok: false, code: 'feature_disabled', message: spaceStopErrorMessage('feature_disabled') }),
    genRequestId: () => 'r',
  })
  await disabled.submit()
  expect(disabled.getState().phase).toBe('error')
  expect(disabled.getState().errorCode).toBe('feature_disabled')
})
