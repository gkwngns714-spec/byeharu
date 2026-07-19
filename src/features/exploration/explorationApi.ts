import { supabase } from '../../lib/supabase'
import {
  explorationScanErrorMessage,
  type CommandExplorationScanResult,
  type GetMyExplorationDiscoveriesResult,
} from './explorationTypes'

// EXPLORATION-P11 — typed client API for the dark exploration surface: the scan command (0099/0100)
// and the reveal-after-discovery read (0101). Mirrors tradeApi.ts conventions: thin supabase.rpc
// wrappers; on a transport/DB error resolve to a normalized failure (never throw a raw error into
// the render path). DARK: the server rejects BOTH RPCs while exploration_enabled is false
// (feature_disabled / exploration_disabled) — visibility is server-driven, no client flag constant.

/** Scan for the nearest undiscovered site (idempotent on requestId; server-rejected while dark). */
export async function commandExplorationScan(
  mainShipId: string | null,
  requestId: string,
): Promise<CommandExplorationScanResult> {
  const { data, error } = await supabase.rpc('command_exploration_scan', {
    p_main_ship_id: mainShipId,
    p_request_id: requestId,
  })
  if (error) return { ok: false, code: 'unavailable', message: explorationScanErrorMessage('unavailable') }
  return data as CommandExplorationScanResult
}

/** Read the caller's own discoveries (server-rejected with exploration_disabled while dark). */
export async function getMyExplorationDiscoveries(): Promise<GetMyExplorationDiscoveriesResult> {
  const { data, error } = await supabase.rpc('get_my_exploration_discoveries', {})
  if (error) return { ok: false, reason: 'unavailable' }
  return data as GetMyExplorationDiscoveriesResult
}

/** WORLD EDITOR (read-only) — one visible exploration_sites row: position + name ONLY (never the
 *  reward_bundle_json composition). Mirrors mining's MiningField marker shape (§WE.8 twin-of-mining). */
export interface ExplorationSiteLite {
  name: string
  space_x: number
  space_y: number
}

/** WORLD EDITOR (read-only) — SELECT-only read of exploration_sites for the editor's Exploration
 *  layer. exploration_sites is RLS server-only (hidden until discovered, 0098), so this fails CLOSED
 *  to [] for a normal client — honest with §WE.8's "built LAST, dark and unproven" reality. NEVER a
 *  write: a plain `.select(...)`, and any transport/RLS error collapses to [] (the mapApi.ts
 *  never-throw-into-render convention). No new RPC, no migration — read-only foundation only. */
export async function getVisibleExplorationSites(): Promise<ExplorationSiteLite[]> {
  const { data, error } = await supabase
    .from('exploration_sites')
    .select('name, space_x, space_y')
  if (error || !Array.isArray(data)) return []
  return data as ExplorationSiteLite[]
}
