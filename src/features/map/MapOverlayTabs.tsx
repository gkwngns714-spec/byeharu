import { useEffect, useState, type ReactNode } from 'react'
import { Icon, OverlayPanel, type IconName } from '../../components/ui'
import { RetreatControl } from '../combat/RetreatControl'
import { selectCombatPhase } from '../combat/combatPhase'
import { hasReinforcementClock, resolveReinforcement } from '../combat/reinforcementClock'
import type { CombatEncounter, CombatUnit } from '../combat/combatTypes'
import {
  MAP_OVERLAY_TABS,
  MAP_OVERLAY_TAB_LABEL,
  MAP_OVERLAY_TAB_STORAGE_KEY,
  pressTab,
  readOpenTab,
  tabStateValue,
  type MapOverlayTabId,
} from './mapOverlayTabModel'

// ██ THE MAP'S TOP-LEFT RAIL, AS TABS. ██
//
// Owner: *"i want a separate tab on map for exploration, which is foldable, at the top, a square
// shaped one. also for combat, when opened it will show next wave incoming (wave info), and fleets
// info"*.
//
// The rule and the reasoning live in ./mapOverlayTabModel.ts — read it first. In one line: three square
// tabs, AT MOST ONE BODY MOUNTED, which is what makes the rail's old three-panel overflow impossible
// by construction rather than merely survivable.
//
// ── WHAT THIS COMPONENT KNOWS ABOUT THE GAME: NOTHING ─────────────────────────────────────────────
// The three readouts arrive as ELEMENTS (`explore` / `fight` / `fleets`). This shell owns which one
// is on screen and nothing else — no feature props pass through it, so a change to the exploration
// panel or the fleet readout cannot reach this file. The panels are still constructed at MapScreen's
// own call site, which is also why the reach-law inventory still finds them there.
//
// ── THE THREE REGIONS, AND WHICH ONE MAY GIVE WAY ─────────────────────────────────────────────────
//   1. THE TAB BAR   — pinned (`shrink-0`). It is all control.
//   2. THE FIGHT ROW — pinned. The fight's phase, the WAVE CLOCK and the ONE way out of it, per live
//      encounter, OUTSIDE the tabs: a control behind a fold is a control the player does not have,
//      and a fight behind a closed tab must not be silent.
//   3. THE BODY      — the one open readout. The only region that may shrink; each panel applies the
//      reach law to ITSELF (its information scrolls, its own controls stay pinned).
//
// ── ██ WHY THE WAVE CLOCK IS ON THE PINNED ROW AND NOT IN A TAB BODY ██ ───────────────────────────
// Owner, playing, 2026-08-09: *"when a wave starts, i see no timer that indicates next wave"*.
//
// The countdown was not missing from the client and it was not missing from the wire. `combatApi`
// reads `select('*')`, `CombatEncounter` declares all three pressure columns, and
// `combat/reinforcementClock` resolves them correctly — it was already MOUNTED, twice: on
// ActiveCombatPanel (the Mission screen, which a player fighting on the map never opens) and inside
// CombatMapCard (the FIGHT tab's body). And this shell mounts AT MOST ONE BODY. So a player standing
// on the FLEETS tab — which is where the owner was, reading "Next wave incoming" with no number —
// had the clock rendered into a tab that was not on screen. The words came from `selectCombatPhase`,
// which is a pure function of the row and deliberately carries no time at all.
//
// A countdown that is only visible in one of three tab states is a countdown the player does not
// have, for the same reason the retreat control is pinned here. So it joins the row that already
// exists to speak for a fight whatever tab is open — ONE more mount of the SAME leaf, never a second
// derivation, and never a countdown assembled from the cadence (`next_reinforcement_at` is the
// authority; nothing here computes a schedule).
//
// The FIELD count, the scheduled ordinal and REINFORCEMENT_RULE stay on the fight tab's card. This
// row is a signal, not a readout: the one fact that decays with time, and the way out.

const TAB_ICON: Record<MapOverlayTabId, IconName> = {
  explore: 'compass',
  fight: 'combat',
  fleets: 'fleet',
}

export function MapOverlayTabs({
  encounters,
  units = [],
  onCombatChanged,
  explore,
  fight,
  fleets,
  openTab,
  nowMs,
}: {
  /** every encounter the shell polled. The LIVE ones drive the pinned fight row. */
  encounters: readonly CombatEncounter[]
  /** the shell's already-polled combat_units. Passed only so the wave clock is read through the ONE
   *  leaf with its real arguments; this row prints no per-unit number of its own. */
  units?: readonly CombatUnit[]
  /** re-poll after a retreat order lands. */
  onCombatChanged: () => void
  explore: ReactNode
  fight: ReactNode
  fleets: ReactNode
  /** Test seam ONLY: force a tab open, so a rendered proof asserts a body instead of racing
   *  localStorage. Absent in the app, where the remembered choice below owns it. */
  openTab?: MapOverlayTabId | null
  /** Test seam ONLY: a fixed clock, so a rendered proof asserts an exact countdown instead of racing
   *  one. Absent in the app, where the 1s tick below owns the time. */
  nowMs?: number
}) {
  // 'active' and 'retreating' are both LIVE — a retreating fleet is still taking fire, and that is
  // exactly when the way out matters most. Same predicate CombatMapCard uses; stated once per
  // surface because the two ask it of different things (this asks "is there a fight at all").
  const live = encounters.filter((e) => e.status === 'active' || e.status === 'retreating')
  const fighting = live.length > 0

  // A 1s clock, RUNNING ONLY WHEN A COUNTDOWN EXISTS — the same rule (and the same predicate)
  // CombatMapCard states: a fight whose row carries no `next_reinforcement_at` re-renders nobody.
  const needsClock = live.some(hasReinforcementClock)
  const [tick, setTick] = useState(() => Date.now())
  useEffect(() => {
    if (!needsClock) return
    const iv = setInterval(() => setTick(Date.now()), 1000)
    return () => clearInterval(iv)
  }, [needsClock])
  const now = nowMs ?? tick

  // The remembered choice, read ONCE on mount through the pure resolver. Lazy initial state (never a
  // storage read in the render body) — the Collapsible idiom.
  const [remembered, setRemembered] = useState<MapOverlayTabId | null>(() =>
    readOpenTab((k) => (typeof window === 'undefined' ? null : window.localStorage.getItem(k)), fighting),
  )
  const open = openTab === undefined ? remembered : openTab

  const press = (id: MapOverlayTabId) => {
    const next = pressTab(open, id)
    setRemembered(next)
    try {
      window.localStorage.setItem(MAP_OVERLAY_TAB_STORAGE_KEY, tabStateValue(next))
    } catch {
      /* private-mode storage: the choice simply is not remembered. Never a reason to fail a tap. */
    }
  }

  const body = open === 'explore' ? explore : open === 'fight' ? fight : open === 'fleets' ? fleets : null

  return (
    <div className="flex min-h-0 w-full flex-col gap-2" data-testid="map-overlay-tabs">
      {/* 1 · THE TAB BAR — square buttons, 44px, at the top of the rail. `aria-pressed` is the
          accessible statement of which readout is open; the icon-only shape is the map-UX rule
          (icons over words on a command surface) and every button carries a name and a tooltip. */}
      <OverlayPanel className="flex shrink-0 items-center gap-1 p-1" data-testid="map-tabbar">
        {MAP_OVERLAY_TABS.map((id) => {
          const isOpen = open === id
          return (
            <button
              key={id}
              type="button"
              onClick={() => press(id)}
              aria-pressed={isOpen}
              aria-label={MAP_OVERLAY_TAB_LABEL[id]}
              title={MAP_OVERLAY_TAB_LABEL[id]}
              data-testid={`map-tab-${id}`}
              className={`relative flex h-11 w-11 items-center justify-center rounded-md transition ${
                isOpen ? 'bg-accent/20 text-accent' : 'text-ink-faint hover:bg-edge/40 hover:text-ink'
              }`}
            >
              <Icon name={TAB_ICON[id]} size={20} />
              {/* THE LIVE SIGNAL ON A CLOSED TAB. A fight happening behind a fold with nothing on
                  screen saying so is the silence the owner has complained about before. The pinned
                  row below says it in words; this says it at a glance. */}
              {id === 'fight' && fighting && (
                <span
                  data-testid="map-tab-fight-live"
                  aria-hidden="true"
                  className="absolute right-1 top-1 h-2 w-2 rounded-full bg-danger"
                />
              )}
            </button>
          )
        })}
      </OverlayPanel>

      {/* 2 · THE FIGHT ROW — pinned, outside the tabs. The phase in words, and the ONE RetreatControl
          (the same component the mission panel mounts). This is why closing every tab is safe. */}
      {live.map((e) => {
        const phase = selectCombatPhase(e)
        // THE WAVE CLOCK — the ONE pressure derivation (combat/reinforcementClock), mounted here so
        // the timer is on screen in EVERY tab state. Null on a server that predates 0344/0347, and
        // then this row says nothing about reinforcements rather than inventing a schedule.
        const wave = resolveReinforcement(e, units, e.id, now)
        return (
          <OverlayPanel
            key={e.id}
            tone="danger"
            className="flex w-64 max-w-full shrink-0 flex-col gap-2"
            data-testid={`map-fight-row-${e.id}`}
          >
            <span className="flex items-baseline justify-between gap-2">
              <span className="text-xs font-semibold uppercase tracking-wide text-danger">{phase.label}</span>
              {wave && (
                <span className="text-xs text-warning" data-testid={`map-fight-row-wave-${e.id}`}>
                  {wave.text}
                </span>
              )}
            </span>
            <RetreatControl
              presenceId={e.presence_id}
              retreating={phase.isRetreating}
              onChanged={onCombatChanged}
              block
              testId={`combat-map-retreat-${e.id}`}
            />
          </OverlayPanel>
        )
      })}

      {/* 3 · THE BODY — at most one, ever. `min-h-0` so the squeeze can reach the panel inside it. */}
      {body !== null && (
        <div className="flex min-h-0 w-full flex-col" data-testid={`map-tab-body-${open}`}>
          {body}
        </div>
      )}
    </div>
  )
}
