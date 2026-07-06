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

// The idempotency-key portion of the RPC args — this pure builder's ONLY responsibility (no coordinates; the
// server computes the stop point itself). TRADE-FLEET-0C §2.5: the explicit p_main_ship_id is added at the
// wrapper boundary (commandMainShipSpaceStop), not in this builder, so the builder + its unit test stay intact.
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

// ── UX-CLEANUP item 3 — LEGACY fleet-domain transit stop (halt → return home) ────────────────────────
// MainShipCommand sends travel as legacy fleet_movements (0050/0053) — invisible to the OSN stop above.
// command_main_ship_stop_transit (0149) halts such a transit and returns the ship home symmetrically.
export const STOP_TRANSIT_RPC = 'command_main_ship_stop_transit' as const

/**
 * THE one selector for "the active legacy movement row of the main-ship fleet" (the fleet's single
 * status='moving' fleet_movements row — at most one exists by the 0007 partial unique index).
 * Shared by AppShell (the consolidated arrival-settle wiring) and MapScreen (the legacy stop CTA
 * predicate) so the derivation lives in exactly one place. Generic so each caller keeps its own
 * movement row type.
 */
export function selectActiveLegacyMovement<M extends { fleet_id: string; status: string }>(
  fleet: { id: string } | null | undefined,
  movements: readonly M[],
): M | null {
  return fleet ? (movements.find((mv) => mv.fleet_id === fleet.id && mv.status === 'moving') ?? null) : null
}

// Visibility predicate: the caller's main-ship fleet is 'moving' on an OUTBOUND (non-return) mission.
// Mirrors isActiveCoordinateTransit's shape; the server (flag gate + state guards) stays authoritative —
// a stale Stop safely no-ops or rejects without mutation.
export function isActiveLegacyOutboundTransit(input: {
  fleetStatus: string | null | undefined
  missionType: string | null | undefined
}): boolean {
  return input.fleetStatus === 'moving' && input.missionType != null && input.missionType !== 'return_home'
}

/**
 * Map the stop-transit server envelope ({ok:true, stopped, reason?} | {ok:false, code, message}) onto the
 * SAME SpaceStopResult the shared stop controller consumes: a successful halt → outcome 'stopped'; every
 * idempotent no-op (already_settled / already_returning / arrived) → outcome 'arrived' (the trip is being
 * settled by its normal path — nothing was halted). Malformed input fails closed to a safe error.
 */
export function parseStopTransitResult(raw: unknown): SpaceStopResult {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { ok: false, code: 'unavailable', message: spaceStopErrorMessage('unavailable') }
  }
  const o = raw as Record<string, unknown>
  if (o.ok === true) {
    return { ok: true, outcome: o.stopped === true ? 'stopped' : 'arrived' }
  }
  if (o.ok === false && typeof o.code === 'string' && o.code.length > 0) {
    const message = typeof o.message === 'string' && o.message.length > 0 ? o.message : spaceStopErrorMessage(o.code)
    return { ok: false, code: o.code, message }
  }
  return { ok: false, code: 'unavailable', message: spaceStopErrorMessage('unavailable') }
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
    // The key is reused ONLY for an in-error retry (idempotent) and is consumed (cleared) on success,
    // so the next Stop on a new transit is a fresh idempotent command — a consumed key would only
    // replay the first Stop's server receipt (a silent no-op on the new movement).
    const requestId = state.requestId ?? deps.genRequestId()
    set({ phase: 'submitting', requestId, errorCode: null, errorMessage: null })
    try {
      const res = await deps.rpc(requestId)
      if (res.ok) {
        set({ phase: 'done', outcome: res.outcome, requestId: null, errorCode: null, errorMessage: null })
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
