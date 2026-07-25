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
  commandRpcArgs,
  commandRpcName,
  normalizeEnvelope,
  type RawServerEnvelope,
  type WorldEditorCommandEnvelope,
  type WorldEditorCommandResult,
  type WorldEditorFailureDetail,
} from './commandContract'

export * from './commandContract'

/** The PostgREST/supabase error shape this client reads. Structural, not an import: supabase-js types
 *  the field as PostgrestError only on some paths, and we must never throw while reporting an error. */
interface RpcErrorLike {
  readonly code?: string | null
  readonly message?: string | null
  readonly details?: string | null
  readonly hint?: string | null
}

/** Turn an RPC-layer refusal into ONE structured detail carrying what the server actually said —
 *  PostgREST's code (PGRST202 = no such function, 42501 = grant revoked, …) plus its message, details
 *  and hint. Pure and total: an unrecognisable error still yields an honest, non-empty detail. */
export function rpcErrorDetail(error: unknown): WorldEditorFailureDetail {
  const e = (typeof error === 'object' && error !== null ? error : {}) as RpcErrorLike
  const code = typeof e.code === 'string' && e.code !== '' ? e.code : 'rpc_error'
  const message = [e.message, e.details, e.hint]
    .filter((part): part is string => typeof part === 'string' && part !== '')
    .join(' — ')
  return { code, message: message === '' ? String(error) : message }
}

/**
 * Thin client wrapper: issue a World Editor command through its server-authoritative RPC and return
 * the typed result. The server guard (is_owner()) is the ONLY authority — this wrapper adds none.
 */
export async function invokeWorldEditorCommand<R = unknown, P = Record<string, unknown>>(
  envelope: WorldEditorCommandEnvelope<P>,
): Promise<WorldEditorCommandResult<R>> {
  // The named-arg shape is owned by the pure contract (commandRpcArgs): every command sends
  // { p_request_id, p_payload } EXCEPT world_editor_revert, whose signature takes { p_request_id, p_audit_id }.
  const { data, error } = await supabase.rpc(commandRpcName(envelope.commandType), commandRpcArgs(envelope))
  if (error) {
    // The RPC layer itself refused. NEVER swallow what it said: a missing function (PGRST202), a
    // revoked grant (42501) and an actual network drop are three different problems that used to
    // render as the same "could not reach the server" sentence. The typed code stays transport_error
    // (the union is the server contract's vocabulary, not ours to extend); the TRUTH rides the
    // existing details[] pipeline — the SAME channel validation_failed already uses, so every
    // consumer renders it with zero new UI (the worldEditorAuditNormalize `malformed_response` idiom).
    return {
      ok: false,
      requestId: envelope.requestId,
      error: 'transport_error',
      details: [rpcErrorDetail(error)],
    }
  }
  return normalizeEnvelope<R>(envelope, data as RawServerEnvelope | null)
}
