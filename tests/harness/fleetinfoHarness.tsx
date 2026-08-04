// ██ MY FLEETS, ON THE MAP (UI proof) ██ — mounts the REAL <FleetStatusPanel> inside the REAL
// top-left <OverlayRail>, i.e. exactly the container and the width constraints MapScreen gives it.
//
// WHY THIS EXISTS. tests/fleetStatus.spec.ts proves the RULES — every state says where it is and
// what it is doing, the refusal is the server's own sentence, the action slot is a toggle. It cannot
// see whether any of that reaches the DOM, whether the retreat button clears the 44px touch floor,
// or whether a fleet name and a "Hunt at Snare" button fit a phone without pushing the page sideways.
// The owner plays on a phone; a panel that overflows is a panel that is not there.
//
// Nothing is stubbed and nothing is re-implemented: the panel is imported from src exactly as
// MapScreen composes it, and it is props-only (no fetch, no store, no context of its own). The one
// thing the harness supplies beyond data is a FIXED clock, so the in-flight ETA is an exact string
// to assert instead of a race against a real second hand.
//
// CSS parity with the real app: harness.css re-exports src/index.css with the @source the harness's
// own Vite root would otherwise hide. Without it every token is undefined and a measurement of the
// rendered panel would be a measurement of nothing.
import './harness.css'
import { createRoot } from 'react-dom/client'
import { OverlayRail } from '../../src/components/ui'
import { FleetStatusPanel } from '../../src/features/map/FleetStatusPanel'
import type { MapLocation } from '../../src/features/map/mapTypes'
import type { FleetPosition } from '../../src/features/map/mainshipApi'
import type { DangerZoneLite } from '../../src/features/map/pirateApi'
import type { GroupRow, ShipGroupMapEntry } from '../../src/features/command/teamRoster'
import type { UnifiedGroupFleetLite } from '../../src/features/command/teamApi'
import type { FleetMovement } from '../../src/features/fleets/fleetTypes'
import type { CombatEncounter } from '../../src/features/combat/combatTypes'

/** A FIXED clock — the ETA below is asserted verbatim, so it must not depend on when the proof runs. */
const NOW = Date.parse('2026-08-04T12:00:00.000Z')

const params = new URLSearchParams(window.location.search)
/** parked | zone | fighting | flight | blocked | none */
const scenario = params.get('s') ?? 'parked'

const loc = (over: Partial<MapLocation> & Pick<MapLocation, 'id' | 'name' | 'x' | 'y'>): MapLocation =>
  ({
    location_type: 'trade_outpost',
    base_difficulty: 1,
    reward_tier: 1,
    activity_type: 'trade_visit',
    min_power_required: 0,
    is_public: true,
    status: 'active',
    territory_radius: 60,
    ...over,
  }) as MapLocation

// Production names and the production shape: the Snare SITE at its own coordinates, wrapped by a
// danger zone that shares its name — the exact pairing the owner kept aiming the wrong half of.
const HAVEN = loc({ id: 'loc-haven', name: 'Haven', x: 0, y: 0 })
const SNARE = loc({
  id: 'loc-snare',
  name: 'Snare',
  x: 500,
  y: 500,
  location_type: 'pirate_hunt',
  activity_type: 'hunt_pirates',
  territory_radius: 40,
})
const LOCATIONS: MapLocation[] = [HAVEN, SNARE]

const G1: GroupRow = { group_id: 'g-fleet-1', group_index: 1, name: 'Fleet 1' }

const inFleet = (is_command_ship: boolean): ShipGroupMapEntry => ({
  group_id: G1.group_id,
  captain_slots: 2,
  is_command_ship,
})
// 'blocked' is the production majority: of 77 live ships, 2 carry the command flag (0335's header).
const MEMBERSHIP: Record<string, ShipGroupMapEntry> = {
  'ship-sparrow': inFleet(scenario !== 'blocked'),
  'ship-sparrow-ii': inFleet(false),
}

const pos = (over: Partial<FleetPosition> & Pick<FleetPosition, 'main_ship_id' | 'place'>): FleetPosition => ({
  name: 'Sparrow',
  class: 'starter_frigate',
  status: 'home',
  location_id: null,
  segment: null,
  space_x: null,
  space_y: null,
  ...over,
})

const parked = (id: string) => pos({ main_ship_id: id, place: 'in_space', space_x: 500, space_y: 500 })
const inTransit = (id: string) =>
  pos({
    main_ship_id: id,
    place: 'transit',
    segment: {
      origin_x: 0,
      origin_y: 0,
      target_x: 500,
      target_y: 500,
      target_kind: 'space',
      depart_at: new Date(NOW - 60_000).toISOString(),
      arrive_at: new Date(NOW + 128_000).toISOString(),
    },
  })

const POSITIONS: FleetPosition[] =
  scenario === 'flight'
    ? [inTransit('ship-sparrow'), inTransit('ship-sparrow-ii')]
    : [parked('ship-sparrow'), parked('ship-sparrow-ii')]

const FLEETS: UnifiedGroupFleetLite[] = [
  {
    id: 'fleet-1',
    group_id: G1.group_id,
    status: scenario === 'flight' ? 'moving' : 'idle',
    location_mode: 'space',
    current_location_id: null,
    space_x: 500,
    space_y: 500,
  },
]

const MOVEMENTS: FleetMovement[] =
  scenario === 'flight'
    ? [
        {
          id: 'mv-1',
          fleet_id: 'fleet-1',
          group_id: G1.group_id,
          origin_type: 'space',
          origin_x: 0,
          origin_y: 0,
          target_type: 'space',
          target_location_id: null,
          target_base_id: null,
          target_x: 500,
          target_y: 500,
          mission_type: 'rally',
          status: 'moving',
          depart_at: new Date(NOW - 60_000).toISOString(),
          arrive_at: new Date(NOW + 128_000).toISOString(),
          travel_seconds: 188,
          travel_distance: 707,
        },
      ]
    : []

const ZONE: DangerZoneLite = {
  id: 'z-snare',
  name: 'Snare',
  source: 'drawn',
  location_id: SNARE.id,
  ring: [
    [440, 440],
    [560, 440],
    [560, 560],
    [440, 560],
    [440, 440],
  ],
  revision: 1,
}
// Every parked scenario stands INSIDE the zone; only 'zone' (and 'fighting', where the fight wins)
// is given the zone list, so 'parked' proves the offer is absent when there is nothing to offer.
const ZONES: DangerZoneLite[] = scenario === 'zone' || scenario === 'fighting' ? [ZONE] : []

const ENCOUNTERS: CombatEncounter[] =
  scenario === 'fighting'
    ? [
        {
          id: 'enc-1',
          player_id: 'p1',
          fleet_id: 'fleet-1',
          presence_id: 'pres-1',
          location_id: SNARE.id,
          status: 'active',
          tick_number: 6,
          danger_level: 2,
          waves_cleared: 0,
          player_power_start: 15,
          player_power_current: 15,
          enemy_power_current: 312,
          player_integrity_max: 480,
          player_integrity_current: 312,
          enemy_integrity_max: 260,
          enemy_integrity_current: 180,
          wave_number: 1,
          next_wave_at: null,
          total_rewards_json: {},
          started_at: new Date(NOW - 30_000).toISOString(),
          retreat_started_at: null,
          ended_at: null,
          engagement_x: 500,
          engagement_y: 500,
        } as CombatEncounter,
      ]
    : []

const w = window as unknown as { __huntSiteCalls: string[] }
w.__huntSiteCalls = []

createRoot(document.getElementById('root') as HTMLElement).render(
  // The panel's real container: the map's top-left rail, with MapScreen's own width caps. The rail
  // is `absolute`, so this stand-in map box gives it something to be absolute inside.
  <div className="relative h-[100dvh] w-full bg-app text-ink" data-testid="map-host">
    <OverlayRail slot="top-left" className="max-h-[60%] w-72 max-w-[calc(100vw-5rem)] overflow-y-auto">
      <FleetStatusPanel
        groups={scenario === 'none' ? [] : [G1]}
        membership={MEMBERSHIP}
        positions={POSITIONS}
        locations={LOCATIONS}
        movements={MOVEMENTS}
        unifiedFleets={FLEETS}
        dangerZones={ZONES}
        encounters={ENCOUNTERS}
        units={[]}
        fleetControlEnabled
        nowMs={NOW}
        onSelectHuntSite={(locationId) => {
          w.__huntSiteCalls.push(locationId)
        }}
        onCombatChanged={() => {}}
      />
    </OverlayRail>
  </div>,
)
