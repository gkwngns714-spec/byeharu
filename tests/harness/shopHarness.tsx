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

// SERVER_OFFERS = what get_port_shop returned, i.e. rows the server built with its own
// `where … and o.active` filter (0235:355-358). Everything in this list IS on sale.
// The live catalog, verbatim (production module_types, 2026-08-04).
const SERVER_OFFERS: ShopOffer[] = [
  offer('mining_rig_extension', 'Mining Rig Extension', 'mining', { mining: 8 }, 120, 8,
    'Extraction rig that widens the reach of a mining run.'),
  offer('deep_scan_sensor_array', 'Deep-Scan Sensor Array', 'sensor', { scan: 8 }, null, null,
    'A long-range survey array tuned on recovered anomaly data. Sees what standard sweeps miss.'),
  offer('vector_thruster_kit', 'Vector Thruster Kit', 'engine', { evasion: 3, speed_mult_bonus: 0.1 }),
  offer('expanded_cargo_lattice', 'Expanded Cargo Lattice', 'cargo', { cargo: 25 }),
  offer('shield_lattice', 'Shield Lattice', 'defense', { defense: 12 }),
  offer('autocannon_battery', 'Autocannon Battery', 'weapon', { attack: 10 }, 5, 10),
]

// THE WITHDRAWN ROW (0342's shape, without naming 0342's item). The Autocannon Battery Mk-II is a
// real production module (module_types, anon key 2026-08-04) that no starter port sells — 0235
// asserts the Mk-II tier is deliberately absent from the buy-list. It is rendered here EXACTLY as a
// stale client would render an offer the server has since withdrawn: a full, attractive row with a
// live combat effect, that the server's current answer does not contain.
//
// It is here because "a withdrawn offer cannot be bought" must be provable on the SCREEN without a
// client rule that recognises a particular item id. Its Buy must be dead, and the row must say why
// in the server's own words.
const WITHDRAWN: ShopOffer = offer('autocannon_battery_mk2', 'Autocannon Battery Mk-II', 'weapon',
  { attack: 18 }, 6, 18, 'A heavier autocannon. Not stocked at starter ports.')

const ROWS: { offer: ShopOffer; offered: boolean }[] = [
  ...SERVER_OFFERS.map((o) => ({ offer: o, offered: true })),
  { offer: WITHDRAWN, offered: false },
]

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <div className="min-h-[100dvh] bg-app p-2 text-ink">
      <ul className="space-y-2" data-testid="shop-offers">
        {ROWS.map((r) => (
          <ShopRow
            key={r.offer.ref_id}
            offer={r.offer}
            offered={r.offered}
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
