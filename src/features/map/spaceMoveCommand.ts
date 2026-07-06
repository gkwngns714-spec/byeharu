// OSN-3 S6C — PURE, framework-free logic for the empty-space coordinate command surface.
//
// No React/DOM/SVG/fetch here. This module owns: (1) the canonical integer-grid rounding that mirrors
// the S6A server wrapper, (2) the pointer-gesture classifier (tap vs pan, multi-touch never targets),
// (3) the player-facing error-code copy, (4) the exact RPC argument shape, and (5) a small stateful
// controller (target selection + idempotent submit lifecycle) that the React hook adapts.
//
// HARD BOUNDARY: S6C is empty-space ONLY. The controller calls a single injected `rpc(target, id)`
// (the S6A wrapper) and the RPC args carry ONLY a coordinate target + an idempotency key — NEVER a
// location id, a `target_kind`, or a ship/player id (the server derives the ship from auth.uid()).
// A coordinate equal to a location's coordinates is still an empty-space target; S6C never docks.

import { isWithinOpenSpaceBounds, type WorldCoord } from './openSpaceTransform'

// The ONE public command S6C is permitted to call (the S6A wrapper). Exported so the API layer and the
// tests reference the same literal — S6C must never reach any other movement endpoint.
export const SPACE_MOVE_RPC = 'command_main_ship_space_move' as const

// Exact RPC argument shape: coordinate target + idempotency key ONLY. No location id, no target_kind,
// no ship/player id. The presence of exactly these three keys is asserted by the tests.
export interface SpaceMoveRpcArgs {
  p_target_x: number
  p_target_y: number
  p_request_id: string
}
export function buildSpaceMoveRpcArgs(target: WorldCoord, requestId: string): SpaceMoveRpcArgs {
  return { p_target_x: target.x, p_target_y: target.y, p_request_id: requestId }
}

// Canonical integer world-unit grid, matching the S6A wrapper's `round(numeric)` = half-AWAY-from-zero
// (round(0.5)=1, round(-0.5)=-1, round(2.5)=3, round(-2.5)=-3). JS `Math.round` is half-toward-+Inf, so
// round the magnitude and re-apply the sign. UI preview only — the server re-canonicalizes and is
// authoritative; non-finite stays non-finite (callers reject via isWithinOpenSpaceBounds).
export function roundHalfAwayFromZero(n: number): number {
  if (!Number.isFinite(n)) return NaN
  return Math.sign(n) * Math.round(Math.abs(n))
}
export function canonicalizeWorldTarget(w: WorldCoord): WorldCoord {
  return { x: roundHalfAwayFromZero(w.x), y: roundHalfAwayFromZero(w.y) }
}

// ── Gesture ownership ────────────────────────────────────────────────────────────────────────────────
// A single, short, near-stationary pointer is a target tap; everything else stays map pan/zoom.
// Multi-touch is NEVER a target. Thresholds per the S6C charter (~8px travel, <400ms).
export const TAP_MAX_TRAVEL_PX = 8
export const TAP_MAX_DURATION_MS = 400

export interface PointerGestureSample {
  travelPx: number // total pointer displacement down→up, CSS px
  durationMs: number // down→up duration, ms
  maxPointers: number // peak simultaneous active pointers during the gesture
}
export type PointerGesture = 'tap' | 'pan'

export function classifyPointerGesture(s: PointerGestureSample): PointerGesture {
  if (s.maxPointers > 1) return 'pan' // multi-touch never selects a target
  if (!Number.isFinite(s.travelPx) || !Number.isFinite(s.durationMs)) return 'pan'
  if (s.travelPx > TAP_MAX_TRAVEL_PX) return 'pan'
  if (s.durationMs > TAP_MAX_DURATION_MS) return 'pan'
  return 'tap'
}

// ── Server result + player-facing error copy ──────────────────────────────────────────────────────────
export interface SpaceMoveSuccess {
  ok: true
  movement_id?: string
  main_ship_id?: string
  target_x: number
  target_y: number
  depart_at?: string
  arrive_at?: string
}
export interface SpaceMoveFailure {
  ok: false
  code: string
  message?: string
}
export type SpaceMoveResult = SpaceMoveSuccess | SpaceMoveFailure

// Stable friendly copy per S6A wrapper code (the server also returns a message; this guarantees a
// consistent string even if that changes or the call throws client-side). Wording is empty-space only —
// it never implies docking or arrival at a named location.
export const SPACE_MOVE_ERROR_COPY: Record<string, string> = {
  feature_disabled: 'Coordinate travel is not available yet.',
  not_authenticated: 'You must be signed in.',
  no_ship: 'You do not have a main ship.',
  invalid_target: 'That destination is not a valid coordinate.',
  out_of_bounds: 'That destination is outside the navigable region.',
  zero_distance: 'The ship is already at that point.',
  over_travel_cap: 'That destination is too far for a single jump.',
  request_conflict: 'This command was already used for a different destination.',
  must_stop_first: 'The ship is already travelling.',
  ship_destroyed: 'The ship must be repaired first.',
  busy_legacy: 'Finish the current expedition first.',
  network: 'Could not reach the server. Check your connection and retry.',
  unavailable: 'The ship is not available to move right now.',
}
export function spaceMoveErrorMessage(code: string | null | undefined, serverMessage?: string): string {
  if (code && SPACE_MOVE_ERROR_COPY[code]) return SPACE_MOVE_ERROR_COPY[code]
  if (serverMessage) return serverMessage
  return SPACE_MOVE_ERROR_COPY.unavailable
}

// ── Stateful controller (framework-free; the React hook adapts it via useSyncExternalStore) ───────────
export type SpaceMovePhase = 'idle' | 'previewing' | 'rejected' | 'submitting' | 'success' | 'error'

export interface SpaceMoveState {
  phase: SpaceMovePhase
  target: WorldCoord | null // canonical integer target (out-of-bounds only when phase==='rejected')
  targetWithinBounds: boolean
  requestId: string | null // current idempotency key (reused on in-error retry; consumed/cleared on success)
  serverTarget: WorldCoord | null // canonical target reconciled from a successful response
  errorCode: string | null
  errorMessage: string | null
}

export interface SpaceMoveControllerDeps {
  rpc: (target: WorldCoord, requestId: string) => Promise<SpaceMoveResult>
  genRequestId: () => string
  isEnabled: () => boolean // the mainship_space_movement_enabled flag (dark-gate)
}

export interface SpaceMoveController {
  getState: () => SpaceMoveState
  subscribe: (fn: () => void) => () => void
  selectTarget: (rawWorld: WorldCoord) => void
  submit: () => Promise<void>
  clear: () => void
}

const INITIAL: SpaceMoveState = {
  phase: 'idle',
  target: null,
  targetWithinBounds: false,
  requestId: null,
  serverTarget: null,
  errorCode: null,
  errorMessage: null,
}

const samePoint = (a: WorldCoord | null, b: WorldCoord | null): boolean =>
  !!a && !!b && a.x === b.x && a.y === b.y

export function createSpaceMoveController(deps: SpaceMoveControllerDeps): SpaceMoveController {
  let state: SpaceMoveState = { ...INITIAL }
  const subs = new Set<() => void>()
  const emit = (): void => subs.forEach((f) => f())
  const set = (patch: Partial<SpaceMoveState>): void => {
    state = { ...state, ...patch }
    emit()
  }

  function selectTarget(rawWorld: WorldCoord): void {
    const canonical = canonicalizeWorldTarget(rawWorld)
    const within = isWithinOpenSpaceBounds(canonical)
    // A CHANGED destination invalidates any prior idempotency key (new target ⇒ new request id). The
    // same destination keeps the key so a retry after an error reuses it.
    const changed = !samePoint(state.target, canonical)
    set({
      target: canonical,
      targetWithinBounds: within,
      phase: within ? 'previewing' : 'rejected',
      errorCode: within ? null : 'out_of_bounds',
      errorMessage: within ? null : spaceMoveErrorMessage('out_of_bounds'),
      requestId: changed ? null : state.requestId,
      serverTarget: changed ? null : state.serverTarget,
    })
  }

  async function submit(): Promise<void> {
    if (!deps.isEnabled()) return // flag dark: never send, never persist, never create movement state
    if (state.phase === 'submitting') return // block duplicate submit while a request is in flight
    if (!state.target || !state.targetWithinBounds) return // nothing valid to send
    // Reuse the existing key for a retry of the same destination; generate one otherwise.
    const requestId = state.requestId ?? deps.genRequestId()
    const target = state.target
    set({ phase: 'submitting', requestId, errorCode: null, errorMessage: null })
    try {
      const res = await deps.rpc(target, requestId)
      if (res.ok) {
        set({
          phase: 'success',
          serverTarget: { x: res.target_x, y: res.target_y }, // reconcile to the server's canonical target
          requestId: null, // consumed by this success — the next confirmed move sends a fresh command
          errorCode: null,
          errorMessage: null,
        })
      } else {
        // keep requestId + target so a retry reuses the same idempotency key
        set({ phase: 'error', errorCode: res.code, errorMessage: spaceMoveErrorMessage(res.code, res.message) })
      }
    } catch (e) {
      // uncertain outcome — keep requestId so the retry is idempotent
      set({
        phase: 'error',
        errorCode: 'network',
        errorMessage: spaceMoveErrorMessage('network', e instanceof Error ? e.message : undefined),
      })
    }
  }

  function clear(): void {
    state = { ...INITIAL }
    emit()
  }

  return {
    getState: () => state,
    subscribe: (fn) => {
      subs.add(fn)
      return () => {
        subs.delete(fn)
      }
    },
    selectTarget,
    submit,
    clear,
  }
}
