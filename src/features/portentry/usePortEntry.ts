import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react'
import {
  derivePortEntryAffordance, type PortEntryAffordance, type PortEntryShipState,
  type CommissionResult, type NormalizeResult,
} from './portEntry'
import {
  createPortEntryController, type PortEntryActionKind, type PortEntryCommandController, type PortEntryPhase,
} from './portEntryCommand'
import { commissionFirstMainShip, fetchPortEntryShipState, normalizeMainShipDock } from './portEntryApi'

// PORT-ENTRY player UI — React adapter. Self-contained (its own owner-reads, like useDockServices): it fetches
// the caller's port-entry ship state on mount, derives the single affordance, and adapts the framework-free
// one-shot controller. After a successful action it re-reads authoritative state and notifies the parent so
// the rest of the UI (e.g. the main-ship panel / dock surface) reconciles. No polling loop — a one-time claim
// / dock is not a high-frequency surface; state also refreshes after every action.

export interface UsePortEntryOverrides {
  // Test injection seams (default to the real authenticated server calls).
  fetchState?: () => Promise<PortEntryShipState>
  commission?: () => Promise<CommissionResult>
  normalize?: () => Promise<NormalizeResult>
  // Notify the parent (e.g. Dashboard.refresh) after a successful commission/normalize.
  onChanged?: () => void
}

export interface UsePortEntry {
  affordance: PortEntryAffordance
  phase: PortEntryPhase
  actionKind: PortEntryActionKind | null
  message: string | null
  submit: (kind: PortEntryActionKind) => Promise<void>
  reset: () => void
}

export function usePortEntry(overrides?: UsePortEntryOverrides): UsePortEntry {
  const fetchState = overrides?.fetchState ?? fetchPortEntryShipState
  const commission = overrides?.commission ?? commissionFirstMainShip
  const normalize = overrides?.normalize ?? normalizeMainShipDock

  // null ⇒ not loaded yet (affordance renders 'loading' — never a premature action or "unavailable").
  const [state, setState] = useState<PortEntryShipState | null>(null)

  const refresh = useCallback(async () => {
    const next = await fetchState()
    setState(next)
  }, [fetchState])

  // Always call the LATEST onChanged from inside the (once-created) controller.
  const onChangedRef = useRef(overrides?.onChanged)
  onChangedRef.current = overrides?.onChanged

  // One stable controller for the component's lifetime (framework-free; unit-tested separately).
  const controllerRef = useRef<PortEntryCommandController | null>(null)
  if (controllerRef.current === null) {
    controllerRef.current = createPortEntryController({
      commission,
      normalize,
      onSettled: async () => {
        await refresh()
        onChangedRef.current?.()
      },
    })
  }
  const controller = controllerRef.current

  const cmd = useSyncExternalStore(controller.subscribe, controller.getState)

  useEffect(() => {
    void refresh()
  }, [refresh])

  const submit = useCallback((kind: PortEntryActionKind) => controller.submit(kind), [controller])
  const reset = useCallback(() => controller.reset(), [controller])

  return {
    affordance: derivePortEntryAffordance(state),
    phase: cmd.phase,
    actionKind: cmd.kind,
    message: cmd.message,
    submit,
    reset,
  }
}
