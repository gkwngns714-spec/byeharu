// COMBAT — the MAP-SIDE combat readout. The fight is a thing happening in SPACE, so its status
// belongs on the map beside the fleet doing it, not only on the Command screen (ActiveCombatPanel
// stays exactly as it is — this is a second VIEW of the same server rows, never a second source).
//
// PURE PRESENTATION. Every number here is read straight off combat_encounters / combat_units, which
// the database owns. This component computes NO combat math: no damage, no hit chance, no power
// derivation, no outcome prediction. It formats what the server already decided. If a value the
// player should see is missing, the fix is a server column — never an approximation here.
//
// Mounted from MapScreen over the already-polled `combat` state (useCombat, ~1.5s = the tick
// cadence), so it needs no new fetch and no new poll.
import type { CombatEncounter, CombatUnit } from '../combat/combatTypes'
import { selectCombatPhase, nextWaveText } from '../combat/combatPhase'
import { OverlayPanel } from '../../components/ui'

/** One side's live standing, as the server reports it. */
function SideBar({
  label,
  power,
  integrity,
  integrityMax,
  tone,
  units,
}: {
  label: string
  power: number
  integrity: number
  integrityMax: number
  tone: 'accent' | 'danger'
  units: number | null
}) {
  // integrity_max can legitimately be 0 on a degenerate row — guard rather than render NaN%.
  const pct = integrityMax > 0 ? Math.max(0, Math.min(1, integrity / integrityMax)) : 0
  const color = tone === 'danger' ? 'var(--color-danger)' : 'var(--color-accent)'
  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-xs font-semibold uppercase tracking-wide" style={{ color }}>
          {label}
        </span>
        <span className="text-xs text-ink-muted">
          {units === null ? '' : `${units} ship${units === 1 ? '' : 's'} · `}
          Power {Math.round(power)}
        </span>
      </div>
      <div className="h-1.5 w-full overflow-hidden rounded-full bg-surface-2">
        <div
          className="h-full rounded-full transition-[width] duration-500"
          style={{ width: `${pct * 100}%`, background: color }}
        />
      </div>
      {/* "Hull" — the word the ship meters already use; "integrity" was an engine noun. */}
      <div className="text-[11px] text-ink-faint">
        Hull {Math.round(integrity)} / {Math.round(integrityMax)}
      </div>
    </div>
  )
}

/** The map's live combat card. Renders nothing when no encounter is active — a clean map is the
 *  default (map-UX law #1); combat summons this, exactly like every other panel. */
export function CombatMapCard({
  encounters,
  units,
}: {
  encounters: readonly CombatEncounter[]
  units: readonly CombatUnit[]
}) {
  // 'active' and 'retreating' are both LIVE: a retreating fleet is still taking fire, and hiding the
  // card at that moment removes the readout exactly when the player most needs it.
  const live = encounters.filter((e) => e.status === 'active' || e.status === 'retreating')
  if (live.length === 0) return null

  return (
    <div className="pointer-events-auto flex flex-col gap-2">
      {live.map((e) => {
        const mine = units.filter((u) => u.encounter_id === e.id && u.side === 'player')
        const theirs = units.filter((u) => u.encounter_id === e.id && u.side === 'enemy')
        // A unit row is a STACK (alive_count), so ship count is the sum, not the row count.
        const aliveOf = (rows: readonly CombatUnit[]) =>
          rows.length === 0 ? null : rows.reduce((n, u) => n + (u.alive_count ?? 0), 0)
        // Positions exist only for spatially-created encounters; say so plainly rather than leaving
        // the player wondering why the map shows no ships for a fight that is clearly happening.
        const spatial = mine.some((u) => u.pos_x !== null && u.pos_x !== undefined)
        // The SAME phase the Command panel shows, from the one shared selector — never re-derived
        // here. Between waves the server has already zeroed the whole enemy side, so those numbers
        // are placeholders and the card must say what is happening instead of printing them.
        const phase = selectCombatPhase(e)

        return (
          // The ONE overlay chrome (OverlayPanel, danger tone) — this card was one of three
          // hand-rolled skins on the map; "tick" (a server-internal unit) no longer prints.
          <OverlayPanel key={e.id} tone="danger" className="w-64" data-testid={`combat-map-card-${e.id}`}>
            <div className="mb-2 flex items-center justify-between">
              <span className="text-xs font-semibold uppercase tracking-wide text-danger">
                {phase.label}
              </span>
              <span className="text-[11px] text-ink-faint">Wave {e.wave_number}</span>
            </div>

            <div className="flex flex-col gap-2.5">
              <SideBar
                label="Your fleet"
                power={e.player_power_current}
                integrity={e.player_integrity_current}
                integrityMax={e.player_integrity_max}
                tone="accent"
                units={aliveOf(mine)}
              />
              {phase.betweenWaves ? (
                <div className="flex flex-col gap-1">
                  <span className="text-xs font-semibold uppercase tracking-wide text-danger">
                    Enemy
                  </span>
                  {/* null = no countdown here on purpose: this is a 256px corner readout and a
                      second-by-second number is noise. The Command panel carries the countdown. */}
                  <p className="text-[11px] text-warning">{nextWaveText(null)}</p>
                </div>
              ) : (
                <SideBar
                  label="Enemy"
                  power={e.enemy_power_current}
                  integrity={e.enemy_integrity_current}
                  integrityMax={e.enemy_integrity_max}
                  tone="danger"
                  units={aliveOf(theirs)}
                />
              )}
            </div>

            {!spatial && (
              <p className="mt-2 text-[11px] text-warning">
                This battle has no ship positions, so nothing is drawn on the map for it.
              </p>
            )}
          </OverlayPanel>
        )
      })}
    </div>
  )
}
