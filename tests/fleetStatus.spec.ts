import { test, expect } from '@playwright/test'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildFleetStatusModel, type FleetStatusModelInput } from '../src/features/map/fleetStatusModel'
import { FLEET_PRESENCE_STATES, fleetWhereText, type FleetPresenceState } from '../src/features/map/fleetPresence'
import { resolveFleetStandingHunts } from '../src/features/map/fleetStandingHunt'
import { teamReasonMessage } from '../src/features/command/teamReasonMessage'
import { huntSiteActionLabel } from '../src/features/command/howAFightStarts'
import type { GroupRow, ShipGroupMapEntry } from '../src/features/command/teamRoster'
import type { MapLocation } from '../src/features/map/mapTypes'
import type { FleetMovement } from '../src/features/fleets/fleetTypes'
import type { CombatEncounter, CombatUnit } from '../src/features/combat/combatTypes'
// type-only imports — erased at compile, so this spec never loads teamApi's supabase client.
import type { UnifiedGroupFleetLite } from '../src/features/command/teamApi'
import type { FleetPosition } from '../src/features/map/mainshipApi'
import type { DangerZoneLite } from '../src/features/map/pirateApi'

// ██ MY FLEETS, ON THE MAP — the proof. ██
//
// ── THE REQUEST (owner, playing, 2026-08-04) ───────────────────────────────────────────────────────
// "in map, i want to see information regarding fleet, where it is, stats, what it is currently doing.
//  I am in snare but in no fight is occuring, i want also a toggle combat on map as well when i
//  arrive at the combat zone on the fleet information on map"
//
// ── WHAT THESE SPECS PIN ──────────────────────────────────────────────────────────────────────────
//  1. EVERY state a fleet can be in produces a WHERE and a DOING. The state set is closed and
//     spec-iterated (the fleetPresence law), so a sixth state added without a phrase fails here —
//     the same protection the markers have, extended to the words.
//  2. THE REFUSAL IS NAMED, and it is the SERVER's own sentence. A fleet with no command ship is the
//     likeliest reason the owner's fleet will not fight (send_ship_group_hunt checks it FIRST, and
//     of 77 live production ships 2 carry the flag), and the map now says so with the fix in it.
//  3. THE CLIENT DOES NOT GUESS. Everything it cannot prove — a wrecked ship, a partial dock, a fleet
//     split across ports, all of which come back as one `member_not_ready` — leaves the line EMPTY.
//  4. ONE ACTION SLOT, and fighting outranks standing on a fight: the way out is never displaced.
//  5. THE HUNT PATH IS NOT FORKED — the offer is the ONE standing-hunt derivation, and the readout
//     submits nothing (tests/howAFightStarts.spec.ts holds the RPC to one call site; this holds the
//     readout to none).
//  6. NO DORMANT STAT REACHES THE SCREEN. Five fold outputs have zero engine consumers and the
//     integer cargo_capacity is deprecated in favour of the m³ hold; none may appear.

// ── fixtures ──────────────────────────────────────────────────────────────────────────────────────
const NOW = Date.parse('2026-08-04T12:00:00.000Z')

const G1: GroupRow = { group_id: 'g1', group_index: 1, name: 'Fleet 1' }

const loc = (over: Partial<MapLocation> & Pick<MapLocation, 'id' | 'name' | 'x' | 'y'>): MapLocation => ({
  location_type: 'trade_outpost',
  base_difficulty: 1,
  reward_tier: 1,
  activity_type: 'trade_visit',
  min_power_required: 0,
  is_public: true,
  status: 'active',
  territory_radius: 50,
  ...over,
})
const HAVEN = loc({ id: 'haven', name: 'Haven', x: 0, y: 0 })
const SNARE = loc({ id: 'snare', name: 'Snare', x: 500, y: 500, activity_type: 'hunt_pirates', territory_radius: 40 })
const LOCS: MapLocation[] = [HAVEN, SNARE]

const member = (isCommand = true): ShipGroupMapEntry => ({
  group_id: G1.group_id,
  captain_slots: 2,
  is_command_ship: isCommand,
})

const pos = (over: Partial<FleetPosition> & Pick<FleetPosition, 'main_ship_id' | 'place'>): FleetPosition => ({
  name: 'Sparrow',
  class: 'starter_frigate',
  status: 'home',
  location_id: null,
  segment: null,
  space_x: null,
  space_y: null,
  ...over,
})

const fleetRow = (over: Partial<UnifiedGroupFleetLite> = {}): UnifiedGroupFleetLite => ({
  id: 'f1',
  group_id: G1.group_id,
  status: 'idle',
  location_mode: 'space',
  current_location_id: null,
  space_x: 500,
  space_y: 500,
  ...over,
})

/** A closed square ring — exactly the shape get_danger_zones returns. */
const ringAround = (cx: number, cy: number, half = 60): [number, number][] => [
  [cx - half, cy - half],
  [cx + half, cy - half],
  [cx + half, cy + half],
  [cx - half, cy + half],
  [cx - half, cy - half],
]
const SNARE_ZONE: DangerZoneLite = {
  id: 'z1',
  name: 'Snare',
  source: 'drawn',
  location_id: SNARE.id,
  ring: ringAround(SNARE.x, SNARE.y),
  revision: 1,
}

const mv = (over: Partial<FleetMovement> = {}): FleetMovement => ({
  id: 'm1',
  fleet_id: 'f1',
  group_id: G1.group_id,
  origin_type: 'space',
  origin_x: 0,
  origin_y: 0,
  target_type: 'space',
  target_location_id: null,
  target_base_id: null,
  target_x: 500,
  target_y: 500,
  mission_type: 'rally',
  status: 'moving',
  depart_at: new Date(NOW - 60_000).toISOString(),
  arrive_at: new Date(NOW + 128_000).toISOString(),
  travel_seconds: 188,
  travel_distance: 700,
  ...over,
})

const enc = (over: Partial<CombatEncounter> = {}): CombatEncounter =>
  ({
    id: 'e1',
    player_id: 'p1',
    fleet_id: 'f1',
    presence_id: 'pr1',
    location_id: SNARE.id,
    status: 'active',
    tick_number: 4,
    danger_level: 1,
    waves_cleared: 0,
    player_power_start: 10,
    player_power_current: 10,
    enemy_power_current: 100,
    player_integrity_max: 400,
    player_integrity_current: 300,
    enemy_integrity_max: 200,
    enemy_integrity_current: 150,
    wave_number: 1,
    next_wave_at: null,
    total_rewards_json: {},
    started_at: new Date(NOW - 30_000).toISOString(),
    retreat_started_at: null,
    ended_at: null,
    engagement_x: 500,
    engagement_y: 500,
    ...over,
  }) as CombatEncounter

const base = (over: Partial<FleetStatusModelInput> = {}): FleetStatusModelInput => ({
  groups: [G1],
  membership: { s1: member() },
  positions: [pos({ main_ship_id: 's1', place: 'docked', location_id: HAVEN.id })],
  locations: LOCS,
  movements: [],
  unifiedFleets: [],
  dangerZones: [],
  encounters: [],
  units: [],
  fleetControlEnabled: true,
  nowMs: NOW,
  ...over,
})

/** One input per presence state, so the table below can walk the whole closed set. */
function worldFor(state: FleetPresenceState): FleetStatusModelInput {
  switch (state) {
    case 'in-combat':
      return base({
        positions: [pos({ main_ship_id: 's1', place: 'in_space', space_x: 500, space_y: 500 })],
        unifiedFleets: [fleetRow()],
        encounters: [enc()],
      })
    case 'moving':
      return base({
        positions: [
          pos({
            main_ship_id: 's1',
            place: 'transit',
            segment: {
              origin_x: 0,
              origin_y: 0,
              target_x: 500,
              target_y: 500,
              target_kind: 'space',
              depart_at: new Date(NOW - 60_000).toISOString(),
              arrive_at: new Date(NOW + 128_000).toISOString(),
            },
          }),
        ],
        movements: [mv()],
      })
    case 'in-space':
      return base({
        positions: [pos({ main_ship_id: 's1', place: 'in_space', space_x: 500, space_y: 500 })],
        unifiedFleets: [fleetRow()],
      })
    case 'docked':
      return base()
    case 'unplaced':
      return base({ positions: [pos({ main_ship_id: 's1', place: 'hidden' })] })
  }
}

const only = (input: FleetStatusModelInput) => {
  const rows = buildFleetStatusModel(input).rows
  expect(rows).toHaveLength(1)
  return rows[0]
}

// ── 1 · EVERY STATE SAYS WHERE IT IS AND WHAT IT IS DOING ─────────────────────────────────────────

test('THE STATE SET IS CLOSED, and every member of it reaches the readout', () => {
  expect([...FLEET_PRESENCE_STATES].slice().sort()).toEqual(
    ['docked', 'in-combat', 'in-space', 'moving', 'unplaced'].sort(),
  )
  for (const state of FLEET_PRESENCE_STATES) {
    expect(only(worldFor(state)).state, `${state} must be reachable from its own world`).toBe(state)
  }
})

test('EVERY STATE HAS A WHERE AND A DOING — a state with nothing to say is a hole in the map', () => {
  for (const state of FLEET_PRESENCE_STATES) {
    const row = only(worldFor(state))
    expect(row.where.trim(), `${state} must say where the fleet is`).not.toBe('')
    expect(row.doing.trim(), `${state} must say what the fleet is doing`).not.toBe('')
    // The where-phrase is the presence module's, never re-worded here.
    expect(row.where, `${state} must compose fleetWhereText`).toBe(
      fleetWhereText(state, state === 'docked' ? 'Haven' : state === 'in-space' || state === 'in-combat' ? 'Snare' : null),
    )
  }
})

test('the phrases NAME THE PLACE the fleet is actually at, and never invent one', () => {
  expect(only(worldFor('docked')).where).toBe('Docked at Haven')
  expect(only(worldFor('in-space')).where).toBe('In orbit of Snare')
  expect(only(worldFor('in-combat')).where).toBe('In combat at Snare')
  // Nothing places a single member: the answer is "we don't know", never a coordinate.
  expect(only(worldFor('unplaced')).where).toBe('Location unknown')
  // Deep space has no territory — no place is named rather than the nearest one guessed.
  const deep = only(
    base({
      positions: [pos({ main_ship_id: 's1', place: 'in_space', space_x: 90_000, space_y: 90_000 })],
      unifiedFleets: [fleetRow({ space_x: 90_000, space_y: 90_000 })],
    }),
  )
  expect(deep.where).toBe('In open space')
})

test('AN IN-FLIGHT FLEET SAYS WHEN IT ARRIVES — the lead-leg ETA, not a guess', () => {
  // 128s out, formatted by the ONE duration helper.
  expect(only(worldFor('moving')).doing).toBe('Arriving in 2m 08s')
})

test('a leg whose clock has run out says it is travelling — it never invents a countdown', () => {
  const world = worldFor('moving')
  const row = only(base({ ...world, movements: [mv({ arrive_at: new Date(NOW - 1000).toISOString() })] }))
  expect(row.doing).toBe('Travelling')
})

test('a fight states its PHASE from the shared selector — never a private combat vocabulary', () => {
  expect(only(worldFor('in-combat')).doing).toBe('In combat')
  const retreating = only(
    base({ ...worldFor('in-combat'), encounters: [enc({ status: 'retreating' })] }),
  )
  expect(retreating.doing).toBe('Retreating')
  // The enemy side is wiped between waves — the phase says so instead of printing placeholder zeros.
  const between = only(base({ ...worldFor('in-combat'), encounters: [enc({ enemy_integrity_current: 0 })] }))
  expect(between.doing).toBe('Next wave incoming')
})

test('a fight running a course says the fleet is moving — and leaves the DISTANCE to the combat card', () => {
  const row = only(
    base({ ...worldFor('in-combat'), encounters: [enc({ reposition_x: 560, reposition_y: 500 })] }),
  )
  expect(row.doing).toBe('In combat — moving into position')
  expect(row.doing, 'the distance belongs to CombatMapCard, which is on this same screen').not.toMatch(/\d+\s*units/)
})

// ── 2/3 · WHY IT CANNOT ACT — the server's sentence, or silence ───────────────────────────────────

test('NO COMMAND SHIP IS NAMED AS THE REASON, in the SERVER’s own words, with the fix in them', () => {
  const row = only(base({ membership: { s1: member(false) } }))
  expect(row.blockedReason).toBe('fleet_inactive_no_command')
  const text = teamReasonMessage(row.blockedReason as string)
  expect(text, 'the player must be told what to do, not only what is wrong').toMatch(/Fleet tab/)
  expect(text).toMatch(/command ship/i)
})

test('the command-ship rule has ONE wording across the whole client — three copies were folded away', () => {
  const files = allSourceFiles()
  const authority = teamReasonMessage('fleet_inactive_no_command')
  // Nobody restates it. The map's hunt section and the roster used to carry their own phrasings of
  // the same refusal, and only one of the three named where the fix lives.
  const restaters = files.filter(
    (f) => f !== 'features/command/teamReasonMessage.ts' && codeOnly(src(f)).includes('has no command ship'),
  )
  expect(restaters, 'one rule, one sentence').toEqual([])
  expect(authority).toContain('has no command ship')
})

test('a fleet with a command ship is NOT accused of anything', () => {
  expect(only(base()).blockedReason).toBeNull()
})

test('an EMPTY fleet is named as empty — a different fact from an inactive one', () => {
  expect(only(base({ membership: {} })).blockedReason).toBe('empty_group')
})

test('THE CLIENT DOES NOT GUESS: with the gate dark, no fleet is ever called inactive', () => {
  // fleet_control_enabled dark → 0204's control model says every fleet is active, so claiming
  // otherwise would be the client inventing a refusal the server would not make.
  expect(only(base({ membership: { s1: member(false) }, fleetControlEnabled: false })).blockedReason).toBeNull()
})

test('THE CLIENT DOES NOT GUESS: the causes it cannot see leave the line empty', () => {
  // A wrecked ship, a partial dock and a fleet split across ports all come back as ONE
  // `member_not_ready`, and the map shell polls no hp at all. The readout says nothing about them
  // rather than picking one — the attempt gets the server's answer, which is where it belongs.
  const scattered = only(
    base({
      membership: { s1: member(), s2: { ...member(false), group_id: G1.group_id } },
      positions: [
        pos({ main_ship_id: 's1', place: 'docked', location_id: HAVEN.id }),
        pos({ main_ship_id: 's2', place: 'docked', location_id: SNARE.id }),
      ],
    }),
  )
  expect(scattered.blockedReason).toBeNull()
  const code = codeOnly(src('features/map/fleetStatusModel.ts'))
  expect(code, 'the readout must not mirror a reject it cannot see the inputs for').not.toContain('member_not_ready')
  expect(code).not.toContain('no_living_ships')
  expect(code).not.toContain('group_scattered')
})

test('every reason the readout can emit is a REAL server code with real copy — never prose, never a raw code', () => {
  for (const world of [base({ membership: {} }), base({ membership: { s1: member(false) } })]) {
    const reason = only(world).blockedReason as string
    expect(reason).toMatch(/^[a-z_]+$/) // a code, not a sentence
    expect(teamReasonMessage(reason)).not.toBe('Fleet order unavailable.') // …with copy behind it
  }
})

// ── 4/5 · ONE ACTION SLOT, ONE HUNT PATH ─────────────────────────────────────────────────────────

test('A FLEET STANDING IN THE ZONE IS OFFERED THE SITE — the answer to "i am in snare but no fight"', () => {
  const row = only(base({ unifiedFleets: [fleetRow()], dangerZones: [SNARE_ZONE], positions: [pos({ main_ship_id: 's1', place: 'in_space', space_x: 500, space_y: 500 })] }))
  expect(row.action).toEqual({
    kind: 'hunt',
    locationId: SNARE.id,
    siteName: 'Snare',
    // The words are the hunt-copy authority's, never a second wording.
    label: huntSiteActionLabel('Snare'),
  })
})

test('the offer is the ONE standing-hunt derivation — the readout does not re-decide containment', () => {
  const input = base({
    unifiedFleets: [fleetRow()],
    dangerZones: [SNARE_ZONE],
    positions: [pos({ main_ship_id: 's1', place: 'in_space', space_x: 500, space_y: 500 })],
  })
  const shared = resolveFleetStandingHunts({
    groups: input.groups,
    unifiedFleets: input.unifiedFleets,
    dangerZones: input.dangerZones,
    locations: input.locations,
  })
  expect(only(input).action).toMatchObject({ locationId: shared[0].locationId, label: shared[0].label })
  // …and the geometry lives there, not here.
  const code = codeOnly(src('features/map/fleetStatusModel.ts'))
  expect(code).not.toContain('zoneAtPoint')
  expect(code).not.toContain('zoneHuntSite')
})

test('a zone with NO huntable site offers nothing at all — a zone is not a target', () => {
  const loose: DangerZoneLite = { ...SNARE_ZONE, id: 'z2', location_id: null }
  const row = only(
    base({
      unifiedFleets: [fleetRow()],
      dangerZones: [loose],
      positions: [pos({ main_ship_id: 's1', place: 'in_space', space_x: 500, space_y: 500 })],
    }),
  )
  expect(row.action).toBeNull()
})

test('FIGHTING OUTRANKS STANDING ON A FIGHT — the way out is never displaced by a way in', () => {
  const row = only(
    base({
      unifiedFleets: [fleetRow()],
      dangerZones: [SNARE_ZONE],
      positions: [pos({ main_ship_id: 's1', place: 'in_space', space_x: 500, space_y: 500 })],
      encounters: [enc()],
    }),
  )
  expect(row.action).toEqual({ kind: 'retreat', encounterId: 'e1', presenceId: 'pr1', retreating: false })
})

test('a retreating fight still offers the control, marked as already ordered', () => {
  const row = only(base({ ...worldFor('in-combat'), encounters: [enc({ status: 'retreating' })] }))
  expect(row.action).toEqual({ kind: 'retreat', encounterId: 'e1', presenceId: 'pr1', retreating: true })
})

test('THE READOUT SUBMITS NOTHING — no second path to the hunt RPC, and no second retreat', () => {
  const model = src('features/map/fleetStatusModel.ts')
  const panel = src('features/map/FleetStatusPanel.tsx')
  for (const [name, text] of [['the model', model], ['the panel', panel]] as const) {
    expect(codeOnly(text), `${name} must not call the hunt RPC`).not.toContain('sendShipGroupHunt')
    expect(codeOnly(text), `${name} must not call the retreat RPC`).not.toContain('requestRetreat')
  }
  // The retreat verb is the ONE component, mounted — never re-implemented.
  expect(panel).toContain('<RetreatControl')
  // The hunt is reached by SELECTING the site, exactly as tapping its marker does.
  expect(codeOnly(panel)).toContain('onSelectHuntSite')
})

// ── 6 · NO DORMANT STAT, NO DEPRECATED CARGO ─────────────────────────────────────────────────────

test('NO DORMANT STAT REACHES THE SCREEN — five fold outputs with zero engine consumers', () => {
  // Owner ruling on the 2026-08-04 stat audit: "The client must not describe it as effective."
  const dormant = ['evasion', 'retreat_safety', 'scouting', 'mining_yield', 'pirate_attention']
  const surfaces = ['features/map/fleetStatusModel.ts', 'features/map/FleetStatusPanel.tsx']
  for (const f of surfaces) {
    const code = codeOnly(src(f))
    for (const key of dormant) {
      expect(code, `${f} must not render the dormant stat ${key}`).not.toContain(key)
    }
  }
  // …and nothing labelled with them reaches a row either.
  for (const state of FLEET_PRESENCE_STATES) {
    for (const stat of only(worldFor(state)).stats) {
      expect(dormant.some((k) => stat.label.toLowerCase().includes(k.replace('_', ' ')))).toBe(false)
    }
  }
})

test('NO CARGO NUMBER AT ALL — the integer is deprecated and the m³ fleet authority is not polled here', () => {
  // FittingDetail renders the meaningless integer 353 lines above the real m³ hold; that mistake is
  // not repeated on the map. Fitting a cargo module raises the integer and expands no hold, and the
  // only FLEET-scope m³ authority (get_my_hold, 0333) is not among the map shell's reads — summing
  // the per-ship m³ here would be a client fold beside a server authority.
  for (const f of ['features/map/fleetStatusModel.ts', 'features/map/FleetStatusPanel.tsx']) {
    const code = codeOnly(src(f))
    expect(code).not.toContain('cargo_capacity')
    expect(code).not.toContain('cargo')
  }
  for (const state of FLEET_PRESENCE_STATES) {
    for (const stat of only(worldFor(state)).stats) {
      expect(stat.label.toLowerCase()).not.toContain('cargo')
    }
  }
})

test('NO TENTH DEFINITION OF POWER OR FLEET SPEED — nothing here is folded client-side', () => {
  for (const f of ['features/map/fleetStatusModel.ts', 'features/map/FleetStatusPanel.tsx']) {
    const code = codeOnly(src(f))
    expect(code).not.toContain('combat_power')
    expect(code).not.toContain('aggregateTeamStats')
    expect(code).not.toContain('teamSkillset')
  }
})

test('the stats that DO render are counts of server rows, and each has a real consumer', () => {
  // Ships: the server's own place projection, with the partial-placement count that the Fleet 1 bug
  // was invisible without.
  expect(only(base()).stats).toEqual([{ label: 'Ships', value: '1' }, { label: 'Command ship', value: '1' }])
  const partial = only(
    base({
      membership: { s1: member(), s2: { ...member(false), group_id: G1.group_id } },
      positions: [pos({ main_ship_id: 's1', place: 'docked', location_id: HAVEN.id }), pos({ main_ship_id: 's2', place: 'hidden' })],
    }),
  )
  expect(partial.stats[0]).toEqual({ label: 'Ships', value: '1 of 2' })
  // Command ship is shown only while 0204's gate is lit — dark, the count decides nothing.
  expect(only(base({ fleetControlEnabled: false })).stats).toEqual([{ label: 'Ships', value: '1' }])
  // …and a fleet WITHOUT one gets the refusal line instead of a bare zero.
  const none = only(base({ membership: { s1: member(false) } }))
  expect(none.stats.map((s) => s.label)).toEqual(['Ships'])
  expect(none.blockedReason).toBe('fleet_inactive_no_command')
})

// ── 6b · ██ WHAT THE FLEET IS MADE OF AND WHAT IT SHOOTS WITH — ONLY WHILE IT IS FIGHTING ██ ──────
// Owner, playing 2026-08-09: *"the fleets tab on map does not show range, its moving speed, hull,
// shield, shield generation"* and *"the fleets tab should also show attacking power, what weapon
// system it is using"*. Every one of these is frozen onto combat_units at spawn and read through the
// ONE leaf; the leaf's own spec owns the arithmetic, these own what the READOUT does with it.

/** The owner's real production fight, in miniature: two hulls, one `basic_player_weapon` each. */
const fightingUnits = (over: Partial<CombatUnit> = {}): CombatUnit[] =>
  [1, 2].map(
    (i) =>
      ({
        id: `cu-${i}`,
        encounter_id: 'e1',
        unit_type_id: null,
        main_ship_id: `msi-${i}`,
        side: 'player',
        ship_hp: 500,
        initial_count: 1,
        alive_count: 1,
        hp_max: 500,
        hp_current: i === 1 ? 473 : 33,
        move_speed: 0.2,
        pos_x: 500,
        pos_y: 500,
        weapons_json: [{ module_type_id: 'basic_player_weapon', power: 15, range: 5 }],
        ...over,
      }) as CombatUnit,
  )

const fightingWorld = (over: Partial<FleetStatusModelInput> = {}): FleetStatusModelInput =>
  base({ ...worldFor('in-combat'), units: fightingUnits(), combatTickSeconds: 3, ...over })

test('A FIGHTING FLEET STATES ITS STANDING AND ITS ARMAMENT, in the order the question is asked', () => {
  const row = only(fightingWorld())
  expect(row.stats).toEqual([
    { label: 'Ships', value: '1' },
    { label: 'Command ship', value: '1' },
    // what is left of me…
    { label: 'Hull', value: '506 / 1000' },
    // …then what I hit with…
    { label: 'Attack', value: '30 / round' },
    { label: 'Weapons', value: 'Basic Player Weapon ×2' },
    { label: 'Range', value: '5 units' },
    { label: 'Fires', value: 'every round · 3s' },
    // …then how I move.
    { label: 'Speed in battle', value: '0.2 units/round' },
  ])
})

test('OFF THE FIELD THERE ARE NO FIGHT STATS AT ALL — a stale copy would be a number with no source', () => {
  // The rows only exist while a fight is running; nothing here caches them.
  for (const state of FLEET_PRESENCE_STATES) {
    if (state === 'in-combat') continue
    const labels = only(
      base({ ...worldFor(state), units: fightingUnits(), combatTickSeconds: 3 }),
    ).stats.map((s) => s.label)
    for (const banned of ['Hull', 'Attack', 'Weapons', 'Range', 'Fires', 'Speed in battle']) {
      expect(labels, `${state} must not carry ${banned}`).not.toContain(banned)
    }
  }
})

test('██ SHIELDS ARE SILENT WHILE THE GAME HAS NONE — no 0/0 line, no zero regen ██', () => {
  // MEASURED ON PRODUCTION 2026-08-09: 0 of 327 combat_units rows carry a pool, 0 of 77 ships have
  // max_shield > 0, 0 of 3 hulls have base_shield > 0, and game_config.shield_regen_combat_pct is 0.
  // 0191 pairs the columns by CHECK and a shieldless hull carries NULL/NULL — never 0/0 — precisely
  // so "no shield machinery" stays distinguishable from "shield down". A bar that can never move and
  // a mechanic that does not run must not appear, exactly like the dormant fold stats above.
  const labels = only(fightingWorld({ shieldRegenCombatPct: 0.02 })).stats.map((s) => s.label)
  expect(labels).not.toContain('Shield')
  expect(labels).not.toContain('Shield regen')
})

test('…AND THEY APPEAR BY THEMSELVES ONCE A POOL EXISTS — the silence is the DATA, never a missing feature', () => {
  // The same fight after scripts/activate-shield.sql: pools on the hulls and the combat regen knob
  // positive. Without this, "shields are silent" and "shields were never built" look identical.
  const lit = only(
    fightingWorld({
      units: fightingUnits({ shield_current: 60, shield_max: 100 }),
      shieldRegenCombatPct: 0.02,
    }),
  )
  const byLabel = Object.fromEntries(lit.stats.map((s) => [s.label, s.value]))
  expect(byLabel['Shield']).toBe('120 / 200')
  expect(byLabel['Shield regen']).toBe('4 / round')
  // …and a pool with the knob still dark states the pool and stays silent about generation: two
  // different facts, two independent silences.
  const poolOnly = only(fightingWorld({ units: fightingUnits({ shield_current: 60, shield_max: 100 }) }))
  expect(poolOnly.stats.map((s) => s.label)).toContain('Shield')
  expect(poolOnly.stats.map((s) => s.label)).not.toContain('Shield regen')
})

test('THE WORDS ARE THE OWNER’S — never "Reach", never a bare "Speed" that could mean travel', () => {
  const labels = only(fightingWorld()).stats.map((s) => s.label)
  expect(labels).toContain('Range')
  expect(labels).not.toContain('Reach')
  expect(labels).toContain('Speed in battle')
  expect(labels, 'a bare "Speed" would read as the map-travel speed, a different quantity').not.toContain('Speed')
})

// ── the shape of the whole thing ─────────────────────────────────────────────────────────────────

test('no fleets → NOTHING. A clean map is the default (map-UX law #1)', () => {
  expect(buildFleetStatusModel(base({ groups: [] })).rows).toEqual([])
})

test('EXISTENCE IS UNCONDITIONAL — every owned fleet gets exactly one row, in every state', () => {
  const G2: GroupRow = { group_id: 'g2', group_index: 2, name: 'Fleet 2' }
  const rows = buildFleetStatusModel(
    base({
      groups: [G1, G2],
      membership: { s1: member(), s2: { group_id: 'g2', captain_slots: 2, is_command_ship: false } },
      positions: [pos({ main_ship_id: 's1', place: 'docked', location_id: HAVEN.id }), pos({ main_ship_id: 's2', place: 'hidden' })],
    }),
  ).rows
  expect(rows.map((r) => r.groupId)).toEqual(['g1', 'g2'])
  expect(rows.map((r) => r.name)).toEqual(['Fleet 1', 'Fleet 2'])
})

// ── local scaffolding (the repositionOnMap.spec.ts idiom, deliberately not a shared import) ───────

const here = dirname(fileURLToPath(import.meta.url))
const srcRoot = join(here, '..', 'src')
function src(rel: string): string {
  return readFileSync(join(srcRoot, rel), 'utf8')
}
function allSourceFiles(dir: string = srcRoot): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...allSourceFiles(full))
    else if (/\.tsx?$/.test(entry.name)) out.push(relative(srcRoot, full).split(sep).join('/'))
  }
  return out
}
/** Source with comment lines stripped — an assertion about what a surface RENDERS must not be
 *  satisfied by the paragraph explaining why it renders it. */
function codeOnly(text: string): string {
  return text
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .split(/\r?\n/)
    .filter((l) => !/^\s*(\/\/|\*)/.test(l))
    .join('\n')
}
