import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../../lib/supabase'
import { fetchWorldMap, fetchLocationStates } from './mapApi'
import type { LocationState, MapLocation } from './mapTypes'
import { fetchActiveMovements } from '../fleets/fleetApi'
import type { FleetMovement } from '../fleets/fleetTypes'
import {
  fetchMainshipSendEnabled, fetchFleetMovementUnifiedEnabled,
  fetchLaunchFromDockEnabled, fetchFleetControlEnabled, fetchTimedDockingEnabled,
  fetchGameConfig,
  fetchPirateInterceptEnabled,
} from '../../lib/catalog'
import { getActiveMiningFields } from '../mining/miningApi'
import { fetchItemCatalog } from '../modules/modulesApi'
import type { MiningField } from '../mining/miningTypes'
import { fetchDangerZones, type DangerZoneLite } from './pirateApi'
import {
  fetchActiveMainShipFleet, fetchActiveMainShipPresence,
  fetchMyFleetPositions, resolveOwnedShip,
  type FleetPosition, type MainShipFleet, type MainShipPresence,
} from './mainshipApi'
import {
  fetchMyShipGroupsChecked, fetchMyShipGroupMap, fetchMyPresentShipFleets, fetchMyUnifiedGroupFleets,
  type ShipGroupMapEntry, type UnifiedGroupFleetLite,
} from '../command/teamApi'
import { deriveDockedTeamRollups, excludeCombatSortieFleets, selectCombatSortieFleets, type DockedTeamRollup } from '../command/teamRollup'
import type { GroupRow } from '../command/teamRoster'
import { TEAM_COMMAND_ENABLED } from './osnReleaseGates'

// Read-only galaxy-map data. Reuses existing world-map / base / movement fetchers and
// adds a tiny owner-read of main_ship_instances. NO writes, NO new backend. Static world
// structure is fetched once; dynamic movement/world-state/ship is polled.

export interface MainShipLite {
  main_ship_id: string
  name: string
  status: string
  hull_type_id: string
  hp: number
  max_hp: number
  // SHIELD-2 (0191 columns): 0/0 on every ship until the human ACT-SHIELD flip. Additive read —
  // kept congruent with the mainshipApi SHIP_COLS owner-ship read (the meter pair's data source).
  shield: number
  max_shield: number
  cargo_capacity: number
  // 4C-CLIENT: the legacy OSN spatial columns (spatial_state / space_x / space_y) are no longer
  // read — 4c-mig-2 drops them from main_ship_instances. Ship placement is served exclusively by
  // the get_my_fleet_positions projection (fleetPositions below).
}

/** Sector + zone names for a location, for the read-only detail panel. */
export interface LocationMeta {
  sectorName: string
  zoneName: string
}

export interface GalaxyMapData {
  loading: boolean
  error: string | null
  locations: MapLocation[]
  meta: Record<string, LocationMeta>
  mainShip: MainShipLite | null
  movements: FleetMovement[]
  locationStates: Record<string, LocationState>
  // Phase 10D: feature flag (read once) + the ship's active linked fleet (polled, for status).
  mainshipSendEnabled: boolean
  mainShipFleet: MainShipFleet | null
  // OSN-2b: the active location-presence for the main-ship fleet (polled). Feeds the Port screen's
  // dock-context refetch key. (4C-CLIENT: the per-ship space-movement read is deleted — the
  // main_ship_space_movements table is retired by 4c-mig-2 and nothing client-side consumed it.)
  mainShipPresence: MainShipPresence | null
  // TEAMMAP-0: the owner's teams (the REUSED teamApi groups read — id → name/slot) and the pure
  // docked-team rollup (live membership × 'present' fleets). Both are gated on the SAME
  // compile-time constant that mounts every other team surface (TEAM_COMMAND_ENABLED): while it is
  // false none of the team reads run and both stay empty — the map renders byte-identical to today.
  teamGroups: GroupRow[]
  // MAP-INTEGRATION M2 review fix: whether the LAST groups read genuinely SUCCEEDED. The plain read
  // normalizes any transport error to [] — indistinguishable from "no fleets" — so one flaky poll
  // would flash the false "No fleet yet" guidance over a fleet-owning player's map. The guidance
  // gates on THIS flag (an affirmative successful-and-empty read); on a failed read the hook also
  // KEEPS the previous poll's groups (below), so fleets/stop rows never dissolve transiently either.
  teamGroupsOk: boolean
  // S5 MAP-UX: the live membership map (main_ship_id → group/command flags) — already fetched for
  // the rollup fold every poll; exposed so the FleetCommandPanel's hunt arm is props-fed from the
  // shell instead of running its own reads (the deleted TeamMapSend fetched this itself).
  teamGroupMap: Record<string, ShipGroupMapEntry>
  dockedTeamRollups: DockedTeamRollup[]
  // FLEETMAP: the whole-fleet position projection (get_my_fleet_positions, 0200) — ONE owner-read of EVERY
  // owned non-destroyed ship, polled with the rest of the map. The fleet layer draws a marker per ship, so a
  // player owning 2+ ships is no longer invisible on the map (the single-ship resolver goes null at N≥2). [].
  fleetPositions: FleetPosition[]
  // FLEET-GO 4a-1: the RUNTIME unified-movement gate (0207's fleet_movement_unified_enabled, OFF in
  // prod; read once like the other static flags) + the group's own fleets (the §2 movers). While the
  // flag is dark the fleet read never runs and this stays [] — the map is byte-identical to today.
  // When 4b flips the flag, the already-deployed client switches arms with no further deploy.
  fleetMovementUnifiedEnabled: boolean
  unifiedGroupFleets: UnifiedGroupFleetLite[]
  // MAP-INTEGRATION M1: the COMBAT-PRESENT group fleets — the exact complement of the
  // excludeCombatSortieFleets filter applied to unifiedGroupFleets above (one raw read, one shared
  // classification, partitioned once here). Feeds the map's "in combat at X" team badge so a fleet
  // mid-hunt-combat keeps a marker (it is stripped from the dock fold by design, has no movement,
  // and the per-ship chevron fallback was deleted in S5). [] while the unified fetch is dark.
  combatSortieFleets: UnifiedGroupFleetLite[]
  // S5 MAP-UX: the NO-HOME + fleet-control runtime gates (read once with the other static flags —
  // previously fetched per-mount by the deleted TeamMapSend). Feed the panel's hunt arm.
  launchFromDockEnabled: boolean
  fleetControlEnabled: boolean
  // S4 TIMED DOCKING (0219): the runtime timed-dock gate — read once like unifiedEnabled and
  // threaded the same way. Lit, the FleetCommandPanel's dock row submits commandShipGroupDock
  // (the 45s leg); dark, it keeps submitting the instant commandShipGroupGo, byte-identical.
  timedDockingEnabled: boolean
  // MINING-FIELD-MARKERS: the active fields visible on the map (get_active_mining_fields, 0226 —
  // [] while mining_enabled is false, fail-closed) + the extraction radius (mining_extract_radius,
  // game_config — already public-read, 0003; read via the SAME fetchGameConfig() every other
  // numeric tunable uses, no new config surface). Fields are migration-seeded static world data
  // (is_active can change, but rarely — an admin action, not a runtime gameplay event), so both are
  // fetched ONCE per session alongside `locations`, not on the movement/ship poll.
  miningFields: MiningField[]
  miningExtractRadius: number
  // HOW LONG A COMBAT ROUND IS — `game_config.combat_tick_seconds`, the knob the engine's own tick
  // reads (`coalesce(cfg_num('combat_tick_seconds'), 3)`, every re-create of process_combat_ticks).
  // It rides the SAME once-per-session fetchGameConfig() batch as the mining radius; NULL when the
  // row is missing or unreadable, and every surface then states the cadence without a number rather
  // than inventing one (the retreatCountdown law).
  combatTickSeconds: number | null
  // HOW FAST A SHIELD COMES BACK — `game_config.shield_regen_combat_pct`, the fraction of a pool the
  // combat tick restores each round. It is the SAME knob the engine reads (0195:
  // `v_shield_regen := coalesce(cfg_num('shield_regen_combat_pct'), 0)`, hoisted once per
  // invocation), rides the SAME once-per-session fetchGameConfig() batch as the two above, and costs
  // no extra request. NULL when the row is missing, unreadable, or NOT POSITIVE — 0 is the committed
  // dark seed (0191) and is the live production value, and a mechanic that restores nothing must not
  // be described on the map. The shield stack is data-gated with no flag; this goes positive the day
  // scripts/activate-shield.sql is run, and the readout's shield lines appear by themselves.
  shieldRegenCombatPct: number | null
  // ITEM VOLUMES — `item_types.item_id -> volume_m3`, from the ONE catalog read
  // (modules/modulesApi.fetchItemCatalog). Static reference data, fetched once with the world. Empty
  // map on a failed read, which reads downstream as "no volume known" and prints nothing — never 0.
  itemVolumes: ReadonlyMap<string, number>
  // PIRATE INTERCEPT (prototype): the runtime gate (read once with the other static flags) + the
  // active danger_zones read (get_danger_zones), gated on the RUNTIME flag — dark → zero extra reads,
  // [] zones, byte-identical to today (the same gating discipline as fleetMovementUnifiedEnabled's
  // fleet-position read above).
  pirateInterceptEnabled: boolean
  dangerZones: DangerZoneLite[]
  refresh: () => Promise<void>
}

/** Last-resort fallback for the range ring, used only if the game_config row is missing or
 *  unreadable. The AUTHORITY is game_config.mining_extract_radius, fetched below.
 *
 *  60 is the LIVE value (production, re-read 2026-08-03) and, since migration 0320, the chain's
 *  too. It used to be 750 — mirroring the server's own stale
 *  `coalesce(cfg_num('mining_extract_radius'), 750)` (0104) — so a client that lost the config row
 *  drew a ring twelve and a half times too wide and told the player they could extract from fields
 *  the server would refuse. A fallback that disagrees with production is not a safety net; it is a
 *  second, wrong authority that only shows up when something is already going wrong. (The
 *  server-side 750 literals are a separate slice — see docs/DEV_LOG.md.) */
const DEFAULT_MINING_EXTRACT_RADIUS = 60

async function fetchMainShip(mainShipId?: string | null): Promise<MainShipLite | null> {
  // Owner-read RLS returns only the caller's ship(s). Plural-safe: read ALL and resolve deterministically
  // (never `.maybeSingle()`, which errors at N≥2 → ghosts the ship). Null when none, or ambiguous >1 without
  // a selection — the map then renders no main-ship marker rather than an arbitrary one.
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select('main_ship_id, name, status, hull_type_id, hp, max_hp, shield, max_shield, cargo_capacity')
    .order('created_at', { ascending: true }) // stable enumeration only; the pick is resolver-decided, not first-row
  if (error) return null // non-fatal: ship is optional in Phase 9A
  return resolveOwnedShip((data ?? []) as MainShipLite[], mainShipId)
}

const EMPTY: Omit<GalaxyMapData, 'refresh'> = {
  loading: true,
  error: null,
  locations: [],
  meta: {},
  mainShip: null,
  movements: [],
  locationStates: {},
  mainshipSendEnabled: false,
  mainShipFleet: null,
  mainShipPresence: null,
  teamGroups: [],
  teamGroupsOk: false, // fail closed: no "No fleet yet" until a groups read affirmatively succeeds
  teamGroupMap: {},
  dockedTeamRollups: [],
  fleetPositions: [],
  fleetMovementUnifiedEnabled: false,
  unifiedGroupFleets: [],
  combatSortieFleets: [],
  launchFromDockEnabled: false,
  fleetControlEnabled: false,
  timedDockingEnabled: false,
  miningFields: [],
  miningExtractRadius: DEFAULT_MINING_EXTRACT_RADIUS,
  combatTickSeconds: null,
  shieldRegenCombatPct: null,
  itemVolumes: new Map<string, number>(),
  pirateInterceptEnabled: false,
  dangerZones: [],
}

export function useGalaxyMapData(pollMs = 4000, selectedShipId: string | null = null): GalaxyMapData {
  const [state, setState] = useState(EMPTY)
  const staticRef = useRef<{
    locations: MapLocation[]
    meta: Record<string, LocationMeta>
    mainshipSendEnabled: boolean
    fleetMovementUnifiedEnabled: boolean
    launchFromDockEnabled: boolean
    fleetControlEnabled: boolean
    timedDockingEnabled: boolean
    miningFields: MiningField[]
    miningExtractRadius: number
    combatTickSeconds: number | null
    shieldRegenCombatPct: number | null
    itemVolumes: ReadonlyMap<string, number>
    pirateInterceptEnabled: boolean
  } | null>(null)
  // M2 review fix: the last SUCCESSFULLY-read groups list. A failed poll re-serves this instead of
  // [] so a transient ship_groups error never dissolves fleets (badges, rollups, stop rows) for a
  // poll — the same keep-prior posture a player expects from any flaky read.
  const lastGroupsRef = useRef<GroupRow[]>([])

  const load = useCallback(async () => {
    try {
      if (!staticRef.current) {
        // S5 MAP-UX: launch-from-dock + fleet-control ride the SAME once-per-session static batch as
        // the other runtime flags (they were per-mount reads in the deleted TeamMapSend).
        // MINING-FIELD-MARKERS: the active fields + the extract radius join the SAME batch — both
        // are static reference reads (fields are migration-seeded; the radius is a game_config
        // tunable), not per-poll dynamic state.
        // PIRATE INTERCEPT (prototype): the runtime gate rides the SAME once-per-session static batch.
        const [world, mainshipSendEnabled, fleetMovementUnifiedEnabled, launchFromDockEnabled, fleetControlEnabled, timedDockingEnabled, miningFields, gameConfig, pirateInterceptEnabled, itemCatalog] =
          await Promise.all([
            fetchWorldMap(), fetchMainshipSendEnabled(), fetchFleetMovementUnifiedEnabled(),
            fetchLaunchFromDockEnabled(), fetchFleetControlEnabled(), fetchTimedDockingEnabled(),
            getActiveMiningFields(), fetchGameConfig(), fetchPirateInterceptEnabled(),
            // ITEM VOLUMES ride the static batch for the same reason the mining radius does: catalog
            // reference data, read once, never per poll. `null` on a failed read -> an empty map.
            fetchItemCatalog(),
          ])
        const locations: MapLocation[] = []
        const meta: Record<string, LocationMeta> = {}
        for (const sector of world.sectors) {
          for (const zone of sector.zones) {
            for (const loc of zone.locations) {
              locations.push(loc)
              meta[loc.id] = { sectorName: sector.name, zoneName: zone.name }
            }
          }
        }
        const miningExtractRadius = gameConfig.mining_extract_radius ?? DEFAULT_MINING_EXTRACT_RADIUS
        // NO FALLBACK, on purpose. A missing knob means the client does not know how long a round
        // is, and DEFAULT_MINING_EXTRACT_RADIUS's own header says why a disagreeing fallback is
        // worse than none: it is a second, wrong authority that only appears when something is
        // already going wrong. Absent -> the surface says "every round" and no number.
        const rawTick = gameConfig.combat_tick_seconds
        const combatTickSeconds =
          typeof rawTick === 'number' && Number.isFinite(rawTick) && rawTick > 0 ? rawTick : null
        // NO FALLBACK here either, and 0 is DELIBERATELY folded to null rather than carried: the
        // dark seed and the live value are both 0, and a "Shield regen 0" line would name a mechanic
        // the engine does not run. Absent -> the readout says nothing about shield generation.
        const rawRegen = gameConfig.shield_regen_combat_pct
        const shieldRegenCombatPct =
          typeof rawRegen === 'number' && Number.isFinite(rawRegen) && rawRegen > 0 ? rawRegen : null
        const itemVolumes = new Map<string, number>()
        for (const row of itemCatalog ?? []) {
          if (Number.isFinite(row.volume_m3) && row.volume_m3 > 0) itemVolumes.set(row.item_id, row.volume_m3)
        }
        staticRef.current = {
          locations, meta, mainshipSendEnabled, fleetMovementUnifiedEnabled,
          launchFromDockEnabled, fleetControlEnabled, timedDockingEnabled,
          miningFields, miningExtractRadius, combatTickSeconds, shieldRegenCombatPct, itemVolumes,
          pirateInterceptEnabled,
        }
      }

      const [movements, locationStates, mainShip, fleetPositions, dangerZones] = await Promise.all([
        fetchActiveMovements(),
        fetchLocationStates(),
        // FLEETMAP: the single-ship reads now address the SELECTED ship (was implicitly the sole ship — null
        // at N≥2). The whole-fleet projection is fetched in the SAME parallel batch (owner-read, [] on error).
        // GATE FIX (post-flip): read the fleet layer when EITHER the legacy send OR the unified mover is live.
        // The flip turned mainship_send_enabled OFF (closing the per-ship send surface) but that flag ALSO
        // gated this read — so gating on send alone starved the map's fleet layer AND the Port tab (which
        // derives docked ships from fleetPositions) the instant unified movement went live. A truly dark env
        // (both off) still does ZERO reads.
        fetchMainShip(selectedShipId),
        (staticRef.current.mainshipSendEnabled || staticRef.current.fleetMovementUnifiedEnabled)
          ? fetchMyFleetPositions()
          : Promise.resolve<FleetPosition[]>([]),
        // PIRATE INTERCEPT (prototype): gated on the RUNTIME flag — dark → zero extra reads, [] zones.
        staticRef.current.pirateInterceptEnabled ? fetchDangerZones() : Promise.resolve<DangerZoneLite[]>([]),
      ])
      // The active linked fleet (zero units) drives the live main-ship status. Only read it
      // when a ship exists; absent ship or no in-flight fleet → null (home).
      const mainShipFleet = mainShip ? await fetchActiveMainShipFleet(mainShip.main_ship_id) : null
      // OSN-2b: only a PRESENT fleet can validate a named-location marker — fetch its active
      // presence then (and only then). Any other state needs no presence read.
      const mainShipPresence =
        mainShipFleet && mainShipFleet.status === 'present'
          ? await fetchActiveMainShipPresence(mainShipFleet.id)
          : null
      // TEAMMAP-0: the team read set — the REUSED owner groups read, the live membership map, and
      // the docked/present fleets — folded by the PURE rollup. Compile-time gated (the teamApi
      // mount-gate law: these reads must not run against a DB predating the team migrations).
      // Poll-cost posture: the groups read goes FIRST; a team-less player (zero groups → zero
      // possible badges/rollups) skips the membership + present-fleet reads entirely, paying one
      // extra read per poll instead of three.
      // M2 review fix: the CHECKED read distinguishes "genuinely zero groups" from "the read
      // errored" (both used to arrive as []). Success → adopt + remember the answer; failure →
      // KEEP the previous poll's groups (never transiently dissolve fleets/stop rows) and report
      // teamGroupsOk=false so the no-fleet guidance can't false-fire.
      const groupsRead = TEAM_COMMAND_ENABLED
        ? await fetchMyShipGroupsChecked()
        : { ok: true, groups: [] as GroupRow[] }
      if (groupsRead.ok) lastGroupsRef.current = groupsRead.groups
      const teamGroups = groupsRead.ok ? groupsRead.groups : lastGroupsRef.current
      const [groupMap, presentFleets] =
        teamGroups.length > 0
          ? await Promise.all([fetchMyShipGroupMap(), fetchMyPresentShipFleets()])
          : [{}, []]
      // FLEET-GO 4a-1: the group's own fleets (charter §2 — the fleet IS the mover). The fetch is
      // gated on the RUNTIME unified flag — NOT dark-inert by construction, because the live hunt
      // mints the same fleet shape (main_ship_id NULL + group_id) today; gating the read keeps the
      // dark world doing ZERO extra reads and folding ZERO extra rows (byte-identical). Lit, rows
      // 'present' at a COMBAT location are excluded before the dock fold: the unified mover refuses
      // combat destinations (0208 combat_destination), so a group fleet at a hunt site can only be
      // the hunt's sortie — folding it as a dock would badge the fleet "docked" mid-combat.
      const rawUnifiedFleets =
        teamGroups.length > 0 && staticRef.current.fleetMovementUnifiedEnabled
          ? await fetchMyUnifiedGroupFleets()
          : []
      const unifiedGroupFleets = excludeCombatSortieFleets(rawUnifiedFleets, staticRef.current.locations)
      // M1: the complement — combat-present sorties, kept visible via the map's in-combat badge.
      const combatSortieFleets = selectCombatSortieFleets(rawUnifiedFleets, staticRef.current.locations)
      const dockedTeamRollups = deriveDockedTeamRollups(teamGroups, groupMap, presentFleets, unifiedGroupFleets)
      setState({
        loading: false,
        error: null,
        locations: staticRef.current.locations,
        meta: staticRef.current.meta,
        mainShip,
        movements,
        locationStates,
        mainshipSendEnabled: staticRef.current.mainshipSendEnabled,
        mainShipFleet,
        mainShipPresence,
        teamGroups,
        teamGroupsOk: groupsRead.ok,
        teamGroupMap: groupMap,
        dockedTeamRollups,
        fleetPositions,
        fleetMovementUnifiedEnabled: staticRef.current.fleetMovementUnifiedEnabled,
        unifiedGroupFleets,
        combatSortieFleets,
        launchFromDockEnabled: staticRef.current.launchFromDockEnabled,
        fleetControlEnabled: staticRef.current.fleetControlEnabled,
        timedDockingEnabled: staticRef.current.timedDockingEnabled,
        miningFields: staticRef.current.miningFields,
        miningExtractRadius: staticRef.current.miningExtractRadius,
        combatTickSeconds: staticRef.current.combatTickSeconds,
        shieldRegenCombatPct: staticRef.current.shieldRegenCombatPct,
        itemVolumes: staticRef.current.itemVolumes,
        pirateInterceptEnabled: staticRef.current.pirateInterceptEnabled,
        dangerZones,
      })
    } catch (e) {
      setState((s) => ({ ...s, loading: false, error: e instanceof Error ? e.message : String(e) }))
    }
  }, [selectedShipId])

  useEffect(() => {
    let active = true
    void load()
    const iv = setInterval(() => { if (active) void load() }, pollMs)
    return () => { active = false; clearInterval(iv) }
  }, [load, pollMs])

  return { ...state, refresh: load }
}
