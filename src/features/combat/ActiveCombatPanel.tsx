import { useEffect, useState } from 'react'
import type { UnitType } from '../../lib/catalog'
import { CombatEventLayer } from './CombatEventLayer'
import { RoundLog } from './RoundLog'
import { RetreatControl } from './RetreatControl'
import type { CombatEncounter, CombatEvent, CombatTick, CombatUnit } from './combatTypes'
import { combatUnitLabel } from './combatLabels'
import { selectCombatPhase, nextWaveSeconds, nextWaveText } from './combatPhase'
import { resolveAutoExitLine, type AutoExitSetting } from './autoExitLine'
import { resolveRepositionCourse } from './repositionCourse'
import { resolveRewardEntries } from './rewardPayload'
import { Card, Notice, Meter, SectionLabel, type MeterTone } from '../../components/ui'
import { ItemChip } from '../../components/items'

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
  autoExit,
  onChanged,
}: {
  encounter: CombatEncounter
  locationName: string
  units: CombatUnit[]
  unitTypes: UnitType[]
  events: CombatEvent[]
  ticks: CombatTick[]
  retreatDelaySeconds: number
  /** the fleet's 0310 safety line, if it could be read. Absent → nothing is said about it. */
  autoExit?: AutoExitSetting
  onChanged: () => void
}) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const iv = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [])

  // COMBAT PHASE: retreating / between-waves / fighting comes from the ONE shared selector
  // (combatPhase.ts), which the map card composes too. This panel used to derive it inline; the
  // derivation moved out unchanged so the two surfaces can never drift apart.
  const phase = selectCombatPhase(encounter)
  const retreating = phase.isRetreating
  // Slice D4: tick jsonb keys are coalesce(unit_type_id, main_ship_id::text) since D1 — resolved by
  // the ONE combatUnitLabel helper (catalog name first, uuid-shaped member key → "Team ship" label).
  // Data-dark: member rows/keys can't exist in prod today, so legacy rendering is byte-identical.
  const typeName = (id: string) => combatUnitLabel(id, unitTypes)
  // The pending haul, read through the ONE payload reader. The inline `Object.entries(...)` this
  // replaces mapped EVERY key to an ItemChip — including `items`, whose value is an array — so a
  // looted hold rendered as the literal string `Items ×[object Object]`.
  const rewards = resolveRewardEntries(encounter.total_rewards_json)

  const playerPct = encounter.player_integrity_max > 0
    ? (encounter.player_integrity_current / encounter.player_integrity_max) * 100 : 0
  const enemyPct = encounter.enemy_integrity_max > 0
    ? (encounter.enemy_integrity_current / encounter.enemy_integrity_max) * 100 : 0

  const latest = ticks.slice().sort((a, b) => b.tick_number - a.tick_number).find((t) => t.result !== 'next_wave_incoming')
  const lossText = (j: Record<string, number>) => {
    const e = Object.entries(j ?? {}).filter(([, v]) => v > 0)
    return e.length ? `Lost: ${e.map(([k, v]) => `${v} ${typeName(k)}`).join(', ')}` : 'Hull damaged, no ships destroyed.'
  }

  let retreatLeft = 0
  if (retreating && encounter.retreat_started_at) {
    retreatLeft = Math.ceil(retreatDelaySeconds - (now - new Date(encounter.retreat_started_at).getTime()) / 1000)
  }

  // THE SAFETY LINE (0310) — the ONE derivation, shared with the map card. Null when the setting is
  // unknown or off, and then this panel says nothing about it rather than implying there is none.
  const exit = resolveAutoExitLine(encounter, autoExit)
  // 0337: the fleet's standing course, read through the ONE resolver. Null = no course to state.
  const course = resolveRepositionCourse(encounter)

  return (
    // UI R4: the existing bh-fade-in entrance when a battle takes the screen (one-shot, no loop);
    // wave/danger/cleared counters read as mono ops telemetry. Strings/logic untouched.
    <Card tone="danger" className="bh-fade-in">
      <div className="mb-4 flex items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold text-danger">⚔️ Combat — {locationName}</h2>
          <p className="text-sm text-ink-muted">
            Wave <span className="font-mono tabular-nums text-ink">{encounter.wave_number}</span> · Danger{' '}
            <span className="font-mono tabular-nums text-ink">{encounter.danger_level}</span> ·{' '}
            <span className="font-mono tabular-nums text-ink">{encounter.waves_cleared}</span> waves cleared ·{' '}
            <span className="text-ink">{phase.label}</span>
          </p>
        </div>
        {/* THE ONE retreat control (combat/RetreatControl) — the same component the map card
            mounts, so the verb, its busy state and its reject copy exist once. */}
        <RetreatControl
          presenceId={encounter.presence_id}
          retreating={retreating}
          onChanged={onChanged}
          testId="combat-panel-retreat"
        />
      </div>

      {retreating && (
        <Notice tone="warning" className="mb-4 text-xs">
          Retreating — fleet breaks away in {retreatLeft > 0 ? `${retreatLeft}s` : 'a moment…'}.
          Warning: it can still take damage until it escapes.
        </Notice>
      )}

      {/* THE STANDING COURSE (0337). A reposition is a MOVE now, not a jump: the order records a
          destination and the tick walks the fleet there at its own speed over several ticks. Without
          this line the player orders a move, watches the marker creep, and has nothing on screen
          saying a course is being run — which reads as a stuck fleet. `course` is null whenever there
          is none (and on any pre-0337 server), so this renders nothing by default. It sits BELOW the
          retreat notice deliberately: a retreating fight is leaving, and the engine stops honouring
          the course, so the resolver returns null and only one of the two can ever be on screen. */}
      {course && (
        <Notice tone="accent" className="mb-4 text-xs" data-testid="combat-panel-reposition">
          {course.text}
        </Notice>
      )}

      {/* Fleet (total) + pirate wave */}
      <div className="mb-4 space-y-3">
        <Bar label="Fleet integrity" pct={playerPct} text={`${playerPct.toFixed(0)}% · ${Math.round(encounter.player_integrity_current).toLocaleString()} / ${Math.round(encounter.player_integrity_max).toLocaleString()}`} tone="accent" />
        {/* THE SAFETY LINE, IN WORDS. 0310 has been ending fights silently since it deployed. */}
        {exit && (
          <p
            data-testid="combat-panel-auto-exit"
            className={`text-xs ${exit.reached || exit.close ? 'text-warning' : 'text-ink-faint'}`}
          >
            {exit.text}
          </p>
        )}
        {phase.betweenWaves ? (
          <div>
            <div className="mb-1 text-xs text-ink-muted">Pirate wave</div>
            <p className="text-xs text-warning/90">
              {nextWaveText(nextWaveSeconds(encounter, now))}
            </p>
          </div>
        ) : (
          <Bar label={`Pirate wave ${encounter.wave_number}`} pct={enemyPct}
            text={`${enemyPct.toFixed(0)}% · ${Math.round(encounter.enemy_integrity_current).toLocaleString()} / ${Math.round(encounter.enemy_integrity_max).toLocaleString()}`}
            tone="danger" />
        )}
      </div>

      {/* Per-unit-type integrity */}
      <div className="mb-4">
        <SectionLabel>Fleet units</SectionLabel>
        <div className="space-y-2">
          {units.length === 0 && <p className="text-sm text-ink-faint">no units</p>}
          {/* Slice D4 null-safety: a unit is keyed by coalesce(unit_type_id, main_ship_id) since D1 —
              sort + label on that coalesced key so a member row (null unit_type_id, dark today) can
              never crash the panel; legacy rows sort/label byte-identically. */}
          {units.slice().sort((a, b) => unitKey(a).localeCompare(unitKey(b))).map((u) => {
            const pct = u.hp_max > 0 ? (u.hp_current / u.hp_max) * 100 : 0
            const lost = u.initial_count - u.alive_count
            return (
              <Bar
                key={u.id}
                label={`${typeName(unitKey(u))} — ${u.alive_count}/${u.initial_count} ships${lost > 0 ? ` (${lost} lost)` : ''}`}
                pct={pct}
                text={`${pct.toFixed(0)}% · ${Math.round(u.hp_current)}/${Math.round(u.hp_max)} HP`}
                tone={u.alive_count === 0 ? 'neutral' : 'success'}
              />
            )
          })}
        </div>
      </div>

      {/* Latest exchange */}
      {latest && (
        <div className="mb-4 rounded-lg border border-edge bg-surface-2/60 p-3 text-sm">
          <SectionLabel className="mb-1">Latest exchange (tick {latest.tick_number})</SectionLabel>
          {retreating ? (
            <>
              <p className="text-warning/90">Your fleet is retreating — weapons disengaged.</p>
              <p className="text-ink-muted">Pirates dealt <span className="font-mono tabular-nums text-danger">{Math.round(latest.enemy_damage)}</span> damage during disengagement.</p>
            </>
          ) : (
            <>
              <p className="text-ink-muted">You dealt <span className="font-mono tabular-nums text-accent">{Math.round(latest.player_damage)}</span> damage to the wave.</p>
              <p className="text-ink-muted">Pirates dealt <span className="font-mono tabular-nums text-danger">{Math.round(latest.enemy_damage)}</span> damage.</p>
            </>
          )}
          <p className="text-ink-faint">{lossText(latest.player_losses_json)}</p>
        </div>
      )}

      <div className="mb-1">
        <SectionLabel>
          Pending rewards {retreating && <span className="text-warning/80 normal-case">(locked)</span>}
        </SectionLabel>
        <p className="text-sm">
          {/* ITEM-VIZ: pending reward codes as ItemChips (glyph + humanized name + mono qty)
              instead of the raw `code: amount` strings; unknown codes degrade gracefully. */}
          {rewards.length === 0 ? <span className="text-ink-faint">none yet</span>
            : rewards.map((r) => (
                <ItemChip key={r.id} id={r.id} qty={r.qty} className="mr-2" />
              ))}
        </p>
        <p className="mt-1 text-[11px] text-ink-faint">
          {/* 0307: rewards ride with the fleet and are banked the moment it arrives — wherever the
              retreat was pointed. The old copy ("secured only after your fleet returns to base")
              documented the pre-0307 defect as a rule and named a base the design does not have. */}
          {retreating
            ? 'Locked — banked as soon as your fleet gets clear and arrives.'
            : 'Pending — banked when your fleet leaves the fight and arrives (lost if it is destroyed).'}
        </p>
      </div>

      <div className="mt-4">
        <CombatEventLayer events={events} />
      </div>

      <div className="mt-4">
        <SectionLabel>Round log</SectionLabel>
        <RoundLog ticks={ticks} unitTypes={unitTypes} limit={12} />
      </div>
    </Card>
  )
}

// Slice D4: the client-side twin of the server's coalesce(unit_type_id, main_ship_id) unit key —
// non-empty for every legal row (the D1 CHECK guarantees exactly one identity is set).
const unitKey = (u: CombatUnit) => u.unit_type_id ?? u.main_ship_id ?? ''

function Bar({ label, pct, text, tone }: { label: string; pct: number; text: string; tone: MeterTone }) {
  return (
    <div>
      <div className="mb-1 flex items-baseline justify-between text-xs">
        <span className="text-ink-muted">{label}</span>
        <span className="font-mono tabular-nums text-ink-faint">{text}</span>
      </div>
      <Meter pct={pct} tone={tone} />
    </div>
  )
}
