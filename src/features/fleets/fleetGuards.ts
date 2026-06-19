import type { Fleet } from './fleetTypes'

// Phase 10E — legacy/main-ship isolation invariant (single source of truth).
//
// A main-ship expedition fleet (Phase 10C) is tagged with `main_ship_id` and carries NO
// fleet_units. The two systems must stay separate in the UI:
//
//   • Main-ship send/recall goes ONLY through the Galaxy Map 🛰 surfaces:
//       MainShipCommand   → send_main_ship_expedition
//       MainShipPreview   → request_main_ship_return
//
//   • The legacy fleet leave/return path (request_leave_location → presence_request_leave)
//     must NEVER operate on a main-ship fleet. It derives speed from fleet_speed(), which is
//     NULL for a unit-less main-ship fleet and crashes movement_create
//     ("invalid fleet speed <NULL>") — the exact live bug fixed in Phase 10D (cfe59f6).
//
// Use this predicate everywhere a legacy fleet-action surface filters or renders actionable
// fleets, and as the basis for the defense-in-depth guard in fleetApi.requestLeaveLocation.
export function isMainShipFleet(f: Pick<Fleet, 'main_ship_id'>): boolean {
  return !!f.main_ship_id
}
