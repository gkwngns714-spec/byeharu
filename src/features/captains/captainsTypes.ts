// CAPTAIN-P15 (post-audit UI, panel 3 of 4) — PURE, framework-free types + player-facing copy for the
// dark Captains (assign/unassign) surface.
//
// Mirrors the server contracts exactly: get_my_captain_instances() (migration 0123) and the
// assign_captain_to_ship / unassign_captain_from_ship wrappers (0120, settled-safe rule 0121). No
// React/DOM/fetch here (the miningTypes.ts idiom). NOTE: this whole surface is REASON-keyed, NOT
// code-keyed (0120/0123 locked decision) — the dark envelope is { ok:false, reason:'captain_assignment_
// disabled' }. DARK: while captain_assignment_enabled is false every RPC returns that reason, so the
// panel renders nothing — the UI is never the control (fail-closed law), no client flag constant.

/** One row of get_my_captain_instances().captains (0123; xp/level added by the 0181 C2-3
 *  projection hunk; station added by the 0189 DECKS-1 hunk). main_ship_id = the assigned ship, or
 *  null when the captain is unassigned (the per-row roster indicator). xp/level are OPTIONAL (a
 *  pre-0181 envelope lacks them) and are 0/1 everywhere while captain_growth_enabled is false —
 *  the CaptainXpBar renders nothing then. station is OPTIONAL likewise (a pre-0189 envelope lacks
 *  it): the held deck station id (ship_stations), or null when unassigned / general quarters. */
export interface CaptainInstance {
  instance_id: string
  captain_type_id: string
  name: string
  specialization: string
  stats_json: Record<string, number>
  xp?: number
  level?: number
  main_ship_id: string | null
  station?: string | null
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
// action + ids (+ idempotent_replay on a same (player, request_id) replay; + the additive DECKS-1
// `station` — the deck station taken, explicit or server-auto-picked; null on unassign and absent
// on a pre-0189 envelope); failure is REASON-keyed with a server message (the 0120/0121/0189
// mapper). Same shape for both commands.
export type AssignCaptainResult =
  | { ok: true; action: string; captain_instance_id: string; main_ship_id: string | null; station?: string | null; idempotent_replay?: boolean }
  | { ok: false; reason?: string; message?: string }

export type UnassignCaptainResult =
  | { ok: true; action: string; captain_instance_id: string; main_ship_id: string | null; station?: string | null; idempotent_replay?: boolean }
  | { ok: false; reason?: string; message?: string }

// Player-facing copy for the EXACT client-visible reason set both wrappers can return, enumerated from
// 0120 + 0121 (the captain_command_client_envelope mapper + the wrapper gates):
//   captain_assignment_disabled (dark; no server message) · not_authenticated · invalid_request
//   (invalid_request_id is mapped to this) · ship_not_settled (0121 settled-safe rule) · captain_not_owned
//   · ship_not_owned · already_assigned · captain_slots_full · not_assigned · unknown_station ·
//   station_occupied · no_free_station (the 0189 DECKS-1 station reasons) · unavailable (fallback).
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
  unknown_station: 'That deck station does not exist.',
  station_occupied: 'That deck station is already held. Free it first.',
  no_free_station: 'Every deck station on this ship is occupied.',
  unavailable: 'Captain assignment is unavailable right now.',
}
export function captainCommandErrorMessage(res: { reason?: string; message?: string }): string {
  return (
    res.message ??
    CAPTAIN_COMMAND_ERROR_COPY[res.reason ?? 'unavailable'] ??
    CAPTAIN_COMMAND_ERROR_COPY.unavailable
  )
}

// ── ROOMS-8 (0203): the configurable room-slot surface — the read + the config command envelopes ───
// get_my_ship_room_slots(p_main_ship_id) → lit: { ok:true, slots:[...] }; dark: { ok:false,
// reason:'captain_assignment_disabled' } (rooms ride the SAME captain gate); not-owned/not-authed
// their own reasons; transport error → { ok:false }. The slot rows are ShipRoomSlot (deckStations.ts).
export type GetShipRoomSlotsResult =
  | { ok: true; slots?: import('./deckStations').ShipRoomSlot[] }
  | { ok: false; reason?: string }

// configure_ship_room(p_main_ship_id, p_slot_index, p_room_type_id) → success echoes the placed
// room; failure is REASON-keyed with a server message (the 0203 wrapper mapper). REASONS (enumerated
// from 0203): captain_assignment_disabled (dark) · not_authenticated · ship_not_settled ·
// ship_not_owned · invalid_slot · unknown_slot · unknown_room · room_duplicate · room_occupied ·
// unavailable (transport fallback).
export type ConfigureRoomResult =
  | { ok: true; main_ship_id: string; slot_index: number; room_type_id: string }
  | { ok: false; reason?: string; message?: string }

const ROOM_CONFIG_ERROR_COPY: Record<string, string> = {
  captain_assignment_disabled: 'Rooms are not available yet.',
  not_authenticated: 'You must be signed in.',
  ship_not_settled: 'The ship must be settled at home or docked to change its rooms.',
  ship_not_owned: 'That ship is not yours.',
  invalid_slot: 'That room slot does not exist.',
  unknown_slot: 'That room slot does not exist.',
  unknown_room: 'That room type does not exist.',
  room_duplicate: 'That room already fills another slot on this ship.',
  room_occupied: 'A captain still staffs this room. Unassign them first.',
  unavailable: 'Room configuration is unavailable right now.',
}
export function roomConfigErrorMessage(res: { reason?: string; message?: string }): string {
  return (
    res.message ??
    ROOM_CONFIG_ERROR_COPY[res.reason ?? 'unavailable'] ??
    ROOM_CONFIG_ERROR_COPY.unavailable
  )
}

// ── CAPTAIN-P16 (post-audit UI, panel 4 of 4): recruitment (progression) types ─────────────────────

/** One raw ingredient row of the public-read captain_recipe_ingredients catalog (0125). */
export interface RecipeIngredient {
  captain_type_id: string
  item_id: string
  qty: number
}

/** A recruitable captain type with its ingredient costs, ASSEMBLED CLIENT-SIDE from the public-read
 *  catalogs (captain_recipe_ingredients + captain_types + item_types) — the shipped direct-select
 *  catalog convention; no new server RPC. item_name is the item_types display name. */
export interface CaptainRecipe {
  captain_type_id: string
  name: string
  specialization: string
  ingredients: { item_id: string; item_name: string; qty: number }[]
}

// recruit_captain wrapper envelope (0126). NOTE: unlike the assign/unassign wrappers (reason-keyed),
// the recruit wrapper is CODE-keyed (the 0109 craft-command mirror) — the REAL client codes, enumerated
// from 0126: feature_disabled · not_authenticated · invalid_request (mapped from invalid_request_id) ·
// unknown_captain · no_recipe · insufficient_items (+ item_id/have/need payload) · unavailable. Success
// carries the recruited instance (+ idempotent_replay on a same (player, request_id) replay).
export type RecruitCaptainResult =
  | {
      ok: true
      receipt_id: string
      instance_id: string
      captain_type_id: string
      recruited_at: string
      idempotent_replay?: boolean
    }
  | { ok: false; code?: string; message?: string; item_id?: string; have?: number; need?: number }

// Player-facing copy for the EXACT recruit code set (0126). Prefers the server `message`, else maps the
// code, then appends the insufficient_items shortfall detail (the ModulesPanel craft-error idiom).
const RECRUIT_ERROR_COPY: Record<string, string> = {
  feature_disabled: 'Captain recruitment is not available yet.',
  not_authenticated: 'You must be signed in.',
  invalid_request: 'Invalid command request.',
  unknown_captain: 'Unknown captain.',
  no_recipe: 'This captain cannot be recruited yet.',
  insufficient_items: 'Not enough materials to recruit this captain.',
  unavailable: 'Captain recruitment is unavailable right now.',
}
export function recruitCaptainErrorMessage(res: {
  code?: string
  message?: string
  item_id?: string
  have?: number
  need?: number
}): string {
  const base = res.message ?? RECRUIT_ERROR_COPY[res.code ?? 'unavailable'] ?? RECRUIT_ERROR_COPY.unavailable
  return res.code === 'insufficient_items' && res.item_id
    ? `${base} (${res.item_id}: ${res.have ?? 0}/${res.need ?? 0})`
    : base
}
