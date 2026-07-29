// TEAM-COMMAND Slice B (sub-slice 2) — pure client mirror of stop_ship_group_transit's PRE-READ reject order.
//
// MOVEMENT-ON-MAP step 2 extended this file rather than adding a teamMapStop.ts beside it: this is the ONE
// home for group-stop purity, and the map's Stop needs the same server contract this module already mirrors.
//
// Mirrors only the reject order that gates whether a group-stop is dispatchable at all (gate → group resolved
// → non-empty), the same convention as teamSend.ts. It does NOT mirror per-member outcomes: unlike send,
// group-stop is BEST-EFFORT and always returns ok:true past the pre-read checks, with a server-side
// {stopped, skipped, failed} breakdown that only the server can compute (which members are actually in
// flight). Display-only; the server stays authoritative. No I/O — unit-tested in tests/teamStop.spec.ts.

import type { FleetMovement } from '../fleets/fleetTypes'
import type { GroupRow } from './teamRoster'

export type GroupStopReason = 'ok' | 'gate_dark' | 'group_not_found' | 'empty_group'

// Mirrors stop_ship_group_transit: gate → group resolved (owned) → group non-empty → ok. "ok" here means the
// stop is dispatchable; how many members actually halt (vs are already docked/home) is the server's call.
export function groupStopAvailability(input: {
  gateEnabled: boolean
  groupResolved: boolean
  memberCount: number
}): { canStop: boolean; reason: GroupStopReason } {
  if (!input.gateEnabled) return { canStop: false, reason: 'gate_dark' }
  if (!input.groupResolved) return { canStop: false, reason: 'group_not_found' }
  if (input.memberCount <= 0) return { canStop: false, reason: 'empty_group' }
  return { canStop: true, reason: 'ok' }
}

// ── MOVEMENT-ON-MAP step 2 — which owned fleets are in flight (the map Stop's derivation) ─────────
//
// Charter §2a: ALL movement interaction lives on the map. Step 1 stripped Send/Hunt/Stop out of the
// Command roster; Send/Hunt/Move already had a map home (TeamMapSend) but Stop did NOT —
// groupStopAvailability above was fully built and ORPHANED with no caller. This is the missing
// input to that caller. It is a SELECTOR over rows the shell already polls (map.movements +
// map.teamGroups) — no new server surface, no second fold.
//
// WHY THIS IS NOT teamMarkers.resolveTeamMarkers (the one real design call — deliberate NON-reuse):
// that function looks like the same derivation and is unsafe here. It DROPS any group whose lead
// segment fails interpolateMovementPoint ("no guessed position" — correct when drawing a badge), and
// takes a nowMs it needs only for that position math. A Stop must inherit neither:
//   • An un-drawable fleet is precisely the fleet a player most needs to stop. Gating the brake on
//     "can we draw it?" hides the control exactly when the data is already broken — the same wreckage
//     posture that produced the orphaned `traveling` ships in prod.
//   • Stoppability is time-INDEPENDENT (a row is 'moving' or it is not), so taking nowMs would imply
//     a staleness the server doesn't have and invite a re-render-per-tick control.
// Same INPUTS, different question. Fail-closed on unknown groups is kept (a tag pointing outside the
// owner's read yields no row — never a guessed name), matching the roster's dangling-membership posture.

// ── 0305 — THE CLIENT NO LONGER GUESSES WHETHER A FLEET MAY BE STOPPED. ──────────────────────────
//
// What used to be here: a `classifySortieLeg(mission_type)` proxy that hid the Stop button whenever
// the lead movement read 'hunt_pirates' or 'return_home', because the 0215 server brake refused a
// sortie with `group_on_sortie`. That made the client the THIRD independent definition of "on a
// sortie" — the SQL had two more, in seven copied places — and all three could disagree.
//
// The server brake no longer refuses. `command_ship_group_stop` (0305) answers every Stop: an open
// fight composes with the retreat authority, and any other leg simply halts. So there is nothing
// for the client to predict, and predicting it is what made the button disappear. The Stop button
// is now offered for every in-flight fleet, and the SERVER decides what the stop means — the same
// posture the rest of this module already documents ("display-only; the server stays authoritative").

export interface StoppableFleetDescriptor {
  groupId: string
  /** The team's name from the owner's groups read — never derived from the movement row. */
  name: string
  /** How many member fleets of this group are in flight (an expedition fans out; a hunt is one). */
  fleetCount: number
  /** Lead (earliest) arrive_at across the group's moving fleets — display only; the server owns ETA. */
  arriveAt: string
}

/**
 * Owned groups with at least one in-flight ('moving') fleet → one descriptor each.
 * Pure, time-independent, no interpolation. Deterministic order (by groupId).
 * EVERY in-flight fleet is stoppable (0305): the server answers every Stop, so this derivation
 * no longer predicts the answer. Arity stays 2 — the time-independence spec pins it.
 */
export function resolveStoppableFleets(
  movements: readonly FleetMovement[],
  groups: readonly GroupRow[],
): StoppableFleetDescriptor[] {
  if (groups.length === 0) return []
  const nameById = new Map(groups.map((g) => [g.group_id, g.name]))

  const byGroup = new Map<string, FleetMovement[]>()
  for (const m of movements) {
    const gid = m.group_id
    if (!gid || m.status !== 'moving') continue
    if (!nameById.has(gid)) continue // fail closed: unknown/foreign tag → no row, never a guessed name
    const list = byGroup.get(gid) ?? []
    list.push(m)
    byGroup.set(gid, list)
  }

  const out: StoppableFleetDescriptor[] = []
  for (const [gid, list] of byGroup) {
    // Lead = earliest ETA; deterministic tie-break on movement id (stable across re-renders). Mirrors
    // the teamMarkers lead rule so the badge and the Stop row always speak about the SAME fleet.
    const lead = list.reduce((a, b) => {
      const ta = Date.parse(a.arrive_at)
      const tb = Date.parse(b.arrive_at)
      if (ta !== tb) return ta <= tb ? a : b
      return a.id <= b.id ? a : b
    })
    // Lead is display truth only (the ETA the row shows). In the lit world a unified group flies ONE
    // fleet with ONE movement, so lead IS the movement.
    out.push({ groupId: gid, name: nameById.get(gid) as string, fleetCount: list.length, arriveAt: lead.arrive_at })
  }
  return out.sort((a, b) => (a.groupId < b.groupId ? -1 : a.groupId > b.groupId ? 1 : 0))
}

// ── FLEET-GO 4a-1 — the UNIFIED stop's envelope parser + outcome copy (0209). ────────────────────
//
// The unified brake is the ONLY group-stop path now (fleet_movement_unified_enabled is on in prod;
// the legacy per-member stop_ship_group_transit parser + its stopShipGroup wrapper were retired with
// the movement-signal cleanup). Its envelope is BOOLEAN-keyed: `stopped: true` means the fleet's ONE
// live leg was cancelled and it now holds in open space — there is no per-member count to aggregate.
//
// 0209's ok:true shape: { stopped: boolean, reason_code?: 'no_fleet' | 'not_moving' |
// 'already_settled', cancelled_movement_id?, space_x?, space_y?, … }. reason_code only accompanies
// stopped:false (the idempotent no-op arms). Rejects (ok:false + reason) never reach this parser —
// TeamMapStop routes those through teamReasonMessage like every other RPC.

// 0305 adds two codes on the stopped:false arm — the brake's answer when a fight is genuinely open.
// They are OUTCOMES, not rejects: the envelope is still ok:true, because the Stop did something.
export type UnifiedStopReasonCode =
  | 'no_fleet'
  | 'not_moving'
  | 'already_settled'
  | 'retreat_started'
  | 'retreat_already_underway'

export interface UnifiedStopOutcome {
  /** BOOLEAN (0209): the fleet's live leg was cancelled and it now holds in open space. */
  stopped: boolean
  /** Why a stopped:false call was a no-op; null on success or on an unrecognized code. */
  reasonCode: UnifiedStopReasonCode | null
}

const STOP_REASON_CODES: readonly UnifiedStopReasonCode[] = [
  'no_fleet',
  'not_moving',
  'already_settled',
  'retreat_started',
  'retreat_already_underway',
]

/** Parse a 0209 ok:true envelope. Strict boolean read: only `stopped === true` counts as a halt. */
export function parseUnifiedStopResult(res: Record<string, unknown>): UnifiedStopOutcome {
  const rc = res.reason_code
  return {
    stopped: res.stopped === true,
    reasonCode: STOP_REASON_CODES.includes(rc as UnifiedStopReasonCode)
      ? (rc as UnifiedStopReasonCode)
      : null,
  }
}

/** Player-facing summary of a unified fleet stop (ONE fleet — no per-ship breakdown exists). */
export function unifiedStopOutcomeMessage(fleetName: string, res: Record<string, unknown>): string {
  const o = parseUnifiedStopResult(res)
  if (o.stopped) return `Stopped ${fleetName} — holding position in open space.`
  if (o.reasonCode === 'already_settled') return `${fleetName} already arrived — nothing to stop.`
  // 0305: a Stop pressed during a real fight breaks off instead of being refused. Say what actually
  // happens — the fleet leaves under fire, so this is not a free halt and must not read like one.
  if (o.reasonCode === 'retreat_started') {
    return `${fleetName} is breaking off — retreating under fire until it clears the fight.`
  }
  if (o.reasonCode === 'retreat_already_underway') {
    return `${fleetName} is already retreating — it leaves when the window closes.`
  }
  // no_fleet / not_moving / unrecognized: the fleet simply is not in flight. Idempotent, calm copy.
  return `${fleetName} was already stopped — nothing was in flight.`
}
