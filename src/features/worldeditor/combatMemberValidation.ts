// E4 — COMBAT CONTENT: the PURE client bounds mirror for member sets. ADVISORY ONLY — the E1 server
// RPCs (0258) are the sole authority; this just flags obviously-bad rows in the form before a round-trip
// so the owner sees the problem immediately. It NEVER clamps or mutates a value — it returns an issues[]
// describing what the server would reject, mirroring the flag-don't-clamp law the draft validators use.
// NO React, NO supabase, NO network. Bounds mirror the 0258 proof (scripts/fleet-encounter-profiles-proof.sql):
//   • counts: 0 <= min <= max <= 100
//   • weight: 0 < weight <= 1000
//   • elite_chance: 0 <= elite <= 1
//   • at least one member (members_required)
//   • no duplicate ref within the set (duplicate_member)
import type { EncounterMemberForm, FleetMemberForm } from './combatPayloads'

/** One advisory issue against a member set. `index` points at the offending row (absent = whole set). */
export interface MemberIssue {
  readonly code: string
  readonly index?: number
  readonly message: string
}

const COUNT_MIN = 0
const COUNT_MAX = 100
const WEIGHT_MIN_EXCLUSIVE = 0
const WEIGHT_MAX = 1000
const ELITE_MIN = 0
const ELITE_MAX = 1

const inRangeInclusive = (v: number, lo: number, hi: number): boolean =>
  Number.isFinite(v) && v >= lo && v <= hi

/** Advisory validation of a FLEET template's members (archetype refs + count/weight/elite numerics). */
export function validateFleetMembers(members: readonly FleetMemberForm[]): MemberIssue[] {
  const issues: MemberIssue[] = []
  if (members.length === 0) {
    issues.push({ code: 'members_required', message: 'Add at least one enemy.' })
    return issues
  }
  const seen = new Set<string>()
  members.forEach((m, index) => {
    if (m.enemy_archetype_id.trim() === '') {
      issues.push({ code: 'invalid_archetype_ref', index, message: 'Pick an enemy for this row.' })
    } else if (seen.has(m.enemy_archetype_id)) {
      issues.push({ code: 'duplicate_member', index, message: 'This enemy is already listed above.' })
    } else {
      seen.add(m.enemy_archetype_id)
    }
    if (
      !inRangeInclusive(m.min_count, COUNT_MIN, COUNT_MAX) ||
      !inRangeInclusive(m.max_count, COUNT_MIN, COUNT_MAX) ||
      m.min_count > m.max_count
    ) {
      issues.push({
        code: 'invalid_count_range',
        index,
        message: 'Counts must be 0 to 100, and the low count cannot exceed the high count.',
      })
    }
    if (!(Number.isFinite(m.weight) && m.weight > WEIGHT_MIN_EXCLUSIVE && m.weight <= WEIGHT_MAX)) {
      issues.push({ code: 'invalid_weight', index, message: 'Weight must be more than 0 and at most 1000.' })
    }
    if (!inRangeInclusive(m.elite_chance, ELITE_MIN, ELITE_MAX)) {
      issues.push({ code: 'invalid_elite_chance', index, message: 'Elite chance must be between 0 and 1.' })
    }
  })
  return issues
}

/** Advisory validation of an ENCOUNTER profile's members (fleet refs + weight). */
export function validateEncounterMembers(members: readonly EncounterMemberForm[]): MemberIssue[] {
  const issues: MemberIssue[] = []
  if (members.length === 0) {
    issues.push({ code: 'members_required', message: 'Add at least one fleet.' })
    return issues
  }
  const seen = new Set<string>()
  members.forEach((m, index) => {
    if (m.fleet_template_id.trim() === '') {
      issues.push({ code: 'invalid_fleet_ref', index, message: 'Pick a fleet for this row.' })
    } else if (seen.has(m.fleet_template_id)) {
      issues.push({ code: 'duplicate_member', index, message: 'This fleet is already listed above.' })
    } else {
      seen.add(m.fleet_template_id)
    }
    if (!(Number.isFinite(m.weight) && m.weight > WEIGHT_MIN_EXCLUSIVE && m.weight <= WEIGHT_MAX)) {
      issues.push({ code: 'invalid_weight', index, message: 'Weight must be more than 0 and at most 1000.' })
    }
  })
  return issues
}
