// ONE REPAIR SURFACE (UI proof) — mounts the REAL <RepairPanel>, exactly as FittingDetail composes
// it, with an injected server API so a Playwright spec can drive the rendered surface across every
// server state (wreck / dent / full hull / adrift / dark flag / failed reads) without a network.
// No production access; nothing connects. The injection seam is the panel's own `api` prop (the
// useDockServices `fetcher` idiom) — production always gets the live one.
import { useEffect, useReducer } from 'react'
import { createRoot } from 'react-dom/client'
import { RepairPanel, type RepairPanelApi } from '../../src/features/ship/RepairPanel'
import type { RepairResult } from '../../src/features/ship/repairApi'
import type { ShipHull } from '../../src/features/ship/repairEconomy'
import type { DisabledShipRow } from '../../src/features/ship/shipRecovery'
import type { EmergencyTowResult } from '../../src/features/ship/shipRecoveryApi'
import type { FleetPositionPlace } from '../../src/features/map/mainshipApi'

const SHIP = 'ship-1'

interface HState {
  shipStatus: string
  disabledShips: DisabledShipRow[] | null
  place: FleetPositionPlace | null
  configRows: Array<{ key: string; value: unknown }>
  /** null → the hull read FAILED (getShipHull's fail-closed answer). */
  hull: ShipHull | null
  wallet: number | null | 'error'
  repairResult: RepairResult
  towResult: EmergencyTowResult
}

interface Calls {
  repair: Array<{ shipId: string | null; hp: number | null }>
  tow: Array<{ shipId: string | null | undefined }>
}

const w = window as unknown as {
  __state: HState
  __calls: Calls
  __set: (p: Partial<HState>) => void
}

w.__calls = { repair: [], tow: [] }

const api: RepairPanelApi = {
  getConfigRows: async () => w.__state.configRows,
  getHull: async () => w.__state.hull,
  getWallet: async () => w.__state.wallet,
  repair: async (shipId, hp) => {
    w.__calls.repair.push({ shipId, hp })
    return w.__state.repairResult
  },
  tow: async (shipId) => {
    w.__calls.tow.push({ shipId })
    return w.__state.towResult
  },
}

// A healthy, fully-configured world; each test flips one clause at a time.
w.__state = {
  shipStatus: 'stationary',
  disabledShips: [],
  place: 'docked',
  configRows: [
    { key: 'repair_economy_enabled', value: true },
    { key: 'repair_credits_per_hp', value: 0 }, // production's live knob: free
    { key: 'starting_credits', value: 500 },
  ],
  hull: { hp: 380, maxHp: 500, status: 'stationary' },
  wallet: 500,
  repairResult: {
    ok: true,
    receipt_id: 'r1',
    main_ship_id: SHIP,
    hp_before: 380,
    hp_after: 500,
    hp_restored: 120,
    credits_per_hp: 0,
    total_price: 0,
    location_id: 'haven',
  },
  towResult: { ok: true, main_ship_id: SHIP, location_id: 'haven', location_name: 'Haven Reach' },
}

// INITIAL state may be seeded from the URL (?s=<json>), so a spec can set the world BEFORE the
// panel's first read. That matters for the fail-closed gates: repairStickyLit deliberately keeps a
// panel lit once this mount has seen the flag enabled, so "the flag was dark all along" can only be
// staged before mount — patching afterwards would be testing the sticky rule, not the dark one.
const seed = new URLSearchParams(window.location.search).get('s')
if (seed) w.__state = { ...w.__state, ...(JSON.parse(seed) as Partial<HState>) }

export function Harness() {
  const [rev, force] = useReducer((n: number) => n + 1, 0)
  // Published from an effect (never the render body) so the spec's driver appears once the tree is
  // mounted — the same thing the react-hooks/immutability rule asks for.
  useEffect(() => {
    w.__set = (patch) => {
      w.__state = { ...w.__state, ...patch }
      force()
    }
  }, [])
  const s = w.__state
  return (
    <RepairPanel
      mainShipId={SHIP}
      shipName="Kestrel"
      shipStatus={s.shipStatus}
      disabledShips={s.disabledShips}
      position={s.place ? { place: s.place } : undefined}
      // A real lifecycle tick on every injected change — the same dep the screen threads down, so
      // the panel re-reads its own wave exactly as it does in the app.
      lifecycleKey={`k${rev}`}
      onChanged={async () => {}}
      api={api}
    />
  )
}

createRoot(document.getElementById('root')!).render(<Harness />)
