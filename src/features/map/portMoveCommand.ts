// PORT-LAUNCH-1B — PURE, framework-free controller for the dark port-to-port command surface.
//
// No React/DOM/SVG/fetch here. It owns: (1) the ONE public command this surface may call, (2) the exact
// argument contract (a destination LOCATION id + an idempotency key — NOTHING else), (3) player-facing
// error copy, and (4) a small stateful select→submit lifecycle the React hook adapts.
//
// HARD BOUNDARY: this surface is location-target ONLY. The controller calls a single injected
// `rpc(locationId, requestId)` and passes ONLY a destination location id + a request id — NEVER a
// coordinate, ship id, player id, anchor, or client-computed travel data (the server derives the ship from
// auth.uid(), resolves the destination coordinate from the location's canonical anchor, and is the sole
// authority). It NEVER references the empty-space coordinate command (command_main_ship_space_move).

import type { MapLocation } from './mapTypes'

// The ONLY command this surface is permitted to call (the OSN-HUB-1A canonical location-target wrapper).
// Exported so the API layer and tests reference the same literal — the port surface must never reach the
// empty-space coordinate endpoint or any other movement RPC.
export const PORT_MOVE_RPC = 'command_main_ship_space_move_to_location' as const

// The server result contract (mirrors command_main_ship_space_move_to_location). Only the fields the
// lifecycle needs; extra fields are ignored.
export type PortMoveResult =
  | { ok: true; target_location_id?: string; arrive_at?: string }
  | { ok: false; code: string; message?: string }

// Stable, sanitized player-facing copy per server code. Guarantees a consistent string even if the server
// message changes or the call throws client-side; a raw RPC/DB error is never shown.
export const PORT_MOVE_ERROR_COPY: Record<string, string> = {
  feature_disabled: 'Port travel is not available yet.',
  not_authenticated: 'You must be signed in.',
  no_ship: 'You do not have a main ship.',
  origin_not_anchored: 'Your ship must be docked at a port first.',
  in_transit_must_stop: 'The ship is already travelling.',
  must_stop_first: 'The ship is already travelling.',
  target_not_legal: 'That port is not a valid destination right now.',
  not_eligible_target: 'That port is not a valid destination right now.',
  same_location: 'The ship is already at that port.',
  request_conflict: 'This command was already used for a different destination.',
  ship_destroyed: 'The ship must be repaired first.',
  destroyed: 'The ship must be repaired first.',
  network: 'Could not reach the server. Check your connection and retry.',
  unavailable: 'That port is not available to travel to right now.',
}
export function portMoveErrorMessage(code: string | null | undefined, serverMessage?: string): string {
  if (code && PORT_MOVE_ERROR_COPY[code]) return PORT_MOVE_ERROR_COPY[code]
  if (serverMessage) return serverMessage
  return PORT_MOVE_ERROR_COPY.unavailable
}

export type PortMovePhase = 'idle' | 'selected' | 'submitting' | 'success' | 'error'

export interface PortMoveState {
  phase: PortMovePhase
  selected: MapLocation | null
  requestId: string | null // current idempotency key (reused on in-error retry; consumed/cleared on success)
  errorCode: string | null
  errorMessage: string | null
}

export interface PortMoveControllerDeps {
  rpc: (locationId: string, requestId: string) => Promise<PortMoveResult>
  genRequestId: () => string
}

export interface PortMoveController {
  getState: () => PortMoveState
  subscribe: (fn: () => void) => () => void
  selectPort: (location: MapLocation) => void
  submit: () => Promise<void>
  clear: () => void
}

const INITIAL: PortMoveState = {
  phase: 'idle',
  selected: null,
  requestId: null,
  errorCode: null,
  errorMessage: null,
}

export function createPortMoveController(deps: PortMoveControllerDeps): PortMoveController {
  let state: PortMoveState = { ...INITIAL }
  const subs = new Set<() => void>()
  const emit = (): void => subs.forEach((f) => f())
  const set = (patch: Partial<PortMoveState>): void => {
    state = { ...state, ...patch }
    emit()
  }

  function selectPort(location: MapLocation): void {
    // A CHANGED destination invalidates any prior idempotency key (new target ⇒ new request id). The same
    // destination keeps the key so a retry after an error reuses it (idempotent).
    const changed = state.selected?.id !== location.id
    set({
      selected: location,
      phase: 'selected',
      errorCode: null,
      errorMessage: null,
      requestId: changed ? null : state.requestId,
    })
  }

  async function submit(): Promise<void> {
    if (state.phase === 'submitting') return // block duplicate submit while a request is in flight
    if (!state.selected) return // nothing chosen to send
    const requestId = state.requestId ?? deps.genRequestId()
    const locationId = state.selected.id
    set({ phase: 'submitting', requestId, errorCode: null, errorMessage: null })
    try {
      const res = await deps.rpc(locationId, requestId)
      if (res.ok) {
        // The key is consumed by this success: clear it so re-travelling to the SAME destination later
        // sends a fresh command instead of replaying this trip's server receipt (a silent no-op).
        set({ phase: 'success', requestId: null, errorCode: null, errorMessage: null })
      } else {
        // keep requestId + selected so a retry reuses the same idempotency key
        set({ phase: 'error', errorCode: res.code, errorMessage: portMoveErrorMessage(res.code, res.message) })
      }
    } catch (e) {
      // uncertain outcome — keep requestId so the retry is idempotent
      set({
        phase: 'error',
        errorCode: 'network',
        errorMessage: portMoveErrorMessage('network', e instanceof Error ? e.message : undefined),
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
    selectPort,
    submit,
    clear,
  }
}
