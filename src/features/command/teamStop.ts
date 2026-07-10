// TEAM-COMMAND Slice B (sub-slice 2) — pure client mirror of stop_ship_group_transit's PRE-READ reject order.
//
// Mirrors only the reject order that gates whether a group-stop is dispatchable at all (gate → group resolved
// → non-empty), the same convention as teamSend.ts. It does NOT mirror per-member outcomes: unlike send,
// group-stop is BEST-EFFORT and always returns ok:true past the pre-read checks, with a server-side
// {stopped, skipped, failed} breakdown that only the server can compute (which members are actually in
// flight). Display-only; the server stays authoritative. No I/O — unit-tested in tests/teamStop.spec.ts.

export type GroupStopReason = 'ok' | 'gate_dark' | 'group_not_found' | 'empty_group'

// Mirrors stop_ship_group_transit: gate → group resolved (owned) → group non-empty → ok. "ok" here means the
// stop is dispatchable; how many members actually halt (vs are already docked/home) is the server's call.
export function groupStopAvailability(input: {
  gateEnabled: boolean
  groupResolved: boolean
  memberCount: number
}): { canStop: boolean; reason: GroupStopReason } {
  if (!input.gateEnabled) return { canStop: false, reason: 'gate_dark' }
  if (!input.groupResolved) return { canStop: false, reason: 'group_not_found' }
  if (input.memberCount <= 0) return { canStop: false, reason: 'empty_group' }
  return { canStop: true, reason: 'ok' }
}
