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
import { WorldEditor } from '../features/worldeditor/WorldEditor'

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
        {/* WORLD EDITOR — the ONE owner-only authoring surface (C1 retired the legacy standalone
            zone editor route; the World Editor's zones layer owns that job on the real map).
            HIDDEN route: RequireAuth (so reads run with an auth session), NOT under AppShell, never
            linked from nav. The WorldEditor renders null unless game_config.dev_zone_editor_enabled
            is true (0238, fail-closed), so a normal player who hits /dev/world sees nothing. */}
        <Route
          path="/dev/world"
          element={
            <RequireAuth>
              <WorldEditor />
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
