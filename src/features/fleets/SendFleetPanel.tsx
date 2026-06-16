import { useMemo, useState } from 'react'
import type { UnitType } from '../../lib/catalog'
import type { Base, BaseUnit } from '../base/baseTypes'
import type { MapLocation } from '../map/mapTypes'
import { distance, previewTravelSeconds, slowestSpeed } from '../../game/movement/travelPreview'
import { sendFleetToLocation, type SelectedUnit } from './fleetApi'

// Lets the player pick a SAFE location + unit quantities and dispatch a fleet.
// Shows a client-side ETA PREVIEW only; the server decides the real travel time.
export function SendFleetPanel({
  base,
  units,
  unitTypes,
  locations,
  onSent,
}: {
  base: Base
  units: BaseUnit[]
  unitTypes: UnitType[]
  locations: MapLocation[]
  onSent: () => void
}) {
  // Dispatchable locations: safe zones (activity 'none') and pirate hunts (M4).
  const destinations = useMemo(
    () => locations.filter((l) => l.activity_type === 'none' || l.activity_type === 'hunt_pirates'),
    [locations],
  )

  const [locationId, setLocationId] = useState('')
  const [qty, setQty] = useState<Record<string, number>>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const availableOf = (typeId: string) => units.find((u) => u.unit_type_id === typeId)?.quantity ?? 0
  const speedOf = (typeId: string) => unitTypes.find((t) => t.id === typeId)?.speed ?? 0

  const selected: SelectedUnit[] = Object.entries(qty)
    .filter(([, q]) => q > 0)
    .map(([unit_type_id, quantity]) => ({ unit_type_id, quantity }))

  const totalSelected = selected.reduce((n, s) => n + s.quantity, 0)
  const location = destinations.find((l) => l.id === locationId)
  const isHunt = location?.activity_type === 'hunt_pirates'

  // Preview only (not authoritative).
  const previewEta = useMemo(() => {
    if (!location || totalSelected === 0) return null
    const speed = slowestSpeed(selected.map((s) => ({ speed: speedOf(s.unit_type_id), quantity: s.quantity })))
    const dist = distance(base.x, base.y, location.x, location.y)
    return Math.round(previewTravelSeconds(dist, speed))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location, totalSelected, qty])

  const tooMany = selected.some((s) => s.quantity > availableOf(s.unit_type_id))
  const canSend = !!location && totalSelected > 0 && !tooMany && !busy

  async function handleSend() {
    if (!location) return
    setBusy(true)
    setError(null)
    try {
      await sendFleetToLocation(base.id, location.id, selected)
      setQty({})
      setLocationId('')
      onSent()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl border border-white/10 bg-white/5 p-6">
      <h2 className="mb-4 text-lg font-medium">Send a fleet</h2>

      <label className="mb-1 block text-xs uppercase tracking-wide text-white/40">Destination</label>
      <select
        value={locationId}
        onChange={(e) => setLocationId(e.target.value)}
        className="mb-2 w-full rounded-lg border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-indigo-400"
      >
        <option value="">Choose a location…</option>
        {destinations.map((l) => (
          <option key={l.id} value={l.id}>
            {l.location_type === 'pirate_hunt'
              ? `⚔️ ${l.name} (hunt · difficulty ${l.base_difficulty})`
              : `🛡️ ${l.name} (safe)`}
          </option>
        ))}
      </select>
      {isHunt && (
        <p className="mb-4 text-xs text-red-300/80">
          Combat begins automatically on arrival. Retreat when you want to bank rewards —
          the longer you stay, the stronger the waves.
        </p>
      )}

      <label className="mb-1 block text-xs uppercase tracking-wide text-white/40">Units</label>
      <div className="space-y-2">
        {units
          .slice()
          .sort((a, b) => a.unit_type_id.localeCompare(b.unit_type_id))
          .map((u) => {
            const name = unitTypes.find((t) => t.id === u.unit_type_id)?.name ?? u.unit_type_id
            const val = qty[u.unit_type_id] ?? 0
            const over = val > u.quantity
            return (
              <div key={u.id} className="flex items-center gap-3">
                <span className="w-24 text-sm text-white/70">{name}</span>
                <input
                  type="number"
                  min={0}
                  max={u.quantity}
                  value={val || ''}
                  placeholder="0"
                  onChange={(e) =>
                    setQty((q) => ({ ...q, [u.unit_type_id]: Math.max(0, Number(e.target.value) || 0) }))
                  }
                  className={
                    'w-24 rounded-lg border bg-black/30 px-2 py-1 text-sm outline-none ' +
                    (over ? 'border-red-500' : 'border-white/10 focus:border-indigo-400')
                  }
                />
                <span className="text-xs text-white/35">/ {u.quantity} available</span>
              </div>
            )
          })}
      </div>

      {location && totalSelected > 0 && (
        <p className="mt-4 text-xs text-white/45">
          Preview ETA ≈ <span className="text-white/70">{previewEta}s</span> to {location.name}{' '}
          <span className="text-white/30">(server decides the real time)</span>
        </p>
      )}
      {tooMany && <p className="mt-2 text-sm text-red-400">Not enough units available.</p>}
      {error && <p className="mt-2 text-sm text-red-400">{error}</p>}

      <button
        onClick={handleSend}
        disabled={!canSend}
        className="mt-4 rounded-lg bg-indigo-500 px-4 py-2 text-sm font-medium text-white transition hover:bg-indigo-400 disabled:opacity-40"
      >
        {busy ? 'Dispatching…' : 'Send fleet'}
      </button>
    </section>
  )
}
