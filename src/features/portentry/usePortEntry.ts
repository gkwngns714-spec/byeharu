import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react'
import {
  derivePortEntryAffordance,
  type PortEntryAffordance, type PortEntryShipState, type CommissionResult,
} from './portEntry'
import {
  createPortEntryController, type PortEntryActionKind, type PortEntryCommandController, type PortEntryPhase,
} from './portEntryCommand'
import { commissionFirstMainShip, fetchPortEntryShipState } from './portEntryApi'

// PORT-ENTRY player UI — React adapter. Self-contained (its own owner-reads, like useDockServices): it fetches
// the caller's port-entry ship state on mount, derives the single affordance, and adapts the framework-free
// one-shot controller. After a successful action it re-reads authoritative state and notifies the parent so
// the rest of the UI (e.g. the main-ship panel / dock surface) reconciles. No polling loop — a one-time claim
// is not a high-frequency surface; state also refreshes after every action.
// (4C-CLIENT: the normalize action + the legacy-present location classification left with the
// normalize affordance — see portEntry.ts.)

export interface UsePortEntryOverrides {
  // Test injection seams (default to the real authenticated server calls).
  fetchState?: () => Promise<PortEntryShipState>
  commission?: () => Promise<CommissionResult>
  // Notify the parent (e.g. Dashboard.refresh) after a successful commission.
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

  // null ⇒ not loaded yet (affordance renders 'loading' — never a premature action or "unavailable").
  const [state, setState] = useState<PortEntryShipState | null>(null)

  const refresh = useCallback(async () => {
    const next = await fetchState()
    setState(next)
  }, [fetchState])

  // Always call the LATEST onChanged from inside the (once-created) controller.
  //
  // NOTE — PRE-EXISTING lint debt, NOT introduced by TRADE-FLEET-0C §2.5: the stable framework-free controller
  // adapter below uses the lazy-init-ref + latest-value-ref pattern (the controller is created exactly once;
  // onChanged is read fresh inside it; the controller itself is unit-tested separately). The newly-strict
  // react-hooks/refs + set-state-in-effect rules flag this otherwise-valid pattern. These directives keep the
  // file lint-clean WITHOUT a behavior-risky lifecycle refactor in this LIVE-mutation, id-threading-only commit
  // (the hook has no direct unit coverage here). A useState-initializer cleanup is a recommended separate follow-up.
  const onChangedRef = useRef(overrides?.onChanged)
  // eslint-disable-next-line react-hooks/refs -- pre-existing: latest-value ref updated for the once-created controller
  onChangedRef.current = overrides?.onChanged

  // One stable controller for the component's lifetime (framework-free; unit-tested separately).
  const controllerRef = useRef<PortEntryCommandController | null>(null)
  if (controllerRef.current === null) {
    // eslint-disable-next-line react-hooks/refs -- pre-existing: lazy-init the stable controller exactly once
    controllerRef.current = createPortEntryController({
      commission,
      onSettled: async () => {
        await refresh()
        onChangedRef.current?.()
      },
    })
  }
  const controller = controllerRef.current

  // eslint-disable-next-line react-hooks/refs -- pre-existing: subscribe to the stable controller's external store
  const cmd = useSyncExternalStore(controller.subscribe, controller.getState)

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- pre-existing: mount fetch; setState is async (post-await)
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
