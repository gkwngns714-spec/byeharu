// FLEET-GO 4a-2 — PURE logic for the fleet COORDINATE-GO surface (charter §2: the FLEET is the only
// mover; §2a: all movement interaction on the MAP). No React/DOM/SVG/fetch/state — unit-tested in
// tests/fleetGoTarget.spec.ts.
//
// This module owns three decisions and REUSES (imports, never copies) the proven geometry:
//   1. WHO owns an open-space tap (resolveSpaceTapOwner) — the unified-world suppression of the
//      per-ship coordinate surface, the mainshipCommandMode idiom at the tap layer.
//   2. WHAT a tapped point means (fleetGoTargetView) — the raw wire value, the canonical PREVIEW
//      point (roundHalfAwayFromZero — the documented mirror of 0208's server-side
//      round(numeric) = half-away-from-zero), and the bounds verdict.
//   3. WHAT a go to that point IS for one group's fleet (classifyFleetCoordinateGo) — a fresh go,
//      a mid-flight redirect (0208:~409-428: an active leg is cancelled at its interpolated point,
//      `redirected:true`), or nothing at all (already parked exactly there).
//
// ── THE RAW-COORDS LAW (4a-1's buildCommandShipGroupGoArgs law, restated) ──────────────────────────
// The RPC payload carries the RAW tapped x/y, NEVER the canonical point: 0208 canonicalizes to the
// integer world grid server-side (0208:259-261) and a client pre-round would be a second authority
// over the grid. Canonical rounding exists for the PREVIEW and the already-here same-point comparison
// ONLY. Corollary: the bounds mirror below checks the RAW point — that is the value 0208 bound-checks
// (0208:257-258, BEFORE its rounding), so e.g. raw 10000.4 is out of bounds even though its canonical
// preview would be 10000. (The per-ship controller bound-checks its canonical point instead — correct
// THERE because the per-ship wrapper sends the canonical target; the fleet wire sends raw.)

import { canonicalizeWorldTarget } from './spaceMoveCommand'
import { isWithinOpenSpaceBounds, type WorldCoord } from './openSpaceTransform'
import type { UnifiedGroupFleetLite } from '../command/teamApi'

// ── 1. Tap ownership ───────────────────────────────────────────────────────────────────────────────
// Unified lit + the player owns ≥1 group → the FLEET owns every open-space tap and the per-ship
// coordinate surface (marker + top-right panel) is SUPPRESSED — under §2 a ship never moves on its
// own, so rendering both surfaces would put two movers on one tap. The fleet surface's ONLY gate is
// the flag + owning a group: deliberately NOT the per-ship canTarget/useOsnReadiness capability (a
// per-SHIP readiness has no authority over the fleet), NOT eligibility==='in_transit' (a go while
// moving IS the redirect), and NOT cmd.active (the unified mover has no command-ship gate).
// Unified dark → today's behavior byte-identical: the per-ship capability decides, verbatim.
export type SpaceTapOwner = 'fleet' | 'per_ship' | 'none'

export function resolveSpaceTapOwner(input: {
  /** The RUNTIME fleet_movement_unified_enabled flag (useGalaxyMapData's one read; false in prod). */
  unifiedEnabled: boolean
  /** Does the player own ≥1 ship group (teamGroups.length > 0)? */
  hasGroups: boolean
  /** The existing per-ship canTarget verdict (isCoordinateTargetingActionable) — the DARK world's owner. */
  perShipCanTarget: boolean
}): SpaceTapOwner {
  if (input.unifiedEnabled && input.hasGroups) return 'fleet'
  return input.perShipCanTarget ? 'per_ship' : 'none'
}

// ── 2. The tapped point, resolved once ─────────────────────────────────────────────────────────────
export interface FleetGoTargetView {
  /** The tapped world point EXACTLY as screenToWorld produced it — the value the RPC sends. */
  raw: WorldCoord
  /** The integer-grid point 0208 will store — PREVIEW + same-point comparison only, never the wire. */
  canonical: WorldCoord
  /** Bounds verdict on the RAW point (±10000 inclusive, finite) — the mirror of 0208:257-258. */
  withinBounds: boolean
}

export function fleetGoTargetView(raw: WorldCoord): FleetGoTargetView {
  return {
    raw,
    canonical: canonicalizeWorldTarget(raw),
    withinBounds: isWithinOpenSpaceBounds(raw),
  }
}

/** The RPC coordinate payload — the RAW law made structural: the ONE place the panel takes its wire
 *  value from, and the exact expression the spec pins (3.5 in → 3.5 out, never 4). */
export function fleetGoRpcTarget(view: FleetGoTargetView): { x: number; y: number } {
  return { x: view.raw.x, y: view.raw.y }
}

// ── 3. What a go to this point IS, per group fleet ─────────────────────────────────────────────────
//   'go'           — a fresh departure (bootstrap: no unified fleet row yet → 0208 creates one; or
//                    parked at a port / anchored — the mover launches from wherever the fleet is).
//   'redirect'     — the fleet has a live leg (status='moving'): the SAME call cancels it at the
//                    interpolated point and departs from there (0208 redirected:true). Checked FIRST:
//                    a moving fleet's parked coords are stale history, never an already-here.
//   'already_here' — parked in open space (location_mode='space') at EXACTLY the canonical point.
//                    SUPPRESS the action: this is the coordinate analog of 4a-1's 'docked_here'. It is
//                    a pointless no-op, not a server hazard. 0208 has no zero-distance guard, BUT
//                    movement_create floors travel at min_travel_seconds (seeded '5', game_config
//                    0003), so a zero-length leg is a harmless 5-second trip that settles back where it
//                    started — arrive_at > depart_at, the CHECK never fires. We suppress because
//                    re-issuing a go to a fleet's own parked point does nothing a player wants, not to
//                    dodge a raise. (If prod ever set min_travel_seconds=0 the raise would become real;
//                    the suppression is correct either way. The redirect path relies on the same floor.)
// The comparison uses the CANONICAL point: fleets park on the integer grid (0208 rounds before
// storing), so canonical-vs-stored is exact integer equality — comparing raw would never match.
export type FleetGoIntent = 'go' | 'redirect' | 'already_here'

export function classifyFleetCoordinateGo(
  fleet: UnifiedGroupFleetLite | null,
  canonical: WorldCoord,
): FleetGoIntent {
  if (fleet === null) return 'go' // bootstrap — 0208 creates the group's fleet on first go
  if (fleet.status === 'moving') return 'redirect'
  if (
    fleet.location_mode === 'space' &&
    fleet.space_x !== null &&
    fleet.space_y !== null &&
    fleet.space_x === canonical.x &&
    fleet.space_y === canonical.y
  ) {
    return 'already_here'
  }
  return 'go' // parked at a port, anchored, or in space elsewhere — all legal departures under §2
}

// ── Copy helpers (redirect-aware; the TeamMapSend success-naming convention) ───────────────────────
export const formatWorldPoint = (w: WorldCoord): string => `(${w.x}, ${w.y})`

export function fleetGoButtonLabel(intent: FleetGoIntent): string {
  return intent === 'redirect' ? 'Redirect fleet here' : 'Send fleet here'
}

/** Success line naming the fleet + the canonical destination. `redirected` comes from the SERVER
 *  envelope (0208's redirected:true), never the client's pre-submit intent — the server is the
 *  authority on whether a leg was cancelled. */
export function fleetGoSuccessMessage(input: {
  fleetName: string
  /** 0208's member_count echo; omitted → the count segment is dropped, the line still reads whole. */
  shipCount?: number
  canonical: WorldCoord
  redirected: boolean
}): string {
  const verb = input.redirected ? 'Redirected' : 'Sent'
  const count =
    typeof input.shipCount === 'number'
      ? ` — ${input.shipCount} ship${input.shipCount === 1 ? '' : 's'} —`
      : ''
  return `${verb} ${input.fleetName}${count} to ${formatWorldPoint(input.canonical)}.`
}
