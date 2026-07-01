// PORT-ENTRY player UI — PURE, framework-free core.
//
// No React/DOM/fetch/writes here. This module owns:
//   (1) the typed results of the two authenticated PORT-ENTRY RPCs (commission_first_main_ship /
//       normalize_main_ship_dock) and STRICT fail-closed parsers of their raw jsonb (migration 0072);
//   (2) a pure classifier that maps the caller's OWN main-ship state to the single affordance the UI
//       should offer — the SERVER is always the final authority, so this only decides which control to
//       show; it never performs or fabricates a state transition;
//   (3) stable player-facing copy for every server outcome / reason.
//
// HARD BOUNDARY: both RPCs are zero-arg and auth.uid()-scoped — the client sends NO player/ship/port id,
// coordinates, status, or lifecycle data. Nothing here touches coordinate travel, its dark flag/gate, the
// coordinate command, port-to-port travel, migrations, or production data. Server-authoritative only.

import type { SpatialState } from '../map/mainshipApi'

// ── The RPC name literals (single source shared with the API layer and the tests) ──────────────────────
export const COMMISSION_RPC = 'commission_first_main_ship' as const
export const NORMALIZE_RPC = 'normalize_main_ship_dock' as const

// ── Parsed RPC results ─────────────────────────────────────────────────────────────────────────────────
// commission_first_main_ship() outcome matrix (migration 0072, §B): a first-ship claim that is idempotent
// server-side (player_id UNIQUE + state-branch). We normalize every documented shape into a discriminated
// result; ANY malformed/unexpected jsonb collapses to a safe failure (never throws, never invents success).
export type CommissionResult =
  | { ok: true; created: boolean; docked: true; locationId: string | null } // A (created) / B·C (already provisioned)
  | { ok: false; reason: CommissionReason; state?: string | null }

export type CommissionReason =
  | 'not_authenticated'
  | 'commission_unavailable'
  | 'needs_normalization' // ship is legacy_present → route the player to Finish Docking
  | 'needs_compat_route' // ship is home / legacy_home → no player docking path yet
  | 'not_provisionable' // destroyed / in_space / in_transit / contradictory / not-found
  | 'malformed'

// normalize_main_ship_dock() (migration 0072, §C): legacy_present → at_location IN PLACE, idempotent.
export type NormalizeResult =
  | { ok: true; normalized: boolean; locationId: string | null } // normalized=true (did work) / false (already canonical)
  | { ok: false; reason: NormalizeReason; state?: string | null }

export type NormalizeReason =
  | 'not_authenticated'
  | 'no_ship'
  | 'not_normalizable' // not legacy_present (e.g. home / legacy_home / in-flight)
  | 'ineligible_port' // the current port is no longer a legal dock
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

/**
 * Strict validator for the raw normalize_main_ship_dock() jsonb. Same fail-closed discipline as above.
 */
export function parseNormalizeResult(raw: unknown): NormalizeResult {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { ok: false, reason: 'malformed' }
  const o = raw as Record<string, unknown>
  if (typeof o.ok !== 'boolean') return { ok: false, reason: 'malformed' }
  if (o.ok === true) {
    return { ok: true, normalized: asBool(o.normalized), locationId: asStr(o.location_id) }
  }
  const reason = asStr(o.reason)
  const known: NormalizeReason[] = ['not_authenticated', 'no_ship', 'not_normalizable', 'ineligible_port']
  if (!reason || !(known as string[]).includes(reason)) return { ok: false, reason: 'malformed' }
  return { ok: false, reason: reason as NormalizeReason, state: asStr(o.state) }
}

// ── The player's own main-ship state signals (owner-read; the input to affordance selection) ───────────
// A DISPLAY-only summary; every field is server-sourced. `null` for the whole object means "not loaded yet".
export interface PortEntryShipState {
  hasShip: boolean
  spatialState: SpatialState | null // NULL ⇒ legacy ship (position from fleet/presence)
  shipStatus: string | null // main_ship_instances.status
  fleetStatus: string | null // active linked fleet: 'present' | 'moving' | 'returning' | null
  fleetLocationMode: string | null // 'location' when present at a named port
  hasActivePresence: boolean // an active location_presence for the linked fleet
}

// ── Affordance: the SINGLE control (or safe explanation) the UI should present ─────────────────────────
// Only 'commission' and 'normalize' carry an action; every other kind is a read-only explanatory state.
export type PortEntryAffordance =
  | { kind: 'loading' }
  | { kind: 'commission' } // no ship → Claim First Ship (commission_first_main_ship)
  | { kind: 'normalize' } // legacy_present at a port → Finish Docking (normalize_main_ship_dock)
  | { kind: 'docked' } // canonical at_location → no action; ordinary dock experience
  | { kind: 'at_home' } // home / legacy_home → explain; no in-place docking path exists yet
  | { kind: 'in_transit' } // traveling / returning → explain; act only from a stable state
  | { kind: 'unavailable'; detail: 'destroyed' | 'in_space' | 'indeterminate' } // explain; no action

/**
 * Pure classifier: caller's own main-ship state → the one affordance to show. This decides ONLY which
 * control renders; the authoritative accept/reject is the server RPC. It never mutates or predicts success.
 *
 * "Finish Docking" (normalize) is offered ONLY for a coherent legacy_present ship — the exact state the
 * server normalizes IN PLACE. home / legacy_home ships DO NOT get a normalize button (the server would
 * reject them with needs_compat_route); they are shown a safe 'at_home' explanation instead, so the UI
 * never offers an action that structurally cannot succeed. (See the PORT-ENTRY-UI scope note.)
 */
export function derivePortEntryAffordance(state: PortEntryShipState | null): PortEntryAffordance {
  if (state === null) return { kind: 'loading' }
  if (!state.hasShip) return { kind: 'commission' }

  // A disabled/destroyed ship is never provisionable/dockable — repair is its own separate path.
  if (state.shipStatus === 'destroyed' || state.spatialState === 'destroyed') {
    return { kind: 'unavailable', detail: 'destroyed' }
  }

  switch (state.spatialState) {
    case 'at_location':
      return { kind: 'docked' }
    case 'in_transit':
      return { kind: 'in_transit' }
    case 'in_space':
      return { kind: 'unavailable', detail: 'in_space' }
    case 'home':
      return { kind: 'at_home' }
    case null: {
      // Legacy ship (spatial_state IS NULL): classify from the linked-fleet shape.
      if (state.fleetStatus === 'present') {
        // Only a COHERENT present-at-named-port shape is the normalizable legacy_present state.
        if (state.fleetLocationMode === 'location' && state.hasActivePresence) return { kind: 'normalize' }
        return { kind: 'unavailable', detail: 'indeterminate' }
      }
      if (state.fleetStatus === 'moving' || state.fleetStatus === 'returning') return { kind: 'in_transit' }
      if (state.fleetStatus === null) return { kind: 'at_home' } // legacy_home: idle at base
      return { kind: 'unavailable', detail: 'indeterminate' }
    }
    default:
      return { kind: 'unavailable', detail: 'indeterminate' }
  }
}

// ── Player-facing copy (stable client strings; the server also returns a message we never rely on) ─────
export const COMMISSION_REASON_COPY: Record<CommissionReason, string> = {
  not_authenticated: 'You must be signed in to claim a ship.',
  commission_unavailable: 'Could not commission your ship right now. Please try again in a moment.',
  needs_normalization: 'Your ship is at a port but not fully docked yet — use Finish Docking.',
  needs_compat_route: 'Your ship is at your home base. Travel to a port before it can be docked.',
  not_provisionable: 'Your ship is not in a state where it can be commissioned.',
  malformed: 'Received an unexpected response. Please try again.',
}

export const NORMALIZE_REASON_COPY: Record<NormalizeReason, string> = {
  not_authenticated: 'You must be signed in to finish docking.',
  no_ship: 'You do not have a ship to dock yet.',
  not_normalizable: 'This ship cannot be docked from its current state.',
  ineligible_port: 'This port is not accepting docking right now.',
  malformed: 'Received an unexpected response. Please try again.',
}

export function commissionReasonMessage(reason: CommissionReason): string {
  return COMMISSION_REASON_COPY[reason] ?? COMMISSION_REASON_COPY.malformed
}
export function normalizeReasonMessage(reason: NormalizeReason): string {
  return NORMALIZE_REASON_COPY[reason] ?? NORMALIZE_REASON_COPY.malformed
}
