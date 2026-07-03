// EXPLORATION-P11 — PURE, framework-free types + player-facing copy for the dark exploration surface.
//
// Mirrors the server contracts exactly: command_exploration_scan's wrapper envelope (migrations
// 0099/0100) and get_my_exploration_discoveries' rows (0101). No React/DOM/fetch here (the
// spaceStopCommand.ts idiom). DARK: the server rejects every exploration RPC while
// exploration_enabled is false; the panel renders nothing on that envelope — the UI is never the
// control (fail-closed law), and no client-side flag constant gates visibility (server-driven).

export interface PendingBundleItem {
  item_id: string
  quantity: number
}
/** The pending-bundle shape ({ metal?, items[] }) — the 0040/0041 reward-bundle contract. */
export interface PendingBundle {
  metal?: number
  items?: PendingBundleItem[]
}

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

/** The dark read-reason token (0087 read idiom): the panel renders nothing on this envelope. */
export const EXPLORATION_DISABLED_REASON = 'exploration_disabled' as const

// ── Scan-enabled predicate ────────────────────────────────────────────────────────────────────────
// Scan is legal only for a SETTLED in-space ship (0055 model: spatial_state 'in_space' ⇔
// status 'stationary'). This predicate only drives the button's enabled state — the server remains
// authoritative and rejects everything else with not_in_space.
export function isSettledInSpace(input: {
  spatialState: string | null | undefined
  status: string | null | undefined
}): boolean {
  return input.spatialState === 'in_space' && input.status === 'stationary'
}

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
