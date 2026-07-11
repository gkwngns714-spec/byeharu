// Combat — the ONE label helper for combat jsonb keys / unit identities (UI R4/D4 follow-up).
//
// Server-side, tick/report jsonb keys and combat_units identities are `coalesce(unit_type_id,
// main_ship_id::text)` (Slice D1, migration 0167): a legacy catalog slug ('scout', 'corvette', …)
// XOR a team-member main-ship uuid. This helper resolves the catalog name FIRST (byte-identical to
// the pre-D4 behavior for every legacy key), then falls back to a friendly "Team ship xxxxxxxx"
// label for uuid-shaped member keys instead of leaking a raw uuid. Member keys are DATA-DARK today
// (their only writer is flag-gated), so live rendering is unchanged. Defined ONCE — RoundLog,
// ActiveCombatPanel, and ReportsSection all consume this; never re-implement per surface.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function combatUnitLabel(id: string, unitTypes: { id: string; name: string }[]): string {
  return unitTypes.find((t) => t.id === id)?.name ?? (UUID_RE.test(id) ? `Team ship ${id.slice(0, 8)}` : id)
}
