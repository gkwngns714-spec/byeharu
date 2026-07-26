import { test, expect } from '@playwright/test'
import { teamReasonMessage } from '../src/features/command/teamReasonMessage'

// Pure unit proof for the fail-closed fleet reason→message map (the tradeReasonMessage.spec.ts
// idiom). Every mapped server reason — the reject vocabularies of send_ship_group_hunt (0168), the
// roster writes (0161/0204/0216), the unified mover/brake/dock/retreat (0207/0208/0209/0219/0292),
// the route planner (0233), and the preview/totals reads (0165/0166) — yields specific player-facing
// text; any unmapped/unknown reason (incl. the teamApi transport 'unavailable' fallback) hits the
// generic "Fleet order unavailable." — never a raw code.
// Run: `npx playwright test teamReasonMessage.spec.ts`.

const FALLBACK = 'Fleet order unavailable.'

test('every known fleet-RPC reject reason maps to specific player text (not the fallback, never the raw code)', () => {
  const known = [
    // shared prefix (0161/0165/0166/0168/0204/0216/…)
    'team_command_disabled',
    'not_authenticated',
    'group_not_found',
    'empty_group',
    // hunt send (0168)
    'invalid_location',
    // shared readiness reject: hunt (0168) + docked-team move (0190)
    'member_not_ready',
    'fleet_limit_reached',
    'stats_invalid',
    'power_below_required',
    'no_home_base',
    // preview/totals reads (0165/0166)
    'invalid_activity',
    // FLEET-GO 4a-1 — the unified mover/brake vocabulary (command_ship_group_go 0207/0208 +
    // command_ship_group_stop 0209), verified against the migrations' actual reject envelopes.
    'unified_movement_disabled',
    'member_busy',
    'group_on_sortie',
    'fleet_ambiguous',
    'group_scattered',
    'no_origin',
    'invalid_origin',
    'movement_settled_retry',
    'combat_destination',
    'target_out_of_bounds',
    'invalid_target_shape',
    'invalid_coordinate',
    // S4 TIMED DOCKING — the dock verb's vocabulary (command_ship_group_dock, 0219).
    'timed_docking_disabled',
    'not_parked',
    'not_in_territory',
    'not_dockable',
    'no_fleet',
    // RETREAT-DESTINATION (0292) — a coordinate order refused while the fleet's combat is live.
    'retreat_needs_port_destination',
    // ROSTER WRITES — upsert_ship_group (0161), set_fleet_command_ship (0204), the berth-model
    // assign/unassign + delete guards (0216), the hunt's in-flight refusal (0231).
    'invalid_group_index',
    'invalid_name',
    'ship_not_found',
    'must_unassign_first',
    'group_fleet_in_flight',
    'group_fleet_elsewhere',
    'fleet_in_flight',
    // PIRATE INTERCEPT route planner (0233) — its leg 1 composes the unified mover, so its rejects
    // share this vocabulary; PirateInterceptPanel routes through THIS map, never a second one.
    'pirate_intercept_disabled',
    'invalid_waypoints',
    'invalid_waypoint_count',
    'invalid_waypoint_point',
  ]
  for (const reason of known) {
    const msg = teamReasonMessage(reason)
    expect(msg).not.toBe(FALLBACK)
    expect(msg).not.toContain(reason) // player copy, never the raw code
    expect(msg.length).toBeGreaterThan(10)
  }
})

test('an unmapped/unknown reason (incl. the transport fallback) hits the generic fallback', () => {
  expect(teamReasonMessage('some_unknown_reason')).toBe(FALLBACK)
  expect(teamReasonMessage('unavailable')).toBe(FALLBACK)
  expect(teamReasonMessage('')).toBe(FALLBACK)
})

// RETIREMENT PIN — 'member_send_failed' was emitted ONLY by send_ship_group_expedition (0163→0204)
// and move_ship_group_to_location (0190→0204/0231). Migration 0232:263-264 DROPPED both functions,
// so no server can return it any more; its copy was deleted with them rather than left as dead text
// (a mapped code no emitter can produce is a second, silent source of truth about the vocabulary).
test('the retired 0232 code is gone from the map, not left as dead copy', () => {
  expect(teamReasonMessage('member_send_failed')).toBe(FALLBACK)
})
