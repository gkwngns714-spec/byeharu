// TEAM-COMMAND Slice B (sub-slice 1) — pure client mirror of send_ship_group_expedition's reject ORDER.
//
// Mirrors the check order of the group-send RPC (migration 0163) using short local reason names (the same
// convention as commissionAvailability/groupUpsertAvailability). Display-only: the server stays authoritative
// and re-checks the gate, ownership, membership, and each per-ship send (the live send's own preconditions —
// ship at home, active-fleet cap, valid destination — are NOT mirrored here; the server owns them and a team
// is all-or-nothing). This lets a future (later sub-slice) team UI disable/hide a "Send team" affordance and
// fail closed without a round-trip. No I/O — unit-tested in tests/teamSend.spec.ts.

export type GroupSendReason = 'ok' | 'gate_dark' | 'group_not_found' | 'empty_group'

// Mirrors send_ship_group_expedition: gate → group resolved (owned) → group non-empty → ok. Note this stops at
// "the send is dispatchable"; whether every member actually launches is the server's all-or-nothing call.
export function groupSendAvailability(input: {
  gateEnabled: boolean
  groupResolved: boolean
  memberCount: number
}): { canSend: boolean; reason: GroupSendReason } {
  if (!input.gateEnabled) return { canSend: false, reason: 'gate_dark' }
  if (!input.groupResolved) return { canSend: false, reason: 'group_not_found' }
  if (input.memberCount <= 0) return { canSend: false, reason: 'empty_group' }
  return { canSend: true, reason: 'ok' }
}
