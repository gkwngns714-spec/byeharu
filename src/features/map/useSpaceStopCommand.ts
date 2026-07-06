import { useMemo, useSyncExternalStore } from 'react'
import { commandMainShipSpaceStop, commandMainShipStopTransit } from './mainshipApi'
import { createSpaceStopController, spaceStopErrorMessage, type SpaceStopControllerDeps, type SpaceStopResult, type SpaceStopState } from './spaceStopCommand'

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
  // TRADE-FLEET-0C §2.5: the explicit selected/sole main-ship id to command. The default `rpc` forwards it as
  // p_main_ship_id so the server targets that OWNED ship instead of deriving the sole ship. Null preserves the
  // shim (behavior-identical while single-ship). Captured directly (no ref) and used as the controller's sole
  // recreation key — see the useMemo deps below for the exact lifecycle.
  mainShipId?: string | null
  rpc?: SpaceStopControllerDeps['rpc']
  genRequestId?: SpaceStopControllerDeps['genRequestId']
}): UseSpaceStopCommand {
  const mainShipId = overrides?.mainShipId ?? null
  const controller = useMemo(
    () =>
      createSpaceStopController({
        // Default sends the explicit commanded ship as p_main_ship_id; null → server sole-ship shim.
        rpc: overrides?.rpc ?? ((requestId) => commandMainShipSpaceStop(requestId, mainShipId)),
        genRequestId: overrides?.genRequestId ?? (() => crypto.randomUUID()),
      }),
    // Recreate ONLY when the commanded ship changes (null→id at load; id→id' on a future ship switch, which
    // correctly resets any in-flight Stop lifecycle); the stable test overrides are captured by closure.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [mainShipId],
  )

  const state = useSyncExternalStore(controller.subscribe, controller.getState, controller.getState)
  return { state, submit: controller.submit, reset: controller.reset }
}

// UX-CLEANUP item 3 — React adapter for the LEGACY fleet-domain transit halt (command_main_ship_stop_transit,
// 0149). Deliberately a THIN sibling of useSpaceStopCommand, not a copy: all submit/duplicate-guard/outcome
// logic is the SAME shared createSpaceStopController; only the wired RPC differs (fleet-id-addressed, and
// idempotent by server state so the controller's request id is simply unused by the wrapper). Recreated when
// the in-transit fleet changes (each legacy trip is a fresh fleet), which correctly resets the lifecycle.
export function useLegacyStopTransitCommand(
  fleetId: string | null,
  overrides?: { rpc?: (fleetId: string) => Promise<SpaceStopResult> },
): UseSpaceStopCommand {
  const rpc = overrides?.rpc
  const controller = useMemo(
    () =>
      createSpaceStopController({
        rpc: () =>
          fleetId === null
            ? Promise.resolve<SpaceStopResult>({ ok: false, code: 'unavailable', message: spaceStopErrorMessage('unavailable') })
            : (rpc ?? commandMainShipStopTransit)(fleetId),
        genRequestId: () => crypto.randomUUID(),
      }),
    // Recreate ONLY when the commanded fleet changes; stable test overrides are captured by closure.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [fleetId],
  )

  const state = useSyncExternalStore(controller.subscribe, controller.getState, controller.getState)
  return { state, submit: controller.submit, reset: controller.reset }
}
