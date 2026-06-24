// OSN-4 — PURE, framework-free logic for the Stop-mid-travel command surface.
//
// No React/DOM/SVG/fetch here. This module owns: (1) the visibility predicate that decides when the
// narrow Stop safety CTA may render, (2) the exact RPC argument shape (idempotency key ONLY — no
// coordinates; the server interpolates the current point), (3) player-facing error copy, and (4) a small
// stateful controller (idempotent submit lifecycle) the React hook adapts.
//
// IN-FLIGHT SAFETY (Constraint 1): the Stop CTA is the narrow exception to the initiation flag. It may
// render ONLY when the ship is in a REAL active coordinate transit, and it does so INDEPENDENTLY of
// `mainship_space_movement_enabled` so an emergency flag disable can never strand an in-flight ship.
// Target selection / new-move / general OSN command UI stay flag-gated elsewhere. The server remains
// authoritative — a stale client Stop safely rejects (feature_disabled / not_in_transit) without mutation.

export const SPACE_STOP_RPC = 'command_main_ship_space_stop' as const

// Exact RPC args: the idempotency key ONLY. No coordinate/ship/player id — the server derives the ship
// from auth.uid() and computes the stop point itself.
export interface SpaceStopRpcArgs {
  p_request_id: string
}
export function buildSpaceStopRpcArgs(requestId: string): SpaceStopRpcArgs {
  return { p_request_id: requestId }
}

// The server's narrow Stop result contract (mirrors command_main_ship_space_stop).
export type SpaceStopResult =
  | {
      ok: true
      outcome: 'stopped' | 'arrived'
      movement_id?: string
      stop_x?: number
      stop_y?: number
      target_x?: number
      target_y?: number
    }
  | { ok: false; code: string; message: string }

// ── Visibility predicate (Constraint 1; flag-INDEPENDENT) ────────────────────────────────────────────
// The Stop CTA renders iff the ship is in a real active open-space coordinate transit: ship
// spatial_state='in_transit' AND an active coordinate movement that is moving AND target_kind='space'.
// This NEVER reads the feature flag — that is the whole point of the in-flight safety exception. Today
// the condition is unreachable (no coordinate moves can exist while the flag is false), so the CTA is
// dark in production; it becomes reachable only once a real coordinate transit exists.
export function isActiveCoordinateTransit(input: {
  spatialState: string | null | undefined
  spaceMovementStatus: string | null | undefined
  spaceMovementTargetKind: string | null | undefined
}): boolean {
  return (
    input.spatialState === 'in_transit' &&
    input.spaceMovementStatus === 'moving' &&
    input.spaceMovementTargetKind === 'space'
  )
}

// Player-facing copy for the narrow set of codes the wrapper can return.
const STOP_ERROR_COPY: Record<string, string> = {
  feature_disabled: 'Coordinate movement is not available yet.',
  not_in_transit: 'The ship is not currently travelling.',
  not_stoppable: 'The ship cannot be stopped right now.',
  request_conflict: 'This command was already used.',
  invalid_request: 'Invalid command request.',
  ship_destroyed: 'The ship must be repaired first.',
  no_ship: 'You do not have a main ship.',
  not_authenticated: 'You must be signed in.',
  unavailable: 'The ship cannot be stopped right now.',
}
export function spaceStopErrorMessage(code: string): string {
  return STOP_ERROR_COPY[code] ?? STOP_ERROR_COPY.unavailable
}

// ── Stateful controller (idempotent submit lifecycle) ────────────────────────────────────────────────
export type SpaceStopPhase = 'idle' | 'submitting' | 'done' | 'error'
export interface SpaceStopState {
  phase: SpaceStopPhase
  requestId: string | null
  outcome: 'stopped' | 'arrived' | null
  errorCode: string | null
  errorMessage: string | null
}
const INITIAL: SpaceStopState = { phase: 'idle', requestId: null, outcome: null, errorCode: null, errorMessage: null }

export interface SpaceStopControllerDeps {
  rpc: (requestId: string) => Promise<SpaceStopResult>
  genRequestId: () => string
}
export interface SpaceStopController {
  getState: () => SpaceStopState
  subscribe: (fn: () => void) => () => void
  submit: () => Promise<void>
  reset: () => void
}

export function createSpaceStopController(deps: SpaceStopControllerDeps): SpaceStopController {
  let state: SpaceStopState = { ...INITIAL }
  const subs = new Set<() => void>()
  const emit = (): void => subs.forEach((f) => f())
  const set = (patch: Partial<SpaceStopState>): void => {
    state = { ...state, ...patch }
    emit()
  }

  async function submit(): Promise<void> {
    if (state.phase === 'submitting') return // block duplicate submit while a request is in flight
    // Reuse the existing key for a retry (idempotent); generate one otherwise. Stop carries no target, so
    // there is no payload to invalidate the key — a retry of the same Stop reuses the same request id.
    const requestId = state.requestId ?? deps.genRequestId()
    set({ phase: 'submitting', requestId, errorCode: null, errorMessage: null })
    try {
      const res = await deps.rpc(requestId)
      if (res.ok) {
        set({ phase: 'done', outcome: res.outcome, errorCode: null, errorMessage: null })
      } else {
        set({ phase: 'error', errorCode: res.code, errorMessage: res.message ?? spaceStopErrorMessage(res.code) })
      }
    } catch (e) {
      set({ phase: 'error', errorCode: 'unavailable', errorMessage: e instanceof Error ? e.message : spaceStopErrorMessage('unavailable') })
    }
  }

  function reset(): void {
    state = { ...INITIAL }
    emit()
  }

  return { getState: () => state, subscribe: (fn) => { subs.add(fn); return () => subs.delete(fn) }, submit, reset }
}
