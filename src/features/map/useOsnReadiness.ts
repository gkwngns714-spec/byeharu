import { useCallback, useEffect, useState } from 'react'
import { fetchOsnMovementReadiness } from './mainshipApi'
import { OSN_NOT_ACTIONABLE, type OsnReadiness } from './osnReadiness'

// PORT-LAUNCH-1B — React adapter that fetches the server readiness projection
// (get_osn_movement_readiness()) and re-fetches on the established invalidation triggers.
//
// • Starts at OSN_NOT_ACTIONABLE so NOTHING actionable renders until the first server answer (dark-safe).
// • Re-fetches on mount, whenever `lifecycleKey` changes (a string derived by the caller from main-ship /
//   movement lifecycle state — so a status refresh or movement lifecycle change re-validates readiness),
//   and on the manual `refresh()` the caller invokes after a successful location-target move command or a
//   Stop success/failure. This reuses the existing poll-derived data as the invalidation signal — no new
//   polling loop is introduced.
// • Any fetch error collapses to OSN_NOT_ACTIONABLE inside the API layer (no raw error reaches the player).

export interface UseOsnReadiness {
  readiness: OsnReadiness
  refresh: () => void
}

export function useOsnReadiness(
  lifecycleKey: string,
  overrides?: { fetcher?: () => Promise<OsnReadiness> },
): UseOsnReadiness {
  const [readiness, setReadiness] = useState<OsnReadiness>(OSN_NOT_ACTIONABLE)
  const [tick, setTick] = useState(0)
  const fetcher = overrides?.fetcher ?? fetchOsnMovementReadiness

  const refresh = useCallback(() => setTick((t) => t + 1), [])

  useEffect(() => {
    let active = true
    void fetcher().then((r) => {
      if (active) setReadiness(r)
    })
    return () => {
      active = false
    }
    // Re-validate on mount, on any main-ship/movement lifecycle change, and on a manual refresh tick.
  }, [fetcher, lifecycleKey, tick])

  return { readiness, refresh }
}
