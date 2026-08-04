// TEAM-COMMAND Slice C0 — pure client mirror of get_my_group_expedition_preview's reject order +
// DISPLAY-ONLY team stat totals.
//
// groupPreviewAvailability mirrors the check order of the group-preview RPC (migration 0165) with
// short local reason names, the teamSend/teamStop convention. Display-only: the server stays
// authoritative and re-checks the gate, activity, ownership, and membership.
//
// aggregateTeamStats is DISPLAY-ONLY and NOT server truth: the server RPC deliberately does zero
// stat arithmetic (delegation + collection only), and AUTHORITATIVE team stats are Slice D's job,
// defined beside the combat consumer. This helper only folds the per-member stats the ONE adapter
// (calculate_expedition_stats, migration 0122) already computed into a client-side summary for
// rendering. No I/O — unit-tested in tests/teamSkillset.spec.ts.

import {
  LEGACY_ENVELOPE_STAT_IDS,
  isPlayerVisibleStatId,
} from '../stats/statLifecycle'

export type GroupPreviewReason =
  | 'ok'
  | 'gate_dark'
  | 'invalid_activity'
  | 'group_not_found'
  | 'empty_group'

// Mirrors get_my_group_expedition_preview: gate → activity known → group resolved (owned) → group
// non-empty → ok. "ok" means the preview is requestable; per-member validity is the server's call.
export function groupPreviewAvailability(input: {
  gateEnabled: boolean
  activityKnown: boolean
  groupResolved: boolean
  memberCount: number
}): { canPreview: boolean; reason: GroupPreviewReason } {
  if (!input.gateEnabled) return { canPreview: false, reason: 'gate_dark' }
  if (!input.activityKnown) return { canPreview: false, reason: 'invalid_activity' }
  if (!input.groupResolved) return { canPreview: false, reason: 'group_not_found' }
  if (input.memberCount <= 0) return { canPreview: false, reason: 'empty_group' }
  return { canPreview: true, reason: 'ok' }
}

// Structural subset of the adapter's per-member stats output (migration 0122's jsonb keys). All
// optional: a missing key contributes 0 (never NaN). `speed` is deliberately NOT in the additive
// set — members travel individually, so a team moves at its slowest member's pace (min, below).
export interface MemberStats {
  combat_power?: number
  survival?: number
  repair?: number
  cargo_capacity?: number
  scouting?: number
  mining_yield?: number
  retreat_safety?: number
  pirate_attention?: number
  captain_slots_used?: number
  captain_slots_limit?: number
  speed?: number
}

export type AdditiveStatKey = Exclude<keyof MemberStats, 'speed'>

// The two captain-slot counters are BOOKKEEPING, not stats. The 0122 fold emits them in the same
// jsonb envelope, but they have no stat_definitions row and claim no gameplay benefit — a slot
// count is a fact about a roster, not a number that promises an effect — so they are named here
// rather than derived. This is not a lifecycle list and tests/statLifecycle.spec.ts's scan proves
// it carries no registered stat identifier.
const CAPTAIN_SLOT_KEYS = ['captain_slots_used', 'captain_slots_limit'] as const

// ── STAT LIFECYCLE, CLIENT SIDE — ONE AUTHORITY, NOT A LIST ───────────────────────────────────────
// SPAGHETTI, NAMED AND RIPPED OUT: this module used to carry DORMANT_STAT_KEYS, a hand-written
// mirror of `stat_definitions.lifecycle = 'dormant'`, plus a hand-written ADDITIVE_STAT_KEYS. Two
// files independently deciding which stats are in play is exactly the duplicate authority migration
// 0340 exists to delete, and the owner's ruling forbids it outright: "The frontend must not
// independently maintain a conflicting active-stat allowlist." Both lists are gone. Membership and
// ORDER now come from the registry projection (src/features/stats/statLifecycle.ts), which comes
// from 0340's seed and nowhere else.
//
// WHAT DORMANT MEANS, and why these keys are still summed but never rendered: the server emits them
// on every call (the deployed fold computes all of them) and NOTHING IN THE GAME READS THEM. Showing
// a number under a heading that says "authoritative" tells the player it does something; for a
// dormant stat that is a promise the game does not keep.

// The additive numeric keys summed across valid members: what the 0122 envelope actually CARRIES,
// which is a question about the wire shape, not about lifecycle. Registry-derived in display_order,
// plus the two slot counters. Totals always carry every key, zeroed when absent.
export const ADDITIVE_STAT_KEYS: readonly AdditiveStatKey[] = [
  ...LEGACY_ENVELOPE_STAT_IDS,
  ...CAPTAIN_SLOT_KEYS,
] as readonly AdditiveStatKey[]

// The keys a player is actually shown: the ones the registry says may carry a number at all —
// 'active' (a working benefit) and 'deprecated' (legacy, kept for its existing readers and labelled
// so). Dormant and unknown lifecycles fall out here, at ONE predicate, and can never be re-added by
// editing a list because there is no list. The slot counters are not stats and pass through.
export const EFFECTIVE_STAT_KEYS: readonly AdditiveStatKey[] = ADDITIVE_STAT_KEYS.filter(
  (k) => (CAPTAIN_SLOT_KEYS as readonly string[]).includes(k) || isPlayerVisibleStatId(k),
)

// Structural member shape from the RPC's members[] (only what aggregation needs). `error` is the
// per-member failure detail migration 0165 emits alongside valid:false (a member's validation
// raise, e.g. over-capacity) — display-only; aggregation only reads `valid`.
export interface PreviewMember {
  main_ship_id: string
  valid: boolean
  stats?: MemberStats
  error?: string
}

export interface TeamStatTotals {
  memberCount: number
  validCount: number
  invalidCount: number
  totals: Record<AdditiveStatKey, number>
  // min valid-member speed (members travel individually — the team is as fast as its slowest
  // ship); null when there is no valid member to take a speed from.
  slowestSpeed: number | null
}

// DISPLAY-ONLY totals (see module header — not server truth; Slice D owns authoritative team
// stats). Sums the additive keys across VALID members, skipping (and counting) invalid ones.
// Missing/non-finite values contribute 0 — the result never contains NaN.
export function aggregateTeamStats(members: PreviewMember[]): TeamStatTotals {
  const totals = Object.fromEntries(ADDITIVE_STAT_KEYS.map((k) => [k, 0])) as Record<
    AdditiveStatKey,
    number
  >
  let validCount = 0
  let invalidCount = 0
  let slowestSpeed: number | null = null

  for (const m of members) {
    // Server validity is authoritative — NEVER reclassify. A member the server marked valid:false is
    // the only invalid case; a valid:true member with a missing stats object counts as valid with
    // zero contribution (every key absent → 0, no speed → no slowestSpeed effect), never demoted.
    if (!m.valid) {
      invalidCount += 1
      continue
    }
    validCount += 1
    const stats = m.stats
    if (!stats) continue // valid, but no stats payload → zero contribution (counted valid above)
    for (const k of ADDITIVE_STAT_KEYS) {
      const v = stats[k]
      totals[k] += typeof v === 'number' && Number.isFinite(v) ? v : 0
    }
    const speed = stats.speed
    if (typeof speed === 'number' && Number.isFinite(speed)) {
      slowestSpeed = slowestSpeed === null ? speed : Math.min(slowestSpeed, speed)
    }
  }

  return { memberCount: members.length, validCount, invalidCount, totals, slowestSpeed }
}
