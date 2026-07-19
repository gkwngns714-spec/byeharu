// WORLD EDITOR — shared, typed command client: the ONE transport binding that issues a World Editor
// command through its server-authoritative RPC. The PURE contract (envelope/result/error unions,
// RPC-name map, normalization, error copy) lives in commandContract.ts — unit-testable with zero
// network — and is re-exported here so every consumer keeps ONE import site. Server-authoritative
// security lives in the RPC (the 0243 is_owner() guard); this client only shapes request/response —
// it grants no authority. As of the 0244 publish slice, exploration_site_create is the FIRST command
// wired to a UI action (ExplorationDraftPanel's Publish button); the capability stays inert until
// migration 0244 is deployed AND an owner is seeded (fail-closed).
import { supabase } from '../../lib/supabase'
import {
  commandRpcName,
  normalizeEnvelope,
  type RawServerEnvelope,
  type WorldEditorCommandEnvelope,
  type WorldEditorCommandResult,
} from './commandContract'

export * from './commandContract'

/**
 * Thin client wrapper: issue a World Editor command through its server-authoritative RPC and return
 * the typed result. The server guard (is_owner()) is the ONLY authority — this wrapper adds none.
 */
export async function invokeWorldEditorCommand<R = unknown, P = Record<string, unknown>>(
  envelope: WorldEditorCommandEnvelope<P>,
): Promise<WorldEditorCommandResult<R>> {
  const { data, error } = await supabase.rpc(commandRpcName(envelope.commandType), {
    p_request_id: envelope.requestId,
    p_payload: envelope.payload ?? {},
  })
  if (error) {
    return { ok: false, requestId: envelope.requestId, error: 'transport_error' }
  }
  return normalizeEnvelope<R>(envelope, data as RawServerEnvelope | null)
}
