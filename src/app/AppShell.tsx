import { NavLink, Outlet } from 'react-router-dom'
import { ShellStateContext } from './shellState'
import { useGameState } from '../features/dashboard/useGameState'
import { useCombat } from '../features/combat/useCombat'
import { useGalaxyMapData } from '../features/map/useGalaxyMapData'
import { useSettleDueArrival } from '../features/map/useSettleDueArrival'

// UI-REBUILD (2b) — the persistent four-destination shell. ONE mobile-first bottom tab bar
// (Map · Ship · Port · Command; active tab derived from the router) over a single shared data
// layer: the three polled hooks (map/game/combat) mount HERE exactly once and reach every
// destination through useShellState — destinations never mount their own useGameState/useCombat.
//
// CONSOLIDATED ARRIVAL SETTLE: the old Dashboard mounted useSettleDueArrival for the legacy leg
// and GalaxyMapScreen for the OSN leg — safe only because those routes were mutually exclusive.
// The persistent shell breaks that invariant, so the hook mounts EXACTLY ONCE here, covering BOTH
// families; no destination mounts it again.

const TABS = [
  { to: '/map', label: 'Map', icon: '🗺' },
  { to: '/ship', label: 'Ship', icon: '🛰' },
  { to: '/port', label: 'Port', icon: '⚓' },
  { to: '/command', label: 'Command', icon: '🏠' },
] as const

export function AppShell() {
  const map = useGalaxyMapData()
  const game = useGameState()
  const combat = useCombat()

  // Both settle legs in one mount (see header). The legacy leg needs the active main-ship fleet's
  // moving row — the same derivation the old screens used.
  const legacyMove = map.mainShipFleet
    ? (map.movements.find((mv) => mv.fleet_id === map.mainShipFleet?.id && mv.status === 'moving') ?? null)
    : null
  useSettleDueArrival({
    mainShipId: map.mainShip?.main_ship_id ?? null,
    movement: map.mainShipSpaceMovement,
    legacyMovement: legacyMove,
    legacyFleetId: map.mainShipFleet?.id ?? null,
    onSettled: () => {
      void map.refresh()
      void game.refresh()
    },
  })

  return (
    <ShellStateContext.Provider value={{ game, combat, map }}>
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
                <span className="text-lg leading-none" aria-hidden>
                  {t.icon}
                </span>
                {t.label}
              </NavLink>
            ))}
          </div>
        </nav>
      </div>
    </ShellStateContext.Provider>
  )
}
