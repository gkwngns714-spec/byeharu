import { supabase } from '../../lib/supabase'
import type {
  AssignCaptainResult,
  GetMyCaptainInstancesResult,
  UnassignCaptainResult,
} from './captainsTypes'

// CAPTAIN-P15 (post-audit UI, panel 3 of 4) — typed client API for the dark Captains surface: the roster
// read (get_my_captain_instances, 0123) + the two assign/unassign commands (0120/0121). Mirrors
// miningApi.ts conventions: thin supabase.rpc wrappers; on a transport/DB error resolve to a normalized
// fail-closed value (never throw a raw error into the render path). Reads ONLY the roster RPC and submits
// ONLY the two existing commands — NO new server authority. The wrapper request_id param is TEXT, so the
// client passes a crypto.randomUUID() STRING (36 chars — inside the server's length cap). DARK: the
// server rejects every RPC while captain_assignment_enabled is false (captain_assignment_disabled).

/** Read the caller's captain roster (each row carries its assigned main_ship_id or null). Dark →
 *  { ok:false, reason:'captain_assignment_disabled' }; transport error → { ok:false } (fail-closed). */
export async function getMyCaptainInstances(): Promise<GetMyCaptainInstancesResult> {
  const { data, error } = await supabase.rpc('get_my_captain_instances', {})
  if (error) return { ok: false }
  return data as GetMyCaptainInstancesResult
}

/** Assign a captain to the player's main ship (idempotent on (player, request_id); server-authoritative
 *  on ownership/slots/settled-safe). request_id is TEXT. Transport error → { ok:false, reason:'unavailable' }. */
export async function assignCaptainToShip(
  requestId: string,
  captainInstanceId: string,
  mainShipId: string,
): Promise<AssignCaptainResult> {
  const { data, error } = await supabase.rpc('assign_captain_to_ship', {
    p_request_id: requestId,
    p_captain_instance_id: captainInstanceId,
    p_main_ship_id: mainShipId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as AssignCaptainResult
}

/** Unassign a captain from its ship (idempotent on (player, request_id)). request_id is TEXT.
 *  Transport error → { ok:false, reason:'unavailable' } (fail-closed). */
export async function unassignCaptainFromShip(
  requestId: string,
  captainInstanceId: string,
): Promise<UnassignCaptainResult> {
  const { data, error } = await supabase.rpc('unassign_captain_from_ship', {
    p_request_id: requestId,
    p_captain_instance_id: captainInstanceId,
  })
  if (error) return { ok: false, reason: 'unavailable' }
  return data as UnassignCaptainResult
}
