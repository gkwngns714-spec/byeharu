// EXPLORATION-P11 — PURE, framework-free types + player-facing copy for the dark exploration surface.
//
// Mirrors the server contracts exactly: command_exploration_scan's wrapper envelope (migrations
// 0099/0100) and get_my_exploration_discoveries' rows (0101). No React/DOM/fetch here (the
// spaceStopCommand.ts idiom). DARK: the server rejects every exploration RPC while
// exploration_enabled is false; the panel renders nothing on that envelope — the UI is never the
// control (fail-closed law), and no client-side flag constant gates visibility (server-driven).

import type { PendingBundle } from '../../lib/rewardBundle'

/** One row of get_my_exploration_discoveries() (0101). secured_at null = deposit still pending. */
export interface ExplorationDiscovery {
  discovery_id: string
  site_name: string
  space_x: number
  space_y: number
  discovered_at: string
  secured_at: string | null
  bundle: PendingBundle
}

export type GetMyExplorationDiscoveriesResult =
  | { ok: true; discoveries: ExplorationDiscovery[] }
  | { ok: false; reason: string }

/** WORLD EDITOR (read-only) — one visible exploration_sites row: position + name ONLY (never the
 *  reward_bundle_json composition). Mirrors mining's MiningField marker shape (§WE.8
 *  twin-of-mining). Lives HERE (the pure types module, the MiningField-in-miningTypes layout) so
 *  pure world-editor modules can bind to the read contract without touching the supabase client;
 *  explorationApi re-exports it for its read function's callers. */
export interface ExplorationSiteLite {
  name: string
  space_x: number
  space_y: number
}

// The server's narrow scan result contract (mirrors command_exploration_scan's wrapper).
export type CommandExplorationScanResult =
  | {
      ok: true
      site_id: string
      name: string
      space_x: number
      space_y: number
      pending_bundle: PendingBundle
      discovered_at: string
    }
  | { ok: false; code: string; message: string }

// The scan-enabled predicate (settled in space, 0055 model) lives in the shared
// src/lib/osnState.ts — one copy for every OSN-native activity surface.

// Player-facing copy for the narrow code set command_exploration_scan's wrapper can return (0099),
// same tone as the OSN command copy (spaceStopCommand.ts). The server's message is preferred when
// present; this map is the client-side fallback.
const SCAN_ERROR_COPY: Record<string, string> = {
  feature_disabled: 'Exploration is not available yet.',
  invalid_request: 'Invalid command request.',
  request_conflict: 'This command was already used.',
  no_ship: 'You do not have a main ship.',
  ship_destroyed: 'The ship must be repaired first.',
  not_in_space: 'The ship must be stopped in open space to scan.',
  busy_legacy: 'Finish the current expedition first.',
  no_site_in_range: 'No signal detected within scanner range.',
  already_discovered: 'Every signal in range has already been discovered.',
  not_authenticated: 'You must be signed in.',
  unavailable: 'The ship cannot scan right now.',
}
export function explorationScanErrorMessage(code: string): string {
  return SCAN_ERROR_COPY[code] ?? SCAN_ERROR_COPY.unavailable
}
