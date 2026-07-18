// MINING-P12 — PURE, framework-free types + player-facing copy for the dark mining surface.
//
// Mirrors the server contracts exactly: command_mining_extract's wrapper envelope (migration
// 0104) and get_my_mining_extractions' rows (0106). No React/DOM/fetch here (the
// spaceStopCommand.ts idiom). DARK: the server rejects every mining RPC while mining_enabled is
// false; the panel renders nothing on that envelope — the UI is never the control (fail-closed
// law), and no client-side flag constant gates visibility (server-driven).
//
// Shared contracts live in src/lib: the pending-bundle shape (rewardBundle.ts) and the
// settled-in-space predicate (osnState.ts) — one copy each, never re-declared here.

import type { PendingBundle } from '../../lib/rewardBundle'

/** One row of get_my_mining_extractions() (0106). secured_at null = deposit still pending. */
export interface MiningExtraction {
  extraction_id: string
  field_name: string
  space_x: number
  space_y: number
  extracted_at: string
  secured_at: string | null
  bundle: PendingBundle
}

export type GetMyMiningExtractionsResult =
  | { ok: true; extractions: MiningExtraction[] }
  | { ok: false; reason: string }

/** MINING-FIELD-MARKERS: one row of get_active_mining_fields() (0226) — position + name ONLY, never
 *  reward_bundle_json (composition stays revealed only via get_my_mining_extractions above). The
 *  server returns a plain jsonb array, [] while mining is disabled (fail-closed gate, not an ok/
 *  reason envelope — there is no caller-specific failure to report). */
export interface MiningField {
  name: string
  space_x: number
  space_y: number
}

// The server's narrow extract result contract (mirrors command_mining_extract's wrapper).
// retry_after_seconds is REAL server data, present only on the 'cooldown' failure (0104).
export type CommandMiningExtractResult =
  | {
      ok: true
      extraction_id: string
      field_id: string
      name: string
      space_x: number
      space_y: number
      pending_bundle: PendingBundle
      extracted_at: string
    }
  | { ok: false; code: string; message: string; retry_after_seconds?: number }

// Player-facing copy for the narrow code set command_mining_extract's wrapper can return (0104),
// same tone as the OSN command copy (spaceStopCommand.ts). The server's message is preferred when
// present; this map is the client-side fallback.
const EXTRACT_ERROR_COPY: Record<string, string> = {
  feature_disabled: 'Mining is not available yet.',
  invalid_request: 'Invalid command request.',
  request_conflict: 'This command was already used.',
  no_ship: 'You do not have a main ship.',
  ship_destroyed: 'The ship must be repaired first.',
  not_in_space: 'The ship must be stopped in open space to extract.',
  busy_legacy: 'Finish the current expedition first.',
  no_field_in_range: 'No mineable field within extractor range.',
  cooldown: 'This field was mined too recently. Try again shortly.',
  not_authenticated: 'You must be signed in.',
  unavailable: 'The ship cannot extract right now.',
}
export function miningExtractErrorMessage(code: string): string {
  return EXTRACT_ERROR_COPY[code] ?? EXTRACT_ERROR_COPY.unavailable
}
