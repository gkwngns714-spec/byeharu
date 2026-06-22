import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import { fetchMainshipSpaceMovementEnabled } from '../../lib/catalog'
import { commandMainShipSpaceMove } from './mainshipApi'
import {
  createSpaceMoveController,
  type SpaceMoveControllerDeps,
  type SpaceMoveState,
} from './spaceMoveCommand'
import type { WorldCoord } from './openSpaceTransform'

// OSN-3 S6C — React adapter over the framework-free space-move controller (spaceMoveCommand.ts).
//
// • The flag `mainship_space_movement_enabled` is read once on mount via the EXISTING catalog read
//   (no new fetch path); the controller is dark (isEnabled() === false) until it resolves true, so a
//   submit before the flag is known sends nothing. In production the flag is false → permanently dark.
// • The default `rpc` calls ONLY the S6A wrapper `commandMainShipSpaceMove`; `genRequestId` is
//   `crypto.randomUUID`. Both are injectable for tests (the controller itself is unit-tested directly).
// • No DB table is read or written here.

export interface UseSpaceMoveCommand {
  state: SpaceMoveState
  enabled: boolean
  selectTarget: (w: WorldCoord) => void
  submit: () => Promise<void>
  clear: () => void
}

export function useSpaceMoveCommand(overrides?: {
  rpc?: SpaceMoveControllerDeps['rpc']
  genRequestId?: SpaceMoveControllerDeps['genRequestId']
}): UseSpaceMoveCommand {
  const [enabled, setEnabled] = useState(false)
  // The controller reads the flag through a ref so it always sees the latest value without being
  // re-created (recreating it would drop in-flight target/request-id state).
  const enabledRef = useRef(false)
  enabledRef.current = enabled

  const controller = useMemo(
    () =>
      createSpaceMoveController({
        rpc: overrides?.rpc ?? ((target, requestId) => commandMainShipSpaceMove(target.x, target.y, requestId)),
        genRequestId: overrides?.genRequestId ?? (() => crypto.randomUUID()),
        isEnabled: () => enabledRef.current,
      }),
    // Stable for the component's lifetime; dependencies are read via refs/closures by design.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  )

  const state = useSyncExternalStore(controller.subscribe, controller.getState, controller.getState)

  useEffect(() => {
    let active = true
    void fetchMainshipSpaceMovementEnabled().then((v) => {
      if (active) setEnabled(v)
    })
    return () => {
      active = false
    }
  }, [])

  return { state, enabled, selectTarget: controller.selectTarget, submit: controller.submit, clear: controller.clear }
}
