import type { UnitType } from '../../lib/catalog'
import type { MapLocation } from '../map/mapTypes'
import type { Fleet } from '../fleets/fleetTypes'
import type { CombatReport } from './combatTypes'

// Player-facing combat history. Three clear phases (no technical wording):
//   defeat                         → "FLEET DESTROYED"
//   escaped/completed, in transit  → "RETREAT SUCCESSFUL" (rewards pending)
//   escaped/completed, arrived     → "RETURN COMPLETE"    (rewards secured)
// Phase is derived from the fleet's live status (returning vs completed).
export function CombatReportsView({
  reports,
  locations,
  unitTypes,
  fleets,
}: {
  reports: CombatReport[]
  locations: MapLocation[]
  unitTypes: UnitType[]
  fleets: Fleet[]
}) {
  const locName = (id: string | null) => (id && locations.find((l) => l.id === id)?.name) || 'unknown'
  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  const ships = (obj: Record<string, number>) => {
    const e = Object.entries(obj ?? {}).filter(([, v]) => v > 0)
    return e.length ? e.map(([k, v]) => `${v} ${typeName(k)}`).join(', ') : 'none'
  }
  const metal = (obj: Record<string, number>) => {
    const m = obj?.metal ?? 0
    return m > 0 ? `${m} metal` : 'none'
  }

  return (
    <section className="rounded-2xl border border-white/10 bg-white/5 p-6">
      <h2 className="mb-4 text-lg font-medium">Combat reports</h2>
      {reports.length === 0 ? (
        <p className="text-sm text-white/40">No battles fought yet.</p>
      ) : (
        <ul className="space-y-3">
          {reports.slice(0, 8).map((r) => {
            const won = r.result === 'escaped' || r.result === 'completed'
            const fleet = fleets.find((f) => f.id === r.fleet_id)
            // Arrived home = fleet completed (or no longer tracked as in-transit).
            const arrived = won && (!fleet || fleet.status === 'completed')

            let title: string
            let titleCls: string
            if (!won) {
              title = 'FLEET DESTROYED'
              titleCls = 'text-red-300'
            } else if (arrived) {
              title = 'RETURN COMPLETE'
              titleCls = 'text-emerald-300'
            } else {
              title = 'RETREAT SUCCESSFUL'
              titleCls = 'text-amber-300'
            }

            return (
              <li key={r.id} className="rounded-lg border border-white/10 bg-black/20 p-3 text-sm">
                <div className="flex items-center justify-between">
                  <span className="text-white/80">{locName(r.location_id)}</span>
                  <span className={`text-xs font-semibold uppercase ${titleCls}`}>{title}</span>
                </div>

                {!won ? (
                  <div className="mt-1 space-y-0.5 text-xs text-white/50">
                    <div>Waves cleared: {r.waves_cleared} · {r.duration_seconds}s</div>
                    <div>Ships lost: <span className="text-white/75">{ships(r.total_losses_json)}</span></div>
                    <div className="text-red-300/70">Rewards forfeited — lost with the fleet.</div>
                  </div>
                ) : arrived ? (
                  <div className="mt-1 space-y-0.5 text-xs text-white/50">
                    <div className="text-emerald-300/80">Fleet returned to base.</div>
                    <div>Ships recovered: <span className="text-white/75">{ships(r.survivors_json)}</span></div>
                    <div>Ships lost: <span className="text-white/75">{ships(r.total_losses_json)}</span></div>
                    <div>Rewards secured: <span className="text-white/75">{metal(r.total_rewards_json)}</span></div>
                  </div>
                ) : (
                  <div className="mt-1 space-y-0.5 text-xs text-white/50">
                    <div>Waves cleared: {r.waves_cleared} · {r.duration_seconds}s</div>
                    <div>Ships returning: <span className="text-white/75">{ships(r.survivors_json)}</span></div>
                    <div>Ships lost: <span className="text-white/75">{ships(r.total_losses_json)}</span></div>
                    <div>Rewards pending: <span className="text-white/75">{metal(r.total_rewards_json)}</span></div>
                    <div className="text-amber-300/70">Fleet is traveling back to base. Rewards will be secured on arrival.</div>
                  </div>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
