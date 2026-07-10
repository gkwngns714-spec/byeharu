// TEAM-COMMAND Slice B0 — pure client mirror of the group WRITE RPCs' reject ORDER.
//
// Mirrors the check ORDER of upsert_ship_group / assign_ship_to_group (migration 0161), using short local
// reason names (the same convention as commissionAvailability in teamRoster.ts — NOT the literal server
// strings). Display-only: the server stays authoritative and re-checks everything; these let a future (Slice B)
// team UI disable/hide affordances and fail closed without a round-trip. No I/O here — unit-tested in
// tests/teamMutations.spec.ts. Note: `.trim()` uses JS whitespace semantics vs the server's SQL `btrim`; a
// borderline whitespace-only name is decided authoritatively by the server, not this mirror.

export type GroupUpsertReason = 'ok' | 'gate_dark' | 'invalid_group_index' | 'invalid_name'

// Mirrors upsert_ship_group: gate → group_index ∈ 1..3 → name char length 1..40 (after trim) → ok.
export function groupUpsertAvailability(input: {
  gateEnabled: boolean
  groupIndex: number
  name: string
}): { canUpsert: boolean; reason: GroupUpsertReason } {
  if (!input.gateEnabled) return { canUpsert: false, reason: 'gate_dark' }
  if (!Number.isInteger(input.groupIndex) || input.groupIndex < 1 || input.groupIndex > 3)
    return { canUpsert: false, reason: 'invalid_group_index' }
  const clean = input.name.trim()
  if (clean.length < 1 || clean.length > 40) return { canUpsert: false, reason: 'invalid_name' }
  return { canUpsert: true, reason: 'ok' }
}

export type AssignReason = 'ok' | 'gate_dark' | 'ship_not_found' | 'group_not_found'

// Mirrors assign_ship_to_group: gate → ship resolved → (only if a group was requested) group owned → ok.
// `groupId === null` means UNASSIGN — always allowed once the gate is on and the ship resolves; it is NEVER
// routed through resolveOwnedGroup (teamRoster.ts), whose sole-group shim would mis-read null as "the sole
// group". Keep this branch independent so a future DRY refactor cannot collapse the two.
export function assignAvailability(input: {
  gateEnabled: boolean
  shipResolved: boolean
  groupId: string | null
  ownedGroupIds: string[]
}): { canAssign: boolean; reason: AssignReason } {
  if (!input.gateEnabled) return { canAssign: false, reason: 'gate_dark' }
  if (!input.shipResolved) return { canAssign: false, reason: 'ship_not_found' }
  if (input.groupId != null && !input.ownedGroupIds.includes(input.groupId))
    return { canAssign: false, reason: 'group_not_found' }
  return { canAssign: true, reason: 'ok' }
}
