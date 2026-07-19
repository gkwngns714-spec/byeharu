import { useEffect } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { useAuthStore } from '../store/authStore'
import { RequireAuth } from './RequireAuth'
import { AppShell } from './AppShell'
import { AuthPage } from '../features/auth/AuthPage'
import { MapScreen } from '../features/map/MapScreen'
import { ShipScreen } from '../features/ship/ShipScreen'
import { PortScreen } from '../features/port/PortScreen'
import { CommandScreen } from '../features/command/CommandScreen'
import { ZoneEditor } from '../features/dev/ZoneEditor'

// UI-REBUILD (2b) — four destinations under the ONE persistent shell (AppShell). `/` lands on the
// Map (the primary play surface); the legacy `/galaxy` and `/reports` routes redirect so old
// bookmarks resolve into the new navigation.

export function App() {
  const init = useAuthStore((s) => s.init)

  useEffect(() => {
    // Subscribe to Supabase auth once for the app's lifetime.
    const unsubscribe = init()
    return unsubscribe
  }, [init])

  return (
    <BrowserRouter basename={import.meta.env.BASE_URL}>
      <Routes>
        <Route path="/auth" element={<AuthPage />} />
        <Route
          element={
            <RequireAuth>
              <AppShell />
            </RequireAuth>
          }
        >
          <Route path="/map" element={<MapScreen />} />
          <Route path="/ship" element={<ShipScreen />} />
          <Route path="/port" element={<PortScreen />} />
          <Route path="/command" element={<CommandScreen />} />
        </Route>
        {/* DEV ZONE EDITOR (owner-only authoring) — a HIDDEN route, deliberately NOT under AppShell
            and never linked from the nav. RequireAuth so pirate_zone_create has an auth.uid(); the
            ZoneEditor itself renders null unless game_config.dev_zone_editor_enabled is true (0238),
            so a normal player who somehow hits /dev/zones sees nothing. */}
        <Route
          path="/dev/zones"
          element={
            <RequireAuth>
              <ZoneEditor />
            </RequireAuth>
          }
        />
        {/* Root + legacy routes resolve into the new shell (bookmarks keep working). */}
        <Route path="/" element={<Navigate to="/map" replace />} />
        <Route path="/galaxy" element={<Navigate to="/map" replace />} />
        <Route path="/reports" element={<Navigate to="/command" replace />} />
        <Route path="*" element={<Navigate to="/map" replace />} />
      </Routes>
    </BrowserRouter>
  )
}
