import { test, expect } from '@playwright/test'
import {
  groupStopAvailability,
  resolveStoppableFleets,
  parseUnifiedStopResult,
  unifiedStopOutcomeMessage,
} from '../src/features/command/teamStop'
import { resolveTeamMarkers } from '../src/features/map/teamMarkers'
import type { FleetMovement } from '../src/features/fleets/fleetTypes'
import type { GroupRow } from '../src/features/command/teamRoster'

// TEAM-COMMAND Slice B (sub-slice 2) — pure-logic specs for the group-stop client mirror (no app/Supabase).
// Asserts the same PRE-READ reject ORDER as the server RPC stop_ship_group_transit (migration 0164): dark gate
// FIRST, then group resolution, then non-empty membership. (Per-member stop outcomes are the server's.)

test('groupStopAvailability: gate dark → gate_dark (before group/member checks)', () => {
  expect(groupStopAvailability({ gateEnabled: false, groupResolved: true, memberCount: 3 })).toEqual({
    canStop: false,
    reason: 'gate_dark',
  })
})

test('groupStopAvailability: gate on + unresolved group → group_not_found', () => {
  expect(groupStopAvailability({ gateEnabled: true, groupResolved: false, memberCount: 3 })).toEqual({
    canStop: false,
    reason: 'group_not_found',
  })
})

test('groupStopAvailability: gate on + resolved + empty group → empty_group', () => {
  expect(groupStopAvailability({ gateEnabled: true, groupResolved: true, memberCount: 0 })).toEqual({
    canStop: false,
    reason: 'empty_group',
  })
})

test('groupStopAvailability: gate on + resolved + ≥1 member → ok', () => {
  expect(groupStopAvailability({ gateEnabled: true, groupResolved: true, memberCount: 1 })).toEqual({
    canStop: true,
    reason: 'ok',
  })
})

test('groupStopAvailability: order — dark gate beats an unresolved AND empty group', () => {
  expect(
    groupStopAvailability({ gateEnabled: false, groupResolved: false, memberCount: 0 }).reason,
  ).toBe('gate_dark')
})

test('groupStopAvailability: order — group resolution is checked before membership', () => {
  expect(
    groupStopAvailability({ gateEnabled: true, groupResolved: false, memberCount: 0 }).reason,
  ).toBe('group_not_found')
})

// ── MOVEMENT-ON-MAP step 2 — the map Stop's derivation (same file, same server contract) ─────────
// The load-bearing case is the deliberate divergence from resolveTeamMarkers: a fleet with an
// un-drawable segment MUST still be stoppable.

const DEP = '2026-01-01T00:00:00Z'
const ARR = '2026-01-01T00:10:00Z'
const ARR_LATE = '2026-01-01T00:30:00Z'

const mv = (o: Partial<FleetMovement> = {}): FleetMovement =>
  ({
    id: 'm1',
    fleet_id: 'f1',
    origin_type: 'base',
    origin_x: 0,
    origin_y: 0,
    target_type: 'location',
    target_location_id: 'loc-A',
    target_base_id: null,
    target_x: 100,
    target_y: 200,
    mission_type: 'rally',
    status: 'moving',
    depart_at: DEP,
    arrive_at: ARR,
    travel_seconds: 600,
    travel_distance: 100,
    group_id: null,
    ...o,
  }) as FleetMovement

const grp = (group_id: string, name: string): GroupRow =>
  ({ group_id, name, group_index: 1 }) as unknown as GroupRow

const G1 = grp('g1', 'Vanguard')
const G2 = grp('g2', 'Hammer')

test('resolveStoppableFleets: no groups → nothing stoppable (team-less map stays byte-identical)', () => {
  expect(resolveStoppableFleets([mv({ group_id: 'g1' })], [])).toEqual([])
})

test('resolveStoppableFleets: a moving tagged fleet → one row carrying the owner-read name', () => {
  const out = resolveStoppableFleets([mv({ group_id: 'g1' })], [G1])
  expect(out).toHaveLength(1)
  expect(out[0]).toMatchObject({ groupId: 'g1', name: 'Vanguard', fleetCount: 1, arriveAt: ARR })
})

test('resolveStoppableFleets: untagged and non-moving rows contribute nothing', () => {
  const rows = [
    mv({ id: 'a', group_id: null }),
    mv({ id: 'b', group_id: 'g1', status: 'arrived' }),
    mv({ id: 'c', group_id: 'g1', status: 'cancelled' }),
  ]
  expect(resolveStoppableFleets(rows, [G1])).toEqual([])
})

test('resolveStoppableFleets: fail closed on a tag outside the owner read (never a guessed name)', () => {
  expect(resolveStoppableFleets([mv({ group_id: 'g-foreign' })], [G1])).toEqual([])
})

test('resolveStoppableFleets: an expedition fan-out collapses to ONE row, counting member fleets', () => {
  const out = resolveStoppableFleets(
    [
      mv({ id: 'm1', fleet_id: 'f1', group_id: 'g1', arrive_at: ARR_LATE }),
      mv({ id: 'm2', fleet_id: 'f2', group_id: 'g1', arrive_at: ARR }),
      mv({ id: 'm3', fleet_id: 'f3', group_id: 'g1', arrive_at: ARR_LATE }),
    ],
    [G1],
  )
  expect(out).toHaveLength(1)
  expect(out[0].fleetCount).toBe(3)
  expect(out[0].arriveAt).toBe(ARR) // lead = earliest ETA, matching the teamMarkers badge rule
})

test('resolveStoppableFleets: two in-flight groups → deterministic order by groupId', () => {
  const out = resolveStoppableFleets([mv({ id: 'm2', group_id: 'g2' }), mv({ id: 'm1', group_id: 'g1' })], [G2, G1])
  expect(out.map((r) => r.groupId)).toEqual(['g1', 'g2'])
})

test('resolveStoppableFleets: equal ETAs tie-break on movement id (stable across re-renders)', () => {
  const a = resolveStoppableFleets([mv({ id: 'zz', group_id: 'g1' }), mv({ id: 'aa', group_id: 'g1' })], [G1])
  const b = resolveStoppableFleets([mv({ id: 'aa', group_id: 'g1' }), mv({ id: 'zz', group_id: 'g1' })], [G1])
  expect(a).toEqual(b)
})

test('an UN-DRAWABLE in-flight fleet is STILL stoppable (the Stop must not inherit the badge gate)', () => {
  // A degenerate segment: teamMarkers refuses to guess a position and draws NO badge for it.
  const broken = mv({ group_id: 'g1', depart_at: ARR, arrive_at: DEP, travel_seconds: 0 })
  expect(resolveTeamMarkers([broken], [G1], Date.parse(ARR))).toEqual([])
  // ...but the player must still be able to halt it — precisely the wreckage case.
  const stoppable = resolveStoppableFleets([broken], [G1])
  expect(stoppable).toHaveLength(1)
  expect(stoppable[0].groupId).toBe('g1')
})

test('stoppability is time-independent — the signature takes no clock at all', () => {
  // Two parameters, and neither is a clock. 0305 REMOVED the third (the sortie flag bag): the client
  // no longer predicts the server's answer, so there is nothing left to configure.
  expect(resolveStoppableFleets.length).toBe(2)
})

// ── 0305 — EVERY IN-FLIGHT FLEET IS STOPPABLE. ───────────────────────────────────────────────────
// What these tests replaced: a client-side `classifySortieLeg(mission_type)` proxy that marked
// hunt_pirates/return_home rows non-actionable so the rail could hide the Stop button, mirroring the
// 0215 server refusal. That refusal is gone — command_ship_group_stop now answers every Stop (an
// open fight composes with the retreat authority). A client that keeps predicting a refusal that no
// longer exists just hides the control the player asked for. The property is now unconditional.

test('a hunt leg is stoppable — no mission_type is special any more (outbound)', () => {
  const out = resolveStoppableFleets([mv({ group_id: 'g1', mission_type: 'hunt_pirates' })], [G1])
  expect(out).toEqual([{ groupId: 'g1', name: 'Vanguard', fleetCount: 1, arriveAt: ARR }])
})

test('a return leg is stoppable too (returning)', () => {
  const out = resolveStoppableFleets([mv({ group_id: 'g1', mission_type: 'return_home' })], [G1])
  expect(out).toEqual([{ groupId: 'g1', name: 'Vanguard', fleetCount: 1, arriveAt: ARR }])
})

test('NO descriptor carries a sortie verdict — the field is gone, not merely always-null', () => {
  // Guards the whole class: a future re-introduction of a client-side refusal proxy fails here.
  const rows = [
    mv({ id: 'm1', group_id: 'g1', mission_type: 'hunt_pirates' }),
    mv({ id: 'm2', group_id: 'g2', mission_type: 'return_home' }),
  ]
  for (const r of resolveStoppableFleets(rows, [G1, G2])) {
    expect(Object.keys(r).sort()).toEqual(['arriveAt', 'fleetCount', 'groupId', 'name'])
  }
})

test('every mission shape yields the same actionable row set, in deterministic order', () => {
  const rows = [
    mv({ id: 'm1', group_id: 'g1', mission_type: 'hunt_pirates' }),
    mv({ id: 'm2', group_id: 'g2', mission_type: 'return_home' }),
    mv({ id: 'm3', group_id: 'g3', mission_type: 'rally' }),
  ]
  const G3 = grp('g3', 'Lance')
  expect(resolveStoppableFleets(rows, [G1, G2, G3])).toEqual([
    { groupId: 'g1', name: 'Vanguard', fleetCount: 1, arriveAt: ARR },
    { groupId: 'g2', name: 'Hammer', fleetCount: 1, arriveAt: ARR },
    { groupId: 'g3', name: 'Lance', fleetCount: 1, arriveAt: ARR },
  ])
})

test('the row still speaks about the LEAD movement (earliest ETA), whatever its mission', () => {
  const out = resolveStoppableFleets(
    [
      mv({ id: 'm-late', group_id: 'g1', mission_type: 'rally', arrive_at: ARR_LATE }),
      mv({ id: 'm-lead', group_id: 'g1', mission_type: 'hunt_pirates', arrive_at: ARR }),
    ],
    [G1],
  )
  expect(out).toHaveLength(1)
  expect(out[0].arriveAt).toBe(ARR)
})

// ── 0305 — the brake's new outcome copy: a Stop in a real fight BREAKS OFF, it is not refused. ────

test('unifiedStopOutcomeMessage: retreat_started says the fleet leaves UNDER FIRE (never a clean halt)', () => {
  const res = { ok: true, group_id: 'g1', fleet_id: 'f1', stopped: false, reason_code: 'retreat_started' }
  const msg = unifiedStopOutcomeMessage('Vanguard', res)
  expect(msg).toBe('Vanguard is breaking off — retreating under fire until it clears the fight.')
  // The copy must NOT read like the free-halt message, or Stop looks better than Retreat.
  expect(msg).not.toContain('holding position')
})

test('unifiedStopOutcomeMessage: retreat_already_underway does not promise a second, faster exit', () => {
  const res = { ok: true, group_id: 'g1', fleet_id: 'f1', stopped: false, reason_code: 'retreat_already_underway' }
  expect(unifiedStopOutcomeMessage('Vanguard', res)).toBe(
    'Vanguard is already retreating — it leaves when the window closes.',
  )
})

test('parseUnifiedStopResult: the two retreat codes parse; an unknown code still degrades to null', () => {
  expect(parseUnifiedStopResult({ stopped: false, reason_code: 'retreat_started' }).reasonCode).toBe('retreat_started')
  expect(parseUnifiedStopResult({ stopped: false, reason_code: 'retreat_already_underway' }).reasonCode).toBe(
    'retreat_already_underway',
  )
  expect(parseUnifiedStopResult({ stopped: false, reason_code: 'who_knows' }).reasonCode).toBeNull()
})

// ── FLEET-GO 4a-1 — the UNIFIED stop's parser (0209), the ONLY group-stop path now. ──────────────
// The legacy per-member stopOutcomeMessage (0164) was retired with the movement-signal cleanup once
// fleet_movement_unified_enabled went on in prod. `stopped` is a BOOLEAN here (ONE fleet, one brake).

test('unifiedStopOutcomeMessage: a 0209 SUCCESS reads the boolean and reports the halt in open space', () => {
  // A real 0209 success envelope: the fleet's leg was cancelled, it now holds in space.
  const success = { ok: true, group_id: 'g1', fleet_id: 'f1', stopped: true, cancelled_movement_id: 'm1', space_x: 10, space_y: 20 }
  expect(unifiedStopOutcomeMessage('Vanguard', success)).toBe('Stopped Vanguard — holding position in open space.')
})

test('parseUnifiedStopResult: strict boolean — only `stopped: true` is a halt (counts never leak in)', () => {
  expect(parseUnifiedStopResult({ stopped: true })).toEqual({ stopped: true, reasonCode: null })
  expect(parseUnifiedStopResult({ stopped: false, reason_code: 'not_moving' })).toEqual({ stopped: false, reasonCode: 'not_moving' })
  // A 0164-shaped COUNT (or any non-boolean) is NOT a unified success — fail closed.
  expect(parseUnifiedStopResult({ stopped: 3 }).stopped).toBe(false)
  expect(parseUnifiedStopResult({ stopped: 'true' }).stopped).toBe(false)
  expect(parseUnifiedStopResult({}).stopped).toBe(false)
})

test('parseUnifiedStopResult: reason codes are the 0209 vocabulary only; unknown codes → null', () => {
  expect(parseUnifiedStopResult({ stopped: false, reason_code: 'no_fleet' }).reasonCode).toBe('no_fleet')
  expect(parseUnifiedStopResult({ stopped: false, reason_code: 'already_settled' }).reasonCode).toBe('already_settled')
  expect(parseUnifiedStopResult({ stopped: false, reason_code: 'surprise' }).reasonCode).toBeNull()
  expect(parseUnifiedStopResult({ stopped: true }).reasonCode).toBeNull()
})

test('unifiedStopOutcomeMessage: the idempotent no-op arms read calm, never as errors', () => {
  expect(unifiedStopOutcomeMessage('Vanguard', { ok: true, stopped: false, reason_code: 'no_fleet' })).toBe(
    'Vanguard was already stopped — nothing was in flight.',
  )
  expect(unifiedStopOutcomeMessage('Vanguard', { ok: true, stopped: false, reason_code: 'not_moving' })).toBe(
    'Vanguard was already stopped — nothing was in flight.',
  )
  expect(unifiedStopOutcomeMessage('Vanguard', { ok: true, stopped: false, reason_code: 'already_settled' })).toBe(
    'Vanguard already arrived — nothing to stop.',
  )
  // Opaque envelope → the calm no-op line, never NaN/undefined leakage.
  expect(unifiedStopOutcomeMessage('Vanguard', {})).toBe('Vanguard was already stopped — nothing was in flight.')
})
