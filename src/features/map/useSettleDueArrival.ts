import { useEffect, useRef } from 'react'
import { commandMainShipSettleArrival } from './mainshipApi'
import { computeSettleDelayMs, type SettleArrivalResult } from './settleArrival'

// UX-CLEANUP item 6 (part A) — React due-trigger for the on-demand OSN arrival settle.
//
// When the caller's active OSN movement becomes due, fire command_main_ship_settle_arrival exactly ONCE
// per movement id (ref-guard, like the existing stop/recall guards) and then refresh the polled state, so
// the ship settles the instant it arrives instead of waiting up to ~30s of cron + a poll tick. A timer set
// at arrive_at (rather than checking only on poll ticks) makes the trigger fire on time; the effect's deps
// are the movement's PRIMITIVE fields, so the 3–4s polls (which recreate the object with identical values)
// never reschedule it. The server re-validates everything under the cron's own locks — an early, duplicate,
// or raced call is a clean no-op — and the unchanged 30s cron remains the backstop for a closed tab,
// a lost timer, or a failed RPC. No poll interval is changed.
export function useSettleDueArrival(input: {
  mainShipId: string | null
  movement: { id: string; status: string; arrive_at: string } | null
  onSettled: () => void
  // Test seam; defaults to the real authenticated RPC wrapper.
  rpc?: (mainShipId: string | null) => Promise<SettleArrivalResult>
}): void {
  const { mainShipId, onSettled, rpc } = input
  const movementId = input.movement?.id ?? null
  const movementStatus = input.movement?.status ?? null
  const arriveAt = input.movement?.arrive_at ?? null

  // Fire-once guard per movement id (a second due-tick for the same movement must not re-fire).
  const firedForRef = useRef<string | null>(null)
  // Latest-value refs so the once-armed timer calls the current callbacks without rescheduling.
  const onSettledRef = useRef(onSettled)
  onSettledRef.current = onSettled
  const rpcRef = useRef(rpc)
  rpcRef.current = rpc

  useEffect(() => {
    if (movementId === null || movementStatus === null || arriveAt === null) return
    const delay = computeSettleDelayMs({ status: movementStatus, arrive_at: arriveAt }, Date.now())
    if (delay === null) return

    const fire = async (): Promise<void> => {
      if (firedForRef.current === movementId) return // once per movement
      firedForRef.current = movementId
      try {
        await (rpcRef.current ?? commandMainShipSettleArrival)(mainShipId)
      } finally {
        onSettledRef.current() // refresh regardless — the server state is the truth either way
      }
    }

    // +150ms epsilon so the server-side `arrive_at <= now()` check is already true when the call lands.
    const timer = setTimeout(() => void fire(), delay + 150)
    return () => clearTimeout(timer)
  }, [movementId, movementStatus, arriveAt, mainShipId])
}
