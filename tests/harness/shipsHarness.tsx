import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { MemoryRouter } from 'react-router-dom'
import { ShipsView } from '../../src/features/ship/ShipsView'
import { FittingDetail } from '../../src/features/ship/FittingDetail'
import type { FleetPosition, MainShipRow } from '../../src/features/map/mainshipApi'
import type { MapLocation } from '../../src/features/map/mapTypes'
import type { GroupRow, RosterShip } from '../../src/features/command/teamRoster'
import type { ShipFittingRow } from '../../src/features/modules/modulesTypes'
import type { SelectableShip } from '../../src/features/map/useMainShipSelection'
import './harness.css'

// ██ SIDE BY SIDE — the harness for tests/shipsSideBySide.uispec.ts ██
//
// It mounts the REAL <ShipsView> (the component the game ships, the whole page frame included) with
// INJECTED data, and hands it the REAL <FittingDetail> as its ship-column slot — exactly the way
// ShipScreen composes them. Nothing about the layout is re-created here: the harness supplies the
// data and the selection state, which is all ShipScreen supplies either.
//
// Only a RENDERED proof can settle a layout claim. "Side by side at lg, stacked on a phone" is a
// statement about two boxes' coordinates, and prose cannot fail when a class changes underneath it.
// So the spec reads the boxes back out of the DOM at 1280px and at the 320px floor.
//
// THE FIXTURE IS THE OWNER'S LIVE SHAPE, read 2026-08-04 (the same production shape
// fleetHarness.tsx carries), plus the two edges the request has to survive:
//   · Fleet 1 — four ships. Sparrow docked at Haven; Sparrow III/IV/V project 'hidden'. Sparrow IV
//     is DESTROYED — the owner has wrecks sitting at Haven right now and they must stay VISIBLE.
//   · Fleet 2 — ONE ship (the single-ship-fleet edge), docked at Slagworks.
//   · Kestrel — a ship in NO fleet at all (group_id NULL ⇔ berthed, the 0216 XOR).
// FittingDetail's own per-ship reads go nowhere here (no server, no session) and every wrapper
// collapses to []/null by design, so what renders is the detail's real markup over injected facts.
//
// ?s=solo — one fleet, one ship, nothing else: the smallest roster the tab can draw.

const loc = (id: string, name: string): MapLocation => ({
  id,
  name,
  x: 0,
  y: 0,
  location_type: 'trade_outpost',
  base_difficulty: 1,
  reward_tier: 1,
  activity_type: 'trade_visit',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  territory_radius: null,
})

const HAVEN = loc('b1a00001-0066-4a00-8a00-000000000001', 'Haven')
const SLAG = loc('b1a00002-0066-4a00-8a00-000000000002', 'Slagworks')
const LOCATIONS = [HAVEN, SLAG]

const G1: GroupRow = { group_id: 'g-fleet-1', group_index: 1, name: 'Fleet 1' }
const G2: GroupRow = { group_id: 'g-fleet-2', group_index: 2, name: 'Fleet 2' }

const member = (main_ship_id: string, name: string, group_id: string | null, status = 'home'): RosterShip => ({
  main_ship_id,
  name,
  status,
  group_id,
  is_command_ship: false,
})

const hull = (main_ship_id: string, name: string, hp: number, status = 'home'): MainShipRow => ({
  main_ship_id,
  name,
  status,
  hp,
  max_hp: 100,
  shield: 0,
  max_shield: 0,
  cargo_capacity: 50,
  captain_slots: 2,
  module_slots: 4,
  hull_type_id: 'starter_frigate',
})

const pos = (
  main_ship_id: string,
  name: string,
  place: FleetPosition['place'],
  location_id: string | null,
  status = 'home',
): FleetPosition => ({
  main_ship_id,
  name,
  class: 'starter_frigate',
  status,
  place,
  location_id,
  segment: null,
  space_x: null,
  space_y: null,
})

const solo = new URLSearchParams(window.location.search).get('s') === 'solo'

const GROUPS: GroupRow[] = solo ? [G1] : [G1, G2]

const ROSTER: RosterShip[] = solo
  ? [member('s-sparrow', 'Sparrow', G1.group_id)]
  : [
      member('s-sparrow', 'Sparrow', G1.group_id),
      member('s-sparrow-iii', 'Sparrow III', G1.group_id),
      member('s-sparrow-iv', 'Sparrow IV', G1.group_id, 'destroyed'),
      member('s-sparrow-v', 'Sparrow V', G1.group_id),
      member('s-sparrow-ii', 'Sparrow II', G2.group_id),
      member('s-kestrel', 'Kestrel', null),
    ]

const HULLS: MainShipRow[] = solo
  ? [hull('s-sparrow', 'Sparrow', 100)]
  : [
      hull('s-sparrow', 'Sparrow', 100),
      hull('s-sparrow-iii', 'Sparrow III', 74),
      hull('s-sparrow-iv', 'Sparrow IV', 0, 'destroyed'),
      hull('s-sparrow-v', 'Sparrow V', 91),
      hull('s-sparrow-ii', 'Sparrow II', 100),
      hull('s-kestrel', 'Kestrel', 100),
    ]

const POSITIONS: FleetPosition[] = solo
  ? [pos('s-sparrow', 'Sparrow', 'docked', HAVEN.id)]
  : [
      pos('s-sparrow', 'Sparrow', 'docked', HAVEN.id),
      pos('s-sparrow-iii', 'Sparrow III', 'hidden', null),
      pos('s-sparrow-iv', 'Sparrow IV', 'hidden', null, 'destroyed'),
      pos('s-sparrow-v', 'Sparrow V', 'hidden', null),
      pos('s-sparrow-ii', 'Sparrow II', 'docked', SLAG.id),
      pos('s-kestrel', 'Kestrel', 'berthed', HAVEN.id),
    ]

// A server-lit fittings read: Sparrow carries two modules, everyone else none.
const FITTINGS: ShipFittingRow[] = [
  {
    module_instance_id: 'm-1',
    main_ship_id: 's-sparrow',
    fitted_at: '2026-08-01T00:00:00Z',
    module_type_id: 'pulse_laser',
    name: 'Pulse Laser',
    slot_type: 'weapon',
    slot_cost: 1,
  },
  {
    module_instance_id: 'm-2',
    main_ship_id: 's-sparrow',
    fitted_at: '2026-08-01T00:00:00Z',
    module_type_id: 'cargo_expander',
    name: 'Cargo Expander',
    slot_type: 'utility',
    slot_cost: 1,
  },
]

const selectable = (s: RosterShip): SelectableShip => ({
  main_ship_id: s.main_ship_id,
  name: s.name,
  status: s.status,
  cargo_capacity_m3: 50,
})

// Exported so react-refresh/only-export-components is satisfied (a file that defines a component
// must export it); the harness entry is this module's default behaviour either way.
export function Harness() {
  const [selectedShipId, setSelectedShipId] = useState<string | null>(null)
  const selected = ROSTER.find((s) => s.main_ship_id === selectedShipId) ?? null
  const selectedHull = selected ? (HULLS.find((h) => h.main_ship_id === selected.main_ship_id) ?? null) : null
  const selectedPos = selected ? POSITIONS.find((p) => p.main_ship_id === selected.main_ship_id) : undefined
  const noop = async () => {}
  return (
    <ShipsView
      loading={false}
      groups={GROUPS}
      rosterShips={ROSTER}
      shipRows={HULLS}
      fleetPositions={POSITIONS}
      locations={LOCATIONS}
      fittings={FITTINGS}
      captains={null}
      selectedShipId={selectedShipId}
      onSelectShip={setSelectedShipId}
      detail={
        <>
          {selected && (
            <FittingDetail
              key={selected.main_ship_id}
              ship={selectable(selected)}
              shipRow={selectedHull}
              hullName="Starter Frigate"
              position={selectedPos}
              locations={LOCATIONS}
              disabledShips={null}
              allFittings={FITTINGS}
              shipCaptains={null}
              refreshKey="harness"
              onLoadoutChanged={noop}
              onIdentityChanged={noop}
            />
          )}
        </>
      }
    />
  )
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <MemoryRouter initialEntries={['/ship']}>
    <div className="h-[100dvh] bg-app text-ink">
      <Harness />
    </div>
  </MemoryRouter>,
)
