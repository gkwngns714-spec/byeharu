import { resolveShipLocationLabel } from '../ship/shipLocation'
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
      active_space_movement_id: null,
    }
    return resolveShipLocationLabel(fleet, null, locations).label
  }
  if (pos.place === 'transit' && pos.segment) {
    return resolveShipLocationLabel(null, movementFromSegment(pos.segment), locations).label
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
