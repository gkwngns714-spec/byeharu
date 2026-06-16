import { Link } from 'react-router-dom'
import { useAuthStore } from '../../store/authStore'

/**
 * Home screen. M2 adds a read-only galaxy map. Fleets, bases, and combat arrive
 * in later milestones.
 */
export function Dashboard() {
  const user = useAuthStore((s) => s.user)
  const signOut = useAuthStore((s) => s.signOut)

  return (
    <div className="mx-auto max-w-3xl px-6 py-10">
      <header className="mb-10 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-indigo-200">
            Byeharu
          </h1>
          <p className="text-sm text-white/40">{user?.email}</p>
        </div>
        <button
          onClick={signOut}
          className="rounded-lg border border-white/10 px-3 py-1.5 text-sm text-white/70 transition hover:bg-white/5"
        >
          Sign out
        </button>
      </header>

      <div className="rounded-2xl border border-white/10 bg-white/5 p-8">
        <h2 className="mb-2 text-lg font-medium">Command center</h2>
        <p className="mb-5 text-sm leading-relaxed text-white/50">
          You're signed in. Auth, routing, and Supabase are wired up, and the galaxy
          is charted. Sending fleets and hunting pirates arrive in later milestones.
        </p>
        <Link
          to="/map"
          className="inline-block rounded-lg bg-indigo-500 px-4 py-2 text-sm font-medium text-white transition hover:bg-indigo-400"
        >
          Open galaxy map →
        </Link>
      </div>
    </div>
  )
}
