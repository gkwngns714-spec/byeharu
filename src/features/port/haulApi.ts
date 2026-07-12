import { supabase } from '../../lib/supabase'
import type { GetPortContractsResult } from './haulBoard'

// HAUL-3 — typed client API for the dark port bulletin: the board read (get_port_contracts, 0181)
// + the two existing HAUL-2 commands (haul_accept_contract / haul_deliver_contract, 0179). Mirrors
// captainsApi.ts / tradeApi.ts conventions: thin supabase.rpc wrappers; on a transport/DB error
// resolve to a normalized fail-closed value (never throw a raw error into the render path). Reads
// ONLY the board RPC and submits ONLY the two existing commands — NO new server authority. Both
// commands are idempotent on (main_ship_id, request_id) — the client passes a fresh
// crypto.randomUUID() per intentional submit (uuid params, unlike the captains TEXT wrappers).
// DARK: the server rejects every RPC while haul_contracts_enabled is false
// (haul_contracts_disabled), so the panel renders nothing — the UI is never the control.

/** Read the docked port's bulletin (fresh offers + the caller's accepted contracts). Dark →
 *  { ok:false, reason:'haul_contracts_disabled' }; transport error → { ok:false } (fail-closed). */
export async function getPortContracts(locationId: string): Promise<GetPortContractsResult> {
  const { data, error } = await supabase.rpc('get_port_contracts', { p_location: locationId })
  if (error) return { ok: false }
  return data as GetPortContractsResult
}

// haul_accept_contract / haul_deliver_contract envelopes (0179): success carries the receipted
// action (+ idempotent_replay on a same (ship, request_id) replay); failure is REASON-keyed
// (haulReasonMessage maps the full vocabulary). Same discriminated shape for both commands.
export type HaulCommandResult =
  | {
      ok: true
      idempotent_replay?: boolean
      receipt_id: string
      contract_id: string
      action: string
      good_id: string
      quantity: number
      reward_credits: number
      contract_reward_credits?: number
      dest_location_id?: string
      deliver_by?: string
      location_id: string
      cost_basis_consumed?: number
    }
  | { ok: false; reason?: string; active?: number; max?: number; available?: number; need?: number }

/** Accept an offered contract at the docked origin port (a CLAIM — moves no cargo/credits; the
 *  server sets deliver_by). Transport error → { ok:false, reason:'unavailable' } (fail-closed). */
export async function haulAcceptContract(
  mainShipId: string,
  contractId: string,
  requestId: string,
): Promise<HaulCommandResult> {
  const { data, error } = await supabase.rpc('haul_accept_contract', {
    p_main_ship_id: mainShipId,
    p_contract_id: contractId,
    p_request_id: requestId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as HaulCommandResult
}

/** Deliver an accepted contract at its destination port (server-authoritative on dock/deadline/
 *  cargo; consume + credit + receipt atomic). Transport error → { ok:false, reason:'unavailable' }. */
export async function haulDeliverContract(
  mainShipId: string,
  contractId: string,
  requestId: string,
): Promise<HaulCommandResult> {
  const { data, error } = await supabase.rpc('haul_deliver_contract', {
    p_main_ship_id: mainShipId,
    p_contract_id: contractId,
    p_request_id: requestId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as HaulCommandResult
}
