// PORT-LAUNCH-1B — PURE, framework-free boundary logic for the dark port-to-port OSN navigation UI.
//
// No React/DOM/fetch here. This module owns:
//   (1) the typed shape of the server readiness projection (get_osn_movement_readiness());
//   (2) a strict boundary validator that accepts ONLY the documented generic categories and treats any
//       malformed / incomplete / unexpected payload as NOT ACTIONABLE (never throws, never leaks);
//   (3) the visible-destination selection rule (server eligibility ∩ visible world-map − current dock);
//   (4) the render-gate predicate for the selection UI;
//   (5) the active-location-target-transit predicate that re-uses the existing Stop command path.
//
// HARD BOUNDARY: the client NEVER reconstructs anchor legality, NEVER derives eligibility from a location's
// name/type/coordinates/distance, and NEVER inspects space_anchors / physical_role / raw coords / hidden
// ports. The server (get_osn_movement_readiness + command_main_ship_space_move_to_location) is the sole
// authority; this module only renders the safe projection the server already computed.

// The ONLY origin categories the client accepts. Anything else → not actionable.
export const OSN_ORIGIN_CATEGORIES = ['anchored', 'not_anchored', 'in_transit', 'destroyed', 'no_ship'] as const
export type OsnOriginCategory = (typeof OSN_ORIGIN_CATEGORIES)[number]

// The sanitized, client-trusted readiness projection. `eligibleDestinationIds` are raw server ids that must
// STILL be intersected with the visible world map before any are shown (selectableDestinationIds).
export interface OsnReadiness {
  osnAvailable: boolean
  originCategory: OsnOriginCategory | null
  reason: string | null
  eligibleDestinationIds: string[]
}

// The safe default for loading / error / malformed / unavailable: nothing is actionable, nothing renders.
export const OSN_NOT_ACTIONABLE: OsnReadiness = {
  osnAvailable: false,
  originCategory: null,
  reason: null,
  eligibleDestinationIds: [],
}

function isOriginCategory(v: unknown): v is OsnOriginCategory {
  return typeof v === 'string' && (OSN_ORIGIN_CATEGORIES as readonly string[]).includes(v)
}

/**
 * Strict boundary validator for the raw get_osn_movement_readiness() jsonb. Returns a sanitized
 * OsnReadiness, or OSN_NOT_ACTIONABLE for ANY malformed / incomplete / unexpected shape. Never throws,
 * never surfaces a raw RPC/database error, never trusts an unknown origin_category.
 */
export function parseOsnReadiness(raw: unknown): OsnReadiness {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return OSN_NOT_ACTIONABLE
  const o = raw as Record<string, unknown>
  if (typeof o.osn_available !== 'boolean') return OSN_NOT_ACTIONABLE
  if (!isOriginCategory(o.origin_category)) return OSN_NOT_ACTIONABLE
  const reason = typeof o.reason === 'string' ? o.reason : null
  const ids = Array.isArray(o.eligible_destination_ids)
    ? o.eligible_destination_ids.filter((x): x is string => typeof x === 'string' && x.length > 0)
    : []
  return {
    osnAvailable: o.osn_available,
    originCategory: o.origin_category,
    reason,
    eligibleDestinationIds: ids,
  }
}

/**
 * The destination ids the client may show: server eligibility ∩ the player-visible world map, with the
 * current docked location excluded (defensively, even if a malformed response included it). De-duplicated,
 * order-preserving. NEVER infers eligibility from anything other than the server's eligible list.
 */
export function selectableDestinationIds(
  readiness: OsnReadiness,
  visibleLocationIds: ReadonlySet<string>,
  currentDockedLocationId: string | null | undefined,
): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const id of readiness.eligibleDestinationIds) {
    if (id === currentDockedLocationId) continue // B5: never the current dock
    if (!visibleLocationIds.has(id)) continue // B1/B4: must be in the visible world-map response
    if (seen.has(id)) continue
    seen.add(id)
    out.push(id)
  }
  return out
}

/**
 * Render gate for the port SELECTION UI: only when the server says OSN is available, the ship is anchored,
 * and at least one visible eligible destination exists. False for loading / malformed / osn_available=false
 * / not_anchored / in_transit / destroyed / no_ship — so nothing mounts while production stays dark.
 */
export function isPortNavActionable(readiness: OsnReadiness, selectableCount: number): boolean {
  return readiness.osnAvailable === true && readiness.originCategory === 'anchored' && selectableCount > 0
}

/**
 * Whether the ship is in a real active LOCATION-target transit (the port-to-port analogue of the existing
 * coordinate-only `isActiveCoordinateTransit`). Drives the re-used Stop CTA + travel status for a port
 * route. Flag-INDEPENDENT and movement-state-driven, so it is naturally dark in production (no such
 * movement can exist while mainship_space_movement_enabled is false). Never reads the feature flag.
 */
export function isActiveLocationTargetTransit(input: {
  spatialState: string | null | undefined
  spaceMovementStatus: string | null | undefined
  spaceMovementTargetKind: string | null | undefined
}): boolean {
  return (
    input.spatialState === 'in_transit' &&
    input.spaceMovementStatus === 'moving' &&
    input.spaceMovementTargetKind === 'location'
  )
}
