import type { UnitType } from '../../lib/catalog'
import type { MapLocation } from '../map/mapTypes'
import type { CombatReport } from './combatTypes'

const RESULT_LABEL: Record<string, { text: string; cls: string }> = {
  escaped: { text: 'Retreat successful', cls: 'text-emerald-300' },
  completed: { text: 'Auto-extracted', cls: 'text-emerald-300' },
  defeat: { text: 'Fleet destroyed', cls: 'text-red-300' },
}

export function CombatReportsView({
  reports,
  locations,
  unitTypes,
}: {
  reports: CombatReport[]
  locations: MapLocation[]
  unitTypes: UnitType[]
}) {
  const locName = (id: string | null) => (id && locations.find((l) => l.id === id)?.name) || 'unknown'
  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  const fmt = (obj: Record<string, number>) => {
    const e = Object.entries(obj ?? {}).filter(([, v]) => v)
    return e.length ? e.map(([k, v]) => `${v} ${typeName(k)}`).join(', ') : null
  }
  const fmtRewards = (obj: Record<string, number>) => {
    const e = Object.entries(obj ?? {}).filter(([, v]) => v)
    return e.length ? e.map(([k, v]) => `${v} ${k}`).join(', ') : null
  }

  return (
    <section className="rounded-2xl border border-white/10 bg-white/5 p-6">
      <h2 className="mb-4 text-lg font-medium">Combat reports</h2>
      {reports.length === 0 ? (
        <p className="text-sm text-white/40">No battles fought yet.</p>
      ) : (
        <ul className="space-y-3">
          {reports.slice(0, 8).map((r) => {
            const label = RESULT_LABEL[r.result] ?? { text: r.result, cls: 'text-white/60' }
            const won = r.result === 'escaped' || r.result === 'completed'
            const returned = fmt(r.survivors_json)
            const lost = fmt(r.total_losses_json)
            const rewards = fmtRewards(r.total_rewards_json)
            return (
              <li key={r.id} className="rounded-lg border border-white/10 bg-black/20 p-3 text-sm">
                <div className="flex items-center justify-between">
                  <span className="text-white/80">{locName(r.location_id)}</span>
                  <span className={`text-xs font-medium uppercase ${label.cls}`}>{label.text}</span>
                </div>
                <div className="mt-1 text-xs text-white/45">
                  Waves cleared: {r.waves_cleared} · {r.duration_seconds}s
                </div>
                <div className="mt-1 grid gap-x-6 gap-y-0.5 text-xs sm:grid-cols-2">
                  <span className="text-white/55">Ships returned: <span className="text-white/75">{won ? (returned ?? 'none') : 'none — fleet lost'}</span></span>
                  <span className="text-white/55">Ships lost: <span className="text-white/75">{lost ?? 'none'}</span></span>
                  <span className="text-white/55">Rewards {won ? 'secured' : 'forfeited'}: <span className="text-white/75">{won ? (rewards ?? 'none') : 'none — lost with fleet'}</span></span>
                  {won && <span className="text-emerald-300/70">Return movement started.</span>}
                </div>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
