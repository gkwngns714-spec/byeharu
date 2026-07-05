import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { formatCountdown } from '../../lib/time'
import { formatLocationLabel } from '../../lib/location'
import type { MapLocation } from '../map/mapTypes'
import type { Fleet, FleetMovement, FleetUnit, LocationPresence } from './fleetTypes'
import { requestLeaveLocation } from './fleetApi'
import { isMainShipFleet } from './fleetGuards'
import { Card, CardHeader, Badge, Button, Notice, type BadgeTone } from '../../components/ui'

const STATUS_TONE: Record<string, BadgeTone> = {
  moving: 'warning',
  present: 'success',
  returning: 'accent',
  completed: 'neutral',
  idle: 'neutral',
  destroyed: 'danger',
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

  // Exclude main-ship fleets from this LEGACY panel entirely (Phase 10E). They carry no fleet_units
  // and must never reach the legacy leave/return path. Main ships are sent/recalled only from the
  // Galaxy Map 🛰 overlay (request_main_ship_return). Uses the shared isMainShipFleet predicate so
  // the rule has a single source of truth.
  const legacy = fleets.filter((f) => !isMainShipFleet(f))
  const active = legacy.filter((f) => f.status === 'moving' || f.status === 'present' || f.status === 'returning')
  const completed = legacy.filter((f) => f.status === 'completed')

  async function handleLeave(presenceId: string, fleet: Fleet) {
    // Belt-and-suspenders: this panel already excludes main-ship fleets, but guard again before
    // the legacy leave call (main ships recall from the Galaxy Map 🛰 overlay).
    if (isMainShipFleet(fleet)) {
      setError('Main ships are recalled from the Galaxy Map, not the Fleets panel.')
      return
    }
    setLeavingId(presenceId)
    setError(null)
    try {
      await requestLeaveLocation(presenceId, fleet)
      onChanged()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLeavingId(null)
    }
  }

  return (
    <Card>
      <CardHeader title="Fleets" subtitle="Active expeditions — travel, on-station, and returns." />

      {error && (
        <Notice tone="danger" className="mb-3">
          {error}
        </Notice>
      )}

      {active.length === 0 ? (
        <p className="text-sm text-ink-muted">
          No active expedition.{' '}
          <Link to="/galaxy" className="text-accent underline-offset-2 hover:underline">
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
              <li key={f.id} className="rounded-lg border border-edge bg-surface-2/60 p-3">
                <div className="flex items-center justify-between">
                  <span className="text-sm text-ink">{composition || 'fleet'}</span>
                  <Badge tone={STATUS_TONE[f.status] ?? 'neutral'}>{phaseLabel}</Badge>
                </div>

                <div className="mt-1 text-xs text-ink-muted">
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
                            <span className="text-warning/80"> · 💰 rewards locked (secured on arrival)</span>
                          )}
                        </>
                      )
                    })()}
                  {f.status === 'present' && <>at {locName(f.current_location_id)}</>}
                </div>

                {f.status === 'present' && presence && presence.activity_type === 'hunt_pirates' && (
                  <p className="mt-2 text-xs text-danger/90">
                    ⚔️ In combat at {locName(f.current_location_id)} — retreat from the combat panel below to bank rewards.
                  </p>
                )}
                {f.status === 'present' && presence && presence.activity_type !== 'hunt_pirates' && (
                  <Button
                    size="sm"
                    onClick={() => handleLeave(presence.id, f)}
                    busy={leavingId === presence.id}
                    busyLabel="Leaving…"
                    className="mt-2"
                  >
                    Leave & return home
                  </Button>
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
            className="text-xs text-ink-faint transition hover:text-ink-muted"
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
                    className="flex justify-between rounded-lg border border-edge bg-surface-2/60 px-3 py-2 text-xs text-ink-muted"
                  >
                    <span>{composition || 'fleet'}</span>
                    <span className="text-ink-faint">returned to {formatLocationLabel({ is_home: true })}</span>
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      )}
    </Card>
  )
}
