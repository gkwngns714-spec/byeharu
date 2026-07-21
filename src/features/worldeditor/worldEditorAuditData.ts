// WORLD EDITOR V1.5 — the ONE transport binding for the owner-only audit reader. Calls the deployed
// SECURITY DEFINER RPC public.world_editor_audit_list(p_payload jsonb) and normalizes the untrusted
// response. This is the ONLY client audit-read path — there is NO direct world_editor_audit table read
// anywhere (the ledger is RLS deny-all). No service-role, no write, no mutation.
import { supabase } from '../../lib/supabase'
import { normalizeAuditResponse } from './worldEditorAuditNormalize'
import type { WorldEditorAuditFilters, WorldEditorAuditResult } from './worldEditorAuditTypes'

/** Build the snake_case RPC payload from typed filters — only server-supported keys, undefined omitted. */
function toPayload(f: WorldEditorAuditFilters): Record<string, unknown> {
  const p: Record<string, unknown> = {}
  if (f.commandType) p.command_type = f.commandType
  if (f.targetType) p.target_type = f.targetType
  if (f.targetId) p.target_id = f.targetId
  if (f.requestId) p.request_id = f.requestId
  if (f.since) p.since = f.since
  if (f.until) p.until = f.until
  if (typeof f.limit === 'number') p.limit = f.limit
  if (f.cursor) p.cursor = { ts: f.cursor.ts, id: f.cursor.id }
  return p
}

/** Fetch one page of the owner audit ledger. A supabase transport error folds to a typed
 *  transport_error; a server-shaped payload goes through the fail-closed normalizer. */
export async function fetchWorldEditorAudit(
  filters: WorldEditorAuditFilters = {},
): Promise<WorldEditorAuditResult> {
  const { data, error } = await supabase.rpc('world_editor_audit_list', { p_payload: toPayload(filters) })
  if (error) return { ok: false, error: 'transport_error' }
  return normalizeAuditResponse(data)
}
