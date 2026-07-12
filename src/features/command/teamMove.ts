// TEAMMOVE-1 — pure client mirror of move_ship_group_to_location's reject ORDER (migration 0190),
// the docked-team onward move, plus the ONE expedition-arm action classifier the map sheet consumes.
// The teamSend.ts convention verbatim: short local reason names, display-only — the server stays
// authoritative and re-checks the gate, ownership, membership, the docked-together readiness, and
// each per-ship move (a team move is all-or-nothing server-side). The docked inputs are the TEAMMAP
// rollup (deriveDockedTeamRollups — REUSED, never re-derived): a rollup's locationId is non-null
// exactly when EVERY member is docked at that one location, and its dockedCount reports
// partial/split docks. No I/O — unit-tested in tests/teamMove.spec.ts.

export type GroupMoveReason =
  | 'ok'
  | 'gate_dark'
  | 'group_not_found'
  | 'empty_group'
  | 'not_docked_together'
  | 'already_there'

// Mirrors move_ship_group_to_location: gate → group resolved (owned) → group non-empty → every
// member docked at ONE location (server: member_not_ready) → not already docked at the destination
// (client-only refinement: the server would surface this as member_send_failed via the per-ship
// "already at that location" raise — rejecting it here saves a doomed round-trip) → ok.
export function groupMoveAvailability(input: {
  gateEnabled: boolean
  groupResolved: boolean
  memberCount: number
  /** The rollup's docked location: non-null ONLY when every member is docked at that one location. */
  dockedLocationId: string | null
  destinationId: string
}): { canMove: boolean; reason: GroupMoveReason } {
  if (!input.gateEnabled) return { canMove: false, reason: 'gate_dark' }
  if (!input.groupResolved) return { canMove: false, reason: 'group_not_found' }
  if (input.memberCount <= 0) return { canMove: false, reason: 'empty_group' }
  if (input.dockedLocationId === null) return { canMove: false, reason: 'not_docked_together' }
  if (input.dockedLocationId === input.destinationId) return { canMove: false, reason: 'already_there' }
  return { canMove: true, reason: 'ok' }
}

// The expedition-arm action for one team row on the map sheet (TeamMapSend) — the ONE eligibility
// surface, so the sheet can never hand-fold its way into an enabled-but-doomed control. THE LAW: a
// team with ANY docked member never renders an enabled Send — the home-team send requires every
// member status='home' server-side (0163 → the live send), so a docked member dooms it to
// member_send_failed.
//   'move'           — fully docked at another location → offer "Move team here" (0190).
//   'docked_here'    — fully docked at THIS location → a muted state, no action (nothing to do).
//   'docked_unready' — some (or split-port) members docked → the Send is doomed AND the move is not
//                      ready (the server's member_not_ready arm): disabled Send + the gather hint.
//   'send'           — no docked member → the original home-team send arm.
// Callers pass a legal expedition destination (teamDestinationKind already classified it); this
// classifier deliberately does not re-check destination legality.
export type TeamMapSendAction = 'send' | 'move' | 'docked_here' | 'docked_unready'

export function teamMapSendAction(input: {
  memberCount: number
  /** The rollup's dockedCount: how many members sit docked (0 = nobody docked). */
  dockedCount: number
  dockedLocationId: string | null
  destinationId: string
}): TeamMapSendAction {
  const mv = groupMoveAvailability({
    gateEnabled: true, // the sheet mounts behind TEAM_COMMAND_ENABLED; the server re-checks its gate
    groupResolved: true, // rows come from the owner's fetched groups
    memberCount: input.memberCount,
    dockedLocationId: input.dockedLocationId,
    destinationId: input.destinationId,
  })
  if (mv.canMove) return 'move'
  if (mv.reason === 'already_there') return 'docked_here'
  if (input.dockedCount > 0) return 'docked_unready'
  return 'send'
}
