// OSN-COORD-ENABLE-1C (UI proof) — mounts the REAL <GalaxyMap> via its dependency-injection seam so a
// Playwright spec can prove the empty-space coordinate command surface mounts/unmounts SOLELY from the
// server-derived runtime capability (coordinate_travel_available) + existing ship eligibility — never the
// retired compile-time constant. No production access: the injected readinessFetcher models the server
// projection and `spaceMoveEnabled` injects the movement-domain flag; nothing connects. The fetcher mirrors
// the real API layer's fail-closed contract (a fetch failure resolves to OSN_NOT_ACTIONABLE).
import { useReducer } from 'react'
import { createRoot } from 'react-dom/client'
import { GalaxyMap } from '../../src/features/map/GalaxyMap'
import { OSN_NOT_ACTIONABLE, type OsnReadiness } from '../../src/features/map/osnReadiness'
import type { MainShipLite } from '../../src/features/map/useGalaxyMapData'

type HState = {
  coordinateTravelAvailable: boolean
  fail: boolean
  spaceMoveEnabled: boolean
  shipPresent: boolean
  shipStatus: string
  shipSpatialState: string
}

const w = window as unknown as {
  __state: HState
  __rerender: () => void
  __set: (patch: Partial<HState>) => void
}

w.__state ??= {
  coordinateTravelAvailable: false,
  fail: false,
  spaceMoveEnabled: true,
  shipPresent: true,
  shipStatus: 'stationary',
  shipSpatialState: 'in_space',
}

function ship(s: HState): MainShipLite | null {
  if (!s.shipPresent) return null
  return {
    main_ship_id: 'ship-harness-1',
    name: 'Test Ship',
    status: s.shipStatus,
    hull_type_id: 'starter_frigate',
    hp: 500,
    max_hp: 500,
    shield: 0, // SHIELD-2: the 0191 columns ride the owner-ship read (0/0 = shieldless, prod today)
    max_shield: 0,
    cargo_capacity: 50,
    spatial_state: s.shipSpatialState as MainShipLite['spatial_state'],
    space_x: 0,
    space_y: 0,
  }
}

function Harness() {
  const [, force] = useReducer((n: number) => n + 1, 0)
  w.__rerender = () => force()
  w.__set = (patch) => {
    w.__state = { ...w.__state, ...patch }
    force()
  }
  const s = w.__state
  return (
    <GalaxyMap
      locations={[]}
      base={null}
      mainShip={ship(s)}
      mainShipFleet={null}
      mainShipPresence={null}
      mainShipSpaceMovement={null}
      mainshipSendEnabled={false}
      movements={[]}
      teamGroups={[]}
      dockedTeamRollups={[]}
      teamRepresentedShipIds={[]}
      fleetPositions={[]}
      unifiedGroupFleets={[]}
      fleetMovementUnifiedEnabled={false}
      onFleetGo={() => {}}
      selectedId={null}
      onSelect={() => {}}
      deps={{
        spaceMoveEnabled: s.spaceMoveEnabled,
        readinessFetcher: async (): Promise<OsnReadiness> =>
          s.fail
            ? OSN_NOT_ACTIONABLE
            : {
                osnAvailable: true,
                originCategory: 'anchored',
                reason: 'none',
                eligibleDestinationIds: [],
                coordinateTravelAvailable: s.coordinateTravelAvailable,
              },
      }}
    />
  )
}

createRoot(document.getElementById('root')!).render(<Harness />)
