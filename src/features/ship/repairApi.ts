import { supabase } from '../../lib/supabase'
import type { ShipHull } from './repairEconomy'

// ONE WAY TO REPAIR (0335) — the typed client API for THE repair verb.
//
// There is exactly one repair RPC now (repair_ship_hull) and exactly one wrapper for it, here.
// Migration 0335 dropped both predecessors: repair_main_ship (free wreck recovery, which threw, and
// whose wrapper lived in features/map/mainshipApi.ts) and repair_ship_hull_at_port (the paid mend).
// They were one concept with two implementations, two position authorities and two error protocols;
// the surviving one is envelope-returning and never raises, so every outcome — wreck recovery or
// paid mend — flows through the ONE repairReasonMessage map.
//
// Also here: the flag/knob read (public-read game_config, 0003 — the getSalvageConfigRows posture)
// and the chosen ship's hull read (owner-read RLS on main_ship_instances, 0043). Thin wrappers; on
// a transport/DB error resolve to a normalized fail-closed value, never a throw into the render
// path. repair_economy_enabled gates the PRICED mend only — a wreck's recovery is never gated and
// never charged (the 0052 no-softlock rule, now stated once, in the server body).

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

// repair_ship_hull envelope (0335): success carries the receipted restore (+ idempotent_replay on a
// same (ship, request_id) replay — replayed VERBATIM, no re-debit/re-heal) and `recovered` for the
// wreck case, which also carries the ship's new status. Failure is REASON-keyed (repairReasonMessage
// maps the full vocabulary; insufficient_credits also carries price/hp_restored). Discriminated
// union so ok narrows cleanly. `receipt_id` is null only when the hull did not move (a wreck already
// at full hull that needed nothing but its status flip).
export type RepairResult =
  | {
      ok: true
      idempotent_replay?: boolean
      /** true when this call recovered a DISABLED ship (free, whole-hull, status back to 'home'). */
      recovered?: boolean
      status?: string
      receipt_id: string | null
      main_ship_id: string
      hp_before: number
      hp_after: number
      max_hp?: number
      hp_restored: number
      credits_per_hp: number
      total_price: number
      location_id: string | null
    }
  | { ok: false; reason?: string; price?: number; hp_restored?: number; credits_per_hp?: number }

/**
 * THE repair command. Restores a hull at the port the ship resolves to (mainship_port_of_ship —
 * fleet dock, then group dock, then berth: one authority, so the button and the server can never
 * disagree about where a ship is).
 *
 * `repairHp` null means "restore everything missing"; a number is CLAMPED server-side to the actual
 * missing hull, so an over-request tops up to max_hp and never over-charges. A DISABLED ship ignores
 * the amount entirely — recovery restores the whole hull, free, and is never gated by the economy
 * flag or the price knob.
 *
 * `requestId` is the replay key and is REQUIRED: pass a fresh crypto.randomUUID() per intentional
 * submit. Transport error → { ok:false, reason:'unavailable' } (fail-closed).
 */
export async function repairShipHull(
  mainShipId: string | null,
  repairHp: number | null,
  requestId: string,
): Promise<RepairResult> {
  const { data, error } = await supabase.rpc('repair_ship_hull', {
    p_main_ship_id: mainShipId,
    p_repair_hp: repairHp,
    p_request_id: requestId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as RepairResult
}
