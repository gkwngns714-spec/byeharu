// WORLD EDITOR — V5 LIFECYCLE: the ONE transport binding for the owner-only inactive-detail /
// REACTIVATION reader (the 0270 world_editor_entity_detail RPC). Calls the deployed SECURITY DEFINER
// RPC public.world_editor_entity_detail(p_payload jsonb) for a zone/location and returns the OPAQUE
// `reactivation_expected` snapshot the domain's reactivation command needs as its optimistic-
// concurrency `expected` — passed STRAIGHT THROUGH, NO client-side reconstruction. mining/exploration
// do NOT use this reader (they reactivate directly from the catalog row). READ-ONLY, grants no
// authority (the server is_owner() guard is the sole authority).
import { supabase } from '../../lib/supabase'
import { normalizeEnvelopeError, type WorldEditorErrorCode, type WorldEditorFailureDetail } from './commandContract'

/** The domains this reader serves (mining/exploration are catalog-sufficient, rejected server-side). */
export type ReactivationDetailDomain = 'zone' | 'location'

/** The typed result of a detail read: the opaque `reactivation_expected` (a plain field bag passed
 *  verbatim into the reactivation command's `expected`), or a typed failure the caller routes through
 *  the shared inline Notice + describeWorldEditorError. */
export type EntityDetailResult =
  | {
      readonly ok: true
      readonly domain: ReactivationDetailDomain
      readonly entityId: string
      readonly name: string
      readonly reactivationExpected: Record<string, unknown>
    }
  | { readonly ok: false; readonly error: WorldEditorErrorCode; readonly details?: ReadonlyArray<WorldEditorFailureDetail> }

/** Fetch the reactivation `expected` snapshot for one INACTIVE zone/location. A transport error folds
 *  to a typed transport_error; a malformed success envelope also folds to transport_error (fail-closed
 *  — never a fabricated expected). */
export async function fetchWorldEditorEntityDetail(
  domain: ReactivationDetailDomain,
  entityId: string,
): Promise<EntityDetailResult> {
  const { data, error } = await supabase.rpc('world_editor_entity_detail', {
    p_payload: { domain, entity_id: entityId },
  })
  if (error) return { ok: false, error: 'transport_error' }
  const raw = data as Record<string, unknown> | null
  if (!raw || typeof raw !== 'object' || typeof raw.ok !== 'boolean') {
    return { ok: false, error: 'transport_error' }
  }
  if (!raw.ok) return normalizeEnvelopeError(raw)
  const expected = raw.reactivation_expected
  const name = raw.name
  if (!expected || typeof expected !== 'object' || Array.isArray(expected) || typeof name !== 'string') {
    return { ok: false, error: 'transport_error' }
  }
  return {
    ok: true,
    domain,
    entityId,
    name,
    reactivationExpected: expected as Record<string, unknown>,
  }
}
