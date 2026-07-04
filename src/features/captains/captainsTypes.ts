// CAPTAIN-P15 (post-audit UI, panel 3 of 4) — PURE, framework-free types + player-facing copy for the
// dark Captains (assign/unassign) surface.
//
// Mirrors the server contracts exactly: get_my_captain_instances() (migration 0123) and the
// assign_captain_to_ship / unassign_captain_from_ship wrappers (0120, settled-safe rule 0121). No
// React/DOM/fetch here (the miningTypes.ts idiom). NOTE: this whole surface is REASON-keyed, NOT
// code-keyed (0120/0123 locked decision) — the dark envelope is { ok:false, reason:'captain_assignment_
// disabled' }. DARK: while captain_assignment_enabled is false every RPC returns that reason, so the
// panel renders nothing — the UI is never the control (fail-closed law), no client flag constant.

/** One row of get_my_captain_instances().captains (0123). main_ship_id = the assigned ship, or null
 *  when the captain is unassigned (the per-row roster indicator). */
export interface CaptainInstance {
  instance_id: string
  captain_type_id: string
  name: string
  specialization: string
  stats_json: Record<string, number>
  main_ship_id: string | null
  created_at: string
}

// get_my_captain_instances() envelope (0123): lit → { ok:true, captains:[...] }; dark → { ok:false,
// reason:'captain_assignment_disabled' }; not-authed → { ok:false, reason:'not_authenticated' };
// transport error → { ok:false }. Discriminated union (the miningTypes.ts idiom) so isServerLit()
// narrows the { ok:true } member cleanly. `captains` optional so a defensive `?? []` read is well-typed.
export type GetMyCaptainInstancesResult =
  | { ok: true; captains?: CaptainInstance[] }
  | { ok: false; reason?: string }

// assign_captain_to_ship / unassign_captain_from_ship wrapper envelopes (0120): success carries the
// action + ids (+ idempotent_replay on a same (player, request_id) replay); failure is REASON-keyed with
// a server message (the 0120/0121 mapper). Same shape for both commands.
export type AssignCaptainResult =
  | { ok: true; action: string; captain_instance_id: string; main_ship_id: string | null; idempotent_replay?: boolean }
  | { ok: false; reason?: string; message?: string }

export type UnassignCaptainResult =
  | { ok: true; action: string; captain_instance_id: string; main_ship_id: string | null; idempotent_replay?: boolean }
  | { ok: false; reason?: string; message?: string }

// Player-facing copy for the EXACT client-visible reason set both wrappers can return, enumerated from
// 0120 + 0121 (the captain_command_client_envelope mapper + the wrapper gates):
//   captain_assignment_disabled (dark; no server message) · not_authenticated · invalid_request
//   (invalid_request_id is mapped to this) · ship_not_settled (0121 settled-safe rule) · captain_not_owned
//   · ship_not_owned · already_assigned · captain_slots_full · not_assigned · unavailable (fallback).
// PREFERS the server `message` when present (the 0120 envelopes carry one for every non-dark failure),
// then falls back to this map — mirroring miningExtractErrorMessage. 'unavailable' is the last resort.
const CAPTAIN_COMMAND_ERROR_COPY: Record<string, string> = {
  captain_assignment_disabled: 'Captains are not available yet.',
  not_authenticated: 'You must be signed in.',
  invalid_request: 'Invalid command request.',
  ship_not_settled: 'The ship must be settled at home or docked to change its captain roster.',
  captain_not_owned: 'That captain is not in your possession.',
  ship_not_owned: 'That ship is not yours.',
  already_assigned: 'That captain is already assigned to a ship. Unassign them first.',
  captain_slots_full: 'No free captain slots on this ship.',
  not_assigned: 'That captain is not assigned to any ship.',
  unavailable: 'Captain assignment is unavailable right now.',
}
export function captainCommandErrorMessage(res: { reason?: string; message?: string }): string {
  return (
    res.message ??
    CAPTAIN_COMMAND_ERROR_COPY[res.reason ?? 'unavailable'] ??
    CAPTAIN_COMMAND_ERROR_COPY.unavailable
  )
}
