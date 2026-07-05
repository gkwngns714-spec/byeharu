import { useEffect, useRef } from 'react'
import { commandMainShipSettleArrival, commandMainShipSettleArrivalLegacy } from './mainshipApi'
import { computeSettleDelayMs, type SettleArrivalResult } from './settleArrival'

// UX-CLEANUP item 6 — React due-trigger for the on-demand arrival settles, covering BOTH movement
// families with ONE hook:
//   • part A (0150): the OSN movement (main_ship_space_movements) → command_main_ship_settle_arrival
//   • part B (0151): the LEGACY main-ship fleet movement (fleet_movements — MainShipCommand trips and
//     return legs) → command_main_ship_settle_arrival_legacy
//
// For each family: arm one timer at arrive_at (+150ms so the server-side due check is already true),
// fire the RPC exactly ONCE per movement id (ref-guard, the existing stop/recall idiom), then refresh.
// Effect deps are the movement's PRIMITIVE fields, so the 3–4s polls (which recreate objects with
// identical values) never reschedule a timer. The server re-validates everything under the crons' own
// locks — an early, duplicate, or raced call is a clean no-op — and the unchanged 30s crons remain the
// backstop for a closed tab, a lost timer, or a failed RPC. No poll interval or cron cadence changes.

interface DueMovement {
  id: string
  status: string
  arrive_at: string
}

// Shared per-family timer: one setTimeout at the movement's arrive_at, one fire per movement id.
function useDueTimer(movement: DueMovement | null, fire: (movementId: string) => Promise<void>): void {
  const movementId = movement?.id ?? null
  const movementStatus = movement?.status ?? null
  const arriveAt = movement?.arrive_at ?? null

  const firedForRef = useRef<string | null>(null)
  const fireRef = useRef(fire)
  fireRef.current = fire

  useEffect(() => {
    if (movementId === null || movementStatus === null || arriveAt === null) return
    const delay = computeSettleDelayMs({ status: movementStatus, arrive_at: arriveAt }, Date.now())
    if (delay === null) return

    const timer = setTimeout(() => {
      if (firedForRef.current === movementId) return // once per movement
      firedForRef.current = movementId
      void fireRef.current(movementId)
    }, delay + 150) // +150ms epsilon: the server-side `arrive_at <= now()` check is already true on landing
    return () => clearTimeout(timer)
  }, [movementId, movementStatus, arriveAt])
}

export function useSettleDueArrival(input: {
  mainShipId: string | null
  // Part A: the active OSN movement (null when none).
  movement: DueMovement | null
  // Part B: the active LEGACY main-ship fleet movement + its fleet id (null when none / not in scope).
  legacyMovement?: DueMovement | null
  legacyFleetId?: string | null
  onSettled: () => void
  // Test seams; default to the real authenticated RPC wrappers.
  rpc?: (mainShipId: string | null) => Promise<SettleArrivalResult>
  legacyRpc?: (fleetId: string | null) => Promise<SettleArrivalResult>
}): void {
  const { mainShipId, onSettled, rpc, legacyRpc } = input
  const legacyFleetId = input.legacyFleetId ?? null

  // Latest-value refs so the armed timers call current callbacks without rescheduling.
  const onSettledRef = useRef(onSettled)
  onSettledRef.current = onSettled
  const rpcRef = useRef(rpc)
  rpcRef.current = rpc
  const legacyRpcRef = useRef(legacyRpc)
  legacyRpcRef.current = legacyRpc
  const legacyFleetIdRef = useRef(legacyFleetId)
  legacyFleetIdRef.current = legacyFleetId

  // Part A — OSN movement.
  useDueTimer(input.movement, async () => {
    try {
      await (rpcRef.current ?? commandMainShipSettleArrival)(mainShipId)
    } finally {
      onSettledRef.current() // refresh regardless — the server state is the truth either way
    }
  })

  // Part B — legacy main-ship fleet movement.
  useDueTimer(input.legacyMovement ?? null, async () => {
    try {
      await (legacyRpcRef.current ?? commandMainShipSettleArrivalLegacy)(legacyFleetIdRef.current)
    } finally {
      onSettledRef.current()
    }
  })
}
