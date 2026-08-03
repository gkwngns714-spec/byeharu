// HUNT DISCOVERABILITY (UI proof) — mounts the REAL <ZoneInfoPanel> and the REAL <NearMissSection>,
// imported from src untouched, so a Playwright spec can drive the two surfaces this slice added:
//
//   · the SIGNPOST — the button that takes a player from "what is this shaded blob?" to the site
//     they can actually fight at. The owner spent an afternoon aiming at the Snare ZONE while the
//     hunt control waited behind the Snare SITE's marker, and nothing on the zone panel said so.
//     The proof that matters is not that the model returns a label but that the button RENDERS and
//     hands back the right location id — the map turns that id into the existing hunt surface.
//
//   · the NEAR MISS — a crossing that was rolled for and missed, which used to be indistinguishable
//     from a broken game. Driven here across the states that decide whether it may speak at all.
//
// No production access; nothing connects. Both components are pure props-in (the zone panel takes
// its words from zoneInfoModel; the section takes its rows from shell state), so the harness only
// has to supply data and record the callback.
import { createRoot } from 'react-dom/client'
import { ZoneInfoPanel } from '../../src/features/map/ZoneInfoPanel'
import { NearMissSection } from '../../src/features/combat/NearMissSection'
import { buildZoneInfo } from '../../src/features/map/zoneInfoModel'
import type { DangerZoneLite, InterceptMissLite } from '../../src/features/map/pirateApi'
import type { MapLocation } from '../../src/features/map/mapTypes'

const params = new URLSearchParams(window.location.search)
/** 'site' (a zone wrapped around a huntable site) | 'loose' (a zone with nothing to fight at) */
const zoneCase = params.get('zone') ?? 'site'
/** 'settled' (the leg is over → announceable) | 'inflight' (still flying) | 'none' (no rolls) */
const missCase = params.get('miss') ?? 'settled'

const SNARE: MapLocation = {
  id: 'loc-snare',
  name: 'Snare',
  location_type: 'pirate_hunt',
  x: -45,
  y: 120,
  base_difficulty: 10,
  reward_tier: 2,
  activity_type: 'hunt_pirates',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  territory_radius: null,
} as MapLocation

const ZONE: DangerZoneLite = {
  id: 'z-snare',
  name: 'Snare',
  source: 'drawn',
  // The whole point of the signpost: danger_zones already carries the site it wraps.
  location_id: zoneCase === 'site' ? 'loc-snare' : null,
  ring: [
    [-80, 80],
    [-10, 80],
    [-10, 160],
    [-80, 160],
    [-80, 80],
  ],
  revision: 1,
}

const MISSES: InterceptMissLite[] =
  missCase === 'none'
    ? []
    : [
        {
          id: 'pim-1',
          movement_id: 'mv-1',
          location_id: 'loc-snare',
          // Fixed and recent; the section keeps every miss regardless of age (NEAR_MISS_KEEP_ALL),
          // so this proof never depends on a live clock.
          created_at: new Date(Date.now() - 60_000).toISOString(),
        },
      ]

const w = window as unknown as { __huntSiteCalls: string[] }
w.__huntSiteCalls = []

// Rendered WITHOUT a wrapper component on purpose: the fixture is fully static, so there is no
// state to hold, and a local component in a file with no exports trips react-refresh's rule.
const ZONE_INFO = buildZoneInfo(ZONE, [SNARE])

createRoot(document.getElementById('root')!).render(
  <div>
    <ZoneInfoPanel
      info={ZONE_INFO}
      onHuntSite={(locationId) => {
        w.__huntSiteCalls.push(locationId)
      }}
    />
    <NearMissSection
      misses={MISSES}
      locations={[SNARE]}
      // Rule 3: a leg still in the active list means the crossing has not happened yet.
      activeMovementIds={missCase === 'inflight' ? ['mv-1'] : []}
    />
  </div>,
)
