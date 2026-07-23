// E4 — COMBAT CONTENT: the PURE client bounds mirror + advisory notes for member sets. ADVISORY ONLY — the
// E1 server RPCs (0258) are the sole authority; this just flags obviously-bad rows in the form before a
// round-trip so the owner sees the problem immediately. It NEVER clamps or mutates a value — it returns an
// issues[] describing what the server would reject (severity 'blocking'), plus purely heads-up notes
// (severity 'advisory') that never disable Save. Every result is a FLAG, mirroring the flag-don't-clamp law.
// NO React, NO supabase, NO network. Blocking bounds mirror the 0258 proof (scripts/fleet-encounter-profiles-proof.sql):
//   • counts: 0 <= min <= max <= 100
//   • weight: 0 < weight <= 1000
//   • elite_chance: 0 <= elite <= 1
//   • at least one member (members_required)
//   • no duplicate ref within the set (duplicate_member)
// Advisory notes (non-blocking heads-ups, NOT rejections): runtime wave unit-cap trimming, elite-inert.
import type { EncounterMemberForm, FleetMemberForm } from './combatPayloads'

/** One issue against a member set. `index` points at the offending row (absent = whole set). `severity`
 *  separates BLOCKING bounds problems (the server would reject) from purely ADVISORY heads-up notes that
 *  never disable Save — both are FLAGS, neither ever clamps or mutates. */
export interface MemberIssue {
  readonly code: string
  readonly index?: number
  readonly severity: 'blocking' | 'advisory'
  readonly message: string
}

const COUNT_MIN = 0
const COUNT_MAX = 100
const WEIGHT_MIN_EXCLUSIVE = 0
const WEIGHT_MAX = 1000
const ELITE_MIN = 0
const ELITE_MAX = 1

/** The E3 runtime wave unit cap. The encounter resolver clamps a resolved wave's TOTAL units to
 *  enemy_synthetic_max_units (default 6, per scripts/fleet-encounter-profiles-proof.sql). Hardcoded to the
 *  E3 default on purpose — this advisory reads NO game_config/flag (frontend-only, fail-closed). */
export const RUNTIME_WAVE_UNIT_CAP = 6

const inRangeInclusive = (v: number, lo: number, hi: number): boolean =>
  Number.isFinite(v) && v >= lo && v <= hi

/** Advisory validation of a FLEET template's members (archetype refs + count/weight/elite numerics). */
export function validateFleetMembers(members: readonly FleetMemberForm[]): MemberIssue[] {
  const issues: MemberIssue[] = []
  if (members.length === 0) {
    issues.push({ code: 'members_required', severity: 'blocking', message: 'Add at least one enemy.' })
    return issues
  }
  const seen = new Set<string>()
  members.forEach((m, index) => {
    if (m.enemy_archetype_id.trim() === '') {
      issues.push({ code: 'invalid_archetype_ref', index, severity: 'blocking', message: 'Pick an enemy for this row.' })
    } else if (seen.has(m.enemy_archetype_id)) {
      issues.push({ code: 'duplicate_member', index, severity: 'blocking', message: 'This enemy is already listed above.' })
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
        severity: 'blocking',
        message: 'Counts must be 0 to 100, and the low count cannot exceed the high count.',
      })
    }
    if (!(Number.isFinite(m.weight) && m.weight > WEIGHT_MIN_EXCLUSIVE && m.weight <= WEIGHT_MAX)) {
      issues.push({ code: 'invalid_weight', index, severity: 'blocking', message: 'Weight must be more than 0 and at most 1000.' })
    }
    if (!inRangeInclusive(m.elite_chance, ELITE_MIN, ELITE_MAX)) {
      issues.push({ code: 'invalid_elite_chance', index, severity: 'blocking', message: 'Elite chance must be between 0 and 1.' })
    }
  })
  return issues
}

/** Purely ADVISORY (non-blocking) heads-up notes for a FLEET's members. NEVER rejects — Save stays allowed.
 *  1. runtime_unit_cap: when the fleet's possible total (Σ max_count) exceeds RUNTIME_WAVE_UNIT_CAP, the E3
 *     resolver trims a resolved wave down to the cap, so extra rolled units are silently dropped at runtime.
 *  2. elite_inert: E1 authors elite_chance and E3 rolls is_elite, but E3 applies NO elite stat effect yet —
 *     elite is authored-but-inert today, so a >0 chance is recorded but has no combat consequence.
 *  3. fleet_weight_inert (M2): the E5 resolver (0261) weights ONLY encounter members (line 148 sum(m.weight))
 *     and location bindings (lines 102-103); it never reads a FLEET member's weight — the fleet expands EVERY
 *     active archetype (lines 164-170 select enemy_archetype_id/min_count/max_count/elite_chance, NOT weight).
 *     So a fleet-member weight set away from the neutral 1 is recorded but has no runtime effect yet. */
export function fleetAdvisories(members: readonly FleetMemberForm[]): MemberIssue[] {
  const notes: MemberIssue[] = []
  const maxTotal = members.reduce((sum, m) => sum + (Number.isFinite(m.max_count) ? m.max_count : 0), 0)
  if (maxTotal > RUNTIME_WAVE_UNIT_CAP) {
    notes.push({
      code: 'runtime_unit_cap',
      severity: 'advisory',
      message: `This fleet can roll up to ${maxTotal} units; the runtime caps a wave at ${RUNTIME_WAVE_UNIT_CAP}, so extra units are trimmed.`,
    })
  }
  members.forEach((m, index) => {
    if (Number.isFinite(m.elite_chance) && m.elite_chance > 0) {
      notes.push({
        code: 'elite_inert',
        index,
        severity: 'advisory',
        message: 'Elite chance is recorded but has no combat effect yet.',
      })
    }
    if (Number.isFinite(m.weight) && m.weight !== 1) {
      notes.push({
        code: 'fleet_weight_inert',
        index,
        severity: 'advisory',
        message: 'Recorded, but fleet-member weight has no runtime effect yet.',
      })
    }
  })
  return notes
}

/** Advisory validation of an ENCOUNTER profile's members (fleet refs + weight). */
export function validateEncounterMembers(members: readonly EncounterMemberForm[]): MemberIssue[] {
  const issues: MemberIssue[] = []
  if (members.length === 0) {
    issues.push({ code: 'members_required', severity: 'blocking', message: 'Add at least one fleet.' })
    return issues
  }
  const seen = new Set<string>()
  members.forEach((m, index) => {
    if (m.fleet_template_id.trim() === '') {
      issues.push({ code: 'invalid_fleet_ref', index, severity: 'blocking', message: 'Pick a fleet for this row.' })
    } else if (seen.has(m.fleet_template_id)) {
      issues.push({ code: 'duplicate_member', index, severity: 'blocking', message: 'This fleet is already listed above.' })
    } else {
      seen.add(m.fleet_template_id)
    }
    if (!(Number.isFinite(m.weight) && m.weight > WEIGHT_MIN_EXCLUSIVE && m.weight <= WEIGHT_MAX)) {
      issues.push({ code: 'invalid_weight', index, severity: 'blocking', message: 'Weight must be more than 0 and at most 1000.' })
    }
  })
  return issues
}
