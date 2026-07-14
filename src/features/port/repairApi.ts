import { supabase } from '../../lib/supabase'
import type { ShipHull } from './repairEconomy'

// REPAIR-ECON — typed client API for the dark paid hull-repair desk: the flag/knob read (public-read
// game_config, 0003 — the getSalvageConfigRows posture), the chosen ship's hull read (owner-read RLS on
// main_ship_instances, 0043 — the useMainShipSelection posture), and the ONE repair command
// (repair_ship_hull_at_port, 0201). Mirrors salvageApi.ts conventions: thin wrappers; on a transport/DB
// error resolve to a normalized fail-closed value (never throw a raw error into the render path). The
// command is idempotent on (main_ship_id, request_id) — the client passes a fresh crypto.randomUUID()
// per intentional submit. DARK: the server rejects the repair RPC while repair_economy_enabled is false
// (repair_economy_disabled, gate FIRST before any read); the panel gates itself on the SAME server flag
// read honestly from game_config — flag false → the panel renders null and never reads a hull.

/** Read the repair gate + the cost knob + the wallet-honesty seed from PUBLIC-READ game_config (one
 *  select — the getSalvageConfigRows shape). Error → [] so repairConfigFromRows fails closed (dark). */
export async function getRepairConfigRows(): Promise<Array<{ key: string; value: unknown }>> {
  const { data, error } = await supabase
    .from('game_config')
    .select('key, value')
    .in('key', ['repair_economy_enabled', 'repair_credits_per_hp', 'starting_credits'])
  if (error) return []
  return (data ?? []) as Array<{ key: string; value: unknown }>
}

/** Owner-read the chosen ship's hull snapshot (hp, max_hp, status) via RLS on main_ship_instances
 *  (0043 owner-read; the useMainShipSelection direct-select posture). null = ship unreadable / not
 *  found (fail-closed; the panel shows an honest unavailable line, never a false full bar). */
export async function getShipHull(mainShipId: string): Promise<ShipHull | null> {
  const { data, error } = await supabase
    .from('main_ship_instances')
    .select('hp, max_hp, status')
    .eq('main_ship_id', mainShipId)
    .maybeSingle()
  if (error || !data) return null
  const r = data as { hp: number | string; max_hp: number | string; status: string }
  return { hp: Number(r.hp) || 0, maxHp: Number(r.max_hp) || 0, status: r.status }
}

// repair_ship_hull_at_port envelope (0201): success carries the receipted mend (+ idempotent_replay on
// a same (ship, request_id) replay — replayed VERBATIM, no re-debit/re-heal); failure is REASON-keyed
// (repairReasonMessage maps the full vocabulary; insufficient_credits also carries price/hp_restored).
// Discriminated union so ok narrows cleanly.
export type RepairResult =
  | {
      ok: true
      idempotent_replay?: boolean
      receipt_id: string
      main_ship_id: string
      hp_before: number
      hp_after: number
      hp_restored: number
      credits_per_hp: number
      total_price: number
      location_id: string | null
    }
  | { ok: false; reason?: string; price?: number; hp_restored?: number; credits_per_hp?: number }

/** Repair a docked, damaged-but-alive ship's hull for credits (server-authoritative on flag/ownership/
 *  destroyed-seam/dock/missing/knob/wallet; wallet_debit + hp heal + receipt atomic under the per-ship
 *  lock). p_repair_hp is CLAMPED server-side to the actual missing hull (over-request tops up to max_hp,
 *  never over-charges). Transport error → { ok:false, reason:'unavailable' } (fail-closed). */
export async function repairShipHullAtPort(
  mainShipId: string,
  repairHp: number,
  requestId: string,
): Promise<RepairResult> {
  const { data, error } = await supabase.rpc('repair_ship_hull_at_port', {
    p_main_ship_id: mainShipId,
    p_repair_hp: repairHp,
    p_request_id: requestId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as RepairResult
}
