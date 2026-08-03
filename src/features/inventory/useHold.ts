import { useEffect, useMemo, useState } from 'react'
import { fetchMyHold } from './holdApi'
import { HOLD_EMPTY, type Hold } from './hold'

// ITEMS-HAVE-A-PLACE (0333) — React adapter over the ONE hold read (get_my_hold) and re-fetches
// whenever its key changes. Mirrors useDockStore/useDockServices exactly: starts at HOLD_EMPTY so
// nothing renders until the first server answer, clears on any key change so a stale hold can never
// linger while a refetch is in flight, and any fetch error collapses to the empty default inside
// the API layer.

export function useHold(
  refreshKey: string,
  // 0333: the hold belongs to this ship's FLEET, so the read is ship-addressed. Null falls back to
  // the server's sole-ship shim.
  mainShipId: string | null,
  overrides?: { fetcher?: () => Promise<Hold> },
): Hold {
  const [hold, setHold] = useState<Hold>(HOLD_EMPTY)
  const overrideFetcher = overrides?.fetcher
  const fetcher = useMemo(
    () => overrideFetcher ?? (() => fetchMyHold(mainShipId)),
    [overrideFetcher, mainShipId],
  )

  useEffect(() => {
    let active = true
    // STALE-DATA PROTECTION (the useDockStore idiom): clear immediately on any key change so a
    // previous hold's numbers can never be shown beside a fresh port's storage.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setHold(HOLD_EMPTY)
    void fetcher()
      .then((h) => {
        if (active) setHold(h)
      })
      .catch(() => {
        if (active) setHold(HOLD_EMPTY)
      })
    return () => {
      active = false
    }
  }, [fetcher, refreshKey])

  return hold
}
