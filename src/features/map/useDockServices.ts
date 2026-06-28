import { useEffect, useState } from 'react'
import { fetchMyCurrentDockServices } from './mainshipApi'
import { DOCK_NOT_DOCKED, type DockServices } from './dockServices'

// PHASE 9 — React adapter that fetches the player's docked-port surface (get_my_current_dock_services())
// and re-fetches whenever the main-ship lifecycle key changes (status / spatial_state / presence / movement).
// Starts at DOCK_NOT_DOCKED so nothing renders until the first server answer; any fetch error collapses to the
// no-dock default inside the API layer.

export function useDockServices(
  lifecycleKey: string,
  overrides?: { fetcher?: () => Promise<DockServices> },
): DockServices {
  const [dock, setDock] = useState<DockServices>(DOCK_NOT_DOCKED)
  const fetcher = overrides?.fetcher ?? fetchMyCurrentDockServices

  useEffect(() => {
    let active = true
    // STALE-DATA PROTECTION: clear the previous dock IMMEDIATELY on any main-ship lifecycle change (e.g.
    // movement begins) so a previously-docked port/service list can never linger while the refetch is in
    // flight. The panel re-appears only if the fresh server answer is still at_location.
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
