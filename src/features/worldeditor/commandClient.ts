// WORLD EDITOR — shared, typed command client (V1B-0 owner-security-spine, §WE.10).
//
// This is the ONE typed envelope + result/error contract that EVERY future World Editor command shares,
// mirroring the server entrypoint migration 0243 (world_editor_ping → generalized). It is deliberately
// NOT wired to any write button or control: the live editor (WorldEditor.tsx) is read-only, and this
// slice ships mutation-READINESS only. Importing this module performs nothing until a future slice
// binds a command to a UI action. Server-authoritative security lives in the RPC (is_owner() guard);
// this client only shapes the request/response — it grants no authority.
import { supabase } from '../../lib/supabase'

/** Command kinds. v1 exposes only the guarded no-op ping; future commands extend this union. */
export type WorldEditorCommandType = 'world_editor_ping'

/**
 * The typed command envelope every World Editor command is issued with. `requestId` is the idempotency
 * key (server-enforced UNIQUE): re-issuing the same requestId returns the prior result, never re-applies.
 */
export interface WorldEditorCommandEnvelope<P = Record<string, unknown>> {
  readonly requestId: string
  readonly commandType: WorldEditorCommandType
  readonly targetType?: string | null
  readonly targetId?: string | null
  readonly payload?: P
}

/** The typed error vocabulary returned by the server guard (must match migration 0243's contract). */
export type WorldEditorErrorCode =
  | 'not_authenticated' // no JWT subject (anonymous)
  | 'not_authorized' // authenticated, but not in the app_owners allow-list
  | 'invalid_request' // missing / blank requestId
  | 'duplicate_request' // idempotent replay (surfaced on a successful replay envelope)
  | 'transport_error' // client-side: the RPC call itself failed (network / permission)

export interface WorldEditorCommandSuccess<R = unknown> {
  readonly ok: true
  readonly requestId: string
  readonly commandType: WorldEditorCommandType
  readonly result: R
  /** true when this is an idempotent replay of a prior identical requestId. */
  readonly replayed?: boolean
  /** set to 'duplicate_request' on a replay; otherwise absent. */
  readonly code?: WorldEditorErrorCode
}

export interface WorldEditorCommandFailure {
  readonly ok: false
  readonly requestId: string
  readonly error: WorldEditorErrorCode
}

export type WorldEditorCommandResult<R = unknown> =
  | WorldEditorCommandSuccess<R>
  | WorldEditorCommandFailure

/** Raw server envelope (snake_case) as returned by the RPC, before normalization. */
interface RawServerEnvelope {
  ok?: boolean
  request_id?: string
  command_type?: WorldEditorCommandType
  result?: unknown
  error?: WorldEditorErrorCode
  replayed?: boolean
  code?: WorldEditorErrorCode
}

/** Generate a fresh idempotency key. Uses the platform UUID (browser + Node 18+). */
export function newRequestId(): string {
  return crypto.randomUUID()
}

/** Map a command kind to its server RPC entrypoint. One entrypoint per command, no client dispatch logic. */
function commandRpcName(commandType: WorldEditorCommandType): string {
  switch (commandType) {
    case 'world_editor_ping':
      return 'world_editor_ping'
    default:
      // exhaustiveness: adding a command kind without an entrypoint is a compile error.
      return assertNever(commandType)
  }
}

/** Normalize the raw snake_case server envelope into the typed camelCase result. */
function normalizeEnvelope<R>(
  envelope: WorldEditorCommandEnvelope,
  raw: RawServerEnvelope | null,
): WorldEditorCommandResult<R> {
  if (!raw || typeof raw.ok !== 'boolean') {
    return { ok: false, requestId: envelope.requestId, error: 'transport_error' }
  }
  if (raw.ok) {
    return {
      ok: true,
      requestId: raw.request_id ?? envelope.requestId,
      commandType: raw.command_type ?? envelope.commandType,
      result: raw.result as R,
      replayed: raw.replayed,
      code: raw.code,
    }
  }
  return {
    ok: false,
    requestId: raw.request_id ?? envelope.requestId,
    error: raw.error ?? 'transport_error',
  }
}

/**
 * Thin client wrapper: issue a World Editor command through its server-authoritative RPC and return the
 * typed result. The server guard (is_owner()) is the ONLY authority — this wrapper adds none. NOT bound
 * to any UI control in this slice.
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

/** Human-readable, exhaustive description of every error code (compile-enforces the union stays covered). */
export function describeWorldEditorError(code: WorldEditorErrorCode): string {
  switch (code) {
    case 'not_authenticated':
      return 'You must be signed in to run World Editor commands.'
    case 'not_authorized':
      return 'This account is not a World Editor owner.'
    case 'invalid_request':
      return 'The command request was malformed (missing request id).'
    case 'duplicate_request':
      return 'This command was already applied; the prior result was returned.'
    case 'transport_error':
      return 'The command could not reach the server.'
    default:
      return assertNever(code)
  }
}

/** Compile-time exhaustiveness guard: unreachable at runtime for a fully-covered union. */
function assertNever(value: never): never {
  throw new Error(`Unhandled World Editor command variant: ${String(value)}`)
}
