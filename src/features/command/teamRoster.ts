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

export type CommissionReason = 'ok' | 'gate_dark' | 'cap_reached'

// Client-side mirror of commission_additional_main_ship()'s reject order (migration 0080/0091): the DARK gate
// is checked BEFORE the cap, and the cap is `count >= cap`. Display-only — the server stays authoritative and
// re-checks both. Lets the UI fail closed (e.g. hide/disable an add-ship affordance) without ever creating a ship.
export function commissionAvailability(input: {
  shipCount: number
  cap: number
  gateEnabled: boolean
}): { canCommission: boolean; reason: CommissionReason } {
  if (!input.gateEnabled) return { canCommission: false, reason: 'gate_dark' }
  if (input.shipCount >= input.cap) return { canCommission: false, reason: 'cap_reached' }
  return { canCommission: true, reason: 'ok' }
}
