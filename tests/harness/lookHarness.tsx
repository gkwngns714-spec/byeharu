// LOOK HARNESS (test only) — mounts the REAL destination screens (ShipScreen / FleetScreen /
// PortScreen / CommandScreen / MapScreen, imported from src, untouched) inside the REAL AppShell
// frame classes + bottom tab bar, with the shared shell state INJECTED as a fixture
// (<ShellStateContext.Provider>) so scripts/look-shots.mjs can screenshot every screen at mobile
// widths. No production access; nothing connects — lookFixtures installs an offline network stub
// BEFORE the supabase client module evaluates (it must stay the FIRST import of this file).
//
//   look.html?screen=ship|fleet|port|command|map   — which real screen to render
//            &state=active|empty                   — mid-game fixture vs brand-new-player fixture
//
// CSS parity with the real app (src/main.tsx): the same @fontsource weights + src/index.css.
// NOTE: Tailwind utilities only materialize when the server runs the app's tailwind pipeline —
// tests/harness/vite.config.ts (the uispec server) deliberately doesn't; scripts/look-shots.mjs
// starts its own Vite server WITH the tailwind plugin for faithful rendering.
import { buildShellState, currentLookScreen, currentLookState, ensureLookNetInstalled } from './lookFixtures'
import type { ComponentType } from 'react'
import { createRoot } from 'react-dom/client'
import { MemoryRouter, NavLink } from 'react-router-dom'
import type { User } from '@supabase/supabase-js'
import '@fontsource/inter/400.css'
import '@fontsource/inter/500.css'
import '@fontsource/inter/600.css'
import '@fontsource/jetbrains-mono/400.css'
import '@fontsource/jetbrains-mono/500.css'
import '../../src/index.css'
import { ShellStateContext } from '../../src/app/shellState'
import { NAV_TABS, navGridClass } from '../../src/app/navTabs'
import { useAuthStore } from '../../src/store/authStore'
import { Icon } from '../../src/components/ui'
import { ShipScreen } from '../../src/features/ship/ShipScreen'
import { FleetScreen } from '../../src/features/command/FleetScreen'
import { PortScreen } from '../../src/features/port/PortScreen'
import { MissionScreen } from '../../src/features/command/MissionScreen'
import { AccountMenu } from '../../src/features/account/AccountMenu'
import { MapScreen } from '../../src/features/map/MapScreen'

ensureLookNetInstalled() // idempotent — already ran at lookFixtures import; kept as an explicit anchor

const screen = currentLookScreen()
const state = currentLookState()

// MissionScreen/AccountMenu read user email + signOut from the zustand auth store; FirstOrdersCard keys its
// dismissal on user.id. Seed the store directly — authStore.init() is never called, so no auth
// network traffic exists to begin with (and the net stub would answer it anyway).
useAuthStore.setState({
  user: {
    id: 'look-user',
    email: 'commander@byeharu.test',
    aud: 'authenticated',
    role: 'authenticated',
    app_metadata: {},
    user_metadata: {},
    created_at: '2026-01-01T00:00:00Z',
  } as User,
  session: null,
  loading: false,
})

const SCREENS: Record<typeof screen, { route: string; Component: ComponentType }> = {
  ship: { route: '/ship', Component: ShipScreen },
  fleet: { route: '/fleet', Component: FleetScreen },
  port: { route: '/port', Component: PortScreen },
  // MISSION-TAB: the ops destination; 'command' kept as an alias of the same screen.
  mission: { route: '/mission', Component: MissionScreen },
  command: { route: '/mission', Component: MissionScreen },
  map: { route: '/map', Component: MapScreen },
}

const { route, Component } = SCREENS[screen]
const fixture = buildShellState(state)

// The AppShell frame + bottom tab bar, mirrored VERBATIM from src/app/AppShell.tsx (same classes,
// same NAV_TABS table) so mobile screenshots show the full in-game chrome. Not imported directly
// because AppShell also mounts the real polling hooks — exactly what this harness replaces.
function LookFrame() {
  return (
    <ShellStateContext.Provider value={fixture}>
      <div className="flex h-[100dvh] flex-col bg-app text-ink">
        {/* ACCOUNT header — mirrored verbatim from AppShell (same classes) so shots carry the
            real chrome; AccountMenu itself is the REAL component over the fixture shell state. */}
        <header className="relative z-40 flex min-h-11 items-center justify-between border-b border-edge bg-surface pl-4 pr-1">
          <span className="font-mono text-xs uppercase tracking-wider text-ink-faint">Byeharu</span>
          <AccountMenu />
        </header>
        <main className="min-h-0 flex-1 overflow-hidden">
          <Component />
        </main>
        <nav aria-label="Primary" data-testid="app-nav" className="border-t border-edge bg-surface">
          <div className={`mx-auto grid max-w-3xl ${navGridClass(NAV_TABS.length)}`}>
            {NAV_TABS.map((t) => (
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

createRoot(document.getElementById('root')!).render(
  <MemoryRouter initialEntries={[route]}>
    <LookFrame />
  </MemoryRouter>,
)
