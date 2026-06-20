import { useEffect, useState } from 'react'
import { deriveMainShipStatus, type MainShipView } from '../map/mainshipApi'
import type { Fleet, FleetMovement } from '../fleets/fleetTypes'
import { isMainShipFleet } from '../fleets/fleetGuards'
import type { MapLocation } from '../map/mapTypes'
import { formatCountdown } from '../../lib/time'

// Phase 10H — read-only Command Center view of the player's main ship: name/hull, derived status
// (home / traveling / on-station / returning / disabled), HP + needs-repair state, active
// destination, and travel countdown/progress. Rendered ONLY when mainship_send_enabled is true
// (gated by the Dashboard). Pure display — the active fleet + movement come from the data already
// loaded by useGameState; no extra fetch, no writes. (Repair action arrives in Commit C.)

const ACTIVE = new Set(['moving', 'present', 'returning'])

export function MainShipPanel({
  mainShip,
  fleets,
  movements,
  locations,
}: {
  mainShip: MainShipView | null
  fleets: Fleet[]
  movements: FleetMovement[]
  locations: MapLocation[]
}) {
  // 1s tick for a smooth countdown/progress bar (the backend stays the source of truth).
  const [, setNow] = useState(() => Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [])

  if (!mainShip) return null
  const ship = mainShip.has_ship ? mainShip.ship : undefined
  const hull = mainShip.hull

  if (!ship) {
    return (
      <section data-testid="dashboard-mainship-panel" className="rounded-2xl border border-sky-400/15 bg-sky-500/5 p-4 sm:p-6">
        <h2 className="text-lg font-medium">🛰 Main Ship</h2>
        <p className="mt-1 text-sm text-white/45">No main ship commissioned yet.</p>
      </section>
    )
  }

  const isDisabled = ship.status === 'destroyed'
  const activeFleet = fleets.find((f) => isMainShipFleet(f) && ACTIVE.has(f.status))
  const status = isDisabled ? 'disabled' : deriveMainShipStatus(activeFleet ?? null)
  const move = activeFleet ? movements.find((m) => m.fleet_id === activeFleet.id && m.status === 'moving') : undefined
  const locName = (id: string | null | undefined) => (id && locations.find((l) => l.id === id)?.name) || '—'

  const destination = move
    ? move.target_type === 'base'
      ? 'Home base'
      : locName(move.target_location_id)
    : status === 'present'
      ? locName(activeFleet?.current_location_id)
      : null

  const countdown = move ? formatCountdown(move.arrive_at) : null
  const progress = move
    ? (() => {
        const dep = new Date(move.depart_at).getTime()
        const arr = new Date(move.arrive_at).getTime()
        if (!(arr > dep)) return null
        return Math.max(0, Math.min(1, (Date.now() - dep) / (arr - dep)))
      })()
    : null

  const statusLabel =
    status === 'disabled' ? 'Disabled — needs repair'
    : status === 'traveling' ? `Traveling to ${destination ?? '—'}`
    : status === 'present' ? `On station${destination ? ` at ${destination}` : ''}`
    : status === 'returning' ? 'Returning home'
    : 'Home'

  return (
    <section data-testid="dashboard-mainship-panel" className="rounded-2xl border border-sky-400/15 bg-sky-500/5 p-4 sm:p-6">
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-lg font-medium">🛰 Main Ship</h2>
        <span className={'rounded px-2 py-0.5 text-[10px] uppercase tracking-wide ' + (isDisabled ? 'bg-amber-500/15 text-amber-300' : 'bg-sky-500/15 text-sky-200')}>
          {statusLabel}
        </span>
      </div>

      {isDisabled && (
        <p className="mb-3 rounded border border-amber-600/40 bg-amber-500/10 px-2 py-1.5 text-sm text-amber-200">
          🛠 Your main ship was disabled and must be repaired before it can travel again.
        </p>
      )}

      <dl className="space-y-1.5 text-sm">
        <Row label="Name" value={ship.name} />
        <Row label="Hull" value={hull?.name ?? ship.hull_type_id} />
        <Row label="Status" value={statusLabel} />
        <Row label="Readiness (HP)" value={`${ship.hp} / ${ship.max_hp}`} />
        {destination && <Row label="Destination" value={destination} />}
        {countdown && <Row label="Arriving in" value={countdown} />}
      </dl>

      {progress !== null && (
        <div className="mt-3 h-1.5 w-full overflow-hidden rounded bg-white/10">
          <div className="h-full bg-sky-400 transition-[width]" style={{ width: `${Math.round(progress * 100)}%` }} />
        </div>
      )}
    </section>
  )
}

function Row({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="text-white/45">{label}</dt>
      <dd className="text-right text-white/80">{value}</dd>
    </div>
  )
}
