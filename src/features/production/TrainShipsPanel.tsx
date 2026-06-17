import { useState } from 'react'
import type { UnitType } from '../../lib/catalog'
import type { Base, BaseResource, BaseUnit } from '../base/baseTypes'
import { formatDuration } from '../../lib/time'
import { previewBuildSeconds, previewMetalCost } from '../../game/production/buildPreview'
import { trainUnits } from './productionApi'

// M7 — player-facing "Train Ships": spend metal to queue ship training. The only
// action is the train_units RPC; cost/time shown here are a PREVIEW (server decides).
export function TrainShipsPanel({
  base,
  units,
  resources,
  unitTypes,
  config,
  onTrained,
}: {
  base: Base
  units: BaseUnit[]
  resources: BaseResource[]
  unitTypes: UnitType[]
  config: Record<string, number>
  onTrained: () => void
}) {
  const [unitTypeId, setUnitTypeId] = useState('')
  const [qty, setQty] = useState(1)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const metal = resources.find((r) => r.resource_code === 'metal')?.amount ?? 0
  const trainable = unitTypes.filter((u) => u.status === 'active')
  const unit = trainable.find((u) => u.id === unitTypeId)
  const cost = previewMetalCost(unit, qty)
  const secs = previewBuildSeconds(unit, qty, config)
  const shipsOf = (id: string) => units.find((u) => u.unit_type_id === id)?.quantity ?? 0
  const affordable = !!unit && cost <= metal
  const canTrain = !!unit && qty > 0 && affordable && !busy

  async function handleTrain() {
    if (!unit) return
    setBusy(true)
    setError(null)
    try {
      await trainUnits(base.id, unit.id, qty)
      onTrained()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl border border-white/10 bg-white/5 p-4 sm:p-6">
      <div className="mb-4 flex items-baseline justify-between">
        <h2 className="text-lg font-medium">Train Ships</h2>
        <span className="text-sm text-white/60">💰 {Math.floor(metal)} metal</span>
      </div>

      <label className="mb-1 block text-xs uppercase tracking-wide text-white/40">Ship</label>
      <select
        value={unitTypeId}
        onChange={(e) => setUnitTypeId(e.target.value)}
        className="mb-3 w-full rounded-lg border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-indigo-400"
      >
        <option value="">Choose a ship…</option>
        {trainable.map((u) => (
          <option key={u.id} value={u.id}>
            {u.name} — {u.metal_cost} metal · {u.build_time_seconds}s each · have {shipsOf(u.id)}
          </option>
        ))}
      </select>

      <label className="mb-1 block text-xs uppercase tracking-wide text-white/40">Quantity</label>
      <input
        type="number"
        min={1}
        value={qty || ''}
        placeholder="1"
        onChange={(e) => setQty(Math.max(1, Number(e.target.value) || 1))}
        className="mb-3 w-28 rounded-lg border border-white/10 bg-black/30 px-2 py-1 text-sm outline-none focus:border-indigo-400"
      />

      {unit && (
        <p className="text-xs text-white/50">
          Cost <span className={affordable ? 'text-white/75' : 'text-red-300'}>{cost} metal</span> · Training time ≈{' '}
          <span className="text-white/75">{formatDuration(secs)}</span>
          {!affordable && <span className="text-red-300"> · Not enough metal</span>}
        </p>
      )}
      {error && <p className="mt-2 text-sm text-red-400">{error}</p>}

      <button
        onClick={handleTrain}
        disabled={!canTrain}
        className="mt-4 rounded-lg bg-indigo-500 px-4 py-2 text-sm font-medium text-white transition hover:bg-indigo-400 disabled:opacity-40"
      >
        {busy ? 'Training…' : 'Train'}
      </button>
    </section>
  )
}
