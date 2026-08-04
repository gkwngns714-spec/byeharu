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
  UNITS_REPOSITIONED,
} from './fightFixtures'

const noop = () => {}

function Fight({
  twoFights,
  advanced,
  repositioned,
}: {
  twoFights: boolean
  advanced: boolean
  repositioned: boolean
}) {
  // `repositioned` moves the WHOLE engagement — hulls, enemies and the anchor — by one delta, which
  // is what a 0337 in-combat reposition does to it tick after tick. It is the state in which the
  // battle is no longer anywhere near the frame the camera took when it opened.
  const mine = repositioned ? ENCOUNTER_REPOSITIONED : ENCOUNTER
  const encounters = twoFights ? [mine, OTHER_ENCOUNTER] : [mine]
  // `advanced` delivers the NEXT server tick's rows — a second observation, which is the only way a
  // rendered proof can watch a step being crossed rather than a glyph standing still.
  const base = repositioned ? UNITS_REPOSITIONED : advanced ? UNITS_NEXT_TICK : UNITS
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
      {/* The SAME rail slot MapScreen mounts the card in. */}
      <OverlayRail slot="top-left" className="max-h-[60%] w-72 max-w-[calc(100vw-5rem)] overflow-y-auto">
        <CombatMapCard
          encounters={encounters}
          units={units}
          ticks={TICKS}
          autoExit={{ [ENCOUNTER.id]: { enabled: true, pct: 30 } }}
          onChanged={noop}
        />
      </OverlayRail>
    </div>
  )
}

function Harness() {
  // Default OFF so the single-fight case (the one the screenshots show) is what loads; the spec
  // flips it to prove a second, higher-tick battle no longer blanks this one.
  const [twoFights, setTwoFights] = useState(false)
  const [advanced, setAdvanced] = useState(false)
  const [repositioned, setRepositioned] = useState(false)
  return (
    <>
      <div id="map-host">
        <Fight twoFights={twoFights} advanced={advanced} repositioned={repositioned} />
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
      </div>
    </>
  )
}

createRoot(document.getElementById('root')!).render(<Harness />)
