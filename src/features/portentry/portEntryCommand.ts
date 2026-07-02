// PORT-ENTRY player UI — PURE, framework-free one-shot action controller.
//
// No React/DOM/fetch here. Owns the submit lifecycle for the two zero-arg PORT-ENTRY actions
// (Claim First Ship / Finish Docking): a single in-flight submission at a time (duplicate-click guard),
// a phase state machine, and a post-success refresh hook. The React hook adapts it via useSyncExternalStore
// (same pattern as createSpaceMoveController). The controller performs NO transition itself — it calls an
// injected RPC and the SERVER decides; on a successful (ok=true) response it triggers the injected refresh
// so the UI re-reads authoritative state (a newly commissioned/docked ship then renders normally).

import {
  commissionReasonMessage, normalizeReasonMessage,
  type CommissionResult, type NormalizeResult,
} from './portEntry'

export type PortEntryActionKind = 'commission' | 'normalize'
export type PortEntryPhase = 'idle' | 'submitting' | 'success' | 'error'

export interface PortEntryCommandState {
  phase: PortEntryPhase
  kind: PortEntryActionKind | null // which action produced the current phase
  message: string | null // player-facing success or error copy
}

export interface PortEntryCommandDeps {
  commission: () => Promise<CommissionResult>
  // TRADE-FLEET-0C §2.5: normalize receives the explicit selected/sole main-ship id (p_main_ship_id); null →
  // server sole-ship shim. A zero-arg injected normalize still satisfies this (the arg is simply ignored).
  normalize: (mainShipId?: string | null) => Promise<NormalizeResult>
  // Re-read authoritative state after a successful action (re-fetch + parent refresh). Called at most once
  // per successful submit. Any rejection here is swallowed — it must never turn a real success into an error.
  onSettled: () => Promise<void> | void
}

export interface PortEntryCommandController {
  getState: () => PortEntryCommandState
  subscribe: (fn: () => void) => () => void
  submit: (kind: PortEntryActionKind, mainShipId?: string | null) => Promise<void>
  reset: () => void
}

const INITIAL: PortEntryCommandState = { phase: 'idle', kind: null, message: null }

const COMMISSION_SUCCESS_COPY = 'Your ship is commissioned and docked at Haven Reach.'
const COMMISSION_ALREADY_COPY = 'Your ship is already commissioned and docked.'
const NORMALIZE_SUCCESS_COPY = 'Docking complete — your ship is now docked at this port.'
const NORMALIZE_ALREADY_COPY = 'Your ship is already docked at this port.'
const NETWORK_COPY = 'Could not reach the server. Please check your connection and try again.'

export function createPortEntryController(deps: PortEntryCommandDeps): PortEntryCommandController {
  let state: PortEntryCommandState = { ...INITIAL }
  const subs = new Set<() => void>()
  const emit = (): void => subs.forEach((f) => f())
  const set = (patch: Partial<PortEntryCommandState>): void => {
    state = { ...state, ...patch }
    emit()
  }

  async function runSettle(): Promise<void> {
    try {
      await deps.onSettled()
    } catch {
      // Refresh failure must never demote a genuine success; the next poll/mount will reconcile.
    }
  }

  async function submit(kind: PortEntryActionKind, mainShipId?: string | null): Promise<void> {
    if (state.phase === 'submitting') return // duplicate-submit guard: exactly one in-flight action
    set({ phase: 'submitting', kind, message: null })
    try {
      if (kind === 'commission') {
        const res = await deps.commission() // first-ship claim: no ship id exists yet (mainShipId unused here)
        if (res.ok) {
          set({ phase: 'success', kind, message: res.created ? COMMISSION_SUCCESS_COPY : COMMISSION_ALREADY_COPY })
          await runSettle()
        } else {
          set({ phase: 'error', kind, message: commissionReasonMessage(res.reason) })
        }
      } else {
        const res = await deps.normalize(mainShipId) // §2.5: normalize the EXPLICIT owned ship (null → shim)
        if (res.ok) {
          set({ phase: 'success', kind, message: res.normalized ? NORMALIZE_SUCCESS_COPY : NORMALIZE_ALREADY_COPY })
          await runSettle()
        } else {
          set({ phase: 'error', kind, message: normalizeReasonMessage(res.reason) })
        }
      }
    } catch {
      // Uncertain outcome (network/throw). Both RPCs are idempotent server-side, so a later retry is safe.
      set({ phase: 'error', kind, message: NETWORK_COPY })
    }
  }

  function reset(): void {
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
    submit,
    reset,
  }
}
