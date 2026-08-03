import { useEffect, useMemo, useState } from 'react'
import { fetchMyDockedStore } from './mainshipApi'
import { DOCK_STORE_EMPTY, type DockedStore } from './dockStore'

// STATION-STORAGE — React adapter that fetches the player's docked-port hangar (get_my_docked_store()) and
// re-fetches whenever the main-ship lifecycle key changes (status / spatial_state / presence / movement).
// Mirrors useDockServices: starts at DOCK_STORE_EMPTY so nothing renders until the first server answer, and any
// fetch error collapses to the empty default inside the API layer.

export function useDockStore(
  lifecycleKey: string,
  // ITEMS-HAVE-A-PLACE (0332): mainShipId joins the SAME overrides bag useDockServices already
  // uses — one idiom for both dock reads on this screen, not a second parameter shape. Passing the
  // CHOSEN ship stops the read falling into the server's sole-ship shim, which resolves to NULL
  // (and so to an empty, invisible hangar) for any player who owns two or more ships.
  overrides?: { fetcher?: () => Promise<DockedStore>; mainShipId?: string | null },
): DockedStore {
  const [store, setStore] = useState<DockedStore>(DOCK_STORE_EMPTY)
  const overrideFetcher = overrides?.fetcher
  const mainShipId = overrides?.mainShipId ?? null
  const fetcher = useMemo(
    () => overrideFetcher ?? (() => fetchMyDockedStore(mainShipId)),
    [overrideFetcher, mainShipId],
  )

  useEffect(() => {
    let active = true
    // STALE-DATA PROTECTION: clear the previous hangar immediately on any lifecycle change so a prior port's
    // store can never linger while the refetch is in flight; the panel re-appears only if still docked.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setStore(DOCK_STORE_EMPTY)
    void fetcher()
      .then((s) => {
        if (active) setStore(s)
      })
      .catch(() => {
        if (active) setStore(DOCK_STORE_EMPTY)
      })
    return () => {
      active = false
    }
  }, [fetcher, lifecycleKey])

  return store
}
