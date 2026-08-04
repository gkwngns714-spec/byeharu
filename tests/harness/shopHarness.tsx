import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { ShopRow } from '../../src/features/port/ShopPanel'
import type { ShopOffer } from '../../src/features/port/portShop'
import './harness.css'

// PORT-SHOP TRUTH — the harness for tests/shopTellsTheTruth.uispec.ts. It mounts the REAL <ShopRow>
// — the component the game ships — over the REAL production catalog rows, read off module_types
// with the anon key on 2026-08-04.
//
// Why a rendered proof: "the dormant chip is gone" and "the Buy button is withdrawn" are claims
// about pixels. A pure spec can only show that offerStatChips() omitted an entry; only a render can
// show that nothing downstream put it back, that the not-implemented sentence actually reaches the
// screen, and that none of it clips or scrolls sideways at the 288px floor.
//
// The shop's own fetch is not injectable, so the row — not the panel — is what mounts. Nothing
// connects: no fetcher, no wallet read, no buy.

const offer = (
  ref: string,
  name: string,
  slot: string,
  stats: Record<string, number> | null,
  range: number | null = null,
  power: number | null = null,
  description: string | null = null,
): ShopOffer => ({
  kind: 'module',
  ref_id: ref,
  price: 110,
  name,
  slot_type: slot,
  slot_cost: 1,
  stats_json: stats,
  range,
  power,
  ammo_type: null,
  category: null,
  rarity: null,
  description,
})

// The live catalog, verbatim (production module_types, 2026-08-04).
const OFFERS: ShopOffer[] = [
  offer('mining_rig_extension', 'Mining Rig Extension', 'mining', { mining: 8 }, 120, 8,
    'Extraction rig that widens the reach of a mining run.'),
  offer('deep_scan_sensor_array', 'Deep-Scan Sensor Array', 'sensor', { scan: 8 }, null, null,
    'A long-range survey array tuned on recovered anomaly data. Sees what standard sweeps miss.'),
  offer('vector_thruster_kit', 'Vector Thruster Kit', 'engine', { evasion: 3, speed_mult_bonus: 0.1 }),
  offer('expanded_cargo_lattice', 'Expanded Cargo Lattice', 'cargo', { cargo: 25 }),
  offer('shield_lattice', 'Shield Lattice', 'defense', { defense: 12 }),
  offer('autocannon_battery', 'Autocannon Battery', 'weapon', { attack: 10 }, 5, 10),
]

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <div className="min-h-[100dvh] bg-app p-2 text-ink">
      <ul className="space-y-2" data-testid="shop-offers">
        {OFFERS.map((o) => (
          <ShopRow
            key={o.ref_id}
            offer={o}
            qty={1}
            setQty={() => {}}
            pending={false}
            anyPending={false}
            note={null}
            knownCredits={100000}
            onBuy={() => {}}
          />
        ))}
      </ul>
    </div>
  </StrictMode>,
)
