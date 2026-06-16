import type { MapLocation } from '../map/mapTypes'
import type { CombatReport } from './combatTypes'

const RESULT_STYLE: Record<string, string> = {
  escaped: 'text-emerald-300',
  completed: 'text-emerald-300',
  defeat: 'text-red-300',
}

function summarize(obj: Record<string, number>): string {
  const entries = Object.entries(obj ?? {}).filter(([, v]) => v)
  return entries.length ? entries.map(([k, v]) => `${v} ${k}`).join(', ') : '—'
}

export function CombatReportsView({
  reports,
  locations,
}: {
  reports: CombatReport[]
  locations: MapLocation[]
}) {
  const locName = (id: string | null) => (id && locations.find((l) => l.id === id)?.name) || 'unknown'

  return (
    <section className="rounded-2xl border border-white/10 bg-white/5 p-6">
      <h2 className="mb-4 text-lg font-medium">Combat reports</h2>
      {reports.length === 0 ? (
        <p className="text-sm text-white/40">No battles fought yet.</p>
      ) : (
        <ul className="space-y-2">
          {reports.slice(0, 10).map((r) => (
            <li key={r.id} className="rounded-lg border border-white/10 bg-black/20 p-3 text-sm">
              <div className="flex items-center justify-between">
                <span className="text-white/80">{locName(r.location_id)}</span>
                <span className={`text-xs uppercase ${RESULT_STYLE[r.result] ?? 'text-white/50'}`}>
                  {r.result}
                </span>
              </div>
              <div className="mt-1 text-xs text-white/45">
                {r.waves_cleared} waves · {r.duration_seconds}s · losses {summarize(r.total_losses_json)} ·
                rewards {summarize(r.total_rewards_json)}
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
