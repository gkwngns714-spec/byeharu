import { supabase } from '../../lib/supabase'
import {
  miningExtractErrorMessage,
  type CommandMiningExtractResult,
  type GetMyMiningExtractionsResult,
  type MiningField,
} from './miningTypes'

// MINING-P12 — typed client API for the dark mining surface: the extract command (0104) and the
// reveal-after-extraction read (0106). Mirrors explorationApi.ts/tradeApi.ts conventions: thin
// supabase.rpc wrappers; on a transport/DB error resolve to a normalized failure (never throw a
// raw error into the render path). DARK: the server rejects BOTH RPCs while mining_enabled is
// false (feature_disabled / mining_disabled) — visibility is server-driven, no client flag constant.

/** Extract from the nearest active field (idempotent on requestId; server-rejected while dark). */
export async function commandMiningExtract(
  mainShipId: string | null,
  requestId: string,
): Promise<CommandMiningExtractResult> {
  const { data, error } = await supabase.rpc('command_mining_extract', {
    p_main_ship_id: mainShipId,
    p_request_id: requestId,
  })
  if (error) return { ok: false, code: 'unavailable', message: miningExtractErrorMessage('unavailable') }
  return data as CommandMiningExtractResult
}

/** Read the caller's own extractions (server-rejected with mining_disabled while dark). */
export async function getMyMiningExtractions(): Promise<GetMyMiningExtractionsResult> {
  const { data, error } = await supabase.rpc('get_my_mining_extractions', {})
  if (error) return { ok: false, reason: 'unavailable' }
  return data as GetMyMiningExtractionsResult
}

/** MINING-FIELD-MARKERS — the active fields visible on the map (0226). A plain array, never an
 *  ok/reason envelope: the server already fails closed to [] while mining_enabled is false, and a
 *  transport/DB error collapses to the SAME empty result (the map's field layer just renders
 *  nothing — never a thrown error into the render path, the mapApi.ts convention). */
export async function getActiveMiningFields(): Promise<MiningField[]> {
  const { data, error } = await supabase.rpc('get_active_mining_fields', {})
  if (error) return []
  return (data as MiningField[]) ?? []
}
