import { supabase } from '../../lib/supabase'
import type { GetWorldEventsResult } from './eventsTypes'

// PHASE20-POLISH — typed client API for the dark World Events read surface (get_world_events, 0141).
// Mirrors explorationApi.ts conventions: a thin supabase.rpc wrapper; on a transport/DB error resolve
// to a normalized fail-closed value ({ ok:false }) — never throw a raw error into the render path.
// DARK: while phase20_polish_enabled is false the server returns { ok:true, events:[] } (empty feed) —
// visibility is server-driven, no client flag constant.

/**
 * Read the currently-live, in-scope world events. This minimal cut requests GLOBAL-scope events only
 * (p_location_id / p_zone_id null) — always map-relevant, no coupling to selected-location state. The
 * server empties the feed while dark and applies the live-window + scope filter when lit.
 */
export async function getWorldEvents(): Promise<GetWorldEventsResult> {
  const { data, error } = await supabase.rpc('get_world_events', {
    p_location_id: null,
    p_zone_id: null,
  })
  if (error) return { ok: false }
  return data as GetWorldEventsResult
}
