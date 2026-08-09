// FIGHT READOUT (UI proof) — mounts the REAL <GalaxyMap> and the REAL <CombatMapCard> over a
// production-shaped battle, in a real browser, at a real phone width, so tests/fightReadout.uispec.ts
// can measure what a player actually SEES during combat.
//
// WHY THIS EXISTS. Every defect this slice fixes is invisible to a source-text spec and invisible to
// a pure unit test of the resolvers:
//   · "the whole engagement is a handful of pixels" is a MEASUREMENT, in CSS px, of the distance
//     between two rendered ship glyphs — the resolvers are all correct while it is true;
//   · "two hits collapsed into one number" and "the killing blow rendered nothing" are counts of
//     elements in the live DOM;
//   · "there is no way to leave from the screen showing the fight" is the presence of a button.
// So the harness puts the real components in front of a real pointer and lets the browser answer.
//
// Nothing is stubbed and nothing is re-implemented: both components are imported from src exactly as
// MapScreen composes them, and both are props-only (no fetch, no store, no context), so the harness
// supplies data and nothing else. No production access; nothing connects.
import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import './harness.css'
import { GalaxyMap } from '../../src/features/map/GalaxyMap'
import { CombatMapCard } from '../../src/features/map/CombatMapCard'
import { MapOverlayTabs } from '../../src/features/map/MapOverlayTabs'
import { OverlayRail } from '../../src/components/ui'
import {
  ENCOUNTER,
  ENCOUNTER_REPOSITIONED,
  EVENTS,
  LOCATIONS,
  OTHER_ENCOUNTER,
  OTHER_EVENTS,
  OTHER_UNITS,
  TICKS,
  UNITS,
  UNITS_NEXT_TICK,
  UNITS_REAL_FORMATION,
  UNITS_REPOSITIONED,
} from './fightFixtures'

const noop = () => {}

function Fight({
  twoFights,
  advanced,
  repositioned,
  tight,
}: {
  twoFights: boolean
  advanced: boolean
  repositioned: boolean
  /** the owner's REAL formation — as wide as its own weapon range. The reach region's hard case. */
  tight: boolean
}) {
  // `repositioned` moves the WHOLE engagement — hulls, enemies and the anchor — by one delta, which
  // is what a 0337 in-combat reposition does to it tick after tick. It is the state in which the
  // battle is no longer anywhere near the frame the camera took when it opened.
  const mine = repositioned ? ENCOUNTER_REPOSITIONED : ENCOUNTER
  const encounters = twoFights ? [mine, OTHER_ENCOUNTER] : [mine]
  // `advanced` delivers the NEXT server tick's rows — a second observation, which is the only way a
  // rendered proof can watch a step being crossed rather than a glyph standing still.
  const base = tight ? UNITS_REAL_FORMATION : repositioned ? UNITS_REPOSITIONED : advanced ? UNITS_NEXT_TICK : UNITS
  const units = twoFights ? [...base, ...OTHER_UNITS] : base
  const events = twoFights ? [...EVENTS, ...OTHER_EVENTS] : EVENTS
  return (
    <div className="relative h-full w-full">
      <GalaxyMap
        locations={LOCATIONS}
        movements={[]}
        teamGroups={[]}
        teamGroupMap={{}}
        fleetPositions={[]}
        unifiedGroupFleets={[]}
        combatSortieFleets={[]}
        fleetGoView={null}
        onDoubleTapPoint={noop}
        selectedId={null}
        onSelect={noop}
        miningFields={[]}
        miningExtractRadius={0}
        selectedMiningFieldName={null}
        onSelectMiningField={noop}
        combatUnits={units}
        combatEvents={events}
        combatEncounters={encounters}
      />
      {/* The SAME rail, and the SAME COMPOSITION, MapScreen mounts the card in: the readout is the
          FIGHT TAB'S BODY, and the ONE RetreatControl is pinned by the tab shell outside it. The tab
          is forced open here so the readout is what this harness measures; the shell's own fight row
          comes with it, which is where "leaving is one click" is now proved.

          The `max-h-[60%] … overflow-y-auto` this call site used to carry is GONE. It was a copy of
          the cap that put the owner's Hunt button 36px under a hidden fold, and a harness that keeps
          a stale cap measures a layout the game does not have — the exact failure
          tests/actionsAreReachable.spec.ts was written to stop, which is why this file is now listed
          there as a rail call site. The rail bounds itself; the tab body is the account that gives. */}
      <OverlayRail
        slot="top-left"
        className="w-72 max-w-[calc(100vw-5rem)]"
        reach={
          <MapOverlayTabs
            encounters={encounters}
            onCombatChanged={noop}
            openTab="fight"
            explore={null}
            fleets={null}
            fight={
              <CombatMapCard
                encounters={encounters}
                units={units}
                ticks={TICKS}
                autoExit={{ [ENCOUNTER.id]: { enabled: true, pct: 30 } }}
              />
            }
          />
        }
      />
    </div>
  )
}

function Harness() {
  // Default OFF so the single-fight case (the one the screenshots show) is what loads; the spec
  // flips it to prove a second, higher-tick battle no longer blanks this one.
  const [twoFights, setTwoFights] = useState(false)
  const [advanced, setAdvanced] = useState(false)
  const [repositioned, setRepositioned] = useState(false)
  const [tight, setTight] = useState(false)
  return (
    <>
      <div id="map-host">
        <Fight twoFights={twoFights} advanced={advanced} repositioned={repositioned} tight={tight} />
      </div>
      <div id="controls">
        <button data-testid="toggle-second-fight" onClick={() => setTwoFights((v) => !v)}>
          second fight: {twoFights ? 'on' : 'off'}
        </button>
        <button data-testid="advance-tick" onClick={() => setAdvanced((v) => !v)}>
          next tick: {advanced ? 'on' : 'off'}
        </button>
        {/* The battle MOVES (0337 reposition). Off by default, so every existing measurement is
            taken against exactly the fight it was taken against before. */}
        <button data-testid="reposition-fight" onClick={() => setRepositioned((v) => !v)}>
          fight moved: {repositioned ? 'on' : 'off'}
        </button>
        {/* The owner's own measured formation (5.14 x 4.24 world units, weapon range 5). Off by
            default so every existing measurement is taken against exactly the fight it always was. */}
        <button data-testid="real-formation" onClick={() => setTight((v) => !v)}>
          real formation: {tight ? 'on' : 'off'}
        </button>
      </div>
    </>
  )
}

createRoot(document.getElementById('root')!).render(<Harness />)
