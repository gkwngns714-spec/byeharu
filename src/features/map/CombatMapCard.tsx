// COMBAT — the MAP-SIDE combat readout. The fight is a thing happening in SPACE, so its status
// belongs on the map beside the fleet doing it, not only on the Mission screen (ActiveCombatPanel
// stays exactly as it is — this is a second VIEW of the same server rows, never a second source).
//
// PURE PRESENTATION. Every number here is read straight off combat_encounters / combat_units /
// combat_ticks, which the database owns. This component computes NO combat math: no damage, no hit
// chance, no power derivation, no outcome prediction. It formats what the server already decided. If
// a value the player should see is missing, the fix is a server column — never an approximation here.
//
// ── WHAT THIS CARD USED TO SAY, AND WHY IT WAS A LIE ───────────────────────────────────────────────
// It labelled BOTH sides "Power" and printed `player_power_current` against `enemy_power_current`.
// Those are not the same quantity. `player_power_current` is the fleet's attack power
// (combat_encounter_side_power, 0299:272-280); `enemy_power_current` is the enemy's REMAINING
// INTEGRITY — 0299's own header says so and explains why it was deliberately NOT repointed
// (:150-156), because every synthetic pirate row is anchored to a unit_type whose power_score is a
// dummy 0. Verified on production: on every live row `enemy_power_current` equals
// `enemy_integrity_current` exactly. So a first fight read "Your fleet · Power 15" against
// "Enemy · Power 312" while the player was out-damaging them two to one, and the one number the
// card existed to give — "am I winning?" — pointed the wrong way.
//
// The fix is not a better label for a number nobody can act on. Both sides now show the SAME
// quantity, the one both sides genuinely have and both bars were already drawing: REMAINING HULL,
// with the ship count beside it. That is the RS3 read — two health bars — and it is answerable at a
// glance. Underneath it sits the LAST EXCHANGE from combat_ticks (which now carry live data, since
// combat_tick_logging was lit): how much you dealt and how much you took in the same three seconds,
// which is the other half of "am I winning" and the half a static bar cannot show.
//
// Mounted from MapScreen over the already-polled `combat` state (useCombat, ~1.5s = the tick
// cadence), so it needs no new fetch and no new poll.
import type { CombatEncounter, CombatTick, CombatUnit } from '../combat/combatTypes'
import { selectCombatPhase, nextWaveText } from '../combat/combatPhase'
import { resolveAutoExitLine, type AutoExitSetting } from '../combat/autoExitLine'
import { RetreatControl } from '../combat/RetreatControl'
import { OverlayPanel } from '../../components/ui'

/** One side's live standing, as the server reports it: how many ships are still up and how much
 *  hull they have left. NO "power" — see the header for why the two sides' power columns were never
 *  comparable. `line` marks the auto-retreat threshold on the track (player side only). */
function SideBar({
  label,
  integrity,
  integrityMax,
  tone,
  units,
  line = null,
  testId,
}: {
  label: string
  integrity: number
  integrityMax: number
  tone: 'accent' | 'danger'
  units: number | null
  line?: number | null
  testId: string
}) {
  // integrity_max can legitimately be 0 on a degenerate row — guard rather than render NaN%.
  const pct = integrityMax > 0 ? Math.max(0, Math.min(1, integrity / integrityMax)) : 0
  const color = tone === 'danger' ? 'var(--color-danger)' : 'var(--color-accent)'
  return (
    <div className="flex flex-col gap-1" data-testid={testId}>
      <div className="flex items-baseline justify-between gap-3">
        <span className="text-xs font-semibold uppercase tracking-wide" style={{ color }}>
          {label}
        </span>
        <span className="text-xs text-ink-muted">
          {units === null ? '' : `${units} ship${units === 1 ? '' : 's'} · `}
          <span className="font-mono tabular-nums">{Math.round(pct * 100)}%</span>
        </span>
      </div>
      <div className="relative h-2 w-full overflow-hidden rounded-full bg-surface-2">
        <div
          className="h-full rounded-full transition-[width] duration-500"
          style={{ width: `${pct * 100}%`, background: color }}
        />
        {/* THE SAFETY LINE, ON THE BAR. A sentence saying "auto-retreat at 30%" is a fact to
            remember; a mark on the track is a distance you can see closing. */}
        {line !== null && (
          <span
            data-testid={`${testId}-auto-exit-mark`}
            className="absolute top-0 h-full w-0.5 bg-warning"
            style={{ left: `${line * 100}%` }}
          />
        )}
      </div>
      {/* "Hull" — the word the ship meters already use; "integrity" was an engine noun. */}
      <div className="text-[11px] text-ink-faint">
        Hull <span className="font-mono tabular-nums">{Math.round(integrity)}</span> /{' '}
        <span className="font-mono tabular-nums">{Math.round(integrityMax)}</span>
      </div>
    </div>
  )
}

/** The map's live combat card. Renders nothing when no encounter is active — a clean map is the
 *  default (map-UX law #1); combat summons this, exactly like every other panel. */
export function CombatMapCard({
  encounters,
  units,
  ticks,
  autoExit,
  onChanged,
}: {
  encounters: readonly CombatEncounter[]
  units: readonly CombatUnit[]
  /** the shell's already-polled combat_ticks — the authoritative per-exchange log. [] → the last
   *  exchange line simply does not render (never an invented number). */
  ticks?: readonly CombatTick[]
  /** the 0310 safety line per ENCOUNTER (combatApi.fetchAutoExitByEncounter). Absent/unknown → the
   *  card says nothing about auto-retreat rather than implying there is none. */
  autoExit?: Record<string, AutoExitSetting>
  /** re-poll after a retreat order lands, so the card shows the new status on the next frame */
  onChanged: () => void
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
        // The SAME phase the Mission panel shows, from the one shared selector — never re-derived
        // here. Between waves the server has already zeroed the whole enemy side, so those numbers
        // are placeholders and the card must say what is happening instead of printing them.
        const phase = selectCombatPhase(e)
        // THE LAST EXCHANGE — this fight's newest real tick. `next_wave_incoming` rows carry no
        // exchange, so they are skipped exactly as the Mission panel skips them (one rule, two
        // surfaces). Scoped to THIS encounter: two simultaneous fights do not share a tick counter.
        const latest = (ticks ?? [])
          .filter((t) => t.encounter_id === e.id && t.result !== 'next_wave_incoming')
          .sort((a, b) => b.tick_number - a.tick_number)[0]
        // THE SAFETY LINE — the ONE derivation (combat/autoExitLine); null when the setting is
        // unknown or the fleet has it off, and then nothing is said about it.
        const exit = resolveAutoExitLine(e, autoExit?.[e.id])

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
                integrity={e.player_integrity_current}
                integrityMax={e.player_integrity_max}
                tone="accent"
                units={aliveOf(mine)}
                line={exit?.frac ?? null}
                testId={`combat-map-side-player-${e.id}`}
              />
              {phase.betweenWaves ? (
                <div className="flex flex-col gap-1">
                  <span className="text-xs font-semibold uppercase tracking-wide text-danger">
                    Enemy
                  </span>
                  {/* null = no countdown here on purpose: this is a 256px corner readout and a
                      second-by-second number is noise. The Mission panel carries the countdown. */}
                  <p className="text-[11px] text-warning">{nextWaveText(null)}</p>
                </div>
              ) : (
                <SideBar
                  label="Enemy"
                  integrity={e.enemy_integrity_current}
                  integrityMax={e.enemy_integrity_max}
                  tone="danger"
                  units={aliveOf(theirs)}
                  testId={`combat-map-side-enemy-${e.id}`}
                />
              )}
            </div>

            {/* WHO IS WINNING THIS EXCHANGE — the server's own per-tick damage totals, both ways,
                from the same three seconds. Two static bars cannot show a rate; this can. */}
            {latest && (
              <p className="mt-2 text-[11px] text-ink-muted" data-testid={`combat-map-exchange-${e.id}`}>
                Last exchange · you dealt{' '}
                <span className="font-mono tabular-nums text-accent">{Math.round(latest.player_damage)}</span>
                {' · '}took{' '}
                <span className="font-mono tabular-nums text-danger">{Math.round(latest.enemy_damage)}</span>
              </p>
            )}

            {/* THE SAFETY LINE, IN WORDS. It decided real production fights silently; a fleet that
                enters already under its threshold pulls out on tick 1 (0310:423-425). */}
            {exit && (
              <p
                data-testid={`combat-map-auto-exit-${e.id}`}
                className={`mt-1 text-[11px] ${exit.reached || exit.close ? 'text-warning' : 'text-ink-faint'}`}
              >
                {exit.text}
              </p>
            )}

            {!spatial && (
              <p className="mt-2 text-[11px] text-warning">
                This battle has no ship positions, so nothing is drawn on the map for it.
              </p>
            )}

            {/* LEAVING IS ONE CLICK, ON THE SCREEN THAT SHOWS THE FIGHT — the ONE retreat control
                (combat/RetreatControl), the same component the Mission panel mounts. */}
            <RetreatControl
              presenceId={e.presence_id}
              retreating={phase.isRetreating}
              onChanged={onChanged}
              className="mt-3"
              testId={`combat-map-retreat-${e.id}`}
            />
          </OverlayPanel>
        )
      })}
    </div>
  )
}
