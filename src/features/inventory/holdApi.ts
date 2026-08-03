import { supabase } from '../../lib/supabase'
import { HOLD_EMPTY, parseHold, type Hold } from './hold'

// ITEMS-HAVE-A-PLACE (0333) — typed client API for THE HOLD and for the one transfer verb.
// Mirrors salvageApi.ts / haulApi.ts conventions: thin wrappers; a transport/DB error resolves to a
// normalized fail-closed value, never a raw error thrown into the render path. The command is
// idempotent on (main_ship_id, request_id) — the client passes a fresh crypto.randomUUID() per
// intentional submit, so a retry after a dropped response replays instead of moving twice.
//
// There is exactly ONE read of the hold in the client (this file) and exactly ONE writer
// (transferItems). Nothing here computes a volume, an occupancy or a capacity.

/** The FLEET'S hold: carried stacks + the server's own used/capacity/free numbers.
 *
 *  0333 - the hold belongs to the ship's FLEET, not to the player: a fleet is in exactly one place
 *  at a time, which is why it and not the player is the unit of carrying. So the read takes the
 *  ship whose fleet's hold this is; null falls back to the server's sole-ship shim. There is no
 *  player-wide hold and there must never be one - it would teleport goods between fleets standing
 *  in different ports.
 *  Error / signed out / malformed -> HOLD_EMPTY (fail-closed; nothing renders, nothing invented). */
export async function fetchMyHold(mainShipId: string | null): Promise<Hold> {
  const { data, error } = await supabase.rpc('get_my_hold', { p_main_ship_id: mainShipId ?? null })
  if (error) return HOLD_EMPTY
  return parseHold(data)
}

/** Which way a stack moves. The server takes the same two literals and rejects anything else. */
export type TransferDirection = 'to_storage' | 'to_hold'

// transfer_items envelope (0333): success carries the receipted move (+ idempotent_replay on a
// same (ship, request_id) replay — replayed VERBATIM, nothing moved twice) and the hold's numbers
// AFTER the move; failure is REASON-keyed (transferReasonMessage maps the full vocabulary;
// insufficient_* also carry have/need, hold_over_capacity carries the volumes). Discriminated
// union so ok narrows cleanly.
export type TransferItemsResult =
  | {
      ok: true
      idempotent_replay?: boolean
      receipt_id: string
      direction: TransferDirection
      item_id: string
      qty: number
      volume_m3: number
      location_id: string | null
      hold_used_m3: number
      hold_capacity_m3: number
    }
  | {
      ok: false
      reason?: string
      item_id?: string
      have?: number
      need?: number
      qty?: number
      hold_used_m3?: number
      hold_capacity_m3?: number
      delta_m3?: number
      hold_free_m3?: number
      location_id?: string
    }

/**
 * Move a whole-item stack between the ship's hold and the storage of the port the ship is DOCKED
 * at. There is deliberately no location argument: the server derives the port from the ship's
 * validated dock, so a move against a port you are not docked at is not a request this surface can
 * express. Transport error → { ok:false, reason:'unavailable' } (fail-closed).
 */
export async function transferItems(
  mainShipId: string | null,
  direction: TransferDirection,
  itemId: string,
  quantity: number,
  requestId: string,
): Promise<TransferItemsResult> {
  const { data, error } = await supabase.rpc('transfer_items', {
    p_main_ship_id: mainShipId,
    p_direction: direction,
    p_item_id: itemId,
    p_quantity: quantity,
    p_request_id: requestId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as TransferItemsResult
}
