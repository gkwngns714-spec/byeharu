// OSN-ENABLEMENT-1B (UI proof) — mounts the REAL <PortNavPanel> in a browser with the component's own
// dependency-injection seam, so a Playwright spec can drive the rendered command surface end-to-end.
// No production access: the injected readinessFetcher/portRpc model the post-reveal active-port server
// state; the real authenticated RPC execution is proven separately by the backend journey. Nothing here
// changes product behavior — it only renders the existing component for test.
import { useReducer } from 'react'
import { createRoot } from 'react-dom/client'
import { PortNavPanel } from '../../src/features/map/PortNavPanel'
import type { OsnReadiness } from '../../src/features/map/osnReadiness'
import type { MapLocation } from '../../src/features/map/mapTypes'
import type { MainShipSpaceMovement } from '../../src/features/map/mainshipApi'

type HState = {
  readiness: OsnReadiness
  visibleLocations: MapLocation[]
  shipStatus: string | null
  shipSpatialState: string | null
  spaceMovement: MainShipSpaceMovement | null
  currentDockedLocationId: string | null
}

const w = window as unknown as {
  __state: HState
  __rpcCalls: Array<{ locationId: string; requestId: string }>
  __committed: number
  __rerender: () => void
  __set: (patch: Partial<HState>) => void
}

w.__rpcCalls = []
w.__committed = 0

function Harness() {
  const [, force] = useReducer((n: number) => n + 1, 0)
  w.__rerender = () => force()
  w.__set = (patch) => {
    w.__state = { ...w.__state, ...patch }
    force()
  }
  const s = w.__state
  return (
    <PortNavPanel
      visibleLocations={s.visibleLocations}
      shipStatus={s.shipStatus}
      shipSpatialState={s.shipSpatialState}
      spaceMovement={s.spaceMovement}
      currentDockedLocationId={s.currentDockedLocationId}
      onCommitted={() => {
        w.__committed = (w.__committed || 0) + 1
      }}
      deps={{
        // The server projection — read live from window so the spec can flip it and a refetch picks it up.
        readinessFetcher: async () => w.__state.readiness,
        // Record exactly what the rendered confirm button dispatches (locationId + requestId ONLY).
        portRpc: async (locationId: string, requestId: string) => {
          w.__rpcCalls.push({ locationId, requestId })
          return { ok: true as const }
        },
        stopRpc: async () => ({ ok: true as const, outcome: 'stopped' as const }),
        genRequestId: () => 'req-ui-fixed-1',
      }}
    />
  )
}

createRoot(document.getElementById('root')!).render(<Harness />)
