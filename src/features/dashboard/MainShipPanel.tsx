import { useEffect, useRef, useState } from 'react'
import { deriveMainShipStatus, repairMainShip, type MainShipView } from '../map/mainshipApi'
import type { Fleet, FleetMovement } from '../fleets/fleetTypes'
import { isMainShipFleet } from '../fleets/fleetGuards'
import type { MapLocation } from '../map/mapTypes'
import { formatCountdown } from '../../lib/time'
import { Card, CardHeader, Badge, Notice, Button, Meter } from '../../components/ui'

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
  onChanged,
}: {
  mainShip: MainShipView | null
  fleets: Fleet[]
  movements: FleetMovement[]
  locations: MapLocation[]
  onChanged: () => void
}) {
  // 1s tick for a smooth countdown/progress bar (the backend stays the source of truth).
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [])
  const [repairing, setRepairing] = useState(false)
  const [repairError, setRepairError] = useState<string | null>(null)
  const repairRef = useRef(false)

  async function doRepair() {
    if (repairRef.current) return // synchronous double-submit guard
    repairRef.current = true
    setRepairing(true)
    setRepairError(null)
    try {
      await repairMainShip(mainShip?.ship?.main_ship_id ?? null) // §2.5: explicit ship id; server asserts ownership (own ship only); null → shim
      onChanged()
    } catch (e) {
      setRepairError(e instanceof Error ? e.message : String(e))
    } finally {
      repairRef.current = false
      setRepairing(false)
    }
  }

  if (!mainShip) return null
  const ship = mainShip.has_ship ? mainShip.ship : undefined
  const hull = mainShip.hull

  if (!ship) {
    return (
      <Card tone="accent" data-testid="dashboard-mainship-panel">
        <h2 className="text-lg font-semibold text-ink">🛰 Main Ship</h2>
        <p className="mt-1 text-sm text-ink-muted">No main ship commissioned yet.</p>
      </Card>
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
        return Math.max(0, Math.min(1, (now - dep) / (arr - dep)))
      })()
    : null

  const statusLabel =
    status === 'disabled' ? 'Disabled — needs repair'
    : status === 'traveling' ? `Traveling to ${destination ?? '—'}`
    : status === 'present' ? `On station${destination ? ` at ${destination}` : ''}`
    : status === 'returning' ? 'Returning home'
    : 'Home'

  return (
    <Card tone="accent" data-testid="dashboard-mainship-panel">
      <CardHeader
        title="🛰 Main Ship"
        aside={<Badge tone={isDisabled ? 'warning' : 'accent'}>{statusLabel}</Badge>}
        className="mb-3"
      />

      {isDisabled && (
        <div className="mb-3">
          <Notice tone="warning">
            🛠 Your main ship was disabled and must be repaired before it can travel again.
          </Notice>
          {repairError && (
            <Notice tone="danger" data-testid="mainship-repair-error" className="mt-2">
              {repairError}
            </Notice>
          )}
          <Button
            variant="warning"
            data-testid="mainship-repair"
            busy={repairing}
            busyLabel="Repairing…"
            onClick={doRepair}
            className="mt-2 w-full"
          >
            Repair main ship
          </Button>
        </div>
      )}

      <dl className="space-y-1.5 text-sm">
        <Row label="Name" value={ship.name} />
        <Row label="Hull" value={hull?.name ?? ship.hull_type_id} />
        <Row label="Status" value={statusLabel} />
        <Row label="Readiness (HP)" value={`${ship.hp} / ${ship.max_hp}`} />
        {destination && <Row label="Destination" value={destination} />}
        {countdown && <Row label="Arriving in" value={countdown} />}
      </dl>

      {progress !== null && <Meter pct={progress * 100} tone="accent" className="mt-3 h-1.5" />}
    </Card>
  )
}

function Row({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="text-ink-faint">{label}</dt>
      <dd className="text-right text-ink">{value}</dd>
    </div>
  )
}
