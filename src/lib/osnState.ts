// OSN spatial-state predicates (the 0055 state model) — display/enablement only, NEVER
// authoritative: these drive button enabled-states; the server re-validates every command and
// rejects anything else (fail-closed law). ONE copy (extracted from explorationTypes.ts when
// Mining P12 needed the identical predicate); activity surfaces import from here.

/**
 * Settled in open space (0055 model: spatial_state 'in_space' ⇔ status 'stationary') — the
 * precondition OSN-native activity commands (exploration scan, mining extract) require. Only
 * drives UI enablement; the server remains authoritative (not_in_space).
 */
export function isSettledInSpace(input: {
  spatialState: string | null | undefined
  status: string | null | undefined
}): boolean {
  return input.spatialState === 'in_space' && input.status === 'stationary'
}
