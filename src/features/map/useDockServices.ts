import { useEffect, useMemo, useState } from 'react'
import { fetchMyCurrentDockServices } from './mainshipApi'
import { DOCK_NOT_DOCKED, type DockServices } from './dockServices'

// PHASE 9 — React adapter that fetches the player's docked-port surface (get_my_current_dock_services())
// and re-fetches whenever the main-ship lifecycle key changes (status / spatial_state / presence / movement).
// Starts at DOCK_NOT_DOCKED so nothing renders until the first server answer; any fetch error collapses to the
// no-dock default inside the API layer.

export function useDockServices(
  lifecycleKey: string,
  overrides?: { fetcher?: () => Promise<DockServices>; mainShipId?: string | null },
): DockServices {
  const [dock, setDock] = useState<DockServices>(DOCK_NOT_DOCKED)
  const mainShipId = overrides?.mainShipId ?? null
  const overrideFetcher = overrides?.fetcher
  // TRADE-FLEET-0C §2.5: the default fetcher reads the dock surface for the EXPLICIT commanded ship
  // (p_main_ship_id; null → server sole-ship shim → behavior-identical while single-ship). Memoized so its
  // identity is STABLE across renders — otherwise the effect's [fetcher] dep would refetch every render. It
  // changes only when the commanded ship (or an injected test fetcher) changes; a test fetcher overrides it.
  const fetcher = useMemo(
    () => overrideFetcher ?? (() => fetchMyCurrentDockServices(mainShipId)),
    [overrideFetcher, mainShipId],
  )

  useEffect(() => {
    let active = true
    // STALE-DATA PROTECTION: clear the previous dock IMMEDIATELY on any main-ship lifecycle change (e.g.
    // movement begins) so a previously-docked port/service list can never linger while the refetch is in
    // flight. The panel re-appears only if the fresh server answer is still at_location. This synchronous
    // reset-on-dep-change is intentional (and covered by the stale-data uispec); disable the effect-setState
    // lint for this one deliberate line rather than refactor tested behavior in a threading-only commit.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setDock(DOCK_NOT_DOCKED)
    void fetcher()
      .then((d) => {
        if (active) setDock(d)
      })
      .catch(() => {
        // Safe failure: any fetch error leaves the surface at the no-dock default (panel hidden); the rest
        // of the map/OSN UI is unaffected. (The real API layer already collapses errors, but this is defensive.)
        if (active) setDock(DOCK_NOT_DOCKED)
      })
    return () => {
      active = false
    }
  }, [fetcher, lifecycleKey])

  return dock
}
