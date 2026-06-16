import { useState } from 'react'
import type { UnitType } from '../../lib/catalog'
import type { FleetUnit } from '../fleets/fleetTypes'
import { CombatEventLayer } from './CombatEventLayer'
import { requestRetreat } from './combatApi'
import type { CombatEncounter, CombatEvent, CombatTick } from './combatTypes'

// Display-only combat panel for one active encounter. The Retreat button is the
// only action; everything else mirrors server state.
export function ActiveCombatPanel({
  encounter,
  locationName,
  fleetUnits,
  unitTypes,
  events,
  ticks,
  onChanged,
}: {
  encounter: CombatEncounter
  locationName: string
  fleetUnits: FleetUnit[]
  unitTypes: UnitType[]
  events: CombatEvent[]
  ticks: CombatTick[]
  onChanged: () => void
}) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const retreating = encounter.status === 'retreating'
  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  const survivors = fleetUnits.filter((u) => u.quantity > 0)
  const rewards = Object.entries(encounter.total_rewards_json ?? {})
  const recentTicks = ticks.slice().sort((a, b) => b.tick_number - a.tick_number).slice(0, 8)

  async function handleRetreat() {
    setBusy(true)
    setError(null)
    try {
      await requestRetreat(encounter.presence_id)
      onChanged()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="rounded-2xl border border-red-500/20 bg-red-500/[0.04] p-6">
      <div className="mb-4 flex items-start justify-between">
        <div>
          <h2 className="text-lg font-medium text-red-200">⚔️ Combat — {locationName}</h2>
          <p className="text-sm text-white/45">
            danger <span className="text-white/80">{encounter.danger_level}</span> · waves cleared{' '}
            <span className="text-white/80">{encounter.waves_cleared}</span> · {encounter.status}
          </p>
        </div>
        <button
          onClick={handleRetreat}
          disabled={busy || retreating}
          className="rounded-lg bg-amber-500/90 px-3 py-1.5 text-sm font-medium text-black transition hover:bg-amber-400 disabled:opacity-50"
        >
          {retreating ? 'Retreating…' : busy ? 'Working…' : 'Retreat'}
        </button>
      </div>
      {retreating && (
        <p className="mb-3 text-xs text-amber-300/80">
          Retreat ordered — fleet still takes fire until it breaks away (server decides).
        </p>
      )}
      {error && <p className="mb-3 text-sm text-red-400">{error}</p>}

      <div className="grid gap-6 sm:grid-cols-2">
        <div>
          <h4 className="mb-2 text-[10px] uppercase tracking-wide text-white/35">Surviving units</h4>
          <ul className="space-y-1 text-sm">
            {survivors.length === 0 && <li className="text-white/40">none</li>}
            {survivors.map((u) => (
              <li key={u.id} className="flex justify-between">
                <span className="text-white/70">{typeName(u.unit_type_id)}</span>
                <span className="tabular-nums">{u.quantity}</span>
              </li>
            ))}
          </ul>

          <h4 className="mb-2 mt-4 text-[10px] uppercase tracking-wide text-white/35">Pending rewards</h4>
          <ul className="space-y-1 text-sm">
            {rewards.length === 0 && <li className="text-white/40">none yet</li>}
            {rewards.map(([code, amt]) => (
              <li key={code} className="flex justify-between">
                <span className="capitalize text-white/70">{code}</span>
                <span className="tabular-nums">{amt}</span>
              </li>
            ))}
          </ul>
        </div>

        <CombatEventLayer events={events} />
      </div>

      <details className="mt-4">
        <summary className="cursor-pointer text-[10px] uppercase tracking-wide text-white/35">
          combat_ticks (debug log)
        </summary>
        <div className="mt-2 overflow-x-auto">
          <table className="w-full text-left text-[11px] text-white/50">
            <thead className="text-white/30">
              <tr>
                <th className="pr-3">tick</th>
                <th className="pr-3">danger</th>
                <th className="pr-3">dmg→pirate</th>
                <th className="pr-3">dmg→you</th>
                <th className="pr-3">result</th>
              </tr>
            </thead>
            <tbody>
              {recentTicks.map((t) => (
                <tr key={t.id}>
                  <td className="pr-3 tabular-nums">{t.tick_number}</td>
                  <td className="pr-3 tabular-nums">{t.danger_level}</td>
                  <td className="pr-3 tabular-nums">{Math.round(t.player_damage)}</td>
                  <td className="pr-3 tabular-nums">{Math.round(t.enemy_damage)}</td>
                  <td className="pr-3">{t.result}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </section>
  )
}
