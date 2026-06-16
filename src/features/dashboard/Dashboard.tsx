import { useAuthStore } from '../../store/authStore'

/**
 * Placeholder home screen for Milestone 1. Milestone 2 replaces this with the
 * living-base view (resources accruing in real time).
 */
export function Dashboard() {
  const user = useAuthStore((s) => s.user)
  const signOut = useAuthStore((s) => s.signOut)

  return (
    <div className="mx-auto max-w-3xl px-6 py-10">
      <header className="mb-10 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-indigo-200">
            Byeolharu
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
        <p className="text-sm leading-relaxed text-white/50">
          You're signed in. This is the Milestone&nbsp;1 shell — auth + routing +
          Supabase are wired up. Next up (Milestone&nbsp;2): your first colony with
          resources ticking up in real time.
        </p>
      </div>
    </div>
  )
}
