// ██ THE ACTION IS ALWAYS REACHABLE (UI proof harness) ██ — the map's overlay rails, WHOLE.
//
// ── WHY THIS EXISTS, AND WHY fleetinfo.html WAS NOT ENOUGH ────────────────────────────────────────
// Owner, playing the LIVE game, 2026-08-08: "right now i can't press hunt." Measured in the running
// page at 1440x675: the "Hunt at Snare" button was NOT disabled (`disabled: false`). Its rect was
// top 391 / bottom 435; the top-left OverlayRail it rides — `max-h-[60%] overflow-y-auto` — ended at
// y=399 with clientHeight 334 against scrollHeight 386. **8 of the button's 44 pixels were inside
// the container.** The rest sat below the fold of a scroll area whose scrollbar is easy to miss.
//
// fleetinfo.html mounts the FleetStatusPanel ALONE in that rail. Alone it always fits, so its proof
// was green while the game was broken. The rail's content in the real game is a STACK — ambush and
// near-miss notices, the combat card, and the fleet readout LAST — and the close-call notice only
// appears near a danger zone, i.e. exactly when the player needs Hunt. This harness mounts the
// STACK, because the stack is where the defect lives.
//
// ── WHAT IS REAL HERE ────────────────────────────────────────────────────────────────────────────
// Every panel is imported from src and composed with the SAME markup and the SAME rail props
// MapScreen gives it (src/features/map/MapScreen.tsx — the top-left rail at :339 and the bottom-right
// command-hub rail at :552). Nothing is stubbed, nothing is re-implemented, nothing connects: the
// panels are props-fed by construction. The one thing the harness adds is a FIXED clock, so an ETA
// is an exact string instead of a race.
//
// CSS parity: harness.css re-exports src/index.css with the @source the harness's own Vite root would
// otherwise hide. Without it the rail loses `absolute` and a measurement measures nothing.
import './harness.css'
import { createRoot } from 'react-dom/client'
import { OverlayPanel, OverlayRail } from '../../src/components/ui'
import { ExplorationPanel } from '../../src/features/exploration/ExplorationPanel'
import { CombatMapCard } from '../../src/features/map/CombatMapCard'
import { MapOverlayTabs } from '../../src/features/map/MapOverlayTabs'
import type { MapOverlayTabId } from '../../src/features/map/mapOverlayTabModel'
import { FleetCommandPanel } from '../../src/features/map/FleetCommandPanel'
import { FleetStatusPanel } from '../../src/features/map/FleetStatusPanel'
import { ZoneInfoPanel } from '../../src/features/map/ZoneInfoPanel'
import { buildZoneInfo } from '../../src/features/map/zoneInfoModel'
import type { MapLocation } from '../../src/features/map/mapTypes'
import type { FleetPosition } from '../../src/features/map/mainshipApi'
import type { DangerZoneLite } from '../../src/features/map/pirateApi'
import type { GroupRow, ShipGroupMapEntry } from '../../src/features/command/teamRoster'
import type { UnifiedGroupFleetLite } from '../../src/features/command/teamApi'
import type { FleetMovement } from '../../src/features/fleets/fleetTypes'
import type { CombatEncounter, CombatUnit } from '../../src/features/combat/combatTypes'
import type { SiteLootEntry } from '../../src/features/combat/combatApi'
import type { Hold } from '../../src/features/inventory/hold'

/** A FIXED clock — an asserted ETA must not depend on when the proof runs. */
const NOW = Date.parse('2026-08-04T12:00:00.000Z')

const params = new URLSearchParams(window.location.search)
/**
 * zone     — THE OWNER'S LIVE SHAPE: the close-call notice + the fleet readout offering Hunt.
 * crowded  — the same, with every notice the rail can carry (an ambush + three near misses).
 * fight    — a live battle: the combat card (its own Retreat) above the readout (its Retreat).
 * fleets   — THREE fleets all standing on the same huntable site: the readout at its tallest.
 * hub      — the bottom-right command hub: header + the real FleetCommandPanel (Stop/Go/Dock/Hunt).
 * zoneinfo — the bottom-right hub carrying the zone panel and its hunt-site signpost.
 */
const scenario = params.get('s') ?? 'zone'
// `?t=` forces the OPEN TAB (explore | fight | fleets | none). Absent, the rail resolves it exactly
// as the game does. It exists because the tabs made the rail's tallest state a CHOICE rather than an
// accumulation: proving "the rail fits" now means proving it for EVERY tab, not for whichever one
// happens to open.
const tabParam = params.get('t')
const forcedTab: MapOverlayTabId | null | undefined =
  tabParam === null ? undefined : tabParam === 'none' ? null : (tabParam as MapOverlayTabId)

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

// Production names and the production pairing: the Snare SITE, wrapped by a zone that shares its name.
const HAVEN = loc({ id: 'loc-haven', name: 'Haven', x: 0, y: 0 })
const SLAG = loc({ id: 'loc-slag', name: 'Slagworks', x: -300, y: 220 })
const SNARE = loc({
  id: 'loc-snare',
  name: 'Snare',
  x: 500,
  y: 500,
  location_type: 'pirate_hunt',
  activity_type: 'hunt_pirates',
  territory_radius: 40,
})
const LOCATIONS: MapLocation[] = [HAVEN, SLAG, SNARE]

const G1: GroupRow = { group_id: 'g-fleet-1', group_index: 1, name: 'Fleet 1' }
const G2: GroupRow = { group_id: 'g-fleet-2', group_index: 2, name: 'Fleet 2' }
/** The hub scenarios carry BOTH fleets, because two fleets is what makes the command panel tall. */
const G3: GroupRow = { group_id: 'g-fleet-3', group_index: 3, name: 'Fleet 3' }
/** The hub scenarios carry TWO fleets (that is what makes the command panel tall); `fleets` carries
 *  THREE, the realistic upper end of what a player parks in one zone (max_active_fleets is 6). */
const GROUPS: GroupRow[] =
  scenario === 'fleets3' ? [G1, G2, G3] : scenario === 'fleets' ? [G1, G2] : scenario === 'hub' || scenario === 'zoneinfo' ? [G1, G2] : [G1]

const inFleet = (group_id: string, is_command_ship: boolean): ShipGroupMapEntry => ({
  group_id,
  captain_slots: 2,
  is_command_ship,
})
const MEMBERSHIP: Record<string, ShipGroupMapEntry> = {
  'ship-sparrow': inFleet(G1.group_id, true),
  'ship-sparrow-ii': inFleet(G1.group_id, false),
  'ship-kestrel': inFleet(G2.group_id, true),
  'ship-petrel': inFleet(G3.group_id, true),
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

/** Parked in open space ON the Snare — the fleet standing on the fight it cannot start. */
const parked = (id: string, x: number, y: number) =>
  pos({ main_ship_id: id, place: 'in_space', space_x: x, space_y: y })

const POSITIONS: FleetPosition[] = [
  parked('ship-sparrow', 500, 500),
  parked('ship-sparrow-ii', 500, 500),
  ...(GROUPS.length > 1 ? [parked('ship-kestrel', 480, 520)] : []),
  ...(GROUPS.length > 2 ? [parked('ship-petrel', 510, 490)] : []),
]

const FLEETS: UnifiedGroupFleetLite[] = GROUPS.map((g, i) => ({
  id: `fleet-${i + 1}`,
  group_id: g.group_id,
  status: 'idle',
  location_mode: 'space',
  current_location_id: null,
  space_x: [500, 480, 510][i] ?? 500,
  space_y: [500, 520, 490][i] ?? 500,
}))

const MOVEMENTS: FleetMovement[] = []

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
const ZONES: DangerZoneLite[] = [ZONE]

const ENCOUNTERS: CombatEncounter[] =
  scenario === 'fight'
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
          // THE PRESSURE CLOCK (0344/0347). A fight in the tallest state the FIGHT tab can reach:
          // a running countdown, a scheduled ordinal, and a field standing AT its stamped cap —
          // which is precisely the state the readout must NOT turn into a promise either way.
          next_reinforcement_at: new Date(NOW + 12_000).toISOString(),
          pressure_wave_index: 4,
          pressure_effective_cap: 4,
          total_rewards_json: { metal: 1115, items: [{ item_id: 'scrap', quantity: 12 }, { item_id: 'pirate_alloy', quantity: 3 }] },
          started_at: new Date(NOW - 30_000).toISOString(),
          retreat_started_at: null,
          ended_at: null,
          engagement_x: 500,
          engagement_y: 500,
        } as CombatEncounter,
      ]
    : []

const unit = (id: string, side: 'player' | 'enemy'): CombatUnit =>
  ({
    id,
    encounter_id: 'enc-1',
    unit_type_id: side === 'player' ? null : 'pirate_raider',
    main_ship_id: side === 'player' ? 'ship-sparrow' : null,
    ship_hp: 120,
    // A unit row is a STACK. The enemy side stands at FOUR bodies against the encounter's stamped
    // cap of four — the field exactly AT its limit, which is the state a client-side reading of the
    // engine's spawn rule would be most tempted to turn into a promise, and therefore the state the
    // fight tab must be measured in.
    initial_count: side === 'player' ? 1 : 4,
    alive_count: side === 'player' ? 1 : 4,
    hp_max: 120,
    hp_current: side === 'player' ? 78 : 90,
    pos_x: 500,
    pos_y: 500,
    side,
  }) as CombatUnit

const UNITS: CombatUnit[] = scenario === 'fight' ? [unit('u-mine', 'player'), unit('u-theirs', 'enemy')] : []

// ── THE FIGHT TAB'S THREE EXTRA READS ────────────────────────────────────────────────────────────
// Catalog volumes (item_types), the fleet's hold exactly as get_my_hold reports it (0333), and what
// the site drops per kill (0348 get_site_loot). All three are what the haul section needs to answer
// "stay for one more kill, or leave with this", so the harness carries them at their real shape —
// a proof that renders the section with all of them missing measures a shorter panel than the game's.
const ITEM_VOLUMES = new Map<string, number>([
  ['scrap', 0.5],
  ['pirate_alloy', 0.5],
  ['weapon_parts', 0.2],
])
const HOLDS: Record<string, Hold> = {
  'enc-1': {
    ok: true,
    items: [],
    usedM3: 22.7,
    capacityM3: 250,
    freeM3: 227.3,
    overCapacity: false,
  },
}
const SITE_LOOT: Record<string, SiteLootEntry[]> = {
  [SNARE.id]: [
    { item_id: 'pirate_alloy', quantity: 1, drop_chance: 1 },
    { item_id: 'scrap', quantity: 1, drop_chance: 1 },
    { item_id: 'weapon_parts', quantity: 1, drop_chance: 0.25 },
  ],
}

// ── THE NOTICES ──────────────────────────────────────────────────────────────────────────────────
// The owner's live rail carried the close-call line verbatim. A notice is pure text — it is the
// INFORMATION half of the rail, and it is what pushed the action off the bottom.
const NEAR_MISS = 'Slipped past the pirates around Snare.'
const nearMisses =
  scenario === 'crowded'
    ? [NEAR_MISS, NEAR_MISS, 'Slipped past the pirates around Driftmarch.']
    : [NEAR_MISS]
const ambushes = scenario === 'crowded' ? ['Ambushed near Snare — the fleet is holding at the strike point.'] : []

const w = window as unknown as { __huntSiteCalls: string[] }
w.__huntSiteCalls = []
const onHuntSite = (locationId: string) => {
  w.__huntSiteCalls.push(locationId)
}

// ── THE TOP-LEFT RAIL — MapScreen.tsx, prop for prop ─────────────────────────────────────────────
// The account (children) is the NOTICES; the reach is the TAB SHELL, which is what MapScreen now
// mounts there. The three readouts are the REAL components, constructed here with the same props
// MapScreen gives them — including the ExplorationPanel, which is server-lit and whose RPC the proof
// routes to an {ok:true} envelope.
//
// WHAT CHANGED, AND WHY THE PROOF IS STRONGER FOR IT: the rail used to STACK all three, and the
// stack was the defect's home. It can no longer stack — at most one body is mounted — so the thing
// to prove moved with it: every TAB must fit, not just the one that opens by default. `?t=` drives
// that, and the uispec sweeps all four states (each tab, and none) at every viewport.
const topLeftRail = (
    <OverlayRail
      slot="top-left"
      className="w-72 max-w-[calc(100vw-5rem)]"
      reach={
        <MapOverlayTabs
          encounters={ENCOUNTERS}
          // The pinned fight row reads the wave clock through the ONE leaf, with the same rows and
          // the same FIXED clock the fight tab's card gets — so the two are asserted to agree
          // exactly, in every tab state, which is the whole point of pinning it there.
          units={UNITS}
          nowMs={NOW}
          onCombatChanged={() => {}}
          openTab={forcedTab}
          explore={
            <ExplorationPanel lifecycleKey="harness" mainShipId="ship-sparrow" shipStatus="home" shipSpatialState={null} />
          }
          fight={
            <CombatMapCard
              encounters={ENCOUNTERS}
              units={UNITS}
              ticks={[]}
              autoExit={{}}
              itemVolumes={ITEM_VOLUMES}
              holds={HOLDS}
              siteLoot={SITE_LOOT}
              nowMs={NOW}
            />
          }
          fleets={
            <FleetStatusPanel
              groups={GROUPS}
              membership={MEMBERSHIP}
              positions={POSITIONS}
              locations={LOCATIONS}
              movements={MOVEMENTS}
              unifiedFleets={FLEETS}
              dangerZones={ZONES}
              encounters={ENCOUNTERS}
              units={UNITS}
              fleetControlEnabled
              combatTickSeconds={3}
              nowMs={NOW}
              onSelectHuntSite={onHuntSite}
              onCombatChanged={() => {}}
            />
          }
        />
      }
    >
      {ambushes.map((text, i) => (
        <OverlayPanel key={`amb-${i}`} tone="danger" data-testid={`map-ambush-notice-${i}`} className="w-64">
          <p className="text-xs font-semibold text-danger">{text}</p>
        </OverlayPanel>
      ))}
      {nearMisses.map((text, i) => (
        <OverlayPanel key={`nm-${i}`} data-testid={`map-near-miss-${i}`} className="w-64">
          <p className="text-xs font-semibold text-warning">{text}</p>
        </OverlayPanel>
      ))}
    </OverlayRail>
  )


// ── THE BOTTOM-RIGHT COMMAND HUB — MapScreen.tsx:552, prop for prop ──────────────────────────────
const zoneInfo = buildZoneInfo(ZONE, LOCATIONS)
const hubRail = (
    <OverlayRail
      slot="bottom-right"
      className="max-w-[calc(100vw-1.5rem)]"
      // The hub is ALL action — the header's ✕ is the only way to dismiss it — so nothing here
      // scrolls and the whole rail is `reach`, exactly as MapScreen composes it.
      reach={
        <>
          <OverlayPanel data-testid="map-command-panel-header" className="flex w-72 max-w-full items-center gap-2">
            <p className="min-w-0 flex-1 truncate text-sm font-semibold text-ink">
              {scenario === 'zoneinfo' ? zoneInfo.title : 'Send fleet'}
            </p>
            <button
              type="button"
              aria-label="Close"
              data-testid="map-command-panel-close"
              className="-mr-1 flex h-7 w-7 shrink-0 items-center justify-center rounded text-ink-faint"
            >
              ✕
            </button>
          </OverlayPanel>
          {scenario === 'zoneinfo' ? (
            <ZoneInfoPanel info={zoneInfo} onHuntSite={onHuntSite} />
          ) : (
            <FleetCommandPanel
              target={{ kind: 'port', locationId: SNARE.id }}
              movements={MOVEMENTS}
              groups={GROUPS}
              groupsLoaded
              unifiedEnabled
              unifiedFleets={FLEETS}
              rollups={[]}
              locations={LOCATIONS}
              dangerZones={ZONES}
              ships={[
                { main_ship_id: 'ship-sparrow', status: 'home' },
                { main_ship_id: 'ship-sparrow-ii', status: 'home' },
                { main_ship_id: 'ship-kestrel', status: 'home' },
              ]}
              membership={MEMBERSHIP}
              launchFromDock
              fleetControlEnabled
              timedDockingEnabled={false}
              onCommanded={() => {}}
              onClearTarget={() => {}}
              onSelectHuntSite={onHuntSite}
            />
          )}
        </>
      }
    />
  )

const bottom = scenario === 'hub' || scenario === 'zoneinfo'

// ── THE MAP BOX IS NOT THE VIEWPORT — and getting that wrong is how a proof lies ──────────────────
// The owner's live measurement: the rail's clientHeight was 334 under a `max-h-[60%]` cap ⇒ the MAP
// BOX was 557px tall inside a 675px viewport. 118px of it is chrome. A harness that hands the rail
// the whole viewport measures a box 118px more generous than the game's, and then reports "it fits"
// about a layout that does not.
//
// So the chrome is REPRODUCED, class for class, from the real shell instead of subtracted as a magic
// number: AppShell's `flex h-[100dvh] flex-col` + its `min-h-11 border-b` header + the
// `min-h-0 flex-1 overflow-hidden` main + the NavBar's `border-t` bar of 44px cells, and MapScreen's
// own `relative flex-1 p-2` map area wrapping the `relative h-full w-full` box the rails are
// absolute inside. Derived the way the app derives it, so it stays true when the chrome changes.
createRoot(document.getElementById('root') as HTMLElement).render(
  <div className="flex h-[100dvh] flex-col bg-app text-ink">
    <header className="flex min-h-11 items-center border-b border-edge bg-surface pl-4 pr-1">
      <span className="font-mono text-xs uppercase tracking-wider text-ink-faint">Byeharu</span>
    </header>
    <main className="min-h-0 flex-1 overflow-hidden">
      <div className="relative flex h-full flex-col overflow-hidden">
        <div className="relative flex-1 p-2">
          <div className="relative h-full w-full" data-testid="map-host">
            {bottom ? hubRail : topLeftRail}
          </div>
        </div>
      </div>
    </main>
    <nav aria-label="Primary" className="border-t border-edge bg-surface">
      <div className="mx-auto grid max-w-3xl grid-cols-6">
        {['Map', 'Fleet', 'Port', 'Ops', 'Assets', 'More'].map((t) => (
          <span key={t} className="flex min-h-11 flex-col items-center justify-center gap-0.5 py-1.5 text-[11px]">
            <span className="h-5 w-5" />
            {t}
          </span>
        ))}
      </div>
    </nav>
  </div>,
)
