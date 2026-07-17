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
// Command roster; Send/Hunt/Move already had a map home (TeamMapSend) but Stop did NOT — stopShipGroup
// and groupStopAvailability above were fully built and ORPHANED with no caller. This is the missing
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

// ── BRAKE CLIENT COMPANION — sortie classification (the affordance mirror of 0215's server brake) ─
//
// The unified server brake rejects a Stop on a fleet that is flying a SORTIE (a hunt's outbound or
// return leg) with reason `group_on_sortie` — combat commitment is not interruptible by the brake.
// TeamMapStop already maps that reject to player copy, so correctness holds; but OFFERING the
// "Stop — hold here" button for a sortie invites a click the server refuses. This classification
// lets the rail swap the button for a non-actionable hint instead.
//
// THE PROXY: the client cannot see the server's sortie manifest, so it keys on the group movement's
// `mission_type` — 0214's unified hunt departs the group's ONE fleet with mission 'hunt_pirates',
// and combat resolution sends it home with mission 'return_home' (0169/0195/0206). That field is a
// PROXY for the UI affordance only; the SERVER stays authoritative on what a stop may actually do.
//
// GATED ON `unifiedEnabled` (the same runtime flag TeamMapStop branches its brake on) so the DARK
// world is byte-identical: flag false → no classification is applied and the stoppable set is
// exactly today's. This gate also moots a real ambiguity: mission_type='return_home' ALSO appears
// on per-ship LEGACY return legs (0169's per-member returns carry the expedition's informational
// group_id tag), which would mis-classify a legacy expedition's way home as a sortie — but those
// shapes matter only in the dark arm, and dark applies no classification at all.

export type SortieLeg = 'outbound' | 'returning'

/** 'hunt_pirates' → outbound sortie leg; 'return_home' → the way back; anything else → not a sortie. */
function classifySortieLeg(missionType: string): SortieLeg | null {
  if (missionType === 'hunt_pirates') return 'outbound'
  if (missionType === 'return_home') return 'returning'
  return null
}

export interface StoppableFleetDescriptor {
  groupId: string
  /** The team's name from the owner's groups read — never derived from the movement row. */
  name: string
  /** How many member fleets of this group are in flight (an expedition fans out; a hunt is one). */
  fleetCount: number
  /** Lead (earliest) arrive_at across the group's moving fleets — display only; the server owns ETA. */
  arriveAt: string
  /**
   * BRAKE CLIENT COMPANION: non-null when the LEAD movement is a sortie leg (see the header above) —
   * the rail renders a hint, NOT a Stop button, because the server brake rejects `group_on_sortie`.
   * Always null in the dark world (the classification is gated on unifiedEnabled).
   */
  sortie: SortieLeg | null
}

/**
 * Owned groups with at least one in-flight ('moving') fleet → one descriptor each.
 * Pure, time-independent, no interpolation. Deterministic order (by groupId).
 * A descriptor with `sortie !== null` is IN FLIGHT but NOT actionable-stoppable (hint row, no button).
 * The third parameter is DEFAULTED (dark) so `resolveStoppableFleets.length` stays 2 — the
 * time-independence spec pins that arity, and a flag is not a clock.
 */
export function resolveStoppableFleets(
  movements: readonly FleetMovement[],
  groups: readonly GroupRow[],
  opts: { unifiedEnabled: boolean } = { unifiedEnabled: false },
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
    // Classify on the LEAD movement: in the lit world a unified group flies ONE fleet with ONE
    // movement, so lead IS the movement — and the row's ETA and its classification always speak
    // about the same fleet. Dark → null unconditionally (byte-identical set; see the header).
    const sortie = opts.unifiedEnabled ? classifySortieLeg(lead.mission_type) : null
    out.push({ groupId: gid, name: nameById.get(gid) as string, fleetCount: list.length, arriveAt: lead.arrive_at, sortie })
  }
  return out.sort((a, b) => (a.groupId < b.groupId ? -1 : a.groupId > b.groupId ? 1 : 0))
}

// ── Stop outcome copy ────────────────────────────────────────────────────────────────────────────
// stop_ship_group_transit (0164) is BEST-EFFORT: past the pre-read checks it always returns ok:true with
// a {stopped, skipped, failed} aggregate only the server can compute (see the header). This builds the
// summary from the server's OWN numbers rather than assuming every member halted.

// The RPC result is an opaque bag (TeamRpcResult's `{ ok: true; [k: string]: unknown }`); the index
// signature keeps this assignable from it while still naming the three keys 0164 actually returns.
export interface GroupStopOutcome {
  stopped?: unknown
  skipped?: unknown
  failed?: unknown
  [k: string]: unknown
}

/** Player-facing summary of a best-effort group stop, from the SERVER's aggregate. */
export function stopOutcomeMessage(fleetName: string, res: GroupStopOutcome): string {
  const n = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : 0)
  const stopped = n(res.stopped)
  const failed = n(res.failed)
  const ships = (c: number) => `${c} ship${c === 1 ? '' : 's'}`
  if (stopped === 0 && failed === 0) return `${fleetName} was already stopped — nothing was in flight.`
  const parts = [`Stopped ${fleetName}`]
  if (stopped > 0) parts.push(`— ${ships(stopped)} holding position`)
  if (failed > 0) parts.push(`· ${ships(failed)} couldn't stop`)
  return `${parts.join(' ')}.`
}

// ── FLEET-GO 4a-1 — the UNIFIED stop's envelope parser + outcome copy (0209). ────────────────────
//
// A NEW parser, not a widening of stopOutcomeMessage — because the two envelopes DISAGREE on the
// same key: `stopped` is a per-member COUNT in 0164 ({stopped: 3, skipped: 1, failed: 0}) but a
// BOOLEAN in 0209 ({stopped: true} — ONE fleet, ONE brake, nothing to count). stopOutcomeMessage's
// numeric filter (`typeof v === 'number' && v > 0`) coerces a 0209 success's `stopped: true` to 0
// and reports "was already stopped — nothing was in flight" ON A SUCCESSFUL STOP. The spec battery
// pins that divergence explicitly (feed a 0209 success to BOTH; assert they disagree), so nobody
// "simplifies" the two parsers back into one.
//
// 0209's ok:true shape: { stopped: boolean, reason_code?: 'no_fleet' | 'not_moving' |
// 'already_settled', cancelled_movement_id?, space_x?, space_y?, … }. reason_code only accompanies
// stopped:false (the idempotent no-op arms). Rejects (ok:false + reason) never reach this parser —
// TeamMapStop routes those through teamReasonMessage like every other RPC.

export type UnifiedStopReasonCode = 'no_fleet' | 'not_moving' | 'already_settled'

export interface UnifiedStopOutcome {
  /** BOOLEAN (0209): the fleet's live leg was cancelled and it now holds in open space. */
  stopped: boolean
  /** Why a stopped:false call was a no-op; null on success or on an unrecognized code. */
  reasonCode: UnifiedStopReasonCode | null
}

/** Parse a 0209 ok:true envelope. Strict boolean read: only `stopped === true` counts as a halt. */
export function parseUnifiedStopResult(res: Record<string, unknown>): UnifiedStopOutcome {
  const rc = res.reason_code
  return {
    stopped: res.stopped === true,
    reasonCode: rc === 'no_fleet' || rc === 'not_moving' || rc === 'already_settled' ? rc : null,
  }
}

/** Player-facing summary of a unified fleet stop (ONE fleet — no per-ship breakdown exists). */
export function unifiedStopOutcomeMessage(fleetName: string, res: Record<string, unknown>): string {
  const o = parseUnifiedStopResult(res)
  if (o.stopped) return `Stopped ${fleetName} — holding position in open space.`
  if (o.reasonCode === 'already_settled') return `${fleetName} already arrived — nothing to stop.`
  // no_fleet / not_moving / unrecognized: the fleet simply is not in flight. Idempotent, calm copy.
  return `${fleetName} was already stopped — nothing was in flight.`
}
