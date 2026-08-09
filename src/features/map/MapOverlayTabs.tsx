import { useState, type ReactNode } from 'react'
import { Icon, OverlayPanel, type IconName } from '../../components/ui'
import { RetreatControl } from '../combat/RetreatControl'
import { selectCombatPhase } from '../combat/combatPhase'
import type { CombatEncounter } from '../combat/combatTypes'
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
//   2. THE FIGHT ROW — pinned. The fight's phase and the ONE way out of it, per live encounter,
//      OUTSIDE the tabs: a control behind a fold is a control the player does not have, and a fight
//      behind a closed tab must not be silent.
//   3. THE BODY      — the one open readout. The only region that may shrink; each panel applies the
//      reach law to ITSELF (its information scrolls, its own controls stay pinned).

const TAB_ICON: Record<MapOverlayTabId, IconName> = {
  explore: 'compass',
  fight: 'combat',
  fleets: 'fleet',
}

export function MapOverlayTabs({
  encounters,
  onCombatChanged,
  explore,
  fight,
  fleets,
  openTab,
}: {
  /** every encounter the shell polled. The LIVE ones drive the pinned fight row. */
  encounters: readonly CombatEncounter[]
  /** re-poll after a retreat order lands. */
  onCombatChanged: () => void
  explore: ReactNode
  fight: ReactNode
  fleets: ReactNode
  /** Test seam ONLY: force a tab open, so a rendered proof asserts a body instead of racing
   *  localStorage. Absent in the app, where the remembered choice below owns it. */
  openTab?: MapOverlayTabId | null
}) {
  // 'active' and 'retreating' are both LIVE — a retreating fleet is still taking fire, and that is
  // exactly when the way out matters most. Same predicate CombatMapCard uses; stated once per
  // surface because the two ask it of different things (this asks "is there a fight at all").
  const live = encounters.filter((e) => e.status === 'active' || e.status === 'retreating')
  const fighting = live.length > 0

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
        return (
          <OverlayPanel
            key={e.id}
            tone="danger"
            className="flex w-64 max-w-full shrink-0 flex-col gap-2"
            data-testid={`map-fight-row-${e.id}`}
          >
            <span className="text-xs font-semibold uppercase tracking-wide text-danger">{phase.label}</span>
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
