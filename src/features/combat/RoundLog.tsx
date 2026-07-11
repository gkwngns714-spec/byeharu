import type { ReactNode } from 'react'
import type { UnitType } from '../../lib/catalog'
import { formatShortTime } from '../../lib/time'
import type { CombatTick } from './combatTypes'
import { combatUnitLabel } from './combatLabels'

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
  // Slice D4: player_losses_json keys are coalesce(unit_type_id, main_ship_id::text) since D1 —
  // resolved by the ONE combatUnitLabel helper (catalog name first, uuid-shaped member key → "Team
  // ship" label). Data-dark today (member rows have no prod writer) → legacy output byte-identical.
  const typeName = (id: string) => combatUnitLabel(id, unitTypes)
  const lossText = (j: Record<string, number>) =>
    Object.entries(j ?? {})
      .filter(([, v]) => v > 0)
      .map(([k, v]) => `${v} ${typeName(k)}`)
      .join(', ')

  const ordered = ticks.slice().sort((a, b) => b.tick_number - a.tick_number).slice(0, limit)
  if (ordered.length === 0) return <p className="text-sm text-ink-faint">No rounds yet.</p>

  return (
    <ol className="space-y-1.5">
      {ordered.map((t) => {
        const losses = lossText(t.player_losses_json)
        const metal = t.reward_delta_json?.metal ?? 0
        let line: ReactNode

        if (t.result === 'next_wave_incoming') {
          line = <span className="text-warning/80">Wave {t.wave_number} incoming…</span>
        } else if (t.result === 'wave_cleared') {
          line = (
            <span>
              <span className="text-success">Wave {t.wave_number} cleared.</span> You dealt{' '}
              {/* UI R4: damage numerals in mono (ops telemetry) — rendered text unchanged. */}
              <span className="font-mono tabular-nums">{Math.round(t.player_damage)}</span> damage
              {metal > 0 && <span className="text-warning/90"> · +{metal} metal pending</span>}
              {losses && <> · lost {losses}</>}
            </span>
          )
        } else if (t.result === 'escaped' || t.result === 'completed') {
          line = <span className="text-warning">Fleet escaped — returning to base.</span>
        } else if (t.result === 'defeat') {
          line = <span className="text-danger">Fleet destroyed.</span>
        } else {
          // 'ongoing'
          line = (
            <span>
              Wave {t.wave_number}: you dealt <span className="font-mono tabular-nums text-accent">{Math.round(t.player_damage)}</span>,
              pirates dealt <span className="font-mono tabular-nums text-danger">{Math.round(t.enemy_damage)}</span>
              {losses ? <> · lost {losses}</> : ' · no ships lost'}
            </span>
          )
        }

        return (
          <li key={t.id} className="flex gap-2 text-xs text-ink-muted">
            <span className="font-mono tabular-nums text-ink-faint/80">
              #{t.tick_number} · {formatShortTime(t.resolved_at)}
            </span>
            <span>{line}</span>
          </li>
        )
      })}
    </ol>
  )
}
