// WORLD EDITOR — V1B-2 location CHECK-enum authority (PURE constants; no React, no DOM, no IO).
// The SINGLE runtime source of truth for the `locations` CHECK-constraint enums. Each array mirrors,
// literal-for-literal, the live CHECK constraint in supabase/migrations/20260616000002_world_map.sql:
//   • location_type  → 20260616000002_world_map.sql:53-56
//   • activity_type  → 20260616000002_world_map.sql:61-64
//   • status         → 20260616000002_world_map.sql:68-69
// The typed arrays are pinned to the REAL mapTypes unions via `satisfies` (a union change breaks this
// build line, never silently drifts); tests/locationValidation.spec.ts additionally set-equal-guards
// them. NO other module may re-declare these literal lists (single-authority law) — the draft panel's
// <select> options and the validator's membership rules both import from here.
import type { ActivityType, LocationType } from '../map/mapTypes'

/** Every legal `locations.location_type` (CHECK, 0002_world_map.sql:53-56). */
export const LOCATION_TYPES = [
  'pirate_hunt',
  'pirate_den',
  'mining_site',
  'derelict_station',
  'trade_outpost',
  'rally_point',
  'safe_zone',
  'event_site',
] as const satisfies readonly LocationType[]

/** Every legal `locations.activity_type` (CHECK, 0002_world_map.sql:61-64). */
export const ACTIVITY_TYPES = [
  'hunt_pirates',
  'mine_resource',
  'explore_derelict',
  'trade_visit',
  'rally',
  'none',
] as const satisfies readonly ActivityType[]

/** Every legal `locations.status` (CHECK, 0002_world_map.sql:68-69). MapLocation.status is a plain
 *  `string` on the read contract, so this array is the ONLY client authority for the status domain. */
export const LOCATION_STATUSES = ['active', 'locked', 'hidden'] as const

export type LocationStatus = (typeof LOCATION_STATUSES)[number]
