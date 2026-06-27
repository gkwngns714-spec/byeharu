import { useMemo, useSyncExternalStore } from 'react'
import { commandMainShipSpaceMoveToLocation } from './mainshipApi'
import {
  createPortMoveController,
  type PortMoveControllerDeps,
  type PortMoveState,
} from './portMoveCommand'
import type { MapLocation } from './mapTypes'

// PORT-LAUNCH-1B — React adapter over the framework-free port-move controller (portMoveCommand.ts).
//
// • The default `rpc` calls ONLY the OSN-HUB-1A location-target wrapper `commandMainShipSpaceMoveToLocation`
//   (destination location id + idempotency key only). `genRequestId` is `crypto.randomUUID`. Both are
//   injectable for tests (the controller itself is unit-tested directly).
// • This hook is NOT flag-gated: the surface that mounts it (PortNavPanel) gates on the server readiness
//   projection (osn_available + anchored), and the server is the final authority — a stale command while
//   dark safely rejects with {ok:false, code:'feature_disabled'} without mutation.
// • No DB table is read or written here.

export interface UsePortMoveCommand {
  state: PortMoveState
  selectPort: (location: MapLocation) => void
  submit: () => Promise<void>
  clear: () => void
}

export function usePortMoveCommand(overrides?: {
  rpc?: PortMoveControllerDeps['rpc']
  genRequestId?: PortMoveControllerDeps['genRequestId']
}): UsePortMoveCommand {
  const controller = useMemo(
    () =>
      createPortMoveController({
        rpc: overrides?.rpc ?? ((locationId, requestId) => commandMainShipSpaceMoveToLocation(locationId, requestId)),
        genRequestId: overrides?.genRequestId ?? (() => crypto.randomUUID()),
      }),
    // Stable for the component's lifetime; deps are read via closures by design.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  )

  const state = useSyncExternalStore(controller.subscribe, controller.getState, controller.getState)
  return { state, selectPort: controller.selectPort, submit: controller.submit, clear: controller.clear }
}
