// WORLD EDITOR — V5 LIFECYCLE: the PURE reactivation command-envelope builders. A selected INACTIVE
// catalog row (+ optionally its 0270 detail `reactivation_expected`) in → the ONE typed World Editor
// command envelope out. No React, no DOM, no supabase, no network IO — so the four per-domain payload
// shapes are unit-tested directly (tests/worldEditorReactivate.spec.ts). The transport/UI composes
// this; server-authoritative security lives in each command's is_owner() guard — this module grants no
// authority and RECONSTRUCTS NO `expected`: zone/location pass the detail snapshot VERBATIM, and
// mining/exploration read the name + point straight off the catalog row.
//
// THE FOUR PATHS (§WE.13 V5):
//   • ZONE     → zone_set_active (0268)  payload {target_id: entityId, expected: detail.reactivation_
//                expected {name, source, location_id}}. (reactivate-only; NO is_active flag.)
//   • LOCATION → location_update (0249)  payload {target_id: entityId, expected: detail.reactivation_
//                expected (the 11 fields), fields: <that snapshot with status flipped to 'active'>}.
//   • MINING / EXPLORATION → *_set_active (0250) payload {target_id: name, expected:{name, space_x,
//                space_y, reward_bundle_json:null}, is_active:true} — straight from the catalog row, NO
//                detail call (reward_bundle_json is compared only when non-null, so null is safe).
import type { WorldEditorCommandEnvelope } from './commandContract'
import type { WorldEditorCatalogRow } from './worldEditorCatalog'
import type { ReactivationDetailDomain } from './worldEditorEntityDetail'

/** mining/exploration reactivate from the catalog row (no detail call); zone/location need the 0270
 *  detail snapshot first. */
export function reactivationNeedsDetail(row: WorldEditorCatalogRow): row is WorldEditorCatalogRow & {
  domain: ReactivationDetailDomain
} {
  return row.domain === 'zone' || row.domain === 'location'
}

/** The mining/exploration *_set_active payload — {target_id: name, expected:{name, space_x, space_y,
 *  reward_bundle_json:null}, is_active:true}. reward_bundle_json:null is deliberately unobservable
 *  (0250: compared only when non-null), so the server-only bundle is never reconstructed. */
export interface CatalogSetActivePayload {
  readonly target_id: string
  readonly expected: {
    readonly name: string
    readonly space_x: number | null
    readonly space_y: number | null
    readonly reward_bundle_json: null
  }
  readonly is_active: true
}

/** Build the reactivation envelope for a MINING or EXPLORATION catalog row (NO detail call). target_id
 *  is the row's NAME (the *_set_active natural key); the coords come from the row's point. */
export function catalogReactivateEnvelope(
  row: WorldEditorCatalogRow,
  requestId: string,
): WorldEditorCommandEnvelope<CatalogSetActivePayload> {
  if (row.domain !== 'mining' && row.domain !== 'exploration') {
    throw new Error(`catalogReactivateEnvelope: ${row.domain} reactivates via the detail reader, not the catalog row`)
  }
  return {
    requestId,
    commandType: row.domain === 'mining' ? 'mining_field_set_active' : 'exploration_site_set_active',
    payload: {
      target_id: row.name,
      expected: {
        name: row.name,
        space_x: row.point ? row.point.x : null,
        space_y: row.point ? row.point.y : null,
        reward_bundle_json: null,
      },
      is_active: true,
    },
  }
}

/** The zone_set_active reactivation payload — {target_id, expected} (the detail snapshot verbatim). */
export interface ZoneReactivatePayload {
  readonly target_id: string
  readonly expected: Record<string, unknown>
}

/** The location_update reactivation payload — {target_id, expected (verbatim), fields (the snapshot
 *  with status→'active')}. */
export interface LocationReactivatePayload {
  readonly target_id: string
  readonly expected: Record<string, unknown>
  readonly fields: Record<string, unknown>
}

/** Build the reactivation envelope for a ZONE or LOCATION from its 0270 `reactivation_expected`
 *  snapshot — passed VERBATIM as `expected` (NO client reconstruction). For a location the same
 *  snapshot becomes `fields` with only `status` flipped to 'active' (reactivation = set status
 *  active); zone_set_active is reactivate-only and needs no fields. */
export function detailReactivateEnvelope(
  domain: ReactivationDetailDomain,
  entityId: string,
  reactivationExpected: Record<string, unknown>,
  requestId: string,
): WorldEditorCommandEnvelope<ZoneReactivatePayload | LocationReactivatePayload> {
  if (domain === 'zone') {
    return {
      requestId,
      commandType: 'zone_set_active',
      payload: { target_id: entityId, expected: reactivationExpected },
    }
  }
  return {
    requestId,
    commandType: 'location_update',
    payload: {
      target_id: entityId,
      expected: reactivationExpected,
      fields: { ...reactivationExpected, status: 'active' },
    },
  }
}
