import { useEffect, useState } from 'react'
import { countdownTo } from '../../game/movement/travelPreview'
import type { MapLocation } from '../map/mapTypes'
import type { Fleet, FleetMovement, FleetUnit, LocationPresence } from './fleetTypes'
import { requestLeaveLocation } from './fleetApi'

const STATUS_STYLE: Record<string, string> = {
  moving: 'bg-amber-500/15 text-amber-300',
  present: 'bg-emerald-500/15 text-emerald-300',
  returning: 'bg-sky-500/15 text-sky-300',
  completed: 'bg-white/10 text-white/50',
  idle: 'bg-white/10 text-white/50',
  destroyed: 'bg-red-500/15 text-red-300',
}

export function FleetStatusPanel({
  fleets,
  movements,
  presences,
  fleetUnits,
  locations,
  onChanged,
}: {
  fleets: Fleet[]
  movements: FleetMovement[]
  presences: LocationPresence[]
  fleetUnits: FleetUnit[]
  locations: MapLocation[]
  onChanged: () => void
}) {
  // Local 1s tick drives the countdown display only (backend remains the truth).
  const [, setNow] = useState(Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [])

  const [leavingId, setLeavingId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const locName = (id: string | null | undefined) =>
    (id && locations.find((l) => l.id === id)?.name) || '—'
  const unitsOf = (fleetId: string) =>
    fleetUnits.filter((u) => u.fleet_id === fleetId && u.quantity > 0)

  const active = fleets.filter((f) => f.status === 'moving' || f.status === 'present' || f.status === 'returning')
  const completedCount = fleets.filter((f) => f.status === 'completed').length

  async function handleLeave(presenceId: string) {
    setLeavingId(presenceId)
    setError(null)
    try {
      await requestLeaveLocation(presenceId)
      onChanged()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLeavingId(null)
    }
  }

  return (
    <section className="rounded-2xl border border-white/10 bg-white/5 p-6">
      <div className="mb-4 flex items-baseline justify-between">
        <h2 className="text-lg font-medium">Fleets</h2>
        {completedCount > 0 && (
          <span className="text-xs text-white/35">{completedCount} completed run(s)</span>
        )}
      </div>

      {error && <p className="mb-3 text-sm text-red-400">{error}</p>}

      {active.length === 0 ? (
        <p className="text-sm text-white/40">No active fleets. Send one above.</p>
      ) : (
        <ul className="space-y-3">
          {active.map((f) => {
            const move = movements.find((m) => m.fleet_id === f.id && m.status === 'moving')
            const presence = presences.find((p) => p.fleet_id === f.id && p.status === 'active')
            const composition = unitsOf(f.id)
              .map((u) => `${u.quantity} ${u.unit_type_id}`)
              .join(', ')

            return (
              <li key={f.id} className="rounded-lg border border-white/10 bg-black/20 p-3">
                <div className="flex items-center justify-between">
                  <span className="text-sm text-white/80">{composition || 'fleet'}</span>
                  <span
                    className={
                      'rounded px-2 py-0.5 text-[10px] uppercase tracking-wide ' +
                      (STATUS_STYLE[f.status] ?? 'bg-white/10 text-white/50')
                    }
                  >
                    {f.status}
                  </span>
                </div>

                <div className="mt-1 text-xs text-white/45">
                  {f.status === 'moving' && move && (
                    <>→ {locName(move.target_location_id)} · arriving in {countdownTo(move.arrive_at)}</>
                  )}
                  {f.status === 'returning' && move && (
                    <>← returning home · arriving in {countdownTo(move.arrive_at)}</>
                  )}
                  {f.status === 'present' && <>at {locName(f.current_location_id)}</>}
                </div>

                {f.status === 'present' && presence && (
                  <button
                    onClick={() => handleLeave(presence.id)}
                    disabled={leavingId === presence.id}
                    className="mt-2 rounded-md border border-white/15 px-3 py-1 text-xs text-white/80 transition hover:bg-white/10 disabled:opacity-40"
                  >
                    {leavingId === presence.id ? 'Leaving…' : 'Leave & return home'}
                  </button>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
