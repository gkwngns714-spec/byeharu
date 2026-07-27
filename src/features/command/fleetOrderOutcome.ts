// INTERCEPT DEFERRED ENTRY — the ONE authority over `command_ship_group_go`'s ORDER OUTCOME.
//
// ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────────────────
// The order RPC used to BE the ambush. `command_ship_group_go` minted a leg and, in the SAME
// transaction, an intercept evaluator rolled the dice, cancelled that leg and stood the fleet in a
// fight — so the ambush happened at ORDER TIME and the fleet never travelled. Under the deferred-entry
// contract (server flag `pirate_intercept_deferred_entry_enabled`) the ambush is only PLANNED at order
// time and FIRED later, by the movement processor, when the fleet actually reaches the zone entry
// point. The order response therefore stops being the authority on whether a fight started.
//
// `order_outcome` is what the RPC now says about ITS OWN transaction, and nothing more:
//   'movement_started' — a leg exists; the fleet is travelling.
//   'combat_started'   — no leg survived this call; the fleet is fighting. Reachable ONLY on the
//                        legacy immediate path (deferred entry dark). Once the flag is lit the RPC
//                        can no longer start combat, so this arm simply stops occurring.
// It is NOT a prediction. There is deliberately NO `intercept_pending` / `predicted_ambush` /
// `predicted_encounter_id` anywhere in this client: a planned ambush is an unrolled future random
// result, and shipping it to the browser would both leak the roll and couple the UI to the server's
// scheduling internals. If a future change wants one, that is a design conversation, not a field.
//
// ── FORWARD/BACKWARD COMPATIBILITY (this client deploys via Pages, INDEPENDENTLY of migrations) ────
// The client can be live against three servers and must be correct on all three:
//   (a) TODAY's server (no migration): sends `intercepted` / `intercept_encounter_id`, NO
//       `order_outcome`. An order-time ambush is REAL there, and `intercepted:true` is a true fact
//       about a fight that has already started — so it maps to 'combat_started'.
//   (b) migration deployed, flag OFF: sends today's `intercepted` values AND `order_outcome`. Both
//       agree; `order_outcome` is read first.
//   (c) flag ON: `order_outcome` decides, and `intercepted` is pinned false / the encounter id null.
// Hence the read order below: `order_outcome` wins when present and recognised, otherwise the legacy
// `intercepted` boolean is the fallback, otherwise the order simply started a movement. An absent
// envelope key can never invent a fight.
//
// The envelope keys arrive as `unknown` (TeamRpcResult's index signature), exactly like 0292's
// `outcome` in teamMove.ts's fleetRetreatOutcomeMessage — so they are COMPARED, never cast.
// Pure — no React/DOM/fetch/clock. Proven in tests/fleetOrderOutcome.spec.ts.

/** What the order RPC did inside its own transaction. Never a forecast of what may happen later. */
export type FleetOrderOutcome = 'movement_started' | 'combat_started'

/** The success half of `command_ship_group_go` (and of `command_ship_group_go_route`, whose leg 1
 *  composes it), as of the deferred-entry contract. EVERY field is optional and typed `unknown`:
 *  today's deployed server sends only some of them, and a value is compared, never trusted. */
export interface FleetOrderEnvelope {
  /** The deferred-entry contract's outcome word. Absent on today's server. */
  order_outcome?: unknown
  /** The leg this order minted, when one exists. Null/absent when no journey started. */
  movement_id?: unknown
  /** When that leg is expected to arrive (the `arrive_at` timestamp, renamed by the contract). */
  movement_eta?: unknown
  /** The encounter this order put the fleet into, when it started one. */
  encounter_id?: unknown
  /** LEGACY, retained by the server through the dark rollout — see (a)/(b)/(c) above. */
  intercepted?: unknown
  /** LEGACY, retained by the server through the dark rollout. */
  intercept_encounter_id?: unknown
  // The RPC wrappers hand back TeamRpcResult / PirateRpcResult — `{ ok: true; [k: string]: unknown }`.
  // This index signature is what lets those envelopes flow in unchanged (and it is why the readers
  // below can be handed a WHOLE response, not a hand-picked subset). It also suppresses TypeScript's
  // weak-type check, which would otherwise reject every all-optional target.
  [k: string]: unknown
}

/**
 * The ONE decision: what did this order actually do?
 *
 * Degradation is the whole point of the read order — an absent `order_outcome` falls back to the
 * legacy `intercepted` boolean, and an absent `intercepted` falls back to the only remaining truth
 * about an `ok:true` order: a movement was started. An unrecognised `order_outcome` value (a server
 * newer than this client) is treated as absent rather than as an error, so a new outcome word can
 * never blank the player's confirmation.
 */
export function readFleetOrderOutcome(envelope: FleetOrderEnvelope): FleetOrderOutcome {
  if (envelope.order_outcome === 'combat_started') return 'combat_started'
  if (envelope.order_outcome === 'movement_started') return 'movement_started'
  // No usable `order_outcome` — fall back to the legacy dark-rollout field.
  if (envelope.intercepted === true) return 'combat_started'
  return 'movement_started'
}

/**
 * The ROUTE planner's confirmation line (PirateInterceptPanel). Replaces the old
 * 'Route sent — ambushed on the first leg!', which claimed an order-time ambush that the deferred
 * path never performs. Always returns a line: the player pressed Send and must be told what happened.
 */
export function routeOrderOutcomeMessage(envelope: FleetOrderEnvelope): string {
  return readFleetOrderOutcome(envelope) === 'combat_started'
    ? 'Route sent — combat started.'
    : 'Route sent — fleet underway.'
}

/**
 * The fleet-command surface's OVERRIDE line (FleetCommandPanel's go arm). Returns null for an
 * ordinary movement so the caller keeps its own, richer "Sent <fleet> to <where>." summary — the
 * same null contract as fleetRetreatOutcomeMessage (teamMove.ts). Only 'combat_started' overrides,
 * because that is the one success whose ordinary summary would describe a journey that never began.
 */
export function fleetGoOrderOutcomeMessage(envelope: FleetOrderEnvelope, fleetName: string): string | null {
  if (readFleetOrderOutcome(envelope) === 'combat_started') {
    return `${fleetName} is in combat — no journey started.`
  }
  return null
}
