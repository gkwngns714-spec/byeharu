import { test, expect } from '@playwright/test'
import {
  buildFleetCommandModel,
  fleetCommandLocks,
  type FleetCommandModelInput,
  type FleetCommandSection,
} from '../src/features/map/fleetCommandModel'
import { fleetGoTargetView } from '../src/features/map/fleetGoTarget'
import type { FleetMovement } from '../src/features/fleets/fleetTypes'
import type { GroupRow, ShipGroupMapEntry } from '../src/features/command/teamRoster'
import type { UnifiedGroupFleetLite } from '../src/features/command/teamApi'
import type { MapLocation } from '../src/features/map/mapTypes'

// S5 MAP-UX — the FleetCommandPanel contract, pinned at the PURE composition model (the panel is a
// SHELL that renders `sections` in array order and submits each row's `wire` verbatim, so these
// pins ARE the panel's behavior). The four laws under proof:
//   (a) NO-SOFTLOCK: the stop section renders with NO target — state-predicated only.
//   (b) Stop is FIRST whenever any owned fleet is in flight, whatever else is live.
//   (c) A dock row exists ONLY for a fleet parked in space inside a dockable PORT's territory.
//   (d) THE RAW-COORDS LAW: a point row's wire is fleetGoRpcTarget(view) — the RAW tap, never the
//       canonical preview.

const G1: GroupRow = { group_id: 'g1', group_index: 1, name: 'Alpha' }
const G2: GroupRow = { group_id: 'g2', group_index: 2, name: 'Beta' }

const loc = (over: Partial<MapLocation> & { id: string }): MapLocation => ({
  name: over.id,
  location_type: 'safe_zone',
  x: 0,
  y: 0,
  base_difficulty: 0,
  reward_tier: 0,
  activity_type: 'none',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  territory_radius: null,
  ...over,
})
const PORT = loc({ id: 'port-1', name: 'Haven', location_type: 'trade_outpost', x: 100, y: 100, territory_radius: 50 })
const RING = loc({ id: 'ring-1', name: 'Quietness', x: -200, y: -200, territory_radius: 50 }) // territory, NOT a port
const HUNT = loc({ id: 'hunt-1', name: 'Deadwake', location_type: 'pirate_hunt', activity_type: 'hunt_pirates', x: 300, y: 300 })
const LOCS = [PORT, RING, HUNT]

const mov = (gid: string): FleetMovement => ({
  id: `m-${gid}`,
  fleet_id: `f-${gid}`,
  origin_type: 'location',
  origin_x: 0,
  origin_y: 0,
  target_type: 'location',
  target_location_id: null,
  target_base_id: null,
  target_x: 10,
  target_y: 10,
  mission_type: 'expedition',
  status: 'moving',
  depart_at: '2026-01-01T00:00:00Z',
  arrive_at: '2026-01-01T01:00:00Z',
  travel_seconds: 3600,
  travel_distance: 10,
  group_id: gid,
})

const parked = (gid: string, x: number, y: number, over: Partial<UnifiedGroupFleetLite> = {}): UnifiedGroupFleetLite => ({
  group_id: gid,
  status: 'idle',
  location_mode: 'space',
  current_location_id: null,
  space_x: x,
  space_y: y,
  ...over,
})

const member = (groupId: string): ShipGroupMapEntry => ({ group_id: groupId, captain_slots: null, is_command_ship: false })

const base = (over: Partial<FleetCommandModelInput> = {}): FleetCommandModelInput => ({
  target: null,
  movements: [],
  groups: [G1],
  groupsLoaded: true, // the groups read succeeded (the normal world; the M2 review-fix spec flips it)
  unifiedEnabled: true,
  unifiedFleets: [],
  rollups: [],
  locations: LOCS,
  ships: [],
  membership: {},
  launchFromDock: false,
  fleetControlEnabled: false,
  ...over,
})

const kinds = (sections: FleetCommandSection[]) => sections.map((s) => s.kind)

// ── (a) NO-SOFTLOCK: stop needs no target, no tap, no selection ──────────────────────────────────

test('(a) stop rows render with NO target — an in-flight fleet alone mounts the panel, stop first', () => {
  const m = buildFleetCommandModel(base({ movements: [mov('g1')] }))
  expect(m.mount).toBe(true)
  expect(m.sections[0].kind).toBe('stop')
  const stop = m.sections[0]
  if (stop.kind !== 'stop') throw new Error('unreachable')
  expect(stop.rows.map((r) => r.groupId)).toEqual(['g1'])
  expect(stop.rows[0].canStop).toBe(true)
})

test('(a) the stop section is target-INDEPENDENT: identical rows with and without a live target', () => {
  const noTarget = buildFleetCommandModel(base({ movements: [mov('g1')] }))
  const withTarget = buildFleetCommandModel(
    base({ movements: [mov('g1')], target: { kind: 'point', view: fleetGoTargetView({ x: 10, y: 10 }) } }),
  )
  expect(withTarget.sections[0]).toEqual(noTarget.sections[0])
})

// ── (b) stop is FIRST whatever else is live ──────────────────────────────────────────────────────

test('(b) stop stays FIRST when a point target, go rows, and a dockable parked fleet are ALL live', () => {
  const m = buildFleetCommandModel(
    base({
      groups: [G1, G2],
      movements: [mov('g1')],
      unifiedFleets: [parked('g2', 120, 120)], // inside Haven's territory (dist ≈ 28 ≤ 50)
      target: { kind: 'point', view: fleetGoTargetView({ x: 10, y: 10 }) },
    }),
  )
  expect(kinds(m.sections)).toEqual(['stop', 'context', 'go', 'dock'])
})

// ── (c) dock rows: space + dockable-PORT territory only ──────────────────────────────────────────

test('(c) dock row ONLY for a fleet parked in space inside a dockable port territory (v1 wire = the instant go-to-port)', () => {
  const inside = buildFleetCommandModel(base({ unifiedFleets: [parked('g1', 120, 120)] }))
  expect(inside.mount).toBe(true) // the dock leg alone mounts the panel (no target, nothing in flight)
  expect(kinds(inside.sections)).toEqual(['dock'])
  const dock = inside.sections[0]
  if (dock.kind !== 'dock') throw new Error('unreachable')
  expect(dock.rows).toEqual([
    { groupId: 'g1', name: 'Alpha', portId: 'port-1', portName: 'Haven', wire: { locationId: 'port-1' } },
  ])
})

test('(c) NO dock row: open space, a non-port territory, a moving fleet, or a docked fleet', () => {
  for (const fleets of [
    [parked('g1', 400, 400)], // open space — no territory contains it
    [parked('g1', -190, -190)], // inside a territory that is NOT a dockable port
    [parked('g1', 120, 120, { status: 'moving' })], // in flight — the stop section's business
    [parked('g1', 120, 120, { location_mode: 'location', current_location_id: 'port-1' })], // already docked
  ]) {
    const m = buildFleetCommandModel(base({ unifiedFleets: fleets }))
    expect(kinds(m.sections)).not.toContain('dock')
  }
})

// ── (e) DISCOVERABILITY: the "send a fleet" prompt fills the otherwise-empty state ───────────────

test('(e) a fleet owner with no flight, no dockable fleet, and no target gets the prompt (panel is NOT empty)', () => {
  const m = buildFleetCommandModel(base()) // one group, nothing in flight, no target
  expect(m.mount).toBe(true)
  expect(kinds(m.sections)).toEqual(['prompt'])
})

test('(e) the prompt yields to a live section — target, in-flight, or dockable all suppress it', () => {
  // a picked destination → context/go, no prompt
  const withTarget = buildFleetCommandModel(base({ target: { kind: 'point', view: fleetGoTargetView({ x: 10, y: 10 }) } }))
  expect(kinds(withTarget.sections)).not.toContain('prompt')
  // a fleet in flight → stop, no prompt
  const inFlight = buildFleetCommandModel(base({ movements: [mov('g1')] }))
  expect(kinds(inFlight.sections)).not.toContain('prompt')
  // a dockable parked fleet → dock, no prompt
  const dockable = buildFleetCommandModel(base({ unifiedFleets: [parked('g1', 120, 120)] }))
  expect(kinds(dockable.sections)).not.toContain('prompt')
})

test('(e) a player with NO fleet never gets the prompt (that is the groupless guidance branch)', () => {
  const noFleet = buildFleetCommandModel(base({ groups: [], ships: [], target: null }))
  expect(kinds(noFleet.sections)).not.toContain('prompt')
  expect(noFleet.mount).toBe(false)
})

// ── (d) THE RAW-COORDS LAW on the point wire ─────────────────────────────────────────────────────

test('(d) a point go row wires the RAW tapped point — never the canonical preview', () => {
  const view = fleetGoTargetView({ x: 3.5, y: -2.5 }) // canonical (half-away-from-zero) = (4, -3)
  expect(view.canonical).toEqual({ x: 4, y: -3 })
  const m = buildFleetCommandModel(base({ target: { kind: 'point', view } }))
  const go = m.sections.find((s) => s.kind === 'go')
  if (!go || go.kind !== 'go') throw new Error('no go section')
  expect(go.rows[0].action).toBe('go')
  expect(go.rows[0].wire).toEqual({ x: 3.5, y: -2.5 }) // RAW — 0208 rounds server-side
  expect(go.rows[0].wire).not.toEqual({ x: 4, y: -3 })
})

test('(d) already-here suppression compares the CANONICAL point (fleets park on the integer grid)', () => {
  const view = fleetGoTargetView({ x: 3.5, y: -2.5 })
  const m = buildFleetCommandModel(
    base({ target: { kind: 'point', view }, unifiedFleets: [parked('g1', 4, -3)] }),
  )
  const go = m.sections.find((s) => s.kind === 'go')
  if (!go || go.kind !== 'go') throw new Error('no go section')
  expect(go.rows[0].action).toBe('already_here')
  expect(go.rows[0].wire).toBeNull() // suppressed — the badge, never a pointless no-op go
})

test('an out-of-bounds point keeps the context (OOB notice + clear) but yields NO go rows', () => {
  const m = buildFleetCommandModel(base({ target: { kind: 'point', view: fleetGoTargetView({ x: 10001, y: 0 }) } }))
  expect(m.mount).toBe(true)
  expect(kinds(m.sections)).toEqual(['context'])
})

// ── port target: unified-arm-only send + docked-here suppression + the hunt absorb ───────────────

test('port target (expedition): unified arm sends {locationId}; a fleet docked THERE is suppressed', () => {
  const m = buildFleetCommandModel(
    base({
      groups: [G1, G2],
      target: { kind: 'port', locationId: 'port-1' },
      rollups: [
        { groupId: 'g1', name: 'Alpha', memberCount: 2, dockedCount: 2, locationId: 'port-1' },
        { groupId: 'g2', name: 'Beta', memberCount: 1, dockedCount: 0, locationId: null },
      ],
    }),
  )
  const go = m.sections.find((s) => s.kind === 'go')
  if (!go || go.kind !== 'go') throw new Error('no go section')
  expect(go.rows).toEqual([
    { groupId: 'g1', name: 'Alpha', action: 'docked_here', label: 'Send fleet here', wire: null },
    { groupId: 'g2', name: 'Beta', action: 'go', label: 'Send fleet here', wire: { locationId: 'port-1' } },
  ])
})

test('port target while the unified flag is DARK: no go arm (un-flip insurance), context only', () => {
  const m = buildFleetCommandModel(base({ unifiedEnabled: false, target: { kind: 'port', locationId: 'port-1' } }))
  expect(kinds(m.sections)).toEqual(['context'])
})

test('hunt target: the absorbed hunt arm (both worlds) — readiness mirror + NO-HOME return picker', () => {
  const ships = [
    { main_ship_id: 's1', status: 'home' },
    { main_ship_id: 's2', status: 'home' },
  ]
  const membership = { s1: member('g1'), s2: member('g1') }
  const ready = buildFleetCommandModel(
    base({ unifiedEnabled: false, target: { kind: 'port', locationId: 'hunt-1' }, ships, membership }),
  )
  const hunt = ready.sections.find((s) => s.kind === 'hunt')
  if (!hunt || hunt.kind !== 'hunt') throw new Error('no hunt section')
  expect(hunt.locationName).toBe('Deadwake')
  expect(hunt.rows[0]).toMatchObject({ groupId: 'g1', memberCount: 2, canHunt: true, cmdActive: true, readyHint: null })
  expect(hunt.rows[0].returnPicker).toBeNull() // dark NO-HOME → the legacy re-home path stands

  // A docked-together team + launch-from-dock lit → hunt-ready WITH the return-port picker; the
  // hunt site itself is never a dockable return option.
  const docked = buildFleetCommandModel(
    base({
      target: { kind: 'port', locationId: 'hunt-1' },
      ships: [
        { main_ship_id: 's1', status: 'docked' },
        { main_ship_id: 's2', status: 'docked' },
      ],
      membership,
      launchFromDock: true,
      rollups: [{ groupId: 'g1', name: 'Alpha', memberCount: 2, dockedCount: 2, locationId: 'port-1' }],
    }),
  )
  const h2 = docked.sections.find((s) => s.kind === 'hunt')
  if (!h2 || h2.kind !== 'hunt') throw new Error('no hunt section')
  expect(h2.rows[0].canHunt).toBe(true)
  expect(h2.rows[0].returnPicker?.launchPortId).toBe('port-1')
  expect(h2.rows[0].returnPicker?.options.map((o) => o.id)).not.toContain('hunt-1')

  // Not ready (a ship away from home, dark NO-HOME) → the hint, never an enabled hunt.
  const away = buildFleetCommandModel(
    base({
      unifiedEnabled: false,
      target: { kind: 'port', locationId: 'hunt-1' },
      ships: [
        { main_ship_id: 's1', status: 'home' },
        { main_ship_id: 's2', status: 'docked' },
      ],
      membership,
    }),
  )
  const h3 = away.sections.find((s) => s.kind === 'hunt')
  if (!h3 || h3.kind !== 'hunt') throw new Error('no hunt section')
  expect(h3.rows[0].canHunt).toBe(false)
  expect(h3.rows[0].readyHint).toBe('Every ship must be home to hunt.')
})

// ── the brake lock: Stop is NEVER disabled by another verb's in-flight request ───────────────────
// (S5 review fix: the consolidation must not couple the safety brake to the shared verb lock —
// supabase-js has no client timeout, so a wedged go/dock/hunt must never take Stop down with it.)

test('brake decoupling: Stop stays enabled while a go/dock/hunt request is busy', () => {
  for (const key of ['go:g1', 'dock:g1', 'hunt:g1']) {
    const locks = fleetCommandLocks({ busy: key, stopBusy: null })
    expect(locks.stopDisabled, `brake must stay live while ${key} is in flight`).toBe(false)
    expect(locks.verbDisabled).toBe(true) // non-safety verbs stay one-at-a-time
  }
})

test('brake decoupling: the brake yields ONLY to its own in-flight stop; verbs yield to the brake', () => {
  const stopping = fleetCommandLocks({ busy: null, stopBusy: 'stop:g1' })
  expect(stopping.stopDisabled).toBe(true) // no double-fired stop
  expect(stopping.verbDisabled).toBe(true) // the one-directional asymmetry: verbs wait for the brake
  expect(fleetCommandLocks({ busy: null, stopBusy: null })).toEqual({ stopDisabled: false, verbDisabled: false })
})

// ── the mount predicate: stop ∨ target ∨ dockable parked fleets ──────────────────────────────────

test('mount predicate: a fleet owner with nothing else live gets the send prompt (never an empty panel)', () => {
  // DISCOVERABILITY: base() owns one fleet with no flight/dock/target — the panel now names the
  // send gesture instead of rendering nothing and popping in on the next tap.
  const m = buildFleetCommandModel(base())
  expect(m.mount).toBe(true)
  expect(m.sections).toEqual([{ kind: 'prompt' }])
})

test('mount predicate: NO fleet and nothing live → no panel', () => {
  const m = buildFleetCommandModel(base({ groups: [], ships: [] }))
  expect(m.mount).toBe(false)
  expect(m.sections).toEqual([])
})

// ── MAP-INTEGRATION M2 — the groupless-player guidance (the prod-majority dead end) ──────────────
// A player whose only ships are berthed (no fleet) used to select a port and get NOTHING here,
// while PortScreen's empty state pointed back at the Map — a circular dead end. Ships + a live
// target + zero groups now mounts ONE guidance section pointing at Command (where TeamRosterPanel
// creates fleets). Guidance only — NO movement/composition controls (charter §2a).

test('M2 guidance: ships + a port target + zero groups → the guidance section (and nothing else)', () => {
  const m = buildFleetCommandModel(
    base({ groups: [], ships: [{ main_ship_id: 's1', status: 'stationary' }], target: { kind: 'port', locationId: 'port-1' } }),
  )
  expect(m.mount).toBe(true)
  expect(m.sections).toEqual([{ kind: 'guidance' }])
})

test('M2 guidance: a point target guides the same way (any live destination counts)', () => {
  const m = buildFleetCommandModel(
    base({
      groups: [],
      ships: [{ main_ship_id: 's1', status: 'stationary' }],
      target: { kind: 'point', view: fleetGoTargetView({ x: 10, y: 10 }) },
    }),
  )
  expect(m.sections).toEqual([{ kind: 'guidance' }])
})

test('M2 guidance REVIEW FIX: a FAILED groups read (groups=[] but groupsLoaded=false) shows NO "No fleet yet"', () => {
  // fetchMyShipGroups collapses transport errors to [] — the same shape as "no fleets". A fleet-
  // owning player on one flaky poll must NOT see the false no-fleet guidance: the claim requires an
  // affirmative successful-and-empty read (groupsLoaded=true).
  const m = buildFleetCommandModel(
    base({
      groups: [],
      groupsLoaded: false,
      ships: [{ main_ship_id: 's1', status: 'stationary' }],
      target: { kind: 'port', locationId: 'port-1' },
    }),
  )
  expect(m.mount).toBe(false)
  expect(m.sections).toEqual([])
})

test('M2 guidance: fails closed without ships, or without a target (the panel stays out of the way)', () => {
  // no ships → nothing to guide (the pre-M2 posture, kept)
  expect(
    buildFleetCommandModel(base({ groups: [], ships: [], target: { kind: 'port', locationId: 'port-1' } })).mount,
  ).toBe(false)
  // no target → no panel (guidance surfaces at the dead end, not permanently)
  expect(
    buildFleetCommandModel(base({ groups: [], ships: [{ main_ship_id: 's1', status: 'stationary' }], target: null })).mount,
  ).toBe(false)
})

test('M2 guidance: never renders for a player WITH a fleet (the normal sections own that world)', () => {
  const m = buildFleetCommandModel(base({ target: { kind: 'port', locationId: 'port-1' } }))
  expect(m.sections.some((s) => s.kind === 'guidance')).toBe(false)
})
