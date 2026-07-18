// PORT-ENTRY player UI — PURE, framework-free core.
//
// No React/DOM/fetch/writes here. This module owns:
//   (1) the typed result of the authenticated PORT-ENTRY RPC (commission_first_main_ship) and a
//       STRICT fail-closed parser of its raw jsonb (migration 0072);
//   (2) a pure classifier that maps the caller's OWN main-ship state to the single affordance the UI
//       should offer — the SERVER is always the final authority, so this only decides which control to
//       show; it never performs or fabricates a state transition;
//   (3) stable player-facing copy for every server outcome / reason.
//
// 4C-CLIENT: the normalize arm (normalize_main_ship_dock — "Finish Docking") is DELETED. It served
// exactly one state — legacy_present (spatial_state NULL + present fleet at a port) — which is
// extinct (prod: zero such ships) and unmintable (its only writer was the retired per-ship legacy
// send family). The classifier now reads the ship's get_my_fleet_positions `place` (the ONE
// placement projection; its server head deliberately answers 'docked' for legacy_present too), so
// the legacy main_ship_instances.spatial_state column is no longer read anywhere client-side.
// normalize_main_ship_dock has NO client caller after this — droppable in 4b-DROP.
//
// HARD BOUNDARY: commission_first_main_ship is zero-arg and auth.uid()-scoped — the client sends NO
// player/port id, coordinates, status, or lifecycle data. Server-authoritative only.

// ── The RPC name literal (single source shared with the API layer and the tests) ───────────────────────
export const COMMISSION_RPC = 'commission_first_main_ship' as const

// ── Parsed RPC result ──────────────────────────────────────────────────────────────────────────────────
// commission_first_main_ship() outcome matrix (migration 0072, §B): a first-ship claim that is idempotent
// server-side (player_id UNIQUE + state-branch). We normalize every documented shape into a discriminated
// result; ANY malformed/unexpected jsonb collapses to a safe failure (never throws, never invents success).
export type CommissionResult =
  | { ok: true; created: boolean; docked: true; locationId: string | null } // A (created) / B·C (already provisioned)
  | { ok: false; reason: CommissionReason; state?: string | null }

export type CommissionReason =
  | 'not_authenticated'
  | 'commission_unavailable'
  | 'needs_normalization' // legacy_present (extinct; kept for the server contract — see the copy below)
  | 'needs_compat_route' // ship is home / legacy_home → no player docking path yet
  | 'not_provisionable' // destroyed / in_space / in_transit / contradictory / not-found
  | 'malformed'

const asStr = (v: unknown): string | null =>
  typeof v === 'string' && v.length > 0 ? v : null
const asBool = (v: unknown): boolean => v === true

/**
 * Strict validator for the raw commission_first_main_ship() jsonb. Returns a discriminated CommissionResult;
 * any object we do not recognise (missing/!boolean ok, unknown reason) becomes {ok:false, reason:'malformed'}.
 */
export function parseCommissionResult(raw: unknown): CommissionResult {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { ok: false, reason: 'malformed' }
  const o = raw as Record<string, unknown>
  if (typeof o.ok !== 'boolean') return { ok: false, reason: 'malformed' }
  if (o.ok === true) {
    // success ⇒ the ship is provisioned & canonically docked (created OR already_provisioned).
    return { ok: true, created: asBool(o.created), docked: true, locationId: asStr(o.location_id) }
  }
  const reason = asStr(o.reason)
  const known: CommissionReason[] = [
    'not_authenticated', 'commission_unavailable', 'needs_normalization', 'needs_compat_route', 'not_provisionable',
  ]
  if (!reason || !(known as string[]).includes(reason)) return { ok: false, reason: 'malformed' }
  return { ok: false, reason: reason as CommissionReason, state: asStr(o.state) }
}

// ── The player's own main-ship state signals (owner-read; the input to affordance selection) ───────────
// A DISPLAY-only summary; every field is server-sourced. `null` for the whole object means "not loaded yet".
// 4C-CLIENT: the legacy spatial_state / linked-fleet-shape fields are REPLACED by the ship's
// get_my_fleet_positions `place` — the same placement truth every other surface reads (SHIPLOC, Port hub).
export interface PortEntryShipState {
  hasShip: boolean
  shipStatus: string | null // main_ship_instances.status
  /** The ship's fleet-positions `place` ('docked' | 'berthed' | 'transit' | 'in_space' | 'hidden'), or
   *  null when the projection has no row / could not be read → fail closed to 'indeterminate'. */
  place: string | null
}

// ── Affordance: the SINGLE control (or safe explanation) the UI should present ─────────────────────────
// Only 'commission' carries an action; every other kind is a read-only explanatory state.
export type PortEntryAffordance =
  | { kind: 'loading' }
  | { kind: 'commission' } // no ship → Claim First Ship (commission_first_main_ship)
  | { kind: 'docked' } // at a port (docked with a fleet, or berthed) → no action; ordinary dock experience
  | { kind: 'at_home' } // hidden (idle/undeployed) → explain; travel to a port
  | { kind: 'in_transit' } // traveling → explain; act only from a stable state
  | { kind: 'unavailable'; detail: 'destroyed' | 'in_space' | 'indeterminate' } // explain; no action

/**
 * Pure classifier: caller's own main-ship state → the one affordance to show. This decides ONLY which
 * control renders; the authoritative accept/reject is the server RPC. It never mutates or predicts success.
 *
 * 4C-CLIENT semantics (place-based, replacing the retired spatial_state branch):
 *   docked/berthed → 'docked' (at a port — berth-truth agrees with the Fitting/Port tabs' "Docked at …");
 *   transit → 'in_transit'; in_space → 'unavailable'; hidden → 'at_home' (idle/undeployed);
 *   null/unknown place (projection unreadable) → fail-closed 'unavailable'/'indeterminate' — never a
 *   wrong action, never a wrong "travel to a port" claim over a ship that may be docked.
 */
export function derivePortEntryAffordance(state: PortEntryShipState | null): PortEntryAffordance {
  if (state === null) return { kind: 'loading' }
  if (!state.hasShip) return { kind: 'commission' }

  // A disabled/destroyed ship is never provisionable/dockable — repair is its own separate path.
  // (Destroyed ships are also excluded from the fleet-positions projection, so this check must
  // come BEFORE the place switch — a destroyed ship has no `place` row by construction.)
  if (state.shipStatus === 'destroyed') return { kind: 'unavailable', detail: 'destroyed' }

  switch (state.place) {
    case 'docked':
    case 'berthed':
      return { kind: 'docked' }
    case 'transit':
      return { kind: 'in_transit' }
    case 'in_space':
      return { kind: 'unavailable', detail: 'in_space' }
    case 'hidden':
      return { kind: 'at_home' }
    default:
      return { kind: 'unavailable', detail: 'indeterminate' }
  }
}

// ── Player-facing copy (stable client strings; the server also returns a message we never rely on) ─────
export const COMMISSION_REASON_COPY: Record<CommissionReason, string> = {
  not_authenticated: 'You must be signed in to claim a ship.',
  commission_unavailable: 'Could not commission your ship right now. Please try again in a moment.',
  // 4C-CLIENT: the "Finish Docking" button this copy used to point at is deleted (the legacy state
  // it served is extinct); the reason stays parsed for the server contract, with honest copy.
  needs_normalization: 'Your ship is already at a port but its docking is incomplete. Please try again later.',
  needs_compat_route: 'Your ship has not docked yet. Travel to a port before it can be docked.',
  not_provisionable: 'Your ship is not in a state where it can be commissioned.',
  malformed: 'Received an unexpected response. Please try again.',
}

export function commissionReasonMessage(reason: CommissionReason): string {
  return COMMISSION_REASON_COPY[reason] ?? COMMISSION_REASON_COPY.malformed
}
