import { test, expect } from '@playwright/test'
import {
  roomPickerOptions,
  roomSlotBoard,
  type ShipRoomSlot,
  type ShipStation,
} from '../src/features/captains/deckStations'
import type { CaptainInstance } from '../src/features/captains/captainsTypes'

// ROOMS-8 — pure-logic specs for the configurable room-slot helpers (no app/Supabase — the
// deckStations.spec mold). Display-side derivation only: the 0203 server (the ship_room_slots
// distinct-room unique, configure_ship_room's rejects, the slot-scoped captain_assign_apply) stays
// the enforcer; these helpers must merely agree with it deterministically.

const room = (over: Partial<ShipStation> & { station_id: string; sort: number }): ShipStation => ({
  name: over.station_id[0].toUpperCase() + over.station_id.slice(1),
  affinity_specialization: null,
  ...over,
})

// a shuffled catalog superset (12 rooms) — helpers must never rely on input order.
const CATALOG: ShipStation[] = [
  room({ station_id: 'armory', sort: 8, affinity_specialization: 'combat' }),
  room({ station_id: 'bridge', sort: 1 }),
  room({ station_id: 'command_deck', sort: 7 }),
  room({ station_id: 'gunnery', sort: 2, affinity_specialization: 'combat' }),
  room({ station_id: 'medbay', sort: 6, affinity_specialization: 'support' }),
  room({ station_id: 'engineering', sort: 3, affinity_specialization: 'mining' }),
  room({ station_id: 'logistics', sort: 4, affinity_specialization: 'trade' }),
  room({ station_id: 'sensors', sort: 5, affinity_specialization: 'exploration' }),
  room({ station_id: 'cargo_hold', sort: 9, affinity_specialization: 'trade' }),
  room({ station_id: 'workshop', sort: 10, affinity_specialization: 'support' }),
  room({ station_id: 'comms', sort: 11, affinity_specialization: 'exploration' }),
  room({ station_id: 'observatory', sort: 14, affinity_specialization: 'exploration' }),
]

// the 8 default slots (the 8 lowest-sort rooms), deliberately shuffled by slot_index.
const SLOTS: ShipRoomSlot[] = [
  { slot_index: 3, room_type_id: 'engineering', name: 'Engineering', affinity_specialization: 'mining' },
  { slot_index: 1, room_type_id: 'bridge', name: 'Bridge', affinity_specialization: null },
  { slot_index: 8, room_type_id: 'armory', name: 'Armory', affinity_specialization: 'combat' },
  { slot_index: 2, room_type_id: 'gunnery', name: 'Gunnery', affinity_specialization: 'combat' },
  { slot_index: 5, room_type_id: 'sensors', name: 'Sensors', affinity_specialization: 'exploration' },
  { slot_index: 4, room_type_id: 'logistics', name: 'Logistics', affinity_specialization: 'trade' },
  { slot_index: 7, room_type_id: 'command_deck', name: 'Command Deck', affinity_specialization: null },
  { slot_index: 6, room_type_id: 'medbay', name: 'Medbay', affinity_specialization: 'support' },
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

test.describe('roomSlotBoard', () => {
  test('empty roster → eight rows in slot_index order, every one an empty room', () => {
    const board = roomSlotBoard(SLOTS, [])
    expect(board.rows).toHaveLength(8)
    expect(board.rows.map((r) => r.slot.slot_index)).toEqual([1, 2, 3, 4, 5, 6, 7, 8])
    expect(board.rows.map((r) => r.slot.room_type_id)).toEqual([
      'bridge',
      'gunnery',
      'engineering',
      'logistics',
      'sensors',
      'medbay',
      'command_deck',
      'armory',
    ])
    expect(board.rows.every((r) => r.captain === null)).toBe(true)
    expect(board.unstationed).toEqual([])
  })

  test('captains land on the slot whose room they staff; the rest stay empty', () => {
    const gunner = captain({ instance_id: 'ci-1', station: 'gunnery' })
    const medic = captain({ instance_id: 'ci-2', station: 'medbay', specialization: 'support' })
    const board = roomSlotBoard(SLOTS, [gunner, medic])
    const byRoom = new Map(board.rows.map((r) => [r.slot.room_type_id, r.captain]))
    expect(byRoom.get('gunnery')).toEqual(gunner)
    expect(byRoom.get('medbay')).toEqual(medic)
    expect(byRoom.get('bridge')).toBeNull()
    expect(board.unstationed).toEqual([])
  })

  test('null-station and rooms-not-fitted-on-this-ship captains go to unstationed, input order kept', () => {
    const gq = captain({ instance_id: 'ci-1', station: null })
    const legacy = captain({ instance_id: 'ci-2' }) // station absent (pre-0189 envelope)
    const nofit = captain({ instance_id: 'ci-3', station: 'observatory' }) // a real room, not a fitted slot
    const board = roomSlotBoard(SLOTS, [gq, legacy, nofit])
    expect(board.rows.every((r) => r.captain === null)).toBe(true)
    expect(board.unstationed.map((c) => c.instance_id)).toEqual(['ci-1', 'ci-2', 'ci-3'])
  })

  test('a duplicate holder (server-impossible; defensive) resolves to the lowest instance_id', () => {
    const late = captain({ instance_id: 'ci-9', station: 'bridge' })
    const early = captain({ instance_id: 'ci-1', station: 'bridge' })
    for (const input of [
      [late, early],
      [early, late],
    ]) {
      const board = roomSlotBoard(SLOTS, input)
      const bridgeRow = board.rows.find((r) => r.slot.room_type_id === 'bridge')
      expect(bridgeRow?.captain?.instance_id).toBe('ci-1')
      expect(board.unstationed.map((c) => c.instance_id)).toEqual(['ci-9'])
    }
  })
})

test.describe('roomPickerOptions', () => {
  test('offers every catalog room except those fitted in OTHER slots, in catalog order', () => {
    // for slot 1 (bridge): every OTHER slot room is excluded; bridge itself stays selectable.
    const opts = roomPickerOptions(CATALOG, SLOTS, 1).map((r) => r.station_id)
    // excluded: gunnery, engineering, logistics, sensors, medbay, command_deck, armory (the other 7 slots)
    expect(opts).toEqual(['bridge', 'cargo_hold', 'workshop', 'comms', 'observatory'])
  })

  test('the slot being edited keeps its own current room in the options (the select value)', () => {
    // for slot 8 (armory): armory itself stays; the other 7 slot rooms are excluded.
    const opts = roomPickerOptions(CATALOG, SLOTS, 8).map((r) => r.station_id)
    expect(opts).toContain('armory')
    expect(opts).not.toContain('gunnery')
    // the not-fitted-anywhere rooms are all offered.
    expect(opts).toEqual(expect.arrayContaining(['cargo_hold', 'workshop', 'comms', 'observatory']))
  })

  test('does not mutate its inputs', () => {
    const catalogCopy = [...CATALOG]
    const slotsCopy = [...SLOTS]
    roomPickerOptions(CATALOG, SLOTS, 1)
    expect(CATALOG).toEqual(catalogCopy)
    expect(SLOTS).toEqual(slotsCopy)
  })
})
