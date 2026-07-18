import { resolveBerthedLocationLabel, resolveShipLocationLabel } from '../ship/shipLocation'
import type { FleetPosition, FleetPositionSegment, MainShipFleet } from '../map/mainshipApi'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { MapLocation } from '../map/mapTypes'

// TEAM-COMMAND Slice A — pure, server-truth-free roster + ownership logic.
//
// TERMINOLOGY: "group" is the backend/DB word (ship_groups, main_ship_instances.group_id); "team" is the UI
// word. The types below carry `group_id` (data) but the view they build is a "team" roster (UI). No I/O here:
// these functions take already-fetched owner-scoped rows and are unit-tested in tests/teamRoster.spec.ts.

export interface GroupRow {
  group_id: string
  group_index: number // 1..3 — the deterministic team slot
  name: string
}

export interface RosterShip {
  main_ship_id: string
  name: string
  status: string
  group_id: string | null // null = ungrouped; a dangling id (group not owned/loaded) is ALSO treated as ungrouped
  // FLEET-CONTROL (0204): the command-ship designation, carried through so the card can count command
  // ships and derive the fleet active/inactive state. Optional (defaults false) — undefined ⇒ not a
  // command ship, so pre-0204 callers/tests need no change.
  is_command_ship?: boolean
}

export interface TeamRosterTeam {
  group: GroupRow
  ships: RosterShip[]
}

export interface TeamRosterView {
  teams: TeamRosterTeam[] // one entry per existing owned group, ordered by group_index (ascending)
  ungrouped: RosterShip[] // ships with group_id null OR pointing at a group not in `groups`
}

// Build the team roster for display. A ship is attached to a team ONLY when its group_id matches an owned
// group in `groups`; a null or dangling group_id falls to `ungrouped` — a ship is NEVER silently attached to
// an arbitrary team. Teams are ordered by group_index; ships within a team preserve input order.
export function buildTeamRoster(groups: GroupRow[], ships: RosterShip[]): TeamRosterView {
  const byId = new Map<string, GroupRow>()
  for (const g of groups) byId.set(g.group_id, g)

  const bucket = new Map<string, RosterShip[]>()
  const ungrouped: RosterShip[] = []
  for (const s of ships) {
    if (s.group_id != null && byId.has(s.group_id)) {
      const list = bucket.get(s.group_id) ?? []
      list.push(s)
      bucket.set(s.group_id, list)
    } else {
      ungrouped.push(s)
    }
  }

  const teams: TeamRosterTeam[] = [...byId.values()]
    .sort((a, b) => a.group_index - b.group_index)
    .map((group) => ({ group, ships: bucket.get(group.group_id) ?? [] }))

  return { teams, ungrouped }
}

// Ownership resolution for a group id, mirroring the backend mainship_resolve_owned_ship contract
// (migrations 0081 / 0159) so the client fails closed the same way the server does:
//   • explicit id → that group ONLY if it is in the owner-scoped `groups` list; otherwise null.
//   • null id     → the SOLE group only when the player has EXACTLY one; zero or >1 (ambiguous) → null.
// It NEVER returns an arbitrary group when ambiguous. Returns the resolved group_id, or null (fail closed).
export function resolveOwnedGroup(groups: GroupRow[], groupId?: string | null): string | null {
  if (groupId != null) {
    return groups.some((g) => g.group_id === groupId) ? groupId : null
  }
  return groups.length === 1 ? groups[0].group_id : null
}

// The lowest unused team slot (group_index) in 1..3, or null when all three exist. Drives the "Create team"
// affordance: null → creation is capped (hide/disable the control). Mirrors the DECLARATIVE 1..3 cap that
// upsert_ship_group leans on (the (player_id, group_index) unique key × the CHECK) — so the UI never offers a
// 4th team. Ignores unordered/duplicate input; never returns a value outside 1..3.
export function nextTeamSlot(groups: GroupRow[]): number | null {
  const used = new Set(groups.map((g) => g.group_index))
  for (let i = 1; i <= 3; i++) if (!used.has(i)) return i
  return null
}

// TEAM-FRIENDLY — adapt a get_my_fleet_positions row (FLEETMAP, migration 0200) to the ONE shared
// location resolver (resolveShipLocationLabel / SHIPLOC) so the team roster shows the SAME leak-safe
// location strings the ship screen shows — never a second location fold. The projection carries the
// server-decided `place` + location_id (docked) + segment (transit); we shape those into the
// resolver's (fleet, movement) inputs and return only its `.label`.
//
// HONEST: a ship absent from the projection, or a 'hidden' placement (home / destroyed / incoherent —
// the FLEETMAP "no marker" case), yields null → the row shows its humanized status only, never a
// guessed place. A transit segment carries coordinates, not a target location id, so an outbound leg
// fails closed to "In transit to its destination" (the resolver's own fallback) — honest, never a
// wrong port. Pure: names resolve solely from the passed world locations.
export function fleetPositionLocationLabel(
  pos: FleetPosition | undefined,
  locations: MapLocation[],
): string | null {
  if (!pos) return null
  if (pos.place === 'docked' || pos.place === 'in_space') {
    const fleet: MainShipFleet = {
      id: '',
      status: 'present',
      current_location_id: pos.place === 'docked' ? pos.location_id : null,
      location_mode: null,
      active_movement_id: null,
    }
    return resolveShipLocationLabel(fleet, null, locations).label
  }
  if (pos.place === 'transit' && pos.segment) {
    return resolveShipLocationLabel(null, movementFromSegment(pos.segment), locations).label
  }
  // S1 BERTH MODEL (0216): an UNFLEETED ship berthed at a port — a docked read through the ONE
  // shared resolver ("Docked at <port>"); never a map marker, so only the label surfaces here.
  if (pos.place === 'berthed') {
    return resolveBerthedLocationLabel(pos.location_id, locations).label
  }
  return null // 'hidden' (home/destroyed/incoherent) or a transit row with no segment → omit, never guess
}

// A transit segment → the minimal FleetMovement the resolver reads (target_type / target_location_id /
// mission_type / arrive_at). target_kind='base' ⇒ the return-home leg; the segment carries no target
// location id, so the outbound name is left null and the resolver fails closed to "its destination".
function movementFromSegment(seg: FleetPositionSegment): FleetMovement {
  return {
    id: '',
    fleet_id: '',
    origin_type: '',
    origin_x: seg.origin_x,
    origin_y: seg.origin_y,
    target_type: seg.target_kind,
    target_location_id: null,
    target_base_id: null,
    target_x: seg.target_x,
    target_y: seg.target_y,
    mission_type: seg.target_kind === 'base' ? 'return_home' : 'expedition',
    status: 'moving',
    depart_at: seg.depart_at,
    arrive_at: seg.arrive_at,
    travel_seconds: 0,
    travel_distance: 0,
  }
}

export type TeamGatherState = 'empty' | 'all_home' | 'co_located' | 'scattered'

// TEAM-FRIENDLY — the team's co-location/readiness state for the roster's inline notice + the
// Send/Hunt-disabled reason. Folded from the REUSED deriveDockedTeamRollups output (dockedLocationId
// is non-null ONLY when every member is docked at ONE port) plus the same per-member status==='home'
// check the card already uses for its send/hunt gate. NOT a second co-location fold — co-location
// comes straight from the rollup. Pure.
//   • empty      — no members.
//   • co_located — every member docked at ONE port (rollup.locationId non-null).
//   • all_home   — every member idle at home (the home-team send/hunt readiness state).
//   • scattered  — members split across ports / in transit → not gathered, not all home.
export function teamGatherState(input: {
  memberCount: number
  allHome: boolean
  dockedLocationId: string | null
}): TeamGatherState {
  if (input.memberCount <= 0) return 'empty'
  if (input.dockedLocationId !== null) return 'co_located'
  if (input.allHome) return 'all_home'
  return 'scattered'
}

// ── FLEET-CONTROL (0204) — pure mirrors of the server's fleet control-model (all fail-closed/dark-safe). ──

/** The per-fleet ship cap the assign path enforces when lit (0204: reject the 9th member `fleet_full`). */
export const FLEET_MAX_SHIPS = 8

export interface FleetCommandState {
  active: boolean
  commandCount: number
}

// A fleet needs ≥1 COMMAND SHIP to be ACTIVE (able to move/send/hunt) — the server rejects an inactive
// fleet with fleet_inactive_no_command (0204), gated on fleet_control_enabled. DARK → a fleet is NEVER
// "inactive" (today's behavior: movement never required a command ship), so active is always true. LIT →
// active ⇔ at least one member is a command ship. Pure display/gate mirror; the server stays authoritative.
export function fleetCommandState(input: {
  commandCount: number
  fleetControlEnabled: boolean
}): FleetCommandState {
  if (!input.fleetControlEnabled) return { active: true, commandCount: input.commandCount }
  return { active: input.commandCount >= 1, commandCount: input.commandCount }
}

// Mirror of the assign path's 8-ship-per-fleet cap (0204). DARK → no cap (today's behavior: assign never
// counted). LIT → atCap once the fleet already holds FLEET_MAX_SHIPS members; the add-ship picker
// disables + hints at that point (the server still re-checks and is the only real gate). `remaining` is
// null while dark (no cap to count against). Pure.
export function fleetCapacityState(input: {
  memberCount: number
  fleetControlEnabled: boolean
}): { atCap: boolean; remaining: number | null; max: number } {
  if (!input.fleetControlEnabled) return { atCap: false, remaining: null, max: FLEET_MAX_SHIPS }
  return {
    atCap: input.memberCount >= FLEET_MAX_SHIPS,
    remaining: Math.max(0, FLEET_MAX_SHIPS - input.memberCount),
    max: FLEET_MAX_SHIPS,
  }
}

// Mirror of set_fleet_command_ship's designation guard (0204): a ship must be IN a fleet to be a command
// ship (the server rejects ship_not_in_fleet otherwise). Clearing (isCommand=false) is always allowed.
// The roster only renders the toggle on grouped members, so this is a defense-in-depth mirror. Pure.
export function canToggleCommandShip(input: { shipGroupId: string | null; isCommand: boolean }): boolean {
  if (!input.isCommand) return true // clearing is always allowed
  return input.shipGroupId != null
}

// The per-ship membership map entry (the fetchMyShipGroupMap shape). group_id null = ungrouped;
// captain_slots null = unexpectedly absent (callers skip the client slot precheck); is_command_ship is
// the FLEET-CONTROL (0204) designation, defaulting false.
export interface ShipGroupMapEntry {
  group_id: string | null
  captain_slots: number | null
  is_command_ship: boolean
}

/** Base membership row — ONLY pre-existing columns (a widened read here would be a deploy-window hazard). */
export interface ShipMembershipRow {
  main_ship_id: string
  group_id: string | null
  captain_slots: number | null
}

/** The decoupled FLEET-CONTROL command-ship row (may be unavailable on a pre-0204 DB). */
export interface ShipCommandRow {
  main_ship_id: string
  is_command_ship: boolean | null
}

// Fold the (decoupled) membership + command-ship reads into the per-ship map. THE INVARIANT: membership
// comes SOLELY from `base` — the command-ship read is a pure OVERLAY. When `command` is null (the read
// failed / the column is absent on a pre-migration DB), every ship keeps is_command_ship=false and
// membership is untouched: the roster still shows correct fleets, just no command badges (inert while the
// flag is dark). A missing column can never drop a fleet. Pure — unit-tested in tests/fleetControl.spec.ts.
export function buildShipGroupMap(
  base: ShipMembershipRow[],
  command: ShipCommandRow[] | null,
): Record<string, ShipGroupMapEntry> {
  const map: Record<string, ShipGroupMapEntry> = {}
  for (const r of base) {
    map[r.main_ship_id] = {
      group_id: r.group_id ?? null,
      captain_slots: r.captain_slots ?? null,
      is_command_ship: false,
    }
  }
  if (command) {
    for (const r of command) {
      const entry = map[r.main_ship_id]
      if (entry) entry.is_command_ship = r.is_command_ship === true
    }
  }
  return map
}

export type CommissionReason = 'ok' | 'gate_dark' | 'cap_reached' | 'insufficient_credits'

// Client-side mirror of commission_additional_main_ship()'s reject order (migration 0080/0091): the DARK gate
// is checked BEFORE the cap, the cap is `count >= cap`, and the CREDIT check comes AFTER the cap (0091 debits
// under the lock only when price > 0 — a free ship never blocks on credits). The credit inputs are OPTIONAL:
// callers that don't know the balance (or config) omit them and the mirror stays silent on affordability —
// honest, because "unknown" must never block. Display-only — the server stays authoritative and re-checks all
// three. Lets the UI fail closed (e.g. hide/disable an add-ship affordance) without ever creating a ship.
export function commissionAvailability(input: {
  shipCount: number
  cap: number
  gateEnabled: boolean
  /** The player's EFFECTIVE balance (wallet row, or the starting_credits seed when unseeded). */
  effectiveBalance?: number
  price?: number
}): { canCommission: boolean; reason: CommissionReason } {
  if (!input.gateEnabled) return { canCommission: false, reason: 'gate_dark' }
  if (input.shipCount >= input.cap) return { canCommission: false, reason: 'cap_reached' }
  if (
    input.effectiveBalance !== undefined &&
    input.price !== undefined &&
    input.price > 0 && // 0091: `if v_price > 0 and not wallet_debit(…)` — price ≤ 0 skips the debit entirely
    input.effectiveBalance < input.price
  ) {
    return { canCommission: false, reason: 'insufficient_credits' }
  }
  return { canCommission: true, reason: 'ok' }
}
