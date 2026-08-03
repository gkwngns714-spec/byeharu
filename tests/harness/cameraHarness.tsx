// CAMERA WIRING (UI proof) — mounts the REAL <GalaxyMap> and the REAL useWheelZoom in a real browser so
// tests/cameraWiring.uispec.ts can measure where a point actually LANDS after a gesture.
//
// WHY THIS EXISTS. tests/mapZoomAuthority.spec.ts reads source TEXT. Text cannot see an anchor computed
// from the wrong origin, a listener that is never released, a wheel that zooms the wrong way, or a +/−
// button that lands off-centre — all four are well-formed code that typechecks and that every unit test
// of the pure camera math still passes, because the math is not what broke. Those defects are only
// visible where the pixels are, so this harness puts the real wiring in front of a real pointer.
//
// Nothing is stubbed and nothing is re-implemented: <GalaxyMap> is imported from src exactly as
// MapScreen composes it, and it is a props-only component (no fetch, no store, no context), so the
// harness supplies data and nothing else. No production access; nothing connects.
import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { GalaxyMap } from '../../src/features/map/GalaxyMap'
import { useWheelZoom } from '../../src/features/map/useWheelZoom'
import type { MapLocation } from '../../src/features/map/mapTypes'

// Two named locations with a KNOWN bounding box, so the mount-time content fit lands on one
// deterministic camera every run. World (-3000,2000) and (4000,-1500) → viewBox (350,400)/(700,575).
const LOCATIONS: MapLocation[] = [
  {
    id: '11111111-1111-4111-8111-111111111111',
    name: 'Alpha',
    location_type: 'trade_outpost',
    x: -3000,
    y: 2000,
    base_difficulty: 1,
    reward_tier: 1,
    activity_type: 'trade_visit',
    min_power_required: 0,
    is_public: true,
    status: 'active',
    territory_radius: null,
  },
  {
    id: '22222222-2222-4222-8222-222222222222',
    name: 'Bravo',
    location_type: 'pirate_hunt',
    x: 4000,
    y: -1500,
    base_difficulty: 2,
    reward_tier: 2,
    activity_type: 'hunt_pirates',
    min_power_required: 0,
    is_public: true,
    status: 'active',
    territory_radius: null,
  },
]

const noop = () => {}

function RealGalaxyMap() {
  return (
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
    />
  )
}

/**
 * The hook's LISTENER LIFECYCLE contract, isolated.
 *
 * useWheelZoom's own header asks callers for a STABLE `zoom` "so the listener is not re-bound per
 * render". This is the other half of that sentence: when the callback is NOT stable the effect re-runs
 * on the SAME element, and the previous listener must be removed — otherwise one wheel notch is
 * counted once per render that ever happened. Deleting the `removeEventListener` cleanup is a
 * one-character-class edit that typechecks and that no source-shape guard can see, so the probe
 * deliberately passes an unstable callback and counts how many times ONE notch arrives.
 */
function WheelListenerProbe() {
  const [el, setEl] = useState<SVGSVGElement | null>(null)
  const [notches, setNotches] = useState(0)
  const [, setGeneration] = useState(0)
  // a NEW function identity every render, on purpose (see above). It ignores the factor and the
  // anchor: what is being counted here is HOW MANY TIMES one notch arrives, not what it asked for.
  const zoom = () => setNotches((n) => n + 1)
  useWheelZoom(el, zoom)
  return (
    <div>
      <svg id="probe-svg" ref={setEl} viewBox="0 0 100 100" />
      <span data-testid="probe-notches">{notches}</span>
      <button data-testid="probe-rerender" onClick={() => setGeneration((g) => g + 1)}>
        rerender
      </button>
    </div>
  )
}

function Harness() {
  const [mapMounted, setMapMounted] = useState(true)
  return (
    <>
      <div id="map-host">{mapMounted ? <RealGalaxyMap /> : null}</div>
      <div id="controls">
        <button data-testid="toggle-map" onClick={() => setMapMounted((m) => !m)}>
          toggle map
        </button>
        <WheelListenerProbe />
      </div>
    </>
  )
}

createRoot(document.getElementById('root')!).render(<Harness />)
