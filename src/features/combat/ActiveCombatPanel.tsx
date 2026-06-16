import { useEffect, useState } from 'react'
import type { UnitType } from '../../lib/catalog'
import type { FleetUnit } from '../fleets/fleetTypes'
import { CombatEventLayer } from './CombatEventLayer'
import { requestRetreat } from './combatApi'
import type { CombatEncounter, CombatEvent, CombatTick } from './combatTypes'

// Display-only combat panel. All values are server-authoritative; the only action
// is the Retreat request. Integrity bars + latest-exchange summary make the fight
// readable without the client computing anything.
export function ActiveCombatPanel({
  encounter,
  locationName,
  fleetUnits,
  unitTypes,
  events,
  ticks,
  retreatDelaySeconds,
  onChanged,
}: {
  encounter: CombatEncounter
  locationName: string
  fleetUnits: FleetUnit[]
  unitTypes: UnitType[]
  events: CombatEvent[]
  ticks: CombatTick[]
  retreatDelaySeconds: number
  onChanged: () => void
}) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [])

  const retreating = encounter.status === 'retreating'
  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  const survivors = fleetUnits.filter((u) => u.quantity > 0)
  const rewards = Object.entries(encounter.total_rewards_json ?? {})

  const playerPct = encounter.player_integrity_max > 0
    ? (encounter.player_integrity_current / encounter.player_integrity_max) * 100 : 0
  const enemyPct = encounter.enemy_integrity_max > 0
    ? (encounter.enemy_integrity_current / encounter.enemy_integrity_max) * 100 : 0

  const latest = ticks.slice().sort((a, b) => b.tick_number - a.tick_number)[0]
  const lossText = (j: Record<string, number>) => {
    const e = Object.entries(j ?? {}).filter(([, v]) => v > 0)
    return e.length ? `Lost: ${e.map(([k, v]) => `${v} ${typeName(k)}`).join(', ')}` : 'Hull damaged, no ships destroyed.'
  }

  let retreatLeft = 0
  if (retreating && encounter.retreat_started_at) {
    retreatLeft = Math.ceil(retreatDelaySeconds - (now - new Date(encounter.retreat_started_at).getTime()) / 1000)
  }

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
        <p className="mb-4 rounded-lg border border-amber-400/30 bg-amber-400/10 px-3 py-2 text-xs text-amber-200">
          Retreating — escaping in {retreatLeft > 0 ? `${retreatLeft}s` : 'a moment…'}. Warning: the
          fleet can still take damage during retreat (server decides the outcome).
        </p>
      )}
      {error && <p className="mb-3 text-sm text-red-400">{error}</p>}

      {/* Integrity bars */}
      <div className="mb-5 space-y-3">
        <IntegrityBar
          label="Fleet integrity"
          pct={playerPct}
          current={encounter.player_integrity_current}
          max={encounter.player_integrity_max}
          color="bg-indigo-400"
        />
        <IntegrityBar
          label="Pirate wave"
          pct={enemyPct}
          current={encounter.enemy_integrity_current}
          max={encounter.enemy_integrity_max}
          color="bg-red-400"
          emptyLabel="incoming…"
        />
      </div>

      {/* Latest exchange */}
      {latest && (
        <div className="mb-5 rounded-lg border border-white/10 bg-black/20 p-3 text-sm">
          <h4 className="mb-1 text-[10px] uppercase tracking-wide text-white/35">Latest exchange (tick {latest.tick_number})</h4>
          <p className="text-white/70">You dealt <span className="text-indigo-300">{Math.round(latest.player_damage)}</span> damage.</p>
          <p className="text-white/70">Pirates dealt <span className="text-red-300">{Math.round(latest.enemy_damage)}</span> damage.</p>
          <p className="text-white/55">{lossText(latest.player_losses_json)}</p>
        </div>
      )}

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
          <h4 className="mb-2 mt-4 text-[10px] uppercase tracking-wide text-white/35">
            Pending rewards {retreating && <span className="text-amber-300/70">(locked)</span>}
          </h4>
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
                <th className="pr-3">tick</th><th className="pr-3">danger</th>
                <th className="pr-3">dmg→pirate</th><th className="pr-3">dmg→you</th>
                <th className="pr-3">your hull</th><th className="pr-3">result</th>
              </tr>
            </thead>
            <tbody>
              {ticks.slice().sort((a, b) => b.tick_number - a.tick_number).slice(0, 8).map((t) => (
                <tr key={t.id}>
                  <td className="pr-3 tabular-nums">{t.tick_number}</td>
                  <td className="pr-3 tabular-nums">{t.danger_level}</td>
                  <td className="pr-3 tabular-nums">{Math.round(t.player_damage)}</td>
                  <td className="pr-3 tabular-nums">{Math.round(t.enemy_damage)}</td>
                  <td className="pr-3 tabular-nums">{Math.round(t.player_integrity_after)}</td>
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

function IntegrityBar({
  label, pct, current, max, color, emptyLabel,
}: {
  label: string
  pct: number
  current: number
  max: number
  color: string
  emptyLabel?: string
}) {
  const clamped = Math.max(0, Math.min(100, pct))
  return (
    <div>
      <div className="mb-1 flex items-baseline justify-between text-xs">
        <span className="text-white/60">{label}</span>
        {max > 0 ? (
          <span className="tabular-nums text-white/45">
            {clamped.toFixed(0)}% · {Math.round(current).toLocaleString()} / {Math.round(max).toLocaleString()}
          </span>
        ) : (
          <span className="text-white/30">{emptyLabel ?? '—'}</span>
        )}
      </div>
      <div className="h-2 w-full overflow-hidden rounded bg-white/10">
        <div className={`h-full ${color} transition-all duration-300`} style={{ width: `${clamped}%` }} />
      </div>
    </div>
  )
}
