import { useEffect, useState } from 'react'
import type { UnitType } from '../../lib/catalog'
import { CombatEventLayer } from './CombatEventLayer'
import { requestRetreat } from './combatApi'
import type { CombatEncounter, CombatEvent, CombatTick, CombatUnit } from './combatTypes'

// Display-only combat panel. All values are server-authoritative; the only action
// is the Retreat request. Shows total + per-unit-type integrity, the pirate wave,
// the latest exchange, the battle feed, and a debug tick log.
export function ActiveCombatPanel({
  encounter,
  locationName,
  units,
  unitTypes,
  events,
  ticks,
  retreatDelaySeconds,
  onChanged,
}: {
  encounter: CombatEncounter
  locationName: string
  units: CombatUnit[]
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
  const rewards = Object.entries(encounter.total_rewards_json ?? {})

  const playerPct = encounter.player_integrity_max > 0
    ? (encounter.player_integrity_current / encounter.player_integrity_max) * 100 : 0
  const enemyPct = encounter.enemy_integrity_max > 0
    ? (encounter.enemy_integrity_current / encounter.enemy_integrity_max) * 100 : 0

  const waveCleared = encounter.enemy_integrity_current <= 0
  const incomingIn = encounter.next_wave_at
    ? Math.ceil((new Date(encounter.next_wave_at).getTime() - now) / 1000) : 0

  const latest = ticks.slice().sort((a, b) => b.tick_number - a.tick_number).find((t) => t.result !== 'next_wave_incoming')
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
            Wave <span className="text-white/80">{encounter.wave_number}</span> · Danger{' '}
            <span className="text-white/80">{encounter.danger_level}</span> ·{' '}
            <span className="text-white/80">{encounter.waves_cleared}</span> waves cleared ·{' '}
            <span className="text-white/70">
              {retreating ? 'Retreating' : waveCleared ? 'Next wave incoming' : 'In combat'}
            </span>
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
          Retreating — fleet breaks away and heads home in {retreatLeft > 0 ? `${retreatLeft}s` : 'a moment…'}.
          Warning: it can still take damage until it escapes.
        </p>
      )}
      {error && <p className="mb-3 text-sm text-red-400">{error}</p>}

      {/* Fleet (total) + pirate wave */}
      <div className="mb-4 space-y-3">
        <Bar label="Fleet integrity" pct={playerPct} text={`${playerPct.toFixed(0)}% · ${Math.round(encounter.player_integrity_current).toLocaleString()} / ${Math.round(encounter.player_integrity_max).toLocaleString()}`} color="bg-indigo-400" />
        {waveCleared ? (
          <div>
            <div className="mb-1 text-xs text-white/60">Pirate wave</div>
            <p className="text-xs text-amber-300/80">
              {incomingIn > 0 ? `Next wave incoming in ${incomingIn}s…` : 'Next wave incoming…'}
            </p>
          </div>
        ) : (
          <Bar label={`Pirate wave ${encounter.wave_number}`} pct={enemyPct}
            text={`${enemyPct.toFixed(0)}% · ${Math.round(encounter.enemy_integrity_current).toLocaleString()} / ${Math.round(encounter.enemy_integrity_max).toLocaleString()}`}
            color="bg-red-400" />
        )}
      </div>

      {/* Per-unit-type integrity */}
      <div className="mb-4">
        <h4 className="mb-2 text-[10px] uppercase tracking-wide text-white/35">Fleet units</h4>
        <div className="space-y-2">
          {units.length === 0 && <p className="text-sm text-white/40">no units</p>}
          {units.slice().sort((a, b) => a.unit_type_id.localeCompare(b.unit_type_id)).map((u) => {
            const pct = u.hp_max > 0 ? (u.hp_current / u.hp_max) * 100 : 0
            const lost = u.initial_count - u.alive_count
            return (
              <Bar
                key={u.id}
                label={`${typeName(u.unit_type_id)} — ${u.alive_count}/${u.initial_count} ships${lost > 0 ? ` (${lost} lost)` : ''}`}
                pct={pct}
                text={`${pct.toFixed(0)}% · ${Math.round(u.hp_current)}/${Math.round(u.hp_max)} HP`}
                color={u.alive_count === 0 ? 'bg-white/20' : 'bg-emerald-400'}
              />
            )
          })}
        </div>
      </div>

      {/* Latest exchange */}
      {latest && (
        <div className="mb-4 rounded-lg border border-white/10 bg-black/20 p-3 text-sm">
          <h4 className="mb-1 text-[10px] uppercase tracking-wide text-white/35">Latest exchange (tick {latest.tick_number})</h4>
          {retreating ? (
            <>
              <p className="text-amber-200/80">Your fleet is retreating — weapons disengaged.</p>
              <p className="text-white/70">Pirates dealt <span className="text-red-300">{Math.round(latest.enemy_damage)}</span> damage during disengagement.</p>
            </>
          ) : (
            <>
              <p className="text-white/70">You dealt <span className="text-indigo-300">{Math.round(latest.player_damage)}</span> damage to the wave.</p>
              <p className="text-white/70">Pirates dealt <span className="text-red-300">{Math.round(latest.enemy_damage)}</span> damage.</p>
            </>
          )}
          <p className="text-white/55">{lossText(latest.player_losses_json)}</p>
        </div>
      )}

      <div className="mb-1">
        <h4 className="mb-2 text-[10px] uppercase tracking-wide text-white/35">
          Pending rewards {retreating && <span className="text-amber-300/70">(locked)</span>}
        </h4>
        <p className="text-sm">
          {rewards.length === 0 ? <span className="text-white/40">none yet</span>
            : rewards.map(([code, amt]) => <span key={code} className="mr-3 capitalize text-white/70">{code}: {amt}</span>)}
        </p>
        <p className="mt-1 text-[11px] text-white/35">
          {retreating
            ? 'Locked — secured only after your fleet returns to base.'
            : 'Pending — secured only after your fleet returns to base (lost if destroyed).'}
        </p>
      </div>

      <div className="mt-4">
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
                <th className="pr-3">tick</th><th className="pr-3">wave</th><th className="pr-3">danger</th>
                <th className="pr-3">→wave</th><th className="pr-3">wave HP</th>
                <th className="pr-3">→you</th><th className="pr-3">your HP</th><th className="pr-3">result</th>
              </tr>
            </thead>
            <tbody>
              {ticks.slice().sort((a, b) => b.tick_number - a.tick_number).slice(0, 10).map((t) => (
                <tr key={t.id}>
                  <td className="pr-3 tabular-nums">{t.tick_number}</td>
                  <td className="pr-3 tabular-nums">{t.wave_number}</td>
                  <td className="pr-3 tabular-nums">{t.danger_level}</td>
                  <td className="pr-3 tabular-nums">{Math.round(t.player_damage)}</td>
                  <td className="pr-3 tabular-nums">{Math.round(t.enemy_integrity_before)}→{Math.round(t.enemy_integrity_after)}</td>
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

function Bar({ label, pct, text, color }: { label: string; pct: number; text: string; color: string }) {
  const clamped = Math.max(0, Math.min(100, pct))
  return (
    <div>
      <div className="mb-1 flex items-baseline justify-between text-xs">
        <span className="text-white/60">{label}</span>
        <span className="tabular-nums text-white/45">{text}</span>
      </div>
      <div className="h-2 w-full overflow-hidden rounded bg-white/10">
        <div className={`h-full ${color} transition-all duration-300`} style={{ width: `${clamped}%` }} />
      </div>
    </div>
  )
}
