import type { ReactNode } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuthStore } from '../store/authStore'
import { Skeleton } from '../components/ui'

/** Gate that redirects unauthenticated users to /auth. */
export function RequireAuth({ children }: { children: ReactNode }) {
  const session = useAuthStore((s) => s.session)
  const loading = useAuthStore((s) => s.loading)

  if (loading) {
    // UI R4: the app-boot placeholder on the design system — a quiet panel-shaped skeleton stack
    // instead of bare text (same auth-loading condition; sr-only status keeps the announcement).
    return (
      <div className="flex min-h-screen items-center justify-center bg-app px-4 text-ink" aria-busy="true">
        <div className="w-full max-w-sm">
          <Skeleton className="h-4 w-24" />
          <Skeleton className="mt-3 h-28 w-full rounded-card" />
          <Skeleton className="mt-3 h-10 w-full rounded-lg" />
          <span className="sr-only" role="status">Loading…</span>
        </div>
      </div>
    )
  }

  if (!session) {
    return <Navigate to="/auth" replace />
  }

  return <>{children}</>
}
