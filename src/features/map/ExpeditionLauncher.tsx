import { Link } from 'react-router-dom'

// Command Center pointer to the single send surface (the Galaxy Map). Replaces the old
// in-dashboard send panel so there is exactly ONE place to launch expeditions. Read-only:
// it just links to /galaxy.
export function ExpeditionLauncher({ hasActive }: { hasActive: boolean }) {
  return (
    <section data-testid="dashboard-expedition-launcher" className="rounded-2xl border border-indigo-400/20 bg-indigo-500/5 p-6">
      <h2 className="mb-1 text-lg font-medium">Expeditions</h2>
      <p className="text-sm text-white/55">
        {hasActive
          ? 'Launch another expedition from the Galaxy Map — pick a destination, choose your ships, and send.'
          : 'No active expedition. Send your first from the Galaxy Map: pick a destination, choose your ships, and send.'}
      </p>
      <p className="mt-2 text-xs text-white/40">
        Rewards stay <span className="text-amber-300/80">pending</span> while your fleet is out and are{' '}
        <span className="text-emerald-300/80">secured only when it returns home</span>.
      </p>
      <Link
        to="/galaxy"
        className="mt-4 inline-flex items-center gap-2 rounded-lg bg-indigo-500 px-4 py-2 text-sm font-medium text-white transition hover:bg-indigo-400"
      >
        🗺 Open Galaxy Map
      </Link>
    </section>
  )
}
