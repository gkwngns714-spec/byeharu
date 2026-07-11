// TEAM-COMMAND Slice D4 — pure client mirrors for the team COMBAT surface (hunt).
//
// The teamSend.ts/teamStop.ts idiom verbatim: no I/O, structural inputs, short local reason names,
// DISPLAY-ONLY — the server (send_ship_group_hunt, migration 0168) stays authoritative and re-checks
// everything under its locks. This lets the dark Hunt UI disable/hide the affordance and fail closed
// without a round-trip. Unit-tested in tests/teamCombat.spec.ts.

export interface HuntDestination {
  id: string
  name: string
}

// Destinations a team hunt-send may target — the sendableDestinations twin for COMBAT. The hunt RPC
// requires the location `status='active'` AND `activity_type='hunt_pirates'` (migration 0168:196 — the
// exact predicate that routes the arrival into combat_create_encounter). Takes a structural row (not
// MapLocation) to stay pure + decoupled. The server re-validates — this is display convenience. NB the
// list can legitimately be EMPTY (no hunt_pirates location revealed yet) — the UI must degrade, not hide.
export function huntableDestinations(
  locations: { id: string; name: string; status: string; activity_type: string }[],
): HuntDestination[] {
  return locations
    .filter((l) => l.status === 'active' && l.activity_type === 'hunt_pirates')
    .map((l) => ({ id: l.id, name: l.name }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

export type GroupHuntReason =
  | 'ok'
  | 'gate_dark'
  | 'group_not_found'
  | 'empty_group'
  | 'invalid_location'
  | 'member_not_ready'

// Mirrors send_ship_group_hunt's reject ORDER (migration 0168) — the client-mirrorable prefix:
//   gate → group resolved (owned) → group non-empty → valid combat destination (active + hunt_pirates)
//   → members ready (EVERY member home AND hp>0 — the caller folds what it knows into ONE boolean;
//   the roster doesn't carry hp, so its fold is status-only and the server's under-lock check is the
//   truth) → ok.
// (`not_authenticated` precedes all of this server-side; the panel implies an authenticated session,
// the teamSend/teamStop/teamSkillset convention — not mirrored.)
//
// SERVER-ONLY rejects (the teamSend precedent for what the client mirrors vs defers): after
// member_not_ready the RPC can still answer, in ITS order,
//   fleet_limit_reached   — count of the player's live fleets vs cfg max_active_fleets,
//   stats_invalid         — the per-member 0122 adapter RAISED (refuse-don't-clamp) during the fold,
//   power_below_required  — Σ member combat_power vs locations.min_power_required,
//   no_home_base          — the 0050 origin anchor is missing (unreachable for real players).
// All four need server state the client doesn't mirror (fleet rows, the stat adapter, min-power,
// bases) — the server owns them; {ok:false, reason} is surfaced verbatim by the panel's run().
export function groupHuntAvailability(input: {
  gateEnabled: boolean
  groupResolved: boolean
  memberCount: number
  locationValid: boolean
  allMembersReady: boolean
}): { canHunt: boolean; reason: GroupHuntReason } {
  if (!input.gateEnabled) return { canHunt: false, reason: 'gate_dark' }
  if (!input.groupResolved) return { canHunt: false, reason: 'group_not_found' }
  if (input.memberCount <= 0) return { canHunt: false, reason: 'empty_group' }
  if (!input.locationValid) return { canHunt: false, reason: 'invalid_location' }
  if (!input.allMembersReady) return { canHunt: false, reason: 'member_not_ready' }
  return { canHunt: true, reason: 'ok' }
}
