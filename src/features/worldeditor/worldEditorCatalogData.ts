// WORLD EDITOR — V5 LIFECYCLE: the ONE transport binding for the owner-only entity CATALOG read. Calls
// the deployed SECURITY DEFINER RPC public.world_editor_entity_catalog(p_payload jsonb) with
// {status:'all'} and normalizes the untrusted response through the PURE worldEditorCatalog model. This
// is the ONLY client catalog-read path; the pure normalization (fail-closed, drop malformed rows) is
// unit-tested with zero network. No write, no mutation — a READ that grants no authority (the server
// is_owner() guard is the sole authority).
import { supabase } from '../../lib/supabase'
import { normalizeCatalogRows, type WorldEditorCatalogRow } from './worldEditorCatalog'

/** Fetch the WHOLE lifecycle catalog ({status:'all'}) — BOTH active and inactive entities across all
 *  four domains — as the ONE nav/lifecycle index. A supabase transport error or a fail-closed server
 *  envelope degrades to NO rows (the editor renders honestly-sparse, never throws into render). */
export async function fetchWorldEditorCatalog(): Promise<WorldEditorCatalogRow[]> {
  const { data, error } = await supabase.rpc('world_editor_entity_catalog', {
    p_payload: { status: 'all' },
  })
  if (error) return []
  return normalizeCatalogRows(data)
}
