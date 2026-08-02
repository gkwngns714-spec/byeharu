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
//
// NO-HOME (0199) — the `launchFromDock` gate (DEFAULT false → byte-identical to the pre-slice
// classifier, and every existing test that omits it stays green). When the server's
// launch_from_dock_enabled flag is LIT, the widened send_ship_group_expedition (each member launches
// from its OWN dock via the widened single send, 0199) makes a docked team SENDABLE — so the
// 'docked_unready' arm (any/split-port docked member) becomes a plain 'send'. 'move' (fully docked at
// ONE other port) and 'docked_here' (fully docked at THIS port) still win first: a gathered team
// relocating as one is the more precise action, and a team already here has nothing to do.
export type TeamMapSendAction = 'send' | 'move' | 'docked_here' | 'docked_unready'

export function teamMapSendAction(input: {
  memberCount: number
  /** The rollup's dockedCount: how many members sit docked (0 = nobody docked). */
  dockedCount: number
  dockedLocationId: string | null
  destinationId: string
  /** NO-HOME (0199): the runtime launch_from_dock_enabled flag. DEFAULT false → the pre-slice behavior. */
  launchFromDock?: boolean
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
  // NO-HOME: with launch-from-dock lit, a docked team can send from its dock(s) — no longer doomed.
  if (input.dockedCount > 0) return input.launchFromDock ? 'send' : 'docked_unready'
  return 'send'
}

// ── FLEET-GO 4a-1 — the UNIFIED-world expedition-arm classifier (charter §2). ──────────────────────
// A SEPARATE classifier, NOT a rewrite of teamMapSendAction above: the old three-arm world stays the
// live default until 4b flips fleet_movement_unified_enabled, so both classifiers coexist and the
// sheet picks one at RUNTIME. Under §2 the unified mover (command_ship_group_go, 0207/0208) launches
// from ANYWHERE — docked, split-docked, parked in open space, or mid-flight (redirect = re-issue) —
// so the docked/home readiness taxonomy ('move' / 'send' / 'docked_unready') collapses to ONE 'go'.
// The single survivor is the trivial "docked here" suppression: a fleet already docked at the
// destination has nothing to do, and dispatching it anyway would mint a zero-distance leg
// (origin === target → arrive_at = depart_at, tripping fleet_movements_check(arrive_at > depart_at)
// server-side). The server stays authoritative for everything else (member_busy, group_on_sortie,
// group_scattered, … arrive as reject envelopes through teamReasonMessage).
export type UnifiedMapSendAction = 'go' | 'docked_here'

export function unifiedMapSendAction(input: {
  /** The rollup's docked location (the unified fleet's 'present' port, or the legacy n/n fold). */
  dockedLocationId: string | null
  destinationId: string
}): UnifiedMapSendAction {
  if (input.dockedLocationId !== null && input.dockedLocationId === input.destinationId) return 'docked_here'
  return 'go'
}

// ── FLEET-GO 4a-1 — the pure arg builder for command_ship_group_go (0208's 4-arg signature). ───────
// The target is a discriminated union: a PORT ({locationId}) XOR a COORDINATE ({x,y}) — never both.
// The builder ENFORCES the exclusive shape by construction: the location branch emits ONLY
// p_location_id (0208 rejects invalid_target_shape if coords ride alongside a location — "a port's
// position is the server's to know, not the caller's to assert"), and the coordinate branch emits the
// RAW x/y with NO client-side rounding: 0208 canonicalizes to the integer world grid server-side
// (0208:259-261), and a client pre-round would be a second authority over the grid.
export type GroupGoTarget = { locationId: string } | { x: number; y: number }

export interface CommandShipGroupGoArgs {
  p_group_id: string
  p_location_id?: string
  p_target_x?: number
  p_target_y?: number
}

export function buildCommandShipGroupGoArgs(groupId: string, target: GroupGoTarget): CommandShipGroupGoArgs {
  if ('locationId' in target) return { p_group_id: groupId, p_location_id: target.locationId }
  return { p_group_id: groupId, p_target_x: target.x, p_target_y: target.y }
}

// ── RETREAT TO ANY DESTINATION (0292, widened 0298) — the mover's COMBAT-TIME success outcomes. ───
// While the group's encounter is live, command_ship_group_go does NOT start an ordinary leg. It
// records the ordered destination — a PORT (fleets.retreat_target_location_id) or a POINT IN OPEN
// SPACE (fleets.retreat_target_x/y), exactly one of the two — and hands the fleet to the existing
// retreat verb: `outcome: 'retreat_started'`. When the fleet is already retreating it re-points the
// destination WITHOUT restarting the retreat window: `outcome: 'retreat_destination_updated'`. Both
// come back ok:true, so the ordinary "Sent X to Y." copy would describe something that did not
// happen (no leg was minted, and the fleet leaves only when the retreat window expires).
//
// `destination` IS A LABEL, NOT A PORT NAME. 0298 removed the port-only restriction, so a retreat may
// be ordered to bare open space — which has no name — and this copy must not imply otherwise. The
// caller passes whatever names the place it picked: a port's name, or openSpaceDestinationLabel()
// for a tapped point. Neither sentence below says "port".
//
// LOOT (0307): naming a destination costs nothing. VERIFIED IN THE SERVER SOURCE, not assumed:
// the retreat leg carries the fight's earned bundle as cargo (movement_attach_cargo, 0299:626), and
// movement_settle_arrival deposits it on ARRIVAL whichever arm settles the leg — the 'base' arm as
// always (0208:153-154), and since 0307 the 'space' arm too: into the player's store at the arrival
// port for an ordered port destination, or the oldest active store for a point in open space. This
// function used to take a fourth argument (`carried_rewards`) and append a "rewards are lost"
// warning — that copy documented the pre-0307 defect (a 'space' arrival granted nothing) as a rule
// of the game, and it told the player to retreat "back to base" when the design has no home to be
// back at. Both died with the defect. The envelope still carries `carried_rewards`; no copy needs
// to threaten the player with it.
//
// ONE authority for this copy, composed by every arm that submits a move (the go arm AND the
// dock arm — the dock arm reaches the same server branch for a fleet ambushed inside a port's
// territory). Returns null for an ordinary move so the caller keeps its own summary. The envelope
// value is `unknown` by TeamRpcResult's shape, so it is compared and inspected, never cast.
// Pure — proven in tests/teamMove.spec.ts.
export function fleetRetreatOutcomeMessage(
  outcome: unknown,
  fleetName: string,
  destination: string,
): string | null {
  if (outcome === 'retreat_started') {
    return `${fleetName} is breaking off the fight and heading for ${destination}.`
  }
  if (outcome === 'retreat_destination_updated') {
    return `${fleetName} will retreat to ${destination} instead.`
  }
  return null
}
