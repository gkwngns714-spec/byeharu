import { useEffect, useState } from 'react'
import type { CombatEncounter, CombatTick, CombatUnit } from '../combat/combatTypes'
import { selectCombatPhase } from '../combat/combatPhase'
import {
  REINFORCEMENT_LABEL,
  REINFORCEMENT_RULE,
  hasReinforcementClock,
  resolveReinforcement,
} from '../combat/reinforcementClock'
import { HAUL_AT_STAKE, resolveFightHaul } from '../combat/fightHaul'
import type { SiteLootEntry } from '../combat/combatApi'
import { resolveAutoExitLine, type AutoExitSetting } from '../combat/autoExitLine'
import { resolveRepositionCourse } from '../combat/repositionCourse'
import { formatM3, holdMeter, type Hold } from '../inventory/hold'
import { OverlayPanel, overlayAccountClass } from '../../components/ui'
import { ItemChip } from '../../components/items'

// COMBAT — the FIGHT tab's body. The fight is a thing happening in SPACE, so its status belongs on
// the map beside the fleet doing it, not only on the Mission screen (ActiveCombatPanel stays exactly
// as it is — this is a second VIEW of the same server rows, never a second source).
//
// PURE PRESENTATION. Every number here is read straight off combat_encounters / combat_units /
// combat_ticks / get_my_hold / item_types, which the database owns. This component computes NO combat
// math: no damage, no hit chance, no power derivation, no outcome prediction, and — see the wave
// section below — no prediction of whether a ship will arrive. It formats what the server already
// decided. If a value the player should see is missing, the fix is a server column, never an
// approximation here.
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
// glance. Underneath it sits the LAST EXCHANGE from combat_ticks: how much you dealt and how much
// you took in the same three seconds, which is the other half of "am I winning" and the half a static
// bar cannot show.
//
// ── ██ TWO DEAD READS DELETED HERE ██ ─────────────────────────────────────────────────────────────
//   · `Wave {e.wave_number}` in the header. Since 0344 the tick only advances wave_number when the
//     whole field is EMPTIED, which under a reinforcement clock is rare — so it sat on 1 for entire
//     fights while ships kept arriving. It is replaced by the thing that actually moves: how many
//     bodies are standing against the cap the ENGINE stamped.
//   · the `next_wave_at` countdown (`combatPhase.nextWaveText`, now deleted from that module). 0344
//     removed the pause that column paced and left the write in place, so it counted down to a moment
//     at which nothing is scheduled to happen. The pressure clock replaces it — one clock, one leaf,
//     `combat/reinforcementClock.ts`.
//
// ── WHERE IT IS MOUNTED ───────────────────────────────────────────────────────────────────────────
// The map's FIGHT tab (map/MapOverlayTabs), over the already-polled `combat` state (useCombat, ~1.5s
// = the tick cadence), so it needs no new poll. It carries NO control: the ONE RetreatControl is
// pinned in the rail OUTSIDE the tabs, because a way out of a fight that lives behind a fold is a way
// out the player does not have.

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

/** The map's live combat readout. Renders nothing when no encounter is active — a clean map is the
 *  default (map-UX law #1); the FIGHT tab then says so itself. */
export function CombatMapCard({
  encounters,
  units,
  ticks,
  autoExit,
  itemVolumes,
  holds,
  siteLoot,
  nowMs,
}: {
  encounters: readonly CombatEncounter[]
  units: readonly CombatUnit[]
  /** the shell's already-polled combat_ticks — the authoritative per-exchange log. [] → the last
   *  exchange line simply does not render (never an invented number). */
  ticks?: readonly CombatTick[]
  /** the 0310 safety line per ENCOUNTER (combatApi.fetchAutoExitByEncounter). Absent/unknown → the
   *  card says nothing about auto-retreat rather than implying there is none. */
  autoExit?: Record<string, AutoExitSetting>
  /** `item_types.item_id → volume_m3`, from the existing catalog read. Absent → the haul lists what
   *  was won and says nothing about how much room it takes. */
  itemVolumes?: ReadonlyMap<string, number>
  /** encounter id → that fleet's hold, EXACTLY as `get_my_hold` reports it (0333). Never recomputed
   *  here. Absent → no cargo line. */
  holds?: Record<string, Hold>
  /** location id → what that site drops per enemy destroyed (0348 get_site_loot). Absent → the card
   *  says nothing about future drops, which is the honest reading of a failed or missing read. */
  siteLoot?: Record<string, SiteLootEntry[]>
  /** Test seam ONLY: a fixed clock, so a rendered proof asserts an exact countdown instead of racing
   *  one. Absent in the app, where the 1s tick below owns the time. */
  nowMs?: number
}) {
  // 'active' and 'retreating' are both LIVE: a retreating fleet is still taking fire, and hiding the
  // card at that moment removes the readout exactly when the player most needs it.
  const live = encounters.filter((e) => e.status === 'active' || e.status === 'retreating')
  // A 1s clock — the house idiom (FleetStatusPanel/ActiveCombatPanel), and it RUNS ONLY WHEN A
  // COUNTDOWN EXISTS. The wave clock is the only thing on this card that needs the time, so a fight
  // whose row carries no `next_reinforcement_at` (a pre-0344 server) re-renders nobody: exactly the
  // rule the fleet readout states for its ETA — "the tick exists exactly when an ETA does".
  const needsClock = live.some(hasReinforcementClock)
  const [tick, setTick] = useState(() => Date.now())
  useEffect(() => {
    if (!needsClock) return
    const iv = setInterval(() => setTick(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [needsClock])
  const now = nowMs ?? tick

  if (live.length === 0) return null

  return (
    // `min-h-0` so the SQUEEZE reaches the cards: this wrapper is the flex item the rail's reach
    // region shrinks, and a flex item's automatic minimum is its full content unless told otherwise.
    <div className="pointer-events-auto flex min-h-0 shrink-[99] flex-col gap-2">
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
        // here. While the field is empty the server has already zeroed every enemy number on the row,
        // so those are placeholders and the card must say what is happening instead of printing them.
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
        // THE STANDING COURSE — the SAME ONE derivation (combat/repositionCourse) the Mission
        // panel reads, mounted a second time here. Null = no course, and then nothing is said.
        const course = resolveRepositionCourse(e)
        // THE WAVE CLOCK — the ONE pressure derivation. Null on a server that predates 0344/0347,
        // and then this section does not render at all.
        const wave = resolveReinforcement(e, units, e.id, now)
        // THE HAUL — the ONE reward reader, with catalog volumes folded in by the ONE haul leaf.
        const haul = resolveFightHaul(e.total_rewards_json, itemVolumes ?? new Map())
        const hold = holds?.[e.id]
        const meter = hold && hold.ok ? holdMeter(hold) : null
        const drops = e.location_id ? siteLoot?.[e.location_id] : undefined

        return (
          // The ONE overlay chrome (OverlayPanel, danger tone). THE REACH LAW
          // (components/ui/overlayLayout.ts): the whole body is an ACCOUNT — it is information, it
          // scrolls, and it yields room — because this card no longer carries a control at all.
          <OverlayPanel
            key={e.id}
            tone="danger"
            className="flex min-h-[4.75rem] w-64 max-w-full flex-col"
            data-testid={`combat-map-card-${e.id}`}
          >
            <div className={overlayAccountClass('flex-1')}>
            <div className="mb-2 flex items-center justify-between gap-2">
              <span className="text-xs font-semibold uppercase tracking-wide text-danger">
                {phase.label}
              </span>
              {/* HOW FULL THE FIELD IS — the number that actually moves, against the cap the ENGINE
                  stamped on this row (0347). Never recomputed here; absent → nothing printed. */}
              {wave && wave.population !== null && wave.cap !== null && (
                <span className="text-[11px] text-ink-faint" data-testid={`combat-map-field-${e.id}`}>
                  Field{' '}
                  <span className="font-mono tabular-nums text-ink">
                    {wave.population}/{wave.cap}
                  </span>
                </span>
              )}
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
                  <p className="text-[11px] text-warning">The field is clear.</p>
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

            {/* ██ THE NEXT WAVE ██ — the owner's "next wave incoming (wave info)".
                Four facts and a rule, and NOT a prediction. The engine spawns a body on a due slot
                only while `population < effective_cap`; both operands are on screen above and here,
                but the VERDICT is deliberately not computed — see reinforcementClock's header. A
                field that is full now can lose a hull two seconds before the slot, so "1 ship
                arriving" and "nothing arrives" are both claims about a future nobody has. */}
            {wave && (
              <div className="mt-3 border-t border-edge pt-2" data-testid={`combat-map-wave-${e.id}`}>
                <div className="flex items-baseline justify-between gap-2">
                  <span className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
                    {REINFORCEMENT_LABEL}
                  </span>
                  {wave.slot !== null && (
                    <span className="text-[11px] text-ink-faint">
                      wave <span className="font-mono tabular-nums">{wave.slot}</span> so far
                    </span>
                  )}
                </div>
                <p className="mt-0.5 text-[11px] text-warning" data-testid={`combat-map-wave-clock-${e.id}`}>
                  {wave.text}
                </p>
                <p className="mt-0.5 text-[10px] text-ink-faint">{REINFORCEMENT_RULE}</p>
              </div>
            )}

            {/* ██ THE HAUL ██ — the owner's "loot info… with total cargo space".
                This is the instrument for the only decision the fight asks. The fight cannot be won
                (0347's cap grows without bound, deliberately), and a DEFEAT zeroes
                total_rewards_json outright, so the question is always "one more kill, or leave with
                this". */}
            <div className="mt-3 border-t border-edge pt-2" data-testid={`combat-map-haul-${e.id}`}>
              <span className="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
                Haul
              </span>
              <p className="mt-0.5 flex flex-wrap gap-1">
                {haul.empty ? (
                  <span className="text-[11px] text-ink-faint">Nothing won yet.</span>
                ) : (
                  haul.entries.map((r) => <ItemChip key={r.id} id={r.id} qty={r.qty} />)
                )}
              </p>
              {haul.m3 !== null && (
                <p className="mt-0.5 text-[10px] text-ink-faint" data-testid={`combat-map-haul-m3-${e.id}`}>
                  Takes {formatM3(haul.m3)}
                  {haul.unmeasured > 0 && ' (plus what has no volume)'}
                </p>
              )}
              {!haul.empty && <p className="mt-0.5 text-[10px] text-warning">{HAUL_AT_STAKE}</p>}
              {/* TOTAL CARGO SPACE — the server's own numbers (get_my_hold, 0333), formatted by the
                  ONE hold formatter. Never a client-side sum of per-ship capacities: that fold is
                  exactly what fleetStatusModel refuses, and this is the authority it points at. */}
              {meter && (
                <p className="mt-1 text-[10px] text-ink-muted" data-testid={`combat-map-hold-${e.id}`}>
                  Fleet hold <span className="font-mono tabular-nums">{meter.label}</span>
                </p>
              )}
              {/* WHAT ONE MORE KILL IS WORTH HERE — the site's own loot table (0348). Quantities are
                  PER ENEMY DESTROYED, which is the unit the server pays in; nothing is multiplied by
                  a kill count nobody has. A chance under 1 is stated, because a drop that is not
                  certain must not read as certain. */}
              {drops && drops.length > 0 && (
                <div className="mt-1" data-testid={`combat-map-drops-${e.id}`}>
                  <p className="text-[10px] text-ink-faint">Each kill here drops</p>
                  <p className="mt-0.5 flex flex-wrap gap-1">
                    {drops.map((d) => (
                      <span key={d.item_id} className="inline-flex items-center gap-0.5">
                        <ItemChip id={d.item_id} qty={d.quantity} />
                        {d.drop_chance < 1 && (
                          <span className="text-[10px] text-ink-faint">
                            {Math.round(d.drop_chance * 100)}%
                          </span>
                        )}
                      </span>
                    ))}
                  </p>
                </div>
              )}
            </div>

            {/* WHO IS WINNING THIS EXCHANGE — the server's own per-tick damage totals, both ways,
                from the same three seconds. Two static bars cannot show a rate; this can. */}
            {latest && (
              <p className="mt-3 text-[11px] text-ink-muted" data-testid={`combat-map-exchange-${e.id}`}>
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

            {/* "WHEN FIGHTING, I AM NOT ABLE TO MOVE MY FLEET." The owner's report, playing live —
                and the order was being ACCEPTED. 0337 made a reposition a WALK, not a jump: the tick
                advances the fleet at its own speed, which at normal zoom is on the order of a
                sixteenth of a pixel per three-second tick. So the fleet really is moving and the
                screen cannot show it. The sentence that closes that gap already existed and was
                already mounted — on the Mission screen (ActiveCombatPanel), which a player fighting
                on the MAP never opens.

                This is the SECOND MOUNT of that one sentence, never a second copy of it: the text,
                the distance and the "is a course even running?" rule all stay inside
                resolveRepositionCourse. */}
            {course && (
              <p
                data-testid={`combat-map-reposition-${e.id}`}
                className="mt-1 text-[11px] text-accent"
              >
                {course.text}
              </p>
            )}

            {!spatial && (
              <p className="mt-2 text-[11px] text-warning">
                This battle has no ship positions, so nothing is drawn on the map for it.
              </p>
            )}

            </div>
          </OverlayPanel>
        )
      })}
    </div>
  )
}
