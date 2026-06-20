import { useEffect } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { useAuthStore } from '../store/authStore'
import { RequireAuth } from './RequireAuth'
import { AuthPage } from '../features/auth/AuthPage'
import { Dashboard } from '../features/dashboard/Dashboard'
import { MapPage } from '../features/map/MapPage'
import { GalaxyMapScreen } from '../features/map/GalaxyMapScreen'
import { CombatReportPage } from '../features/combat/CombatReportPage'
import { DebugErrorBoundary } from './DebugErrorBoundary'

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
          path="/"
          element={
            <RequireAuth>
              <Dashboard />
            </RequireAuth>
          }
        />
        <Route
          path="/map"
          element={
            <RequireAuth>
              <MapPage />
            </RequireAuth>
          }
        />
        <Route
          path="/galaxy"
          element={
            <RequireAuth>
              {/* TEMPORARY: catch + display the pan-crash render error (remove in cleanup). */}
              <DebugErrorBoundary>
                <GalaxyMapScreen />
              </DebugErrorBoundary>
            </RequireAuth>
          }
        />
        <Route
          path="/reports"
          element={
            <RequireAuth>
              <CombatReportPage />
            </RequireAuth>
          }
        />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  )
}
