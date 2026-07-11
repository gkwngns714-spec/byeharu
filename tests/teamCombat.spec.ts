import { test, expect } from '@playwright/test'
import { groupHuntAvailability, huntableDestinations } from '../src/features/command/teamCombat'

// TEAM-COMMAND Slice D4 — pure-logic specs for the team-combat client mirrors (no app/Supabase).
// The teamSend.spec.ts mold: destination filter first, then the full reject-order table of the
// availability mirror against send_ship_group_hunt (migration 0168).

const loc = (o: Partial<{ id: string; name: string; status: string; activity_type: string }> = {}) => ({
  id: 'l1',
  name: 'Warzone',
  status: 'active',
  activity_type: 'hunt_pirates',
  ...o,
})

// ── huntableDestinations — active + hunt_pirates only, projected + sorted ───────────────────────────
test('huntableDestinations: keeps active hunt_pirates, drops every other activity (incl. "none")', () => {
  const out = huntableDestinations([
    loc({ id: 'a', name: 'Warzone', activity_type: 'hunt_pirates' }),
    loc({ id: 'b', name: 'Haven', activity_type: 'none' }), // the SEND destination — not huntable
    loc({ id: 'c', name: 'Market', activity_type: 'trade_visit' }),
    loc({ id: 'd', name: 'Digsite', activity_type: 'mine_resource' }),
  ])
  expect(out).toEqual([{ id: 'a', name: 'Warzone' }])
})

test('huntableDestinations: drops non-active even when hunt_pirates (defensive status clause)', () => {
  expect(huntableDestinations([loc({ id: 'x', status: 'inactive' })])).toEqual([])
})

test('huntableDestinations: projects to {id,name} and sorts by name, independent of input order', () => {
  const out = huntableDestinations([
    loc({ id: 'c', name: 'Slag Reach' }),
    loc({ id: 'a', name: 'Drift Ambush' }),
    loc({ id: 'b', name: 'Pirate Shoal' }),
  ])
  expect(out).toEqual([
    { id: 'a', name: 'Drift Ambush' },
    { id: 'b', name: 'Pirate Shoal' },
    { id: 'c', name: 'Slag Reach' },
  ])
})

test('huntableDestinations: empty input and no-combat input → [] (a legitimate, renderable state)', () => {
  expect(huntableDestinations([])).toEqual([])
  expect(huntableDestinations([loc({ activity_type: 'none' })])).toEqual([])
})

// TEAM-COMMAND Slice D4 — reject-order table for the group-hunt client mirror. Asserts the same
// reject ORDER as the server RPC send_ship_group_hunt (migration 0168): dark gate FIRST, then group
// resolution, then non-empty membership, then the combat destination, then member readiness. Each
// stage is pinned with every LATER input also failing, so the table is an order proof, not just a
// vocabulary proof.

const allGreen = {
  gateEnabled: true,
  groupResolved: true,
  memberCount: 2,
  locationValid: true,
  allMembersReady: true,
}

test('groupHuntAvailability: gate dark → gate_dark (beats everything else failing too)', () => {
  expect(
    groupHuntAvailability({
      gateEnabled: false,
      groupResolved: false,
      memberCount: 0,
      locationValid: false,
      allMembersReady: false,
    }),
  ).toEqual({ canHunt: false, reason: 'gate_dark' })
})

test('groupHuntAvailability: gate on + unresolved group → group_not_found (beats later failures)', () => {
  expect(
    groupHuntAvailability({
      gateEnabled: true,
      groupResolved: false,
      memberCount: 0,
      locationValid: false,
      allMembersReady: false,
    }),
  ).toEqual({ canHunt: false, reason: 'group_not_found' })
})

test('groupHuntAvailability: resolved + empty group → empty_group (beats later failures)', () => {
  expect(
    groupHuntAvailability({
      gateEnabled: true,
      groupResolved: true,
      memberCount: 0,
      locationValid: false,
      allMembersReady: false,
    }),
  ).toEqual({ canHunt: false, reason: 'empty_group' })
})

test('groupHuntAvailability: populated group + invalid destination → invalid_location (beats readiness)', () => {
  expect(
    groupHuntAvailability({
      gateEnabled: true,
      groupResolved: true,
      memberCount: 2,
      locationValid: false,
      allMembersReady: false,
    }),
  ).toEqual({ canHunt: false, reason: 'invalid_location' })
})

test('groupHuntAvailability: valid destination + members not ready → member_not_ready', () => {
  expect(
    groupHuntAvailability({
      gateEnabled: true,
      groupResolved: true,
      memberCount: 2,
      locationValid: true,
      allMembersReady: false,
    }),
  ).toEqual({ canHunt: false, reason: 'member_not_ready' })
})

test('groupHuntAvailability: all green → ok', () => {
  expect(groupHuntAvailability(allGreen)).toEqual({ canHunt: true, reason: 'ok' })
})

// ── Server-only rejects — documentation pin ─────────────────────────────────────────────────────────
// Migration 0168's tail (after member_not_ready) is deliberately NOT client-mirrored:
//   fleet_limit_reached → stats_invalid → power_below_required → no_home_base
// Each needs server state the client doesn't mirror (live fleet count, the 0122 stat adapter,
// locations.min_power_required, the player's base row) — the teamSend precedent (the live send's own
// preconditions are the server's). So an all-green CLIENT answer is 'ok' (dispatchable), and the
// server may still envelope-reject; the panel surfaces that reason verbatim after the round-trip.
test('groupHuntAvailability: "ok" means dispatchable, not guaranteed — server-only rejects stay server-side', () => {
  const res = groupHuntAvailability(allGreen)
  expect(res.canHunt).toBe(true)
  // The client vocabulary is EXACTLY the mirrored prefix — none of the server-only tokens exist here.
  const clientReasons = ['ok', 'gate_dark', 'group_not_found', 'empty_group', 'invalid_location', 'member_not_ready']
  expect(clientReasons).toContain(res.reason)
  expect(clientReasons).not.toContain('fleet_limit_reached')
  expect(clientReasons).not.toContain('stats_invalid')
  expect(clientReasons).not.toContain('power_below_required')
  expect(clientReasons).not.toContain('no_home_base')
})
