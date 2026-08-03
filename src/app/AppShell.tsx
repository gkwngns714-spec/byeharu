import { NavLink, Outlet } from 'react-router-dom'
import { ShellStateContext } from './shellState'
import { useGameState } from '../features/dashboard/useGameState'
import { useCombat } from '../features/combat/useCombat'
import { useGalaxyMapData } from '../features/map/useGalaxyMapData'
import { useMainShipSelection } from '../features/map/useMainShipSelection'
import { Icon } from '../components/ui'
import { AccountMenu } from '../features/account/AccountMenu'
import { COMBAT_TAB_TO, NAV_TABS, navGridClass } from './navTabs'

// UI-REBUILD (2b) — the persistent shell. ONE mobile-first bottom tab bar (Map · Ships · Fleet ·
// Port · Command; active tab derived from the router; the table + its gating live in navTabs.ts,
// spec-pinned) over a single shared data layer: the three polled hooks (map/game/combat) mount
// HERE exactly once and reach every destination through useShellState — destinations never mount
// their own useGameState/useCombat.
//
// 4C-CLIENT: the consolidated arrival-settle mount (useSettleDueArrival — both per-ship movement
// families) is DELETED with the per-ship movement client. Neither family can fire anymore: no
// client writer can create a main_ship_space_movements row or a moving main-ship fleet_movements
// row (4a-post deleted the per-ship command client; the legacy mover flags are off; the drain is
// 0). Unified fleet arrivals are settled by the server's own cron (process_fleet_movements).

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
        {/* ACCOUNT (2026-08-03): a slim persistent header whose only control is the top-right
            profile affordance — identity/credits/totals live behind it (AccountMenu), NOT in a
            nav cell. The wordmark is quiet chrome, not a control. z-40 keeps the open panel above
            every screen's own overlays (the map's stacks top out at z-30). */}
        <header className="relative z-40 flex min-h-11 items-center justify-between border-b border-edge bg-surface pl-4 pr-1">
          <span className="font-mono text-xs uppercase tracking-wider text-ink-faint">Byeharu</span>
          <AccountMenu />
        </header>
        {/* Destination content gets the full viewport minus the header + tab bar; each screen owns its scroll. */}
        <main className="min-h-0 flex-1 overflow-hidden">
          <Outlet />
        </main>
        {/* The one persistent navigation (table + gating in navTabs.ts): ≥44px touch targets,
            tokens only. Tab glyphs come from the design-system Icon set (currentColor line icons —
            they inherit the NavLink's token color). No emoji in chrome. */}
        <nav aria-label="Primary" data-testid="app-nav" className="border-t border-edge bg-surface">
          <div className={`mx-auto grid max-w-3xl ${navGridClass(NAV_TABS.length)}`}>
            {NAV_TABS.map((t) => {
              // A LIVE BATTLE IS ANNOUNCED ON EVERY SCREEN. The nav is the only chrome that is
              // always mounted, and combat.encounters is already polled here — no new read.
              const fighting = t.to === COMBAT_TAB_TO && combat.encounters.length > 0
              return (
                <NavLink
                  key={t.to}
                  to={t.to}
                  data-testid={`nav-${t.label.toLowerCase()}`}
                  className={({ isActive }) =>
                    `relative flex min-h-14 flex-col items-center justify-center gap-0.5 text-[11px] transition ${
                      isActive ? 'font-medium text-accent' : 'text-ink-muted hover:text-ink'
                    }`
                  }
                >
                  <span className="relative">
                    <Icon name={t.icon} size={20} />
                    {fighting && (
                      <span
                        data-testid="nav-combat-alert"
                        aria-label={`${combat.encounters.length} battle${combat.encounters.length === 1 ? '' : 's'} under way`}
                        title="Battle under way"
                        className="absolute -right-1.5 -top-1 h-2.5 w-2.5 animate-pulse rounded-full bg-danger ring-2 ring-surface"
                      />
                    )}
                  </span>
                  {t.label}
                </NavLink>
              )
            })}
          </div>
        </nav>
      </div>
    </ShellStateContext.Provider>
  )
}
