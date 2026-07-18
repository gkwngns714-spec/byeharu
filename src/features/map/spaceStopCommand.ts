// OSN-4 origin, 4A-POST trimmed — the per-ship Stop command surface (RPC shapes, visibility
// predicates, error copy, and the stateful submit controller) was deleted with the per-ship
// movement client; the unified fleet mover (TeamMapStop) owns stopping now. The ONE survivor is
// the legacy-movement selector below, which the consolidated arrival-settle wiring still needs
// while the legacy drain runs (removing the DRAIN path is 4b-DROP's job, not this cleanup's).

/**
 * THE one selector for "the active legacy movement row of the main-ship fleet" (the fleet's single
 * status='moving' fleet_movements row — at most one exists by the 0007 partial unique index).
 * Used by AppShell (the consolidated arrival-settle wiring) so the derivation lives in exactly one
 * place. Generic so each caller keeps its own movement row type.
 */
export function selectActiveLegacyMovement<M extends { fleet_id: string; status: string }>(
  fleet: { id: string } | null | undefined,
  movements: readonly M[],
): M | null {
  return fleet ? (movements.find((mv) => mv.fleet_id === fleet.id && mv.status === 'moving') ?? null) : null
}
