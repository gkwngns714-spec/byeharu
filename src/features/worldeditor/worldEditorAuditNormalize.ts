// WORLD EDITOR V1.5 — the runtime validation boundary for the audit reader. The RPC payload is treated
// as UNTRUSTED at the browser edge: this module validates the snake_case server envelope and normalizes
// it into the typed camelCase WorldEditorAuditResult. PURE (no React/DOM/supabase) — unit-testable.
//
// FAIL-CLOSED rules (V1.5 Phase C):
//   • A malformed envelope / item is a CONTROLLED failure ({ok:false,error:'transport_error'}), never a
//     thrown error into the World Editor shell.
//   • Unknown command/target values are PRESERVED as raw strings (never coerced into a known value).
//   • Redacted values are NEVER inferred.
//   • A FORBIDDEN server-only key (reward_bundle_json / created_by / actor) appearing in any snapshot
//     marks the whole response COMPROMISED → the normalizer fails closed (returns transport_error), it
//     does not merely strip-and-continue. The server field-filter is the boundary; this is defence in depth.
import {
  FORBIDDEN_SNAPSHOT_KEYS,
  type AuditSnapshot,
  type WorldEditorAuditCursor,
  type WorldEditorAuditEntry,
  type WorldEditorAuditErrorCode,
  type WorldEditorAuditFailureDetail,
  type WorldEditorAuditResult,
} from './worldEditorAuditTypes'

/** Internal-only normalization version. NOT a server field — never presented as if it came from the RPC. */
export const AUDIT_NORMALIZE_VERSION = 1 as const

const isObj = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)
const asStr = (v: unknown): string | null => (typeof v === 'string' ? v : null)

const KNOWN_ERROR_CODES: readonly WorldEditorAuditErrorCode[] = [
  'not_authenticated',
  'not_authorized',
  'invalid_request',
  'transport_error',
]

/** A controlled, typed failure — the ONLY thing this module ever "throws" outward. */
function fail(
  error: WorldEditorAuditErrorCode,
  details?: readonly WorldEditorAuditFailureDetail[],
): WorldEditorAuditResult {
  return details ? { ok: false, error, details } : { ok: false, error }
}
const malformed = (field: string): WorldEditorAuditResult =>
  fail('transport_error', [{ code: 'malformed_response', field }])

/** A sentinel a snapshot normalizer throws when a forbidden key is present, so the whole page fails closed. */
class ForbiddenFieldError extends Error {
  readonly key: string
  constructor(key: string) {
    super(`forbidden snapshot key present: ${key}`)
    this.key = key
  }
}

/** RECURSIVELY scan every nested object/array for a forbidden server-only KEY (values are never keys,
 *  so a redaction label string like "created_by" is not matched). Depth-bounded to avoid pathological
 *  inputs. Throws ForbiddenFieldError on the first hit → whole-page fail-closed. */
function scanForbiddenKeys(v: unknown, depth: number): void {
  if (depth > 64) return
  if (Array.isArray(v)) {
    for (const x of v) scanForbiddenKeys(x, depth + 1)
    return
  }
  if (isObj(v)) {
    for (const [k, val] of Object.entries(v)) {
      if ((FORBIDDEN_SNAPSHOT_KEYS as readonly string[]).includes(k)) throw new ForbiddenFieldError(k)
      scanForbiddenKeys(val, depth + 1)
    }
  }
}

function sanitizeSnapshot(v: unknown): AuditSnapshot | null {
  if (v === null || v === undefined || !isObj(v)) return null
  scanForbiddenKeys(v, 0)
  // shallow-freeze a copy so components can't accidentally mutate the record
  return Object.freeze({ ...v })
}

function normalizeCursor(v: unknown): WorldEditorAuditCursor | null {
  if (v === null || v === undefined || !isObj(v)) return null
  const ts = asStr(v.ts)
  const id = asStr(v.id)
  return ts && id ? { ts, id } : null
}

/** Returns a normalized entry, or null if the item is structurally malformed. Throws ForbiddenFieldError
 *  (caught by the caller → whole-page fail-closed) if a snapshot carries a server-only key. */
function normalizeEntry(v: unknown): WorldEditorAuditEntry | null {
  if (!isObj(v)) return null
  const id = asStr(v.id)
  const requestId = asStr(v.request_id)
  const commandType = asStr(v.command_type)
  const createdAt = asStr(v.created_at)
  if (!id || !requestId || !commandType || !createdAt) return null
  const redactions = Array.isArray(v.redactions)
    ? v.redactions.filter((x): x is string => typeof x === 'string')
    : []
  return {
    id,
    requestId,
    commandType,
    targetType: asStr(v.target_type),
    targetId: asStr(v.target_id),
    createdAt,
    sourceRevision: asStr(v.source_revision),
    result: isObj(v.result) ? Object.freeze({ ...v.result }) : null,
    actorIsOwner: v.actor_is_owner === true,
    before: sanitizeSnapshot(v.before),
    after: sanitizeSnapshot(v.after),
    redactions: Object.freeze(redactions),
  }
}

/**
 * Normalize a raw RPC response (already unwrapped from supabase's {data,error}) into a typed result.
 * `raw` is whatever the server returned — treat as untrusted. A supabase transport error is handled by
 * the caller (worldEditorAuditData) which passes a synthetic {ok:false,error:'transport_error'} here or
 * short-circuits; this function only validates a server-shaped payload.
 */
export function normalizeAuditResponse(raw: unknown): WorldEditorAuditResult {
  if (!isObj(raw) || typeof raw.ok !== 'boolean') return malformed('envelope')

  if (raw.ok === false) {
    const code = asStr(raw.error)
    const error: WorldEditorAuditErrorCode =
      code && (KNOWN_ERROR_CODES as readonly string[]).includes(code)
        ? (code as WorldEditorAuditErrorCode)
        : 'transport_error'
    const details = Array.isArray(raw.details)
      ? raw.details
          .filter(isObj)
          .map((d): WorldEditorAuditFailureDetail => ({ code: asStr(d.code) ?? 'unknown', field: asStr(d.field) }))
      : undefined
    return fail(error, details)
  }

  // success envelope
  if (!Array.isArray(raw.items)) return malformed('items')
  const pageSize = typeof raw.page_size === 'number' && Number.isFinite(raw.page_size) ? raw.page_size : null
  if (pageSize === null) return malformed('page_size')

  const items: WorldEditorAuditEntry[] = []
  try {
    for (const it of raw.items) {
      const entry = normalizeEntry(it)
      if (!entry) return malformed('item')
      items.push(entry)
    }
  } catch (e) {
    if (e instanceof ForbiddenFieldError) {
      // FAIL CLOSED: a server-only field reached the client — treat the whole response as compromised.
      return fail('transport_error', [{ code: 'forbidden_field_present', field: e.key }])
    }
    return malformed('item')
  }

  return {
    ok: true,
    pageSize,
    nextCursor: normalizeCursor(raw.next_cursor),
    items,
  }
}
