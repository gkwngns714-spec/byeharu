import type { MainShipFleet } from '../map/mainshipApi'
import type { FleetMovement } from '../fleets/fleetTypes'
import type { MapLocation } from '../map/mapTypes'
import { formatCountdown } from '../../lib/time'

// S6 NOTE (Fitting tab): ShipStatusCard/ShipDossier/ShipScreen's direct consumption is RETIRED —
// every live consumer now reaches this resolver through the fleet-positions adapter
// (teamRoster.fleetPositionLocationLabel / resolveBerthedLocationLabel below), i.e. the ONE
// map.fleetPositions read. CLEANUP FLAG (updated by MAP-INTEGRATION n2 — recorded, not done here):
// MainShipCommand (this note's old "remaining consumer") was DELETED with the per-ship movement
// client (4a-post), so deriveMainShipStatus (mainshipApi) is now fully ORPHANED — zero callers; its
// documented mirror fleetDisplayStatus below survives only as this resolver's internal fleet-status
// mapper. Delete deriveMainShipStatus (and this mirror note) on the next mainshipApi touch. Do NOT
// add a third copy.
//
// SHIPLOC — the ONE shared main-ship LOCATION resolver. Born to answer the owner order "in ship
// tab, i should be able to see where the ship is, the location as well." ShipStatusCard already
// inlined this name-resolution (docked → the present fleet's location name; traveling → the moving
// movement's target name + countdown); the dossier now needs the SAME facts. Rather than a second
// copy, both surfaces call THIS pure helper, so there is exactly one implementation of "where is
// the ship" (anti-spaghetti law). ShipStatusCard consumes `destination` / `heading` / `etaText`
// (its rendering is byte-identical — it still owns its own badge/branch/progress); the dossier
// consumes `kind` + `label` for its one-line location strip.
//
// PURE — no React/DOM/fetch/state. Names resolve SOLELY from the passed `locations` (the shell's
// already-polled world-map list); a location id absent from that list (a hidden/unknown port)
// FAILS CLOSED to a generic label and never leaks the id (the mainshipStatusLabel idiom). The
// server stays the source of truth — this only re-labels the fleet/movement the client already
// holds.
//
// HONESTY (multi-ship): the caller (ShipScreen) threads the SOLE-ship-resolved fleet/movement (the
// shell's map poll resolves the sole ship today — fetchMainShip no-id → null at N≥2). When the
// selected ship is NOT that resolved ship, the caller passes NO resolution (the dossier shows
// "Location unavailable") — it never asks this helper to guess. So a null fleet+movement here
// means a genuine idle/undeployed ship (kind 'idle'), never "we don't know". Per-ship location for a
// non-sole ship arrives later via the MAP slice's fleet-positions projection.

export type ShipLocationKind =
  | 'docked' // present at a named, visible location
  | 'in-transit' // a moving expedition toward a destination
  | 'returning' // a moving return-home leg
  | 'combat' // present at a hostile/hunt site (pirate_hunt / pirate_den / hunt_pirates)
  | 'deep-space' // present but at no named location (open space)
  | 'idle' // no active fleet — the ship is idle/undeployed (NO-HOME LAW: there is no "home port")

export interface ShipLocationResolved {
  kind: ShipLocationKind
  /** The dossier's one-line label, e.g. "Docked at Haven Reach" / "In transit to Slagworks". */
  label: string
  /** Live countdown for a moving leg (in-transit / returning), else null — the dossier appends "· arrives in …". */
  etaText: string | null
  /** The resolved place/target name (docked/in-transit), reused verbatim by ShipStatusCard's own render. Null-safe. */
  destination: string | null
  /** Return-home leg (no destination shown), reused by ShipStatusCard. */
  heading: boolean
}

// A location the ship is PRESENT at where "being there" means fighting (hunt/pirate sites). Derived
// from the same public world-map row the name comes from — honest, in-scope, and touches no server.
function isCombatLocation(loc: MapLocation): boolean {
  return loc.location_type === 'pirate_hunt' || loc.location_type === 'pirate_den' || loc.activity_type === 'hunt_pirates'
}

// A byte-for-byte mirror of mainshipApi's deriveMainShipStatus (no fleet → home · present · returning
// · else traveling). Inlined ONLY because this helper must stay supabase-free so it is directly
// unit-testable, and mainshipApi (which imports the client) is owned by the parallel MAP slice — not
// ours to re-home its exports. It is a fleet-status mapper, NOT a second LOCATION resolver.
type DisplayStatus = 'home' | 'traveling' | 'present' | 'returning'
function fleetDisplayStatus(fleet: { status: string } | null): DisplayStatus {
  if (!fleet) return 'home'
  if (fleet.status === 'present') return 'present'
  if (fleet.status === 'returning') return 'returning'
  return 'traveling'
}

/**
 * Resolve the main ship's human-readable LOCATION from its active fleet + the (already-resolved)
 * moving movement + the world-map locations. Pure and null-safe.
 *
 * `movement` is the caller's resolved moving movement for this fleet (or null) — the same value
 * ShipStatusCard finds for its own progress bar, so the shared derivation stays a single pass.
 */
export function resolveShipLocationLabel(
  fleet: MainShipFleet | null,
  movement: FleetMovement | null,
  locations: MapLocation[],
): ShipLocationResolved {
  const status = fleetDisplayStatus(fleet) // fleet-only: no fleet → home · present · returning · else traveling
  const nameOf = (id: string | null | undefined): string | null => (id && locations.find((l) => l.id === id)?.name) || null

  // `destination` — computed EXACTLY as ShipStatusCard did (so its reuse is byte-identical): a moving
  // leg names its target (base target → "base"; unknown/hidden target → the "its destination" fallback),
  // otherwise a present fleet names its current location (null when idle/hidden).
  const destination = movement
    ? movement.target_type === 'base'
      ? 'base'
      : (nameOf(movement.target_location_id) ?? 'its destination')
    : status === 'present'
      ? nameOf(fleet?.current_location_id)
      : null

  const heading = movement?.mission_type === 'return_home' || status === 'returning'
  const etaText = movement ? formatCountdown(movement.arrive_at) : null

  // ── kind + label for the dossier's location strip ──────────────────────────────────────────────
  if (movement) {
    return heading
      ? { kind: 'returning', label: 'Returning home', etaText, destination, heading }
      : { kind: 'in-transit', label: `In transit to ${destination ?? 'its destination'}`, etaText, destination, heading }
  }

  if (status === 'present') {
    const locId = fleet?.current_location_id ?? null
    const loc = locId ? (locations.find((l) => l.id === locId) ?? null) : null
    if (!locId) return { kind: 'deep-space', label: 'In deep space', etaText, destination, heading }
    if (!loc) return { kind: 'docked', label: 'Docked', etaText, destination, heading } // hidden loc → fail closed, no id leak
    if (isCombatLocation(loc)) return { kind: 'combat', label: `In combat at ${loc.name}`, etaText, destination, heading }
    return { kind: 'docked', label: `Docked at ${loc.name}`, etaText, destination, heading }
  }

  if (status === 'returning') {
    return { kind: 'returning', label: 'Returning home', etaText, destination, heading }
  }

  // no active fleet → the ship is idle/undeployed. NO-HOME LAW: ports are the ONLY base — there is no
  // "home port" — so the label must NOT claim one; a neutral "Idle" is the honest read (it also agrees
  // with the sibling ShipStatusCard, which shows this same idle ship as "Ready to launch"). A fleet in
  // an odd state with no movement row degrades to a plain "In transit" rather than a false place.
  if (!fleet) return { kind: 'idle', label: 'Idle', etaText, destination, heading }
  return { kind: 'in-transit', label: 'In transit', etaText, destination, heading }
}

// ── S1 BERTH MODEL (migration 0216) — a BERTHED ship's location, through the ONE resolver ────────
// The server's fleet-positions projection now answers place='berthed' for an unfleeted ship docked
// at its berth port (location_id = the port). Its label is a DOCKED read — "Docked at <port>" —
// so this helper COMPOSES resolveShipLocationLabel with a synthetic present-at-port fleet instead
// of minting a second name-resolution path (anti-spaghetti: one implementation of "where is the
// ship"). Combat-port berths therefore also inherit the "In combat at …" wording, and an unknown/
// hidden port fails closed to a bare "Docked" exactly like the docked arm — one rule, one place.
// Pure; a null port id (shape-impossible for a server 'berthed' row, but typed honestly) degrades
// to the deep-space read rather than inventing a port.
export function resolveBerthedLocationLabel(
  berthLocationId: string | null,
  locations: MapLocation[],
): ShipLocationResolved {
  return resolveShipLocationLabel(
    {
      id: '',
      status: 'present',
      current_location_id: berthLocationId,
      location_mode: null,
      active_movement_id: null,
      active_space_movement_id: null,
    },
    null,
    locations,
  )
}
