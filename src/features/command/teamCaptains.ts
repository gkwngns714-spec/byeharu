import type { CaptainInstance } from '../captains/captainsTypes'

// TEAM-COMMAND Slice C1 — PURE captain-roster helpers for the team surface (the teamRoster.ts /
// teamSkillset.ts idiom: no I/O, no React, types-only import from the captains feature).
//
// captainsByShip splits the ONE captain roster read (get_my_captain_instances, 0123) into
// per-ship buckets for rendering inside the team roster's ship rows. captainAssignAvailability is
// a DISPLAY-ONLY mirror of the assign command's reject order (0120/0121) — the server stays
// authoritative on ownership / slots / the settled-safe rule; this only lets the UI fail closed
// without a round-trip. PREVIEW_ACTIVITY_TYPES pins the EXACT activity set the group-preview RPC
// accepts (migration 0165 / the 0122 adapter set) — defined ONCE, here. Unit-tested in
// tests/teamCaptains.spec.ts.

export interface CaptainsByShipView {
  // main_ship_id → the captains assigned to that ship, in roster (input) order. A captain whose
  // main_ship_id points at a ship NOT in the caller's roster still buckets under that id — the
  // server's assignment is truth; the client NEVER reclassifies it as unassigned.
  byShip: Map<string, CaptainInstance[]>
  // captains with main_ship_id null, in roster (input) order.
  unassigned: CaptainInstance[]
}

// Split the captain roster on main_ship_id (null → unassigned), PRESERVING input order in every
// bucket. Pure re-shaping of server truth — no filtering, no validity calls.
export function captainsByShip(captains: CaptainInstance[]): CaptainsByShipView {
  const byShip = new Map<string, CaptainInstance[]>()
  const unassigned: CaptainInstance[] = []
  for (const c of captains) {
    if (c.main_ship_id == null) {
      unassigned.push(c)
    } else {
      const list = byShip.get(c.main_ship_id) ?? []
      list.push(c)
      byShip.set(c.main_ship_id, list)
    }
  }
  return { byShip, unassigned }
}

export type CaptainAssignReason =
  | 'ok'
  | 'captains_dark'
  | 'ship_not_settled'
  | 'captain_slots_full'
  | 'already_assigned'

// DISPLAY-ONLY mirror of assign_captain_to_ship's reject order (0120 + the 0121 settled-safe
// rule), with short local reason names (the teamSend/teamStop convention). Reject order: dark
// FIRST → ship_not_settled (0121 wrapper) → already_assigned (writer 0119 step 4) →
// captain_slots_full (writer 0119 step 5) → ok. Note the writer checks the candidate's own
// assignment BEFORE the headcount cap — an already-assigned captain targeting a full ship answers
// already_assigned, and this mirror matches that. Inputs are the caller's already-derived
// booleans: `serverLit` from isServerLit(get_my_captain_instances), `hasFreeSlot` from the
// SERVER-reported captain_slots vs the assigned count (never a hardcoded 2 or 6),
// `captainUnassigned` from the candidate captain's main_ship_id. The server re-checks everything.
export function captainAssignAvailability(input: {
  serverLit: boolean
  shipSettled: boolean
  hasFreeSlot: boolean
  captainUnassigned: boolean
}): { canAssign: boolean; reason: CaptainAssignReason } {
  if (!input.serverLit) return { canAssign: false, reason: 'captains_dark' }
  if (!input.shipSettled) return { canAssign: false, reason: 'ship_not_settled' }
  if (!input.captainUnassigned) return { canAssign: false, reason: 'already_assigned' }
  if (!input.hasFreeSlot) return { canAssign: false, reason: 'captain_slots_full' }
  return { canAssign: true, reason: 'ok' }
}

// EXACTLY the activity set get_my_group_expedition_preview accepts (migration 0165 — the 0122
// calculate_expedition_stats set). The ONE client definition; the preview <select> and the
// availability check both key off it.
export const PREVIEW_ACTIVITY_TYPES = ['pirate_hunt', 'trade_run', 'exploration', 'mining', 'none'] as const

export type PreviewActivityType = (typeof PREVIEW_ACTIVITY_TYPES)[number]

// Case-sensitive exact-set membership — mirrors the server's `in (...)` check verbatim (no trim,
// no case folding: the server does neither).
export function isPreviewActivity(s: string): s is PreviewActivityType {
  return (PREVIEW_ACTIVITY_TYPES as readonly string[]).includes(s)
}
