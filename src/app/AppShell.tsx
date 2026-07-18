import { NavLink, Outlet } from 'react-router-dom'
import { ShellStateContext } from './shellState'
import { useGameState } from '../features/dashboard/useGameState'
import { useCombat } from '../features/combat/useCombat'
import { useGalaxyMapData } from '../features/map/useGalaxyMapData'
import { useMainShipSelection } from '../features/map/useMainShipSelection'
import { Icon, type IconName } from '../components/ui'

// UI-REBUILD (2b) — the persistent four-destination shell. ONE mobile-first bottom tab bar
// (Map · Fitting · Port · Command; active tab derived from the router) over a single shared data
// layer: the three polled hooks (map/game/combat) mount HERE exactly once and reach every
// destination through useShellState — destinations never mount their own useGameState/useCombat.
//
// 4C-CLIENT: the consolidated arrival-settle mount (useSettleDueArrival — both per-ship movement
// families) is DELETED with the per-ship movement client. Neither family can fire anymore: no
// client writer can create a main_ship_space_movements row or a moving main-ship fleet_movements
// row (4a-post deleted the per-ship command client; the legacy mover flags are off; the drain is
// 0). Unified fleet arrivals are settled by the server's own cron (process_fleet_movements).

// Tab glyphs come from the design-system Icon set (currentColor line icons — they inherit the
// NavLink's token color: accent when active, ink-muted otherwise). No emoji in chrome.
const TABS: readonly { to: string; label: string; icon: IconName }[] = [
  { to: '/map', label: 'Map', icon: 'map' },
  // S6: the Ship destination is now FITTING (ship outfitting by fleet; route kept at /ship so old
  // bookmarks keep resolving). nav testid follows the label → `nav-fitting`.
  { to: '/ship', label: 'Fitting', icon: 'ship' },
  { to: '/port', label: 'Port', icon: 'anchor' },
  { to: '/command', label: 'Command', icon: 'command' },
]

export function AppShell() {
  // A0: the ONE selected-ship model, mounted exactly once here (was duplicated per-screen). Every destination
  // reads/writes the same selection through useShellState().selection. Mounted BEFORE the map hook so the
  // selected-ship id can be threaded into it (FLEETMAP).
  const selection = useMainShipSelection()
  // FLEETMAP: thread the shell-selected ship into the map data — the single-ship reads (marker / route /
  // command) then address the SELECTED ship (the single-ship resolver otherwise returns null at N≥2), and the
  // whole-fleet layer highlights it. Changing selection re-polls the map (its own load dep).
  const map = useGalaxyMapData(4000, selection.selectedShipId)
  const game = useGameState()
  const combat = useCombat()

  return (
    <ShellStateContext.Provider value={{ game, combat, map, selection }}>
      <div className="flex h-[100dvh] flex-col bg-app text-ink">
        {/* Destination content gets the full viewport minus the tab bar; each screen owns its scroll. */}
        <main className="min-h-0 flex-1 overflow-hidden">
          <Outlet />
        </main>
        {/* The one persistent navigation: four destinations, ≥44px touch targets, tokens only. */}
        <nav aria-label="Primary" data-testid="app-nav" className="border-t border-edge bg-surface">
          <div className="mx-auto grid max-w-3xl grid-cols-4">
            {TABS.map((t) => (
              <NavLink
                key={t.to}
                to={t.to}
                data-testid={`nav-${t.label.toLowerCase()}`}
                className={({ isActive }) =>
                  `flex min-h-14 flex-col items-center justify-center gap-0.5 text-[11px] transition ${
                    isActive ? 'font-medium text-accent' : 'text-ink-muted hover:text-ink'
                  }`
                }
              >
                <Icon name={t.icon} size={20} />
                {t.label}
              </NavLink>
            ))}
          </div>
        </nav>
      </div>
    </ShellStateContext.Provider>
  )
}
