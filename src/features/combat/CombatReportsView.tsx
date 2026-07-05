import { Link } from 'react-router-dom'
import type { UnitType } from '../../lib/catalog'
import type { MapLocation } from '../map/mapTypes'
import type { Fleet } from '../fleets/fleetTypes'
import type { CombatReport } from './combatTypes'
import { Card, CardHeader } from '../../components/ui'

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
    <Card>
      <CardHeader
        title="Combat reports"
        aside={
          <Link to="/reports" className="text-xs text-accent transition hover:text-accent-hover">
            View all →
          </Link>
        }
      />
      {reports.length === 0 ? (
        <p className="text-sm text-ink-muted">No battles fought yet.</p>
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
              titleCls = 'text-danger'
            } else if (arrived) {
              title = 'RETURN COMPLETE'
              titleCls = 'text-success'
            } else {
              title = 'RETREAT SUCCESSFUL'
              titleCls = 'text-warning'
            }

            return (
              <li key={r.id} className="rounded-lg border border-edge bg-surface-2/60 p-3 text-sm">
                <div className="flex items-center justify-between">
                  <span className="text-ink">{locName(r.location_id)}</span>
                  <span className={`text-xs font-semibold uppercase ${titleCls}`}>{title}</span>
                </div>

                {!won ? (
                  <div className="mt-1 space-y-0.5 text-xs text-ink-faint">
                    <div>Waves cleared: {r.waves_cleared} · {r.duration_seconds}s</div>
                    <div>Ships lost: <span className="text-ink-muted">{ships(r.total_losses_json)}</span></div>
                    <div className="text-danger/80">Rewards forfeited — lost with the fleet.</div>
                  </div>
                ) : arrived ? (
                  <div className="mt-1 space-y-0.5 text-xs text-ink-faint">
                    <div className="text-success/90">Fleet returned to base.</div>
                    <div>Ships recovered: <span className="text-ink-muted">{ships(r.survivors_json)}</span></div>
                    <div>Ships lost: <span className="text-ink-muted">{ships(r.total_losses_json)}</span></div>
                    <div>Rewards secured: <span className="text-ink-muted">{metal(r.total_rewards_json)}</span></div>
                  </div>
                ) : (
                  <div className="mt-1 space-y-0.5 text-xs text-ink-faint">
                    <div>Waves cleared: {r.waves_cleared} · {r.duration_seconds}s</div>
                    <div>Ships returning: <span className="text-ink-muted">{ships(r.survivors_json)}</span></div>
                    <div>Ships lost: <span className="text-ink-muted">{ships(r.total_losses_json)}</span></div>
                    <div>Rewards pending: <span className="text-ink-muted">{metal(r.total_rewards_json)}</span></div>
                    <div className="text-warning/80">Fleet escaped. Rewards will be secured when it reaches base.</div>
                  </div>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </Card>
  )
}
