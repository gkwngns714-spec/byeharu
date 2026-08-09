// LOOK HARNESS (test only) — fixture data + the offline network stub for look.html.
//
// TWO jobs, one module (it must be the FIRST import of lookHarness.tsx):
//   1. Install a window.fetch stub BEFORE ../../src/lib/supabase.ts evaluates — supabase-js
//      captures the global fetch reference when the client is constructed at module scope, so the
//      stub has to be in place before any src import. This module therefore imports NOTHING from
//      src at runtime (type-only imports are erased by verbatimModuleSyntax). The stub answers the
//      supabase REST/auth endpoints from the fixtures below; every other request (Vite modules,
//      fonts) passes through untouched. No production access; nothing connects.
//   2. Export buildShellState() — the injected ShellState fixture the real screens read via
//      <ShellStateContext.Provider>, in two flavors keyed by ?state=:
//        'active' — a mid-game player: 3 ships, 1 fleet, docked at a port, reports, inventory
//        'empty'  — a brand-new player: no ships, no fleets, no reports
//
// HONESTY: the screens themselves are 100% real (imported from src, untouched). Server-lit panels
// whose RPCs the stub does NOT serve get a 404 → their own normalize-don't-throw wrappers collapse
// to the dark default → the panel hides, exactly as in a dark production env.

import type { ShellState } from '../../src/app/shellState'
import type { GameState } from '../../src/features/dashboard/useGameState'
import type { CombatState } from '../../src/features/combat/useCombat'
import type { GalaxyMapData, LocationMeta, MainShipLite } from '../../src/features/map/useGalaxyMapData'
import type { MainShipSelection, SelectableShip } from '../../src/features/map/useMainShipSelection'
import type { MapLocation, LocationState } from '../../src/features/map/mapTypes'
import type { Fleet, LocationPresence } from '../../src/features/fleets/fleetTypes'
import type { Base } from '../../src/features/base/baseTypes'
import type { CombatReport } from '../../src/features/combat/combatTypes'
import type { FleetPosition } from '../../src/features/map/mainshipApi'
import type { InterceptMissLite } from '../../src/features/map/pirateApi'
import type { GroupRow, ShipGroupMapEntry } from '../../src/features/command/teamRoster'
import type { DockedTeamRollup } from '../../src/features/command/teamRollup'
import type { UnitType } from '../../src/lib/catalog'
import type { MiningField } from '../../src/features/mining/miningTypes'

export type LookState = 'active' | 'empty'
// MISSION-TAB: 'mission' replaced 'command' as the ops destination; 'command' stays accepted as an
// alias so older screenshot invocations keep resolving (it renders the same MissionScreen).
export type LookScreen = 'ship' | 'fleet' | 'port' | 'mission' | 'command' | 'map'

/** The ?state= flavor, read live so the net stub and the harness agree per page load. */
export function currentLookState(): LookState {
  return new URLSearchParams(window.location.search).get('state') === 'empty' ? 'empty' : 'active'
}

export function currentLookScreen(): LookScreen {
  const s = new URLSearchParams(window.location.search).get('screen')
  return s === 'ship' || s === 'fleet' || s === 'port' || s === 'mission' || s === 'command' || s === 'map'
    ? s
    : 'mission'
}

// ── the world (shared by both states — a new player sees the same galaxy) ───────────────────────

const LOCATIONS: MapLocation[] = [
  { id: 'loc-haven', name: 'Haven', location_type: 'trade_outpost', x: 120, y: 80, base_difficulty: 0, reward_tier: 1, activity_type: 'trade_visit', min_power_required: 0, is_public: true, status: 'active', territory_radius: 40 },
  { id: 'loc-slagworks', name: 'Slagworks', location_type: 'trade_outpost', x: -160, y: 40, base_difficulty: 0, reward_tier: 2, activity_type: 'trade_visit', min_power_required: 0, is_public: true, status: 'active', territory_radius: 36 },
  { id: 'loc-driftwatch', name: 'Driftwatch', location_type: 'trade_outpost', x: 60, y: -150, base_difficulty: 0, reward_tier: 1, activity_type: 'trade_visit', min_power_required: 0, is_public: true, status: 'active', territory_radius: 32 },
  { id: 'loc-vex', name: 'Vex Hollow', location_type: 'pirate_hunt', x: -40, y: 170, base_difficulty: 12, reward_tier: 3, activity_type: 'hunt_pirates', min_power_required: 40, is_public: true, status: 'active', territory_radius: null },
  { id: 'loc-calm', name: 'Calm Belt', location_type: 'safe_zone', x: 210, y: -60, base_difficulty: 0, reward_tier: 0, activity_type: 'none', min_power_required: 0, is_public: true, status: 'active', territory_radius: null },
]

const META: Record<string, LocationMeta> = {
  'loc-haven': { sectorName: 'Cyra Reach', zoneName: 'Haven Approaches' },
  'loc-slagworks': { sectorName: 'Cyra Reach', zoneName: 'Smelter Line' },
  'loc-driftwatch': { sectorName: 'Cyra Reach', zoneName: 'Outer Drift' },
  'loc-vex': { sectorName: 'Cyra Reach', zoneName: 'Vex Margin' },
  'loc-calm': { sectorName: 'Cyra Reach', zoneName: 'Calm Belt' },
}

const MINING_FIELDS: MiningField[] = [{ name: 'Cinder Veil', space_x: -90, space_y: -90 }]
const MINING_EXTRACT_RADIUS = 60

const LOCATION_STATES: Record<string, LocationState> = {
  'loc-vex': { location_id: 'loc-vex', pressure: 12, danger_modifier: 1.2, active_fleets: 1 },
}

// ── the active player's ships / fleet ───────────────────────────────────────────────────────────

interface ShipSeed {
  id: string
  name: string
  hull: string
  status: string
  hp: number
  maxHp: number
  cargo: number
  cargoM3: number
  captainSlots: number
  moduleSlots: number
  groupId: string | null
  isCommand: boolean
  place: FleetPosition['place']
  locationId: string | null
  createdAt: string
}

const SHIPS: ShipSeed[] = [
  { id: 'ship-dawn', name: 'Dawnbreaker', hull: 'starter_frigate', status: 'home', hp: 86, maxHp: 120, cargo: 24, cargoM3: 30, captainSlots: 2, moduleSlots: 4, groupId: 'grp-strike', isCommand: true, place: 'docked', locationId: 'loc-haven', createdAt: '2026-07-01T09:00:00Z' },
  { id: 'ship-haul', name: 'Long Haul', hull: 'ironclad_hauler', status: 'home', hp: 160, maxHp: 160, cargo: 60, cargoM3: 60, captainSlots: 2, moduleSlots: 3, groupId: 'grp-strike', isCommand: false, place: 'docked', locationId: 'loc-haven', createdAt: '2026-07-10T09:00:00Z' },
  { id: 'ship-wind', name: 'Windward', hull: 'starter_frigate', status: 'home', hp: 64, maxHp: 120, cargo: 24, cargoM3: 30, captainSlots: 2, moduleSlots: 4, groupId: null, isCommand: false, place: 'berthed', locationId: 'loc-slagworks', createdAt: '2026-07-20T09:00:00Z' },
]

const GROUPS: GroupRow[] = [{ group_id: 'grp-strike', group_index: 1, name: 'Strike Group 1' }]

const GROUP_MAP: Record<string, ShipGroupMapEntry> = Object.fromEntries(
  SHIPS.map((s) => [s.id, { group_id: s.groupId, captain_slots: s.captainSlots, is_command_ship: s.isCommand }]),
)

const FLEET_POSITIONS: FleetPosition[] = SHIPS.map((s) => ({
  main_ship_id: s.id,
  name: s.name,
  class: s.hull,
  status: s.status,
  place: s.place,
  location_id: s.locationId,
  segment: null,
}))

const DOCKED_ROLLUPS: DockedTeamRollup[] = [
  { groupId: 'grp-strike', name: 'Strike Group 1', memberCount: 2, dockedCount: 2, locationId: 'loc-haven' },
]

const MAIN_SHIP_LITE: MainShipLite = {
  main_ship_id: 'ship-dawn', name: 'Dawnbreaker', status: 'home', hull_type_id: 'starter_frigate',
  hp: 86, max_hp: 120, shield: 0, max_shield: 0, cargo_capacity: 24,
}

const SELECTABLE_SHIPS: SelectableShip[] = SHIPS.map((s) => ({
  main_ship_id: s.id, name: s.name, status: s.status, cargo_capacity_m3: s.cargoM3,
}))

// ── the rest of the game state ──────────────────────────────────────────────────────────────────

const BASE: Base = {
  id: 'base-look', player_id: 'look-user', name: 'Field Command', sector_id: null,
  x: 0, y: 0, status: 'active', created_at: '2026-07-01T00:00:00Z',
}

const UNIT_TYPES: UnitType[] = [
  { id: 'fighter', name: 'Fighter', attack: 6, defense: 4, hull: 20, speed: 9, cargo: 2, power_score: 10, build_time_seconds: 60, metal_cost: 25, status: 'active' },
  { id: 'corvette', name: 'Corvette', attack: 14, defense: 10, hull: 60, speed: 6, cargo: 8, power_score: 30, build_time_seconds: 180, metal_cost: 90, status: 'active' },
]

const CONFIG: Record<string, number> = {
  retreat_delay_seconds: 20,
  mining_extract_radius: MINING_EXTRACT_RADIUS,
  starting_credits: 400,
}

const REPORTS: CombatReport[] = [
  {
    id: 'rep-1', encounter_id: 'enc-1', fleet_id: null, location_id: 'loc-vex', result: 'completed',
    waves_cleared: 3, duration_seconds: 222, total_losses_json: { fighter: 2 },
    total_rewards_json: { metal: 120, credits: 60 }, survivors_json: { fighter: 5, corvette: 1 },
    summary_text: null, created_at: '2026-08-01T09:12:00Z',
  },
  {
    id: 'rep-2', encounter_id: 'enc-2', fleet_id: null, location_id: 'loc-vex', result: 'defeat',
    waves_cleared: 1, duration_seconds: 98, total_losses_json: { fighter: 4 },
    total_rewards_json: {}, survivors_json: {}, summary_text: null, created_at: '2026-07-30T18:40:00Z',
  },
]

const FLEETS: Fleet[] = [
  {
    id: 'flt-strike', player_id: 'look-user', origin_base_id: null, status: 'present',
    location_mode: 'location', current_location_id: 'loc-haven', active_movement_id: null,
    main_ship_id: null, created_at: '2026-08-01T08:00:00Z', updated_at: '2026-08-02T08:00:00Z',
  },
]

const PRESENCES: LocationPresence[] = [
  { id: 'pres-1', fleet_id: 'flt-strike', location_id: 'loc-haven', activity_type: 'trade_visit', status: 'active', entered_at: '2026-08-02T08:00:00Z' },
]

// THE NEAR MISS — one rolled-and-missed crossing on a leg that has already settled (its
// movement_id is absent from `movements: []`, which is exactly what makes it announceable — see
// nearMissNotice rule 3). ACTIVE fixture only, so the look shots show what a player now gets
// instead of the silence they used to get, and the EMPTY (brand-new player) shots stay honestly
// bare. `created_at` is fixed, not relative: the Mission record keeps every miss regardless of age,
// so no screenshot depends on a live clock.
const INTERCEPT_MISSES: InterceptMissLite[] = [
  { id: 'pim-1', movement_id: 'mv-settled', location_id: 'loc-vex', created_at: '2026-08-02T08:04:00Z' },
]

// ── the ShellState fixture ───────────────────────────────────────────────────────────────────────

const noopAsync = async (): Promise<void> => {}

export function buildShellState(state: LookState): ShellState {
  const active = state === 'active'

  const game: GameState & { refresh: () => Promise<void> } = {
    loading: false,
    error: null,
    base: BASE,
    unitTypes: UNIT_TYPES,
    locations: LOCATIONS,
    config: CONFIG,
    fleets: active ? FLEETS : [],
    fleetUnits: [],
    movements: [],
    presences: active ? PRESENCES : [],
    locationStates: LOCATION_STATES,
    mainShip: active
      ? {
          has_ship: true,
          ship: {
            main_ship_id: 'ship-dawn', name: 'Dawnbreaker', status: 'home', hp: 86, max_hp: 120,
            shield: 0, max_shield: 0, cargo_capacity: 24, captain_slots: 2, module_slots: 4,
            hull_type_id: 'starter_frigate',
          },
        }
      : null,
    mainshipSendEnabled: false,
    interceptMisses: active ? INTERCEPT_MISSES : [],
    refresh: noopAsync,
  }

  const combat: CombatState = {
    encounters: [],
    events: [],
    ticks: [],
    units: [],
    reports: active ? REPORTS : [],
    autoExit: {},
    holds: {},
    siteLoot: {},
    refresh: noopAsync,
  }

  const map: GalaxyMapData = {
    loading: false,
    error: null,
    locations: LOCATIONS,
    meta: META,
    mainShip: active ? MAIN_SHIP_LITE : null,
    movements: [],
    locationStates: LOCATION_STATES,
    mainshipSendEnabled: false,
    mainShipFleet: null,
    mainShipPresence: null,
    teamGroups: active ? GROUPS : [],
    teamGroupsOk: true,
    teamGroupMap: active ? GROUP_MAP : {},
    dockedTeamRollups: active ? DOCKED_ROLLUPS : [],
    fleetPositions: active ? FLEET_POSITIONS : [],
    fleetMovementUnifiedEnabled: true,
    unifiedGroupFleets: [],
    combatSortieFleets: [],
    launchFromDockEnabled: true,
    fleetControlEnabled: true,
    timedDockingEnabled: false,
    miningFields: MINING_FIELDS,
    miningExtractRadius: MINING_EXTRACT_RADIUS,
    combatTickSeconds: 3,
    itemVolumes: new Map<string, number>(),
    pirateInterceptEnabled: false,
    dangerZones: [],
    refresh: noopAsync,
  }

  const selection: MainShipSelection = {
    ships: active ? SELECTABLE_SHIPS : [],
    selectedShipId: active ? 'ship-dawn' : null,
    selectedShip: active ? SELECTABLE_SHIPS[0] : null,
    selectShip: () => {},
    loading: false,
    refresh: noopAsync,
  }

  return { game, combat, map, selection }
}

// ═══ THE NETWORK STUB ═════════════════════════════════════════════════════════════════════════
// Answers the supabase REST surface (tables + RPCs) the screens read on mount, per ?state=.
// Anything not listed: unknown table → [], unknown RPC → 404 PGRST202 — the same "dark" answer the
// client wrappers already normalize (panels hide, exactly like a dark production feature).

type Json = unknown

// full-width rows: PostgREST would project the select list; returning extra columns is harmless
// to supabase-js, so each table carries the union of every column any reader selects.
const SHIP_ROWS = SHIPS.map((s) => ({
  main_ship_id: s.id, name: s.name, status: s.status, hp: s.hp, max_hp: s.maxHp,
  shield: 0, max_shield: 0, cargo_capacity: s.cargo, captain_slots: s.captainSlots,
  module_slots: s.moduleSlots, hull_type_id: s.hull, cargo_capacity_m3: s.cargoM3,
  group_id: s.groupId, is_command_ship: s.isCommand, created_at: s.createdAt,
}))

const HULL_ROWS = [
  { hull_type_id: 'starter_frigate', name: 'Sparrow-class Frigate', base_hp: 120, base_speed: 10, base_cargo_capacity: 24, base_captain_slots: 2, base_module_slots: 4 },
  { hull_type_id: 'ironclad_hauler', name: 'Ironclad Hauler', base_hp: 160, base_speed: 7, base_cargo_capacity: 60, base_captain_slots: 2, base_module_slots: 3 },
]

const GAME_CONFIG_ROWS = [
  { key: 'starting_credits', value: 400 },
  { key: 'retreat_delay_seconds', value: 20 },
  { key: 'mining_extract_radius', value: 60 },
  { key: 'trade_market_enabled', value: true },
  { key: 'team_command_enabled', value: true },
  { key: 'fleet_movement_unified_enabled', value: true },
  { key: 'launch_from_dock_enabled', value: true },
  { key: 'fleet_control_enabled', value: true },
  { key: 'timed_docking_enabled', value: false },
  { key: 'salvage_market_enabled', value: false },
  { key: 'shipyard_enabled', value: false },
  { key: 'mainship_send_enabled', value: false },
]

const ITEM_TYPES = [
  { item_id: 'salvage_scrap', name: 'Salvage Scrap', category: 'material', rarity: 'common', description: 'Recovered hull fragments and burnt plating.', stackable: true, icon_key: 'scrap' },
  { item_id: 'ion_cells', name: 'Ion Cells', category: 'component', rarity: 'uncommon', description: 'Charged cells that feed shipboard systems.', stackable: true, icon_key: 'cell' },
  { item_id: 'hull_plating', name: 'Hull Plating', category: 'material', rarity: 'common', description: 'Standard structural plating.', stackable: true, icon_key: 'plate' },
]

const MODULE_TYPES = [
  { id: 'mod_light_cannon', name: 'Light Cannon', slot_type: 'weapon', description: 'A dependable short-range cannon.', slot_cost: 1, stats_json: { attack: 4 }, range: 120, projectile_speed: 40, power: 3, ammo_type: null, ammo_per_shot: 0, cooldown_seconds: 2 },
  { id: 'mod_cargo_frame', name: 'Cargo Frame', slot_type: 'utility', description: 'Expands usable cargo volume.', slot_cost: 1, stats_json: { cargo: 8 }, range: null, projectile_speed: null, power: null, ammo_type: null, ammo_per_shot: 0, cooldown_seconds: 0 },
]

function tables(state: LookState): Record<string, Json[]> {
  const active = state === 'active'
  return {
    main_ship_instances: active ? SHIP_ROWS : [],
    main_ship_hull_types: HULL_ROWS,
    ship_groups: active ? GROUPS.map((g) => ({ ...g, auto_exit_hull_pct: null })) : [],
    fleets: active
      ? [
          { id: 'flt-d1', status: 'present', main_ship_id: 'ship-dawn', current_location_id: 'loc-haven', location_mode: 'location', active_movement_id: null },
          { id: 'flt-d2', status: 'present', main_ship_id: 'ship-haul', current_location_id: 'loc-haven', location_mode: 'location', active_movement_id: null },
        ]
      : [],
    game_config: GAME_CONFIG_ROWS,
    player_inventory: active
      ? [
          { item_id: 'salvage_scrap', quantity: 14 },
          { item_id: 'ion_cells', quantity: 6 },
          { item_id: 'hull_plating', quantity: 3 },
        ]
      : [],
    item_types: ITEM_TYPES,
    module_types: MODULE_TYPES,
    module_recipe_ingredients: [
      { module_type_id: 'mod_light_cannon', item_id: 'salvage_scrap', qty: 6 },
      { module_type_id: 'mod_light_cannon', item_id: 'ion_cells', qty: 2 },
      { module_type_id: 'mod_cargo_frame', item_id: 'hull_plating', qty: 3 },
    ],
    ship_cargo_lots: active
      ? [{ lot_id: 'lot-1', good_id: 'cinder_ore', qty: 6, unit_cost_basis: 12, acquired_at: '2026-08-02T12:00:00Z', trade_goods: { unit_volume_m3: 2 } }]
      : [],
    player_wallet: active ? [{ balance: 312 }] : [],
    unit_types: UNIT_TYPES,
  }
}

function rpcs(state: LookState): Record<string, Json> {
  const active = state === 'active'
  return {
    get_my_current_dock_services: active
      ? { state: 'at_location', location_id: 'loc-haven', location_name: 'Haven', services: ['docking', 'market', 'repair', 'recruitment'] }
      : { state: 'no_main_ship' },
    get_my_fleet_positions: active ? FLEET_POSITIONS : [],
    get_my_disabled_ships: [],
    get_my_ship_fittings: {
      ok: true,
      fittings: active
        ? [
            { module_instance_id: 'mi-1', main_ship_id: 'ship-dawn', fitted_at: '2026-07-30T10:00:00Z', module_type_id: 'mod_light_cannon', name: 'Light Cannon', slot_type: 'weapon', slot_cost: 1 },
            { module_instance_id: 'mi-2', main_ship_id: 'ship-dawn', fitted_at: '2026-07-31T10:00:00Z', module_type_id: 'mod_cargo_frame', name: 'Cargo Frame', slot_type: 'utility', slot_cost: 1 },
            { module_instance_id: 'mi-3', main_ship_id: 'ship-haul', fitted_at: '2026-07-29T10:00:00Z', module_type_id: 'mod_cargo_frame', name: 'Cargo Frame', slot_type: 'utility', slot_cost: 1 },
          ]
        : [],
    },
    get_my_captain_instances: {
      ok: true,
      captains: active
        ? [
            { instance_id: 'cap-1', captain_type_id: 'nav_officer', name: 'Rhea Voss', specialization: 'navigation', stats_json: { speed: 2 }, xp: 120, level: 2, main_ship_id: 'ship-dawn', station: 'helm', created_at: '2026-07-20T00:00:00Z' },
            { instance_id: 'cap-2', captain_type_id: 'gun_officer', name: 'Tomas Idri', specialization: 'gunnery', stats_json: { attack: 2 }, xp: 40, level: 1, main_ship_id: null, station: null, created_at: '2026-07-25T00:00:00Z' },
          ]
        : [],
    },
    get_my_module_instances: {
      ok: true,
      instances: active
        ? [{ instance_id: 'mi-4', module_type_id: 'mod_light_cannon', name: 'Light Cannon', slot_type: 'weapon', created_at: '2026-08-01T00:00:00Z' }]
        : [],
    },
    get_market_offers: active
      ? {
          ok: true,
          main_ship_id: 'ship-dawn',
          location_id: 'loc-haven',
          offers: [
            { offer_id: 'off-1', good_id: 'cinder_ore', buy_price: 9, sell_price: 12 },
            { offer_id: 'off-2', good_id: 'ration_packs', buy_price: 4, sell_price: 6 },
            { offer_id: 'off-3', good_id: 'ion_fuel', buy_price: 21, sell_price: 26 },
          ],
        }
      : { ok: false, reason: 'not_docked' },
  }
}

function jsonResponse(body: Json, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

/** PostgREST-ish answer for one /rest/v1/* request. */
function restAnswer(pathname: string, accept: string, state: LookState): Response {
  const rest = pathname.slice(pathname.indexOf('/rest/v1/') + '/rest/v1/'.length)
  if (rest.startsWith('rpc/')) {
    const fn = rest.slice(4)
    const map = rpcs(state)
    if (fn in map) return jsonResponse(map[fn])
    // dark RPC → the same not-found shape PostgREST serves; wrappers collapse it to their dark default
    return jsonResponse({ code: 'PGRST202', message: `Could not find the function public.${fn}`, details: null, hint: null }, 404)
  }
  const table = rest.split('?')[0]
  const rows = tables(state)[table] ?? []
  if (accept.includes('vnd.pgrst.object')) {
    // .single()/.maybeSingle(): one row → the object; zero → the PGRST116 shape maybeSingle maps to null
    if (rows.length >= 1) return jsonResponse(rows[0])
    return jsonResponse({ code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned', details: 'Results contain 0 rows', hint: null }, 406)
  }
  return jsonResponse(rows)
}

let installed = false

/** Install the fetch stub (idempotent). Runs at module scope below so it precedes every src import. */
export function ensureLookNetInstalled(): void {
  if (installed) return
  installed = true
  const realFetch = window.fetch.bind(window)
  window.fetch = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url =
      typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url
    let parsed: URL
    try {
      parsed = new URL(url, window.location.href)
    } catch {
      return realFetch(input, init)
    }
    if (parsed.pathname.startsWith('/auth/v1/') || parsed.pathname.includes('/auth/v1/')) {
      return jsonResponse({})
    }
    if (parsed.pathname.includes('/rest/v1/')) {
      const headers = new Headers(input instanceof Request ? input.headers : undefined)
      if (init?.headers) new Headers(init.headers).forEach((v, k) => headers.set(k, v))
      return restAnswer(parsed.pathname, headers.get('accept') ?? '', currentLookState())
    }
    return realFetch(input, init)
  }) as typeof window.fetch
}

ensureLookNetInstalled()
