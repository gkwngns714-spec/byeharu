import type { CaptainInstance } from './captainsTypes'

// DECKS-2 — PURE helpers for the ship decks board (no React/DOM/fetch — the shipDossierView.ts /
// teamCaptains.ts mold). The server (0189) is the ONE authority on station placement — the
// ship_stations catalog, the (main_ship_id, station) partial unique, and captain_assign_apply's
// unknown_station/station_occupied rejects; these helpers are display-side derivation only:
// station ordering, the free-station set for the assign picker, and the six-row board view-model.
// Specs: tests/deckStations.spec.ts.

/** One row of the public-read ship_stations catalog (0189 — the six deck stations).
 *  affinity_specialization is INERT display data this slice (DECKS-3 owns the bonus). */
export interface ShipStation {
  station_id: string
  name: string
  sort: number
  affinity_specialization: string | null
}

/** The picker's "let the server pick" sentinel — NOT a station id (the server auto-assigns the
 *  lowest-sort free station when the command carries no station). */
export const AUTO_STATION = 'auto'

/** Catalog order: sort ascending (the server's auto-assign walk), station_id as the total-order
 *  tiebreak (the catalog's sort is UNIQUE server-side; the tiebreak only guards a malformed read). */
export function orderStations(stations: ShipStation[]): ShipStation[] {
  return [...stations].sort((a, b) => a.sort - b.sort || a.station_id.localeCompare(b.station_id))
}

/** One board row: a station and whoever holds it (null = "Empty station"). */
export interface DeckBoardRow {
  station: ShipStation
  captain: CaptainInstance | null
}

/** The decks board view-model over ONE ship's captains (pre-filtered — captainsForShip). Every
 *  catalog station appears exactly once, in catalog order. A captain whose station is null
 *  (general quarters), unknown to the catalog, or a duplicate holder (the server's partial unique
 *  makes both impossible — defensive) lands in `unstationed`, input order preserved; the
 *  deterministic duplicate winner is the lexically-lowest instance_id. */
export function deckBoard(
  stations: ShipStation[],
  shipCaptains: CaptainInstance[],
): { rows: DeckBoardRow[]; unstationed: CaptainInstance[] } {
  const ordered = orderStations(stations)
  const byStation = new Map<string, CaptainInstance>()
  const unstationed: CaptainInstance[] = []
  const known = new Set(ordered.map((s) => s.station_id))
  for (const c of shipCaptains) {
    const st = c.station ?? null
    if (st === null || !known.has(st)) {
      unstationed.push(c)
      continue
    }
    const holder = byStation.get(st)
    if (!holder) {
      byStation.set(st, c)
    } else if (c.instance_id < holder.instance_id) {
      byStation.set(st, c)
      unstationed.push(holder)
    } else {
      unstationed.push(c)
    }
  }
  return {
    rows: ordered.map((station) => ({ station, captain: byStation.get(station.station_id) ?? null })),
    unstationed,
  }
}

/** The stations of ONE ship with no holder, catalog order — the assign picker's option set.
 *  Display-side only: the server's station_occupied reject stays the enforcer. */
export function freeStations(stations: ShipStation[], shipCaptains: CaptainInstance[]): ShipStation[] {
  const held = new Set<string>()
  for (const c of shipCaptains) {
    if (c.station != null) held.add(c.station)
  }
  return orderStations(stations).filter((s) => !held.has(s.station_id))
}

/** Picker value → the command's station argument: the AUTO sentinel means null = server
 *  auto-assign; ANY other pick is sent VERBATIM — never silently substituted. A stale pick of a
 *  meanwhile-taken (or meanwhile-unknown) station gets the server's honest station_occupied /
 *  unknown_station answer — both already mapped to player copy — instead of quietly landing the
 *  captain somewhere else. */
export function stationForCommand(pick: string): string | null {
  return pick === AUTO_STATION ? null : pick
}

/** Display name for a station id (the success-note / board label source); an id the catalog
 *  doesn't know (defensive — the server names only catalog stations) falls back to the raw id,
 *  never an empty label. */
export function stationLabel(stations: ShipStation[], stationId: string): string {
  return stations.find((s) => s.station_id === stationId)?.name ?? stationId
}

// ── ROOMS-8 (0203): the CONFIGURABLE room-slot board ──────────────────────────────────────────────
// A ship now has 8 configurable room-slots (ship_room_slots, 0203): the player CHOOSES which room
// type occupies each slot, and captains staff the rooms. The board is driven by the SHIP'S slots
// (get_my_ship_room_slots), not the whole catalog — a captain's station is the slot's room_type_id
// (so the 0196 adapter reads its affinity unchanged). These helpers are display-side derivation
// only; the 0203 server (the distinct-room unique, configure_ship_room's rejects, the slot-scoped
// captain_assign_apply) stays the enforcer.

/** One configured room-slot of a ship (get_my_ship_room_slots, 0203). affinity_specialization is
 *  the fitted room's favored specialization (0117 vocabulary or null) — the 0196 adapter fold input. */
export interface ShipRoomSlot {
  slot_index: number
  room_type_id: string
  name: string
  affinity_specialization: string | null
}

/** One room-slot board row: a slot (its fitted room) and whoever staffs it (null = "Empty room"). */
export interface RoomSlotBoardRow {
  slot: ShipRoomSlot
  captain: CaptainInstance | null
}

/** The room-slot board over ONE ship's configured slots (get_my_ship_room_slots) + that ship's
 *  captains (pre-filtered — captainsForShip). Every slot appears exactly once, in slot_index order;
 *  the captain whose station equals the slot's room_type_id staffs it. A captain whose station is
 *  null (general quarters), unknown to the ship's slots, or a duplicate holder (the server's uniques
 *  make both impossible — defensive) lands in `unstationed`, input order preserved; the
 *  deterministic duplicate winner is the lexically-lowest instance_id (the deckBoard idiom). */
export function roomSlotBoard(
  slots: ShipRoomSlot[],
  shipCaptains: CaptainInstance[],
): { rows: RoomSlotBoardRow[]; unstationed: CaptainInstance[] } {
  const ordered = [...slots].sort((a, b) => a.slot_index - b.slot_index)
  const byRoom = new Map<string, CaptainInstance>()
  const unstationed: CaptainInstance[] = []
  const fittedRooms = new Set(ordered.map((s) => s.room_type_id))
  for (const c of shipCaptains) {
    const st = c.station ?? null
    if (st === null || !fittedRooms.has(st)) {
      unstationed.push(c)
      continue
    }
    const holder = byRoom.get(st)
    if (!holder) {
      byRoom.set(st, c)
    } else if (c.instance_id < holder.instance_id) {
      byRoom.set(st, c)
      unstationed.push(holder)
    } else {
      unstationed.push(c)
    }
  }
  return {
    rows: ordered.map((slot) => ({ slot, captain: byRoom.get(slot.room_type_id) ?? null })),
    unstationed,
  }
}

/** The picker options for ONE slot: every catalog room EXCEPT rooms already fitted in ANOTHER slot
 *  on this ship (a room fills at most one slot — the server's room_duplicate reject). The slot's OWN
 *  current room stays selectable (it is the select's current value). Catalog order. */
export function roomPickerOptions(
  catalog: ShipStation[],
  slots: ShipRoomSlot[],
  slotIndex: number,
): ShipStation[] {
  const usedByOthers = new Set(
    slots.filter((s) => s.slot_index !== slotIndex).map((s) => s.room_type_id),
  )
  return orderStations(catalog).filter((room) => !usedByOthers.has(room.station_id))
}
