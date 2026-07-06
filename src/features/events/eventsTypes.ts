// PHASE20-POLISH — PURE, framework-free types for the dark World Events display surface.
//
// Mirrors the server contract exactly: get_world_events' row shape (migration 0141). No
// React/DOM/fetch here (the explorationTypes.ts idiom). DARK: while phase20_polish_enabled is false
// the server returns { ok:true, events:[] } (the flag gate empties the feed server-side), so the panel
// renders nothing — the UI is never the control (fail-closed law), and no client-side flag constant
// gates visibility (server-driven).

export type WorldEventSeverity = 'info' | 'warning' | 'critical'

/** One row of get_world_events() (0141). Purely presentational world info. */
export interface WorldEvent {
  id: string
  event_type: string
  scope: string
  zone_id: string | null
  location_id: string | null
  title: string
  body: string | null
  severity: WorldEventSeverity
  starts_at: string
  ends_at: string | null
}

// get_world_events() envelope (0141): dark → { ok:true, events:[] }; transport error → { ok:false }.
// A DISCRIMINATED union (the explorationTypes.ts idiom), NOT a flat { ok:boolean; events? } — so the
// shared isServerLit() guard narrows to the { ok:true } member cleanly (a flat shape would Extract to
// `never`). Runtime shape is identical; the panel's fail-closed check reads the same.
export type GetWorldEventsResult =
  | { ok: true; events?: WorldEvent[] }
  | { ok: false }
