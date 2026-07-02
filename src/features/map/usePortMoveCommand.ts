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
  // TRADE-FLEET-0C §2.5: the explicit selected/sole main-ship id to command. The default `rpc` forwards it as
  // p_main_ship_id so the server targets that OWNED ship instead of deriving the sole ship. Null preserves the
  // shim (behavior-identical while single-ship). Captured directly (no ref) and used as the controller's sole
  // recreation key — see the useMemo deps below for the exact lifecycle.
  mainShipId?: string | null
  rpc?: PortMoveControllerDeps['rpc']
  genRequestId?: PortMoveControllerDeps['genRequestId']
}): UsePortMoveCommand {
  const mainShipId = overrides?.mainShipId ?? null
  const controller = useMemo(
    () =>
      createPortMoveController({
        // Default sends the explicit commanded ship as p_main_ship_id; null → server sole-ship shim.
        rpc: overrides?.rpc ?? ((locationId, requestId) => commandMainShipSpaceMoveToLocation(locationId, requestId, mainShipId)),
        genRequestId: overrides?.genRequestId ?? (() => crypto.randomUUID()),
      }),
    // Recreate ONLY when the commanded ship changes (null→id at load; id→id' on a future ship switch, which
    // correctly resets any pending selection); the stable test overrides are captured by closure.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [mainShipId],
  )

  const state = useSyncExternalStore(controller.subscribe, controller.getState, controller.getState)
  return { state, selectPort: controller.selectPort, submit: controller.submit, clear: controller.clear }
}
