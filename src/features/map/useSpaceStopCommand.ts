import { useMemo, useSyncExternalStore } from 'react'
import { commandMainShipSpaceStop } from './mainshipApi'
import { createSpaceStopController, type SpaceStopControllerDeps, type SpaceStopState } from './spaceStopCommand'

// OSN-4 — React adapter over the framework-free Stop controller (spaceStopCommand.ts).
//
// Unlike the move command, this hook is NOT flag-gated: the Stop safety action must remain usable for a
// ship already in a real active coordinate transit even after an emergency flag disable (Constraint 1).
// The server is the final authority — a Stop with no active coordinate transit safely rejects without
// mutation. The default `rpc` calls ONLY the public Stop wrapper `commandMainShipSpaceStop`; both deps are
// injectable for tests. No DB table is read or written here.

export interface UseSpaceStopCommand {
  state: SpaceStopState
  submit: () => Promise<void>
  reset: () => void
}

export function useSpaceStopCommand(overrides?: {
  rpc?: SpaceStopControllerDeps['rpc']
  genRequestId?: SpaceStopControllerDeps['genRequestId']
}): UseSpaceStopCommand {
  const controller = useMemo(
    () =>
      createSpaceStopController({
        rpc: overrides?.rpc ?? ((requestId) => commandMainShipSpaceStop(requestId)),
        genRequestId: overrides?.genRequestId ?? (() => crypto.randomUUID()),
      }),
    // Stable for the component's lifetime; deps are read via closures by design.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  )

  const state = useSyncExternalStore(controller.subscribe, controller.getState, controller.getState)
  return { state, submit: controller.submit, reset: controller.reset }
}
