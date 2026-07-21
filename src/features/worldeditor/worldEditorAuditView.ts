// WORLD EDITOR V1.5 — pure display helpers for the audit History UI. No React/DOM. Unknown command/
// target values are shown as `Unsupported: <value>` (never coerced). "Inactive/unpublished" is derived
// from the sanitized `after` snapshot only.
import {
  isKnownAuditCommandType,
  isKnownAuditTargetType,
  type WorldEditorAuditEntry,
} from './worldEditorAuditTypes'

export const safeCommandLabel = (c: string): string =>
  isKnownAuditCommandType(c) ? c : `Unsupported: ${c}`

export const safeTargetLabel = (t: string | null): string =>
  t == null ? '—' : isKnownAuditTargetType(t) ? t : `Unsupported: ${t}`

/** Whether the record's RESULTING (after) state is inactive/unpublished, from the sanitized snapshot. */
export function deriveInactive(entry: WorldEditorAuditEntry): boolean {
  const a = entry.after
  if (!a) return false
  return a.status === 'inactive' || a.is_active === false
}

/** A short, safe display of a uuid-ish id for the list (never load-bearing UI). */
export const shortId = (id: string | null): string =>
  id ? (id.length > 10 ? `${id.slice(0, 8)}…` : id) : '—'

/** A compact, human timestamp (falls back to the raw string if unparseable — never throws). */
export function formatAuditTime(iso: string): string {
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return iso
  return new Date(t).toISOString().replace('T', ' ').replace(/\.\d+Z$/, 'Z')
}

/** A one-line summary of the typed `result` payload (e.g. "created", "unpublished"). */
export function summarizeResult(result: Readonly<Record<string, unknown>> | null): string {
  if (!result) return '—'
  for (const verb of ['created', 'updated', 'unpublished', 'set_active']) {
    if (result[verb] === true) return verb
  }
  return Object.keys(result).length > 0 ? 'ok' : '—'
}

/** Append a fresh page to the accumulated list, dropping any entry whose id is already present. Pure —
 *  guarantees keyset pagination never yields duplicate rows even if a page overlaps the previous cursor. */
export function mergePageDedup(
  prev: readonly WorldEditorAuditEntry[],
  incoming: readonly WorldEditorAuditEntry[],
): WorldEditorAuditEntry[] {
  const seen = new Set(prev.map((e) => e.id))
  const out: WorldEditorAuditEntry[] = [...prev]
  for (const e of incoming) {
    if (seen.has(e.id)) continue // dedup against prior pages AND within this page; order stays stable
    seen.add(e.id)
    out.push(e)
  }
  return out
}
