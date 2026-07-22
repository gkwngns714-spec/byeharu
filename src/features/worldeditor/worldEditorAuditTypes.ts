// WORLD EDITOR V1.5 — the PURE, frozen contract for the owner-only audit reader
// public.world_editor_audit_list(jsonb) (migration 0256, deployed + production-proven). No React / DOM /
// supabase here — unit-testable with zero network. These types MIRROR the deployed RPC response EXACTLY.
//
// SECURITY BOUNDARY is the RPC (server-side is_owner() guard + field-filter). These types and the
// normalizer add DEFENSE IN DEPTH only and must NEVER reconstruct or infer redacted values. Unknown
// command/target values from the server are preserved as raw strings (shown as `Unsupported: <value>`),
// never coerced into a known value.

/** The audit ledger's command vocabulary (world_editor_audit.command_type across 0243–0266). */
export const KNOWN_AUDIT_COMMAND_TYPES = [
  'world_editor_ping',
  'exploration_site_create',
  'mining_field_create',
  'location_create',
  'zone_create',
  'exploration_site_update',
  'mining_field_update',
  'location_update',
  'zone_update',
  'exploration_site_set_active',
  'mining_field_set_active',
  'zone_unpublish',
] as const
export type KnownAuditCommandType = (typeof KNOWN_AUDIT_COMMAND_TYPES)[number]

/** The target-type vocabulary (world_editor_audit.target_type). */
export const KNOWN_AUDIT_TARGET_TYPES = ['none', 'exploration_site', 'mining_field', 'location', 'zone'] as const
export type KnownAuditTargetType = (typeof KNOWN_AUDIT_TARGET_TYPES)[number]

/** Error codes the reader returns (0256), plus the client-side transport fallback. */
export type WorldEditorAuditErrorCode =
  | 'not_authenticated'
  | 'not_authorized'
  | 'invalid_request'
  | 'transport_error'

/** Server-only keys that must NEVER appear in a sanitized snapshot. The server strips them; this
 *  client deny-list is a FAIL-CLOSED integrity assertion (a present key marks the response compromised). */
export const FORBIDDEN_SNAPSHOT_KEYS = ['reward_bundle_json', 'created_by', 'actor'] as const

/** A sanitized snapshot bag of allow-listed fields, or null (e.g. a create's `before`). */
export type AuditSnapshot = Readonly<Record<string, unknown>>

export interface WorldEditorAuditFailureDetail {
  readonly code: string
  readonly field?: string | null
}

/** ONE normalized audit record (camelCase, mirroring commandContract's normalization style). */
export interface WorldEditorAuditEntry {
  readonly id: string
  readonly requestId: string
  readonly commandType: string // known OR unknown-preserved (never coerced)
  readonly targetType: string | null
  readonly targetId: string | null
  readonly createdAt: string // ISO timestamptz
  readonly sourceRevision: string | null
  readonly result: Readonly<Record<string, unknown>> | null
  readonly actorIsOwner: boolean
  readonly before: AuditSnapshot | null
  readonly after: AuditSnapshot | null
  readonly redactions: readonly string[]
}

export interface WorldEditorAuditCursor {
  readonly ts: string
  readonly id: string
}

export interface WorldEditorAuditPage {
  readonly ok: true
  readonly pageSize: number
  readonly nextCursor: WorldEditorAuditCursor | null
  readonly items: readonly WorldEditorAuditEntry[]
}

export interface WorldEditorAuditFailure {
  readonly ok: false
  readonly error: WorldEditorAuditErrorCode
  readonly details?: readonly WorldEditorAuditFailureDetail[]
}

export type WorldEditorAuditResult = WorldEditorAuditPage | WorldEditorAuditFailure

/** The request filters the reader supports (0256). All optional; the client sends only these. */
export interface WorldEditorAuditFilters {
  readonly commandType?: string
  readonly targetType?: string
  readonly targetId?: string
  readonly requestId?: string
  readonly since?: string
  readonly until?: string
  readonly limit?: number
  readonly cursor?: WorldEditorAuditCursor | null
}

export function isKnownAuditCommandType(v: string): v is KnownAuditCommandType {
  return (KNOWN_AUDIT_COMMAND_TYPES as readonly string[]).includes(v)
}

export function isKnownAuditTargetType(v: string): v is KnownAuditTargetType {
  return (KNOWN_AUDIT_TARGET_TYPES as readonly string[]).includes(v)
}

/** Human copy for the failure codes (exhaustive over the union). */
export function describeAuditError(code: WorldEditorAuditErrorCode): string {
  switch (code) {
    case 'not_authenticated':
      return 'You must be signed in to view World Editor history.'
    case 'not_authorized':
      return 'This account is not a World Editor owner.'
    case 'invalid_request':
      return 'The history request was rejected by the server.'
    case 'transport_error':
      return 'Could not load history — the response was unavailable or malformed.'
    default:
      return assertNeverAuditError(code)
  }
}

function assertNeverAuditError(v: never): never {
  throw new Error(`Unhandled audit error code: ${String(v)}`)
}
