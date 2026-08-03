// ██ WHERE ARE MY FLEETS (UI proof) ██ — mounts the REAL <GalaxyMap> with the owner's REAL production
// fleet shape, so tests/fleetMarkers.uispec.ts can look at what the player actually sees.
//
// WHY THIS EXISTS. tests/fleetPresence.spec.ts proves the RULE — one presence per fleet, in every
// state. It cannot see whether a badge reaches the DOM, whether two fleets at one port write their
// labels on top of each other, or whether a fleet the world cannot place is silently dropped between
// the resolver and the screen. The defect that started this slice was exactly that class: the rule
// looked fine in four separate pieces and the map rendered ONE badge for TWO fleets.
//
// Nothing is stubbed and nothing is re-implemented: <GalaxyMap> is imported from src exactly as
// MapScreen composes it, and it is a props-only component (no fetch, no store, no context), so the
// harness supplies data and nothing else. No production access; nothing connects.
//
// THE FIXTURE IS PRODUCTION, READ ON 2026-08-04 (get_my_fleet_positions + ship_groups +
// main_ship_instances, read-only). It is the exact shape that rendered no marker for Fleet 1:
//   · Fleet 1 — four ships. Sparrow is docked at Haven; Sparrow III/IV/V carry the abolished
//     `legacy_home` state, so the server projects them 'hidden'.
//   · Fleet 2 — one ship, Sparrow II, docked at Slagworks.
// CSS parity with the real app: harness.css re-exports src/index.css with the @source the harness's
// own Vite root would otherwise hide. Without it every colour token is undefined and the map renders
// black — a screenshot that proves nothing, and an overlay rail that loses `absolute`.
import './harness.css'
import { createRoot } from 'react-dom/client'
import { GalaxyMap } from '../../src/features/map/GalaxyMap'
import type { MapLocation } from '../../src/features/map/mapTypes'
import type { FleetPosition } from '../../src/features/map/mainshipApi'
import type { GroupRow, ShipGroupMapEntry } from '../../src/features/command/teamRoster'

const loc = (o: Partial<MapLocation> & Pick<MapLocation, 'id' | 'name' | 'x' | 'y'>): MapLocation => ({
  location_type: 'trade_outpost',
  base_difficulty: 1,
  reward_tier: 1,
  activity_type: 'trade_visit',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  territory_radius: null,
  ...o,
})

// Production coordinates, scaled apart enough that the two ports cannot overlap at the fitted camera.
const HAVEN = loc({ id: 'b1a00001-0066-4a00-8a00-000000000001', name: 'Haven', x: -1200, y: 900 })
const SLAG = loc({ id: 'b1a00002-0066-4a00-8a00-000000000002', name: 'Slagworks', x: 1400, y: -800 })
const LOCATIONS: MapLocation[] = [HAVEN, SLAG]

const G1: GroupRow = { group_id: 'g-fleet-1', group_index: 1, name: 'Fleet 1' }
const G2: GroupRow = { group_id: 'g-fleet-2', group_index: 2, name: 'Fleet 2' }
const G3: GroupRow = { group_id: 'g-fleet-3', group_index: 3, name: 'Fleet 3' }

const inFleet = (group_id: string): ShipGroupMapEntry => ({ group_id, captain_slots: 2, is_command_ship: false })

const ship = (
  main_ship_id: string,
  name: string,
  place: FleetPosition['place'],
  location_id: string | null,
): FleetPosition => ({
  main_ship_id,
  name,
  class: 'starter_frigate',
  status: 'home',
  place,
  location_id,
  segment: null,
  space_x: null,
  space_y: null,
})

// Scenario A (default) — the owner's live world. Scenario B (?s=unplaced) adds a third fleet whose
// every ship is 'hidden', the one state that has no world coordinate at all.
const unplaced = new URLSearchParams(location.search).get('s') === 'unplaced'

const GROUPS = unplaced ? [G1, G2, G3] : [G1, G2]
const MEMBERSHIP: Record<string, ShipGroupMapEntry> = {
  'ship-sparrow': inFleet(G1.group_id),
  'ship-sparrow-iii': inFleet(G1.group_id),
  'ship-sparrow-iv': inFleet(G1.group_id),
  'ship-sparrow-v': inFleet(G1.group_id),
  'ship-sparrow-ii': inFleet(G2.group_id),
  ...(unplaced ? { 'ship-ghost': inFleet(G3.group_id) } : {}),
}
const POSITIONS: FleetPosition[] = [
  ship('ship-sparrow', 'Sparrow', 'docked', HAVEN.id),
  ship('ship-sparrow-iii', 'Sparrow III', 'hidden', null),
  ship('ship-sparrow-iv', 'Sparrow IV', 'hidden', null),
  ship('ship-sparrow-v', 'Sparrow V', 'hidden', null),
  ship('ship-sparrow-ii', 'Sparrow II', 'docked', SLAG.id),
  ...(unplaced ? [ship('ship-ghost', 'Ghost', 'hidden', null)] : []),
]

const noop = () => {}

createRoot(document.getElementById('root') as HTMLElement).render(
  <div id="map-host">
    <GalaxyMap
      locations={LOCATIONS}
      movements={[]}
      teamGroups={GROUPS}
      teamGroupMap={MEMBERSHIP}
      fleetPositions={POSITIONS}
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
  </div>,
)
