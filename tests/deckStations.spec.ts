import { test, expect } from '@playwright/test'
import {
  AUTO_STATION,
  deckBoard,
  freeStations,
  orderStations,
  stationForCommand,
  stationLabel,
  type ShipStation,
} from '../src/features/captains/deckStations'
import type { CaptainInstance } from '../src/features/captains/captainsTypes'

// DECKS-2 — pure-logic specs for the decks-board helpers (no app/Supabase — the shipDossier.spec
// mold). Display-side derivation only: the 0189 server (catalog, partial unique, the writer's
// unknown_station/station_occupied rejects, the lowest-sort auto-assign) stays the enforcer;
// these helpers must merely agree with it deterministically.

const station = (over: Partial<ShipStation> & { station_id: string; sort: number }): ShipStation => ({
  name: over.station_id[0].toUpperCase() + over.station_id.slice(1),
  affinity_specialization: null,
  ...over,
})

// the six 0189 seeds, deliberately shuffled — helpers must never rely on input order.
const CATALOG: ShipStation[] = [
  station({ station_id: 'medbay', sort: 6, affinity_specialization: 'support' }),
  station({ station_id: 'bridge', sort: 1 }),
  station({ station_id: 'sensors', sort: 5, affinity_specialization: 'exploration' }),
  station({ station_id: 'gunnery', sort: 2, affinity_specialization: 'combat' }),
  station({ station_id: 'logistics', sort: 4, affinity_specialization: 'trade' }),
  station({ station_id: 'engineering', sort: 3, affinity_specialization: 'mining' }),
]

const captain = (over: Partial<CaptainInstance> & { instance_id: string }): CaptainInstance => ({
  captain_type_id: 'gunnery_veteran',
  name: 'Rhee',
  specialization: 'combat',
  stats_json: {},
  main_ship_id: 'ship-a',
  station: null,
  created_at: '2026-07-01T00:00:00Z',
  ...over,
})

test.describe('orderStations', () => {
  test('sorts by sort ascending regardless of input order, without mutating the input', () => {
    const input = [...CATALOG]
    const ordered = orderStations(input)
    expect(ordered.map((s) => s.station_id)).toEqual([
      'bridge',
      'gunnery',
      'engineering',
      'logistics',
      'sensors',
      'medbay',
    ])
    expect(input).toEqual(CATALOG) // no in-place sort
  })

  test('breaks a (malformed) sort tie by station_id — still a total order', () => {
    const tied = [station({ station_id: 'zeta', sort: 1 }), station({ station_id: 'alpha', sort: 1 })]
    expect(orderStations(tied).map((s) => s.station_id)).toEqual(['alpha', 'zeta'])
  })
})

test.describe('deckBoard', () => {
  test('empty roster → six rows in catalog order, every one an empty slot', () => {
    const board = deckBoard(CATALOG, [])
    expect(board.rows).toHaveLength(6)
    expect(board.rows.map((r) => r.station.station_id)).toEqual([
      'bridge',
      'gunnery',
      'engineering',
      'logistics',
      'sensors',
      'medbay',
    ])
    expect(board.rows.every((r) => r.captain === null)).toBe(true)
    expect(board.unstationed).toEqual([])
  })

  test('stationed captains land on their stations; the rest stay empty', () => {
    const gunner = captain({ instance_id: 'ci-1', station: 'gunnery' })
    const medic = captain({ instance_id: 'ci-2', station: 'medbay', specialization: 'support' })
    const board = deckBoard(CATALOG, [gunner, medic])
    const byId = new Map(board.rows.map((r) => [r.station.station_id, r.captain]))
    expect(byId.get('gunnery')).toEqual(gunner)
    expect(byId.get('medbay')).toEqual(medic)
    expect(byId.get('bridge')).toBeNull()
    expect(board.unstationed).toEqual([])
  })

  test('null-station (general quarters) and unknown-station captains go to unstationed, input order kept', () => {
    const gq = captain({ instance_id: 'ci-1', station: null })
    const legacy = captain({ instance_id: 'ci-2' }) // station absent (pre-0189 envelope)
    const ghost = captain({ instance_id: 'ci-3', station: 'helm' }) // not in the catalog
    const board = deckBoard(CATALOG, [gq, legacy, ghost])
    expect(board.rows.every((r) => r.captain === null)).toBe(true)
    expect(board.unstationed.map((c) => c.instance_id)).toEqual(['ci-1', 'ci-2', 'ci-3'])
  })

  test('a duplicate holder (server-impossible; defensive) resolves deterministically to the lowest instance_id', () => {
    const late = captain({ instance_id: 'ci-9', station: 'bridge' })
    const early = captain({ instance_id: 'ci-1', station: 'bridge' })
    // same result regardless of input order — the derivation is order-independent.
    for (const input of [
      [late, early],
      [early, late],
    ]) {
      const board = deckBoard(CATALOG, input)
      expect(board.rows[0].captain?.instance_id).toBe('ci-1')
      expect(board.unstationed.map((c) => c.instance_id)).toEqual(['ci-9'])
    }
  })
})

test.describe('freeStations', () => {
  test('full catalog free on an empty roster, in catalog order', () => {
    expect(freeStations(CATALOG, []).map((s) => s.station_id)).toEqual([
      'bridge',
      'gunnery',
      'engineering',
      'logistics',
      'sensors',
      'medbay',
    ])
  })

  test('held stations drop out; general-quarters captains hold nothing', () => {
    const free = freeStations(CATALOG, [
      captain({ instance_id: 'ci-1', station: 'bridge' }),
      captain({ instance_id: 'ci-2', station: 'sensors' }),
      captain({ instance_id: 'ci-3', station: null }),
    ])
    expect(free.map((s) => s.station_id)).toEqual(['gunnery', 'engineering', 'logistics', 'medbay'])
  })

  test('all six held → nothing free (the server-side captain_slots_full world)', () => {
    const all = CATALOG.map((s, i) => captain({ instance_id: `ci-${i}`, station: s.station_id }))
    expect(freeStations(CATALOG, all)).toEqual([])
  })
})

test.describe('stationForCommand', () => {
  test('the AUTO sentinel → null (server auto-assign)', () => {
    expect(stationForCommand(AUTO_STATION)).toBeNull()
  })

  test('any non-AUTO pick passes through VERBATIM — a stale pick is never silently substituted', () => {
    // The server is the honest authority: a meanwhile-taken pick answers station_occupied, an
    // unknown one answers unknown_station (both mapped to player copy). Collapsing here would
    // land the captain on a DIFFERENT station than the one the player named.
    expect(stationForCommand('gunnery')).toBe('gunnery')
    expect(stationForCommand('helm')).toBe('helm')
  })
})

test.describe('stationLabel', () => {
  test('a catalog id → its display name (the success-note source)', () => {
    expect(stationLabel(CATALOG, 'gunnery')).toBe('Gunnery')
    expect(stationLabel(CATALOG, 'medbay')).toBe('Medbay')
  })

  test('an unknown id falls back to the raw id — never an empty label', () => {
    expect(stationLabel(CATALOG, 'helm')).toBe('helm')
    expect(stationLabel([], 'gunnery')).toBe('gunnery')
  })
})
