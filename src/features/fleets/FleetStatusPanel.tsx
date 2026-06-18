import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { formatCountdown } from '../../lib/time'
import { formatLocationLabel } from '../../lib/location'
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

// M6: friendlier lifecycle wording (server status stays the truth).
const PHASE_LABEL: Record<string, string> = {
  moving: 'Traveling',
  present: 'On station',
  returning: 'Returning',
  completed: 'Completed',
  idle: 'Idle',
  destroyed: 'Destroyed',
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
  const [, setNow] = useState(() => Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [])

  const [leavingId, setLeavingId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [showHistory, setShowHistory] = useState(false)

  const locName = (id: string | null | undefined) =>
    (id && locations.find((l) => l.id === id)?.name) || '—'
  const unitsOf = (fleetId: string) =>
    fleetUnits.filter((u) => u.fleet_id === fleetId && u.quantity > 0)

  const active = fleets.filter((f) => f.status === 'moving' || f.status === 'present' || f.status === 'returning')
  const completed = fleets.filter((f) => f.status === 'completed')

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
      <h2 className="text-lg font-medium">Fleets</h2>
      <p className="mb-4 text-xs text-white/40">Active expeditions — travel, on-station, and returns.</p>

      {error && <p className="mb-3 text-sm text-red-400">{error}</p>}

      {active.length === 0 ? (
        <p className="text-sm text-white/40">
          No active expedition.{' '}
          <Link to="/galaxy" className="text-indigo-300 underline-offset-2 hover:underline">
            Send your first from the Galaxy Map →
          </Link>
        </p>
      ) : (
        <ul className="space-y-3">
          {active.map((f) => {
            const move = movements.find((m) => m.fleet_id === f.id && m.status === 'moving')
            const presence = presences.find((p) => p.fleet_id === f.id && p.status === 'active')
            const composition = unitsOf(f.id)
              .map((u) => `${u.quantity} ${u.unit_type_id}`)
              .join(', ')
            // Activity-aware phase label (server status stays the truth).
            const phaseLabel =
              f.status === 'present'
                ? presence?.activity_type === 'hunt_pirates'
                  ? 'Fighting'
                  : 'On station'
                : (PHASE_LABEL[f.status] ?? f.status)

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
                    {phaseLabel}
                  </span>
                </div>

                <div className="mt-1 text-xs text-white/45">
                  {f.status === 'moving' &&
                    move &&
                    (() => {
                      const clock = formatCountdown(move.arrive_at)
                      return (
                        <>
                          Traveling to {locName(move.target_location_id)} ·{' '}
                          {clock ? `arriving in ${clock}` : 'awaiting server confirmation…'}
                        </>
                      )
                    })()}
                  {f.status === 'returning' &&
                    move &&
                    (() => {
                      const clock = formatCountdown(move.arrive_at)
                      const hasReward = move.reward_payload_json && Object.keys(move.reward_payload_json).length > 0
                      return (
                        <>
                          Returning home ·{' '}
                          {clock ? `arriving in ${clock}` : 'awaiting server confirmation…'}
                          {hasReward && (
                            <span className="text-amber-300/70"> · 💰 rewards locked (secured on arrival)</span>
                          )}
                        </>
                      )
                    })()}
                  {f.status === 'present' && <>at {locName(f.current_location_id)}</>}
                </div>

                {f.status === 'present' && presence && presence.activity_type === 'hunt_pirates' && (
                  <p className="mt-2 text-xs text-red-300/80">
                    ⚔️ In combat at {locName(f.current_location_id)} — retreat from the combat panel below to bank rewards.
                  </p>
                )}
                {f.status === 'present' && presence && presence.activity_type !== 'hunt_pirates' && (
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

      {completed.length > 0 && (
        <div className="mt-4">
          <button
            onClick={() => setShowHistory((s) => !s)}
            className="text-xs text-white/40 transition hover:text-white/70"
          >
            {showHistory ? 'Hide previous run(s)' : `Show ${completed.length} previous run(s)`}
          </button>
          {showHistory && (
            <ul className="mt-2 space-y-1">
              {completed.map((f) => {
                const composition = unitsOf(f.id)
                  .map((cu) => `${cu.quantity} ${cu.unit_type_id}`)
                  .join(', ')
                return (
                  <li
                    key={f.id}
                    className="flex justify-between rounded-lg border border-white/10 bg-black/20 px-3 py-2 text-xs text-white/55"
                  >
                    <span>{composition || 'fleet'}</span>
                    <span className="text-white/40">returned to {formatLocationLabel({ is_home: true })}</span>
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      )}
    </section>
  )
}
