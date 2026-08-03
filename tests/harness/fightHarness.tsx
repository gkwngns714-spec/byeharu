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
  EVENTS,
  LOCATIONS,
  OTHER_ENCOUNTER,
  OTHER_EVENTS,
  OTHER_UNITS,
  TICKS,
  UNITS,
} from './fightFixtures'

const noop = () => {}

function Fight({ twoFights }: { twoFights: boolean }) {
  const encounters = twoFights ? [ENCOUNTER, OTHER_ENCOUNTER] : [ENCOUNTER]
  const units = twoFights ? [...UNITS, ...OTHER_UNITS] : UNITS
  const events = twoFights ? [...EVENTS, ...OTHER_EVENTS] : EVENTS
  return (
    <div className="relative h-full w-full">
      <GalaxyMap
        locations={LOCATIONS}
        movements={[]}
        teamGroups={[]}
        dockedTeamRollups={[]}
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
  return (
    <>
      <div id="map-host">
        <Fight twoFights={twoFights} />
      </div>
      <div id="controls">
        <button data-testid="toggle-second-fight" onClick={() => setTwoFights((v) => !v)}>
          second fight: {twoFights ? 'on' : 'off'}
        </button>
      </div>
    </>
  )
}

createRoot(document.getElementById('root')!).render(<Harness />)
