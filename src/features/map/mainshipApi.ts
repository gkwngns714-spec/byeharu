import { supabase } from '../../lib/supabase'
import { SETTLE_ARRIVAL_RPC, LEGACY_SETTLE_ARRIVAL_RPC, parseSettleArrivalResult, type SettleArrivalResult } from './settleArrival'
import { parseDockServices, DOCK_NOT_DOCKED, type DockServices } from './dockServices'
import { parseDockedStore, DOCK_STORE_EMPTY, type DockedStore } from './dockStore'

// Main-ship client API.
//
// Phase 10B (revised) — READ-ONLY main-ship view (fetchMyMainShip): name, hull, base stats.
// No support craft, no support capacity, no loadout. NOTE: support capacity / support craft is
// DEPRECATED (see docs/MAINSHIP_TRANSITION.md); the dormant backend stays but the UI never uses it.
//
// Phase 10D origin, 4A-POST trimmed — the per-ship movement WRITE wrappers (send/move/space-move/
// stop/port-nav readiness) were deleted with the per-ship movement client; the unified fleet mover
// (teamApi) is the only movement writer. What remains here is owner READS (ship/fleet/presence/
// space-movement/fleet-positions), the repair + rename + settle wrappers, and the dock reads.
// The client only REQUESTS; the server validates and decides.

// OSN-2 spatial-mode selector (migration 0054). NULL on every row today (legacy): no writer sets
// a non-null value yet. Position for NULL rows still comes from the base/fleet/movement/presence
// model; only 'in_space' (a future OSN-3/4 writer) carries ship-owned coordinates.
export type SpatialState = 'home' | 'at_location' | 'in_transit' | 'in_space' | 'destroyed'

export interface MainShipRow {
  main_ship_id: string
  name: string
  status: string
  hp: number
  max_hp: number
  // SHIELD-2 (0191 columns): 0/0 on every ship until the human ACT-SHIELD flip — the meter pair
  // is data-gated on max_shield > 0, so these ride along dark (additive columns, no flag).
  shield: number
  max_shield: number
  cargo_capacity: number
  captain_slots: number
  module_slots: number
  hull_type_id: string
}

export interface HullRow {
  hull_type_id: string
  name: string
  base_hp: number
  base_speed: number
  base_cargo_capacity: number
  base_captain_slots: number
  base_module_slots: number
}

export interface MainShipView {
  has_ship: boolean
  ship?: MainShipRow
  hull?: HullRow
}

const HULL_COLS = 'hull_type_id, name, base_hp, base_speed, base_cargo_capacity, base_captain_slots, base_module_slots'
const SHIP_COLS = 'main_ship_id, name, status, hp, max_hp, shield, max_shield, cargo_capacity, captain_slots, module_slots, hull_type_id'

async function fetchHull(hullTypeId: string): Promise<HullRow | undefined> {
  const { data } = await supabase.from('main_ship_hull_types').select(HULL_COLS).eq('hull_type_id', hullTypeId).maybeSingle()
  return (data as HullRow) ?? undefined
}

/**
 * S6 (Fitting tab) — the WHOLE hull catalog (public-read Reference/Config; the same table/columns
 * fetchHull reads per id, kept in this module so there is ONE hull-select convention). The Fitting
 * roster resolves every ship's class display name from its own hull_type_id — per-ship-correct at
 * any N, never via the sole-ship-resolved view (fetchMyMainShip with no id fail-closes to the
 * starter teaser at N≥2, whose hull is the WRONG class for any non-starter ship). Static reference
 * data: callers fetch once per mount. Returns [] on error (rows fall back to the raw class id).
 */
export async function fetchHullTypes(): Promise<HullRow[]> {
  const { data, error } = await supabase.from('main_ship_hull_types').select(HULL_COLS)
  if (error) return []
  return (data ?? []) as HullRow[]
}

/**
 * The ONE client owned-ship resolution rule — mirrors the backend `mainship_resolve_owned_ship`: an explicit
 * `mainShipId` selects that owned ship; otherwise the SOLE ship, and ONLY when the player owns exactly one.
 * Zero or >1 (ambiguous, once multi-ship is live) → null (fail closed). Never picks an arbitrary/first ship,
 * never relies on row order. Callers pass the shell-selected id once multi-ship lights up; today (dark) every
 * player owns exactly one ship, so a null id resolves to it — behavior unchanged.
 */
export function resolveOwnedShip<T extends { main_ship_id: string }>(
  ships: T[],
  mainShipId?: string | null,
): T | null {
  if (mainShipId) return ships.find((s) => s.main_ship_id === mainShipId) ?? null
  return ships.length === 1 ? ships[0] : null
}

/**
 * Read the caller's own main ship (owner-read RLS) + its hull. No writes; no support data. Plural-safe: reads
 * ALL owned ships and resolves via resolveOwnedShip (never `.maybeSingle()`, which errors at N≥2). A null
 * resolution (no ship, or ambiguous >1 without a selection) falls through to the read-only starter-hull teaser.
 */
export async function fetchMyMainShip(mainShipId?: string | null): Promise<MainShipView> {
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select(SHIP_COLS)
    .order('created_at', { ascending: true }) // stable enumeration only; the pick is resolver-decided, not first-row
  if (error) throw new Error(error.message)

  const ship = resolveOwnedShip((data ?? []) as MainShipRow[], mainShipId)
  if (ship) {
    const hull = await fetchHull(ship.hull_type_id)
    return { has_ship: true, ship, hull }
  }
  // no resolvable ship (none commissioned, or ambiguous >1 without a selection) → read-only starter-hull teaser
  return { has_ship: false, hull: await fetchHull('starter_frigate') }
}

/**
 * FITTING-P14 — owner-read ALL of the caller's ships (the multi-ship-ready LIST variant of
 * fetchMyMainShip; same owner-read RLS, same columns — kept inside this module so there is ONE
 * ship-select convention, never a second copy elsewhere). Used by the fitting section's ship
 * picker. Returns [] on error (non-fatal; the picker degrades to nothing).
 */
export async function fetchMyMainShips(): Promise<MainShipRow[]> {
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select(SHIP_COLS)
    .order('created_at', { ascending: true })
  if (error) return []
  return (data ?? []) as MainShipRow[]
}

// ── FLEETMAP: whole-fleet map positions (the honest multi-ship fix) ─────────────────
//
// The client mirror of the get_my_fleet_positions() projection (migration 0200). ONE owner-read that returns
// EVERY owned non-destroyed ship's placeable position, replacing the N-fanout of the singular fetchers above.
// The server (via mainship_space_validate_context) decides each ship's `place`; the pure resolveFleetMarkers
// resolver turns these into map markers (docked → look up the port coords; transit → interpolate the segment;
// in_space → space_x/space_y). Coordinates arrive as jsonb numbers (double precision), never numeric strings.

// S1 BERTH MODEL (migration 0216): 'berthed' — an UNFLEETED ship docked at its berth port.
// INFO only, never a map marker (resolveFleetMarkers deliberately draws nothing for it); the
// roster/labels read it as "Docked at <port>" via the ONE shared SHIPLOC resolver.
export type FleetPositionPlace = 'transit' | 'in_space' | 'docked' | 'berthed' | 'hidden'

/** A committed movement segment for client-side interpolation (the shared movementInterpolation contract). */
export interface FleetPositionSegment {
  origin_x: number
  origin_y: number
  target_x: number
  target_y: number
  target_kind: string // 'base' → returning; anything else → outbound
  depart_at: string
  arrive_at: string
}

export interface FleetPosition {
  main_ship_id: string
  name: string
  class: string // hull_type_id
  status: string
  spatial_state: SpatialState | null
  place: FleetPositionPlace
  location_id: string | null // docked: the present fleet's current location; berthed: the berth port
  space_x: number | null // in_space only
  space_y: number | null // in_space only
  segment: FleetPositionSegment | null // transit only
}

/**
 * Owner-read ALL of the caller's ships' map positions in ONE call (get_my_fleet_positions, 0200). Returns []
 * on error or pre-deploy (the RPC not yet present) — non-fatal, so the map falls back to its single-ship
 * marker and never error-states. NOT gated by a flag: it is a pure additive owner read.
 */
export async function fetchMyFleetPositions(): Promise<FleetPosition[]> {
  const { data, error } = await supabase.rpc('get_my_fleet_positions')
  if (error || !Array.isArray(data)) return []
  return data as FleetPosition[]
}

// ── Phase 10D: main-ship send/return + live status ────────────────────────────────

export type MainShipDisplayStatus = 'home' | 'traveling' | 'present' | 'returning'

/** The active fleet linked to a main ship (zero units; status drives the UI). */
export interface MainShipFleet {
  id: string
  status: string // 'moving' | 'present' | 'returning'
  current_location_id: string | null // set when present (used to exclude the current location)
  // OSN-3 S1 read fields (used by the resolver to validate coordinate in_transit / at_location / home).
  location_mode: string | null
  active_movement_id: string | null
  active_space_movement_id: string | null
}

const ACTIVE_FLEET_STATUSES = ['moving', 'present', 'returning']

// The ONE MainShipFleet column list — shared by every fleet owner-read below (no second copy).
const MAIN_SHIP_FLEET_COLS = 'id, status, current_location_id, location_mode, active_movement_id, active_space_movement_id'

/**
 * Owner-read the caller's active main-ship fleet (the one tagged with this ship), if any.
 * Returns null when the ship is idle at home (no in-flight linked fleet).
 */
export async function fetchActiveMainShipFleet(mainShipId: string): Promise<MainShipFleet | null> {
  const { data, error } = await supabase
    .from('fleets')
    .select(MAIN_SHIP_FLEET_COLS)
    .eq('main_ship_id', mainShipId)
    .in('status', ACTIVE_FLEET_STATUSES)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) return null // non-fatal: treat as no active fleet (home)
  return (data as MainShipFleet) ?? null
}

// OSN-3 S1: the active coordinate-movement row for a main ship (read-model only; no writer in S1).
// Only the fields the display resolver needs to interpolate a coordinate in_transit marker.
export interface MainShipSpaceMovement {
  id: string
  main_ship_id: string
  fleet_id: string
  origin_x: number
  origin_y: number
  target_x: number
  target_y: number
  target_kind: string // 'space' | 'location' | 'base'
  // OSN-HUB-1A: the destination identity for a named-location target (target_kind='location'); NULL for a
  // raw open-space target. Owner-read only (RLS on main_ship_space_movements). The client resolves a NAME for
  // it solely from the public get_world_map() result; if it is not in that public map (e.g. a hidden port),
  // presentation FAILS CLOSED — no route, no id/coords/name leak (see spaceRouteModel / mainshipStatusLabel).
  target_location_id?: string | null
  status: string // 'moving' (only active rows are fetched)
  depart_at: string
  arrive_at: string
}

/**
 * Owner-read the caller's ACTIVE coordinate movement (status='moving') for a main ship, if any.
 * Scoped by exact main_ship_id; at most one row (enforced by a partial unique index). No writer in S1.
 */
export async function fetchActiveMainShipSpaceMovement(mainShipId: string): Promise<MainShipSpaceMovement | null> {
  const { data, error } = await supabase
    .from('main_ship_space_movements')
    .select('id, main_ship_id, fleet_id, origin_x, origin_y, target_x, target_y, target_kind, target_location_id, status, depart_at, arrive_at')
    .eq('main_ship_id', mainShipId)
    .eq('status', 'moving')
    .limit(1)
    .maybeSingle()
  if (error) return null // non-fatal (e.g. table not yet present pre-deploy): treat as no coordinate movement
  return (data as MainShipSpaceMovement) ?? null
}

// The active location-presence row for a main-ship fleet (owner-read). Used ONLY to validate a
// named-location marker per the OSN-2b deterministic rule (fleet present ∧ current_location_id ∧
// matching ACTIVE presence). Read-only; no new polling — fetched inside the existing map poll.
export interface MainShipPresence {
  fleet_id: string
  location_id: string | null
  status: string // 'active' is the only state that validates a present-at-location marker
}

/**
 * Owner-read the ACTIVE location-presence row for a main-ship fleet, if any. Returns null when the
 * fleet has no active presence (e.g. moving/returning, or none). No RPC; owner-read RLS on
 * location_presence already grants SELECT to the authenticated owner.
 */
export async function fetchActiveMainShipPresence(fleetId: string): Promise<MainShipPresence | null> {
  const { data, error } = await supabase
    .from('location_presence')
    .select('fleet_id, location_id, status')
    .eq('fleet_id', fleetId)
    .eq('status', 'active')
    .order('entered_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) return null // non-fatal: treat as no active presence
  return (data as MainShipPresence) ?? null
}

/**
 * Display status derived from the active linked fleet (the main ship's own status row stays
 * 'traveling' while the fleet is 'present', so the fleet is the source of truth here):
 *   no fleet → home · moving → traveling · present → present · returning → returning
 */
export function deriveMainShipStatus(fleet: { status: string } | null): MainShipDisplayStatus {
  if (!fleet) return 'home'
  if (fleet.status === 'present') return 'present'
  if (fleet.status === 'returning') return 'returning'
  return 'traveling' // 'moving'
}

// SHIP-POWER §2.5 — thin read wrapper over the LIVE per-ship stats preview (get_my_expedition_preview,
// 0049 → resolver-swapped 0159). FIRST client caller: until SHIP-POWER no shipped UI read this RPC at
// all (only the group twin, teamApi). Sends an EMPTY loadout (support craft is deprecated — see
// MAINSHIP_TRANSITION.md), the NEUTRAL activity 'none' (accepted by the 0122 adapter; no activity-tag
// warnings folded in) and the EXPLICIT selected/sole main-ship id (p_main_ship_id; null → server
// sole-ship shim). Returns the RAW jsonb envelope for the PURE parser (shipDossierView's
// parseShipStatsPreview) to interpret; a transport error collapses to null (→ parsed 'hidden') —
// normalize-don't-throw, the file's dark-RPC style.
export async function fetchMyExpeditionPreview(mainShipId?: string | null): Promise<unknown> {
  const { data, error } = await supabase.rpc('get_my_expedition_preview', {
    p_loadout: [],
    p_activity_type: 'none',
    p_main_ship_id: mainShipId ?? null,
  })
  if (error) return null
  return data
}

// PHASE 9 / TRADE-FLEET-0C §2.5 — read the current docked-port surface for the EXPLICIT selected/sole main
// ship (p_main_ship_id; null → server sole-ship shim → behavior-identical while every player has exactly one
// ship). The player is still derived from auth.uid(); no other input is sent. Errors / pre-deploy collapse to
// the no-dock default so nothing renders (unchanged).
export async function fetchMyCurrentDockServices(mainShipId?: string | null): Promise<DockServices> {
  const { data, error } = await supabase.rpc('get_my_current_dock_services', { p_main_ship_id: mainShipId ?? null })
  if (error) return DOCK_NOT_DOCKED
  return parseDockServices(data)
}

// STATION-STORAGE — the per-port hangar for the docked port (get_my_docked_store(); no args, server derives the
// ship + validated dock). Any error collapses to the empty store default (panel hidden), like the dock-services
// read above. Dark by default (server gates on station_storage_enabled).
export async function fetchMyDockedStore(): Promise<DockedStore> {
  const { data, error } = await supabase.rpc('get_my_docked_store')
  if (error) return DOCK_STORE_EMPTY
  return parseDockedStore(data)
}

// Phase 10F / TRADE-FLEET-0C §2.5 — repair a disabled main ship (status='destroyed' = disabled/needs-repair
// for a PERSISTENT ship; never deletion). The only normal player recovery path; instant + free, restores
// hp=max_hp and status='home'. Not routed through any legacy fleet API. Passes the EXPLICIT selected/sole
// main-ship id (p_main_ship_id); the server asserts ownership (so it can only ever repair the caller's own
// ship), and a null id preserves the sole-ship shim (behavior-identical while every player has exactly one).
export async function repairMainShip(mainShipId?: string | null): Promise<{ main_ship_id: string; status: string; hp: number; max_hp: number }> {
  const { data, error } = await supabase.rpc('repair_main_ship', { p_main_ship_id: mainShipId ?? null })
  if (error) throw new Error(error.message)
  return data as { main_ship_id: string; status: string; hp: number; max_hp: number }
}

// SHIP-IDENTITY (0184) / §2.5 — thin client wrapper over the player rename (rename_main_ship_self).
// Sends the raw name plus the EXPLICIT selected/sole main-ship id (p_main_ship_id; null → server
// sole-ship shim). The server owns validation (btrim → non-empty → ≤ 40) and asserts ownership via
// mainship_resolve_owned_ship — the client mirror (shipNameProblem) is display-only. A transport
// error collapses to the reject envelope ('unavailable') so the UI can map it, never a throw.
export type RenameMainShipResult =
  | { ok: true; main_ship_id: string; name: string }
  | { ok: false; reason: string }

export async function renameMainShip(name: string, mainShipId?: string | null): Promise<RenameMainShipResult> {
  const { data, error } = await supabase.rpc('rename_main_ship_self', {
    p_name: name,
    p_main_ship_id: mainShipId ?? null,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as RenameMainShipResult
}

// UX-CLEANUP item 6 (part A) — thin client wrapper over the on-demand OSN arrival settle
// (command_main_ship_settle_arrival, 0150). Sends ONLY the explicit selected/sole main-ship id (§2.5;
// null → server sole-ship shim). The server re-validates flag/ownership/coherence/due-ness under the
// arrival cron's own locks and settles via the cron's own primitives — an early/duplicate/raced call is a
// clean {settled:false} no-op, so this wrapper needs no idempotency key.
export async function commandMainShipSettleArrival(mainShipId?: string | null): Promise<SettleArrivalResult> {
  try {
    const { data, error } = await supabase.rpc(SETTLE_ARRIVAL_RPC, { p_main_ship_id: mainShipId ?? null })
    if (error) return { ok: false, reason: error.message }
    return parseSettleArrivalResult(data)
  } catch (e) {
    return { ok: false, reason: e instanceof Error ? e.message : 'unavailable' }
  }
}

// UX-CLEANUP item 6 (part B) — thin client wrapper over the on-demand LEGACY arrival settle
// (command_main_ship_settle_arrival_legacy, 0151). Sends ONLY the caller's own in-flight main-ship fleet
// id (null → server sole-in-flight-fleet resolution, the 0081 fail-closed shape). The server re-validates
// flag/ownership/main-ship predicate/due-ness and settles via the cron's extracted movement_settle_arrival
// helper — an early/duplicate/raced call is a clean {settled:false} no-op, so no idempotency key needed.
export async function commandMainShipSettleArrivalLegacy(fleetId?: string | null): Promise<SettleArrivalResult> {
  try {
    const { data, error } = await supabase.rpc(LEGACY_SETTLE_ARRIVAL_RPC, { p_fleet: fleetId ?? null })
    if (error) return { ok: false, reason: error.message }
    return parseSettleArrivalResult(data)
  } catch (e) {
    return { ok: false, reason: e instanceof Error ? e.message : 'unavailable' }
  }
}

