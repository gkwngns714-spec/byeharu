import type { ReactNode } from 'react'
import type { UnitType } from '../../lib/catalog'
import { formatShortTime } from '../../lib/time'
import type { CombatTick } from './combatTypes'

// M6: player-facing round-by-round log. Built ONLY from real combat_ticks fields
// (player_damage, enemy_damage, wave_number, player_losses_json, reward_delta_json,
// result). No invented damage/losses/wave details; if a tick lacks data, the wording
// simplifies. Newest round first.
export function RoundLog({
  ticks,
  unitTypes,
  limit = 20,
}: {
  ticks: CombatTick[]
  unitTypes: UnitType[]
  limit?: number
}) {
  const typeName = (id: string) => unitTypes.find((t) => t.id === id)?.name ?? id
  const lossText = (j: Record<string, number>) =>
    Object.entries(j ?? {})
      .filter(([, v]) => v > 0)
      .map(([k, v]) => `${v} ${typeName(k)}`)
      .join(', ')

  const ordered = ticks.slice().sort((a, b) => b.tick_number - a.tick_number).slice(0, limit)
  if (ordered.length === 0) return <p className="text-sm text-white/40">No rounds yet.</p>

  return (
    <ol className="space-y-1.5">
      {ordered.map((t) => {
        const losses = lossText(t.player_losses_json)
        const metal = t.reward_delta_json?.metal ?? 0
        let line: ReactNode

        if (t.result === 'next_wave_incoming') {
          line = <span className="text-amber-300/70">Wave {t.wave_number} incoming…</span>
        } else if (t.result === 'wave_cleared') {
          line = (
            <span>
              <span className="text-emerald-300">Wave {t.wave_number} cleared.</span> You dealt{' '}
              {Math.round(t.player_damage)} damage
              {metal > 0 && <span className="text-amber-300/80"> · +{metal} metal pending</span>}
              {losses && <> · lost {losses}</>}
            </span>
          )
        } else if (t.result === 'escaped' || t.result === 'completed') {
          line = <span className="text-amber-300">Fleet escaped — returning to base.</span>
        } else if (t.result === 'defeat') {
          line = <span className="text-red-300">Fleet destroyed.</span>
        } else {
          // 'ongoing'
          line = (
            <span>
              Wave {t.wave_number}: you dealt <span className="text-indigo-300">{Math.round(t.player_damage)}</span>,
              pirates dealt <span className="text-red-300">{Math.round(t.enemy_damage)}</span>
              {losses ? <> · lost {losses}</> : ' · no ships lost'}
            </span>
          )
        }

        return (
          <li key={t.id} className="flex gap-2 text-xs text-white/60">
            <span className="tabular-nums text-white/30">
              #{t.tick_number} · {formatShortTime(t.resolved_at)}
            </span>
            <span>{line}</span>
          </li>
        )
      })}
    </ol>
  )
}
